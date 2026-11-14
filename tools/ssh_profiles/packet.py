"""New SSH-profile packet; never resets prior B11/server/runtime allowances."""
import hashlib
from contextlib import ExitStack
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import development as d
import dev

TOOLING = REPO / '.build/ssh-profile-tooling'
TOOLCHAIN = REPO / '.build/b06-toolchain/rust-1.99.1'
MIB = 1 << 20


def directory(path):
    path.relative_to(REPO / '.build')
    current = REPO
    for part in path.relative_to(REPO).parts:
        if part in ['', '.', '..']:
            raise RuntimeError('Invalid owned SSH-profile path')
        current /= part
        current.mkdir(mode=0o700, exist_ok=True)
        found = current.lstat()
        if not stat.S_ISDIR(found.st_mode) or found.st_uid != os.getuid():
            raise RuntimeError('Redirected SSH-profile build path')
    return path


def prepare():
    directory(TOOLING)
    marker = TOOLING / 'packet.json'
    expected = {'packet': 'ssh-profiles-tooling-v1', 'maximumAllocatedBytes': 2 << 30,
                'oldDevelopmentLimitBytes': 2 << 30, 'oldReleaseToolingLimitBytes': 4 << 30,
                'oldB11ToolingLimitBytes': 2 << 30}
    if marker.exists():
        if marker.is_symlink() or json.loads(marker.read_text()) != expected:
            raise RuntimeError('SSH-profile tooling marker mismatch')
    else:
        d.put(marker, expected)
    for area in ['swift', 'clang', 'tmp']:
        directory(TOOLING / area)


def _with_profile_limit(value):
    own = d.measure(TOOLING)
    if own['allocatedBytes'] > 2 << 30 or own['entries'] > 32768:
        raise RuntimeError('SSH-profile isolated tooling limit reached')
    value['sshProfileTooling'] = own
    return value


def audit():
    # Existing qualification callers retain the legacy development ledger.
    return _with_profile_limit(d.audit())


def completion_helper_audit():
    # Only the separately gated Stage5 ordinary-helper build calls this.
    import completion_resources_2026_10_29 as completion
    if Path(completion.__file__).resolve() != REPO / 'tools/completion_resources_2026_10_29.py':
        raise RuntimeError('Completion audit module changed')
    return _with_profile_limit(completion.audit())


def environment(root):
    value = dev.environment(tooling=False)
    value.update(CFFIXED_USER_HOME=str(directory(root / 'cache/user')),
                 CLANG_MODULE_CACHE_PATH=str(TOOLING / 'clang'),
                 SWIFTPM_MODULECACHE_OVERRIDE=str(TOOLING / 'swift'),
                 TMPDIR=str(TOOLING / 'tmp'))
    if (root/'source/StateFixtures').is_dir():
        value['MAC_EXPLORER_SSH_PROFILE_STATE_ROOT'] = str(root/'source/StateFixtures')
        value['MAC_EXPLORER_B12_SOURCE'] = str(root/'source/StateFixtures')
        value['MAC_EXPLORER_B12_UPLOAD_SOURCE'] = str(root/'source/StateFixtures')
    if (root/'source/AdaptiveReplayFixtures').is_dir():
        value['MAC_EXPLORER_ADAPTIVE_REPLAY_ROOT'] = str(root/'source/AdaptiveReplayFixtures')
    if (root/'source/FolderFixtures').is_dir():
        value['TRAVERSE_FOLDER_DOWNLOAD_TEST_ROOT'] = str(root)
    if (root/'source/UploadFixtures').is_dir():
        value['TRAVERSE_EXCLUSIVE_UPLOAD_TEST_ROOT'] = str(root)
        value['MAC_EXPLORER_B12_UPLOAD_SOURCE'] = str(root/'source/UploadFixtures')
    if (root/'source/ZIPExportFixtures').is_dir():
        value['TRAVERSE_ZIP_ROOT_EXPORT_ROOT'] = str(root)
    return value


def rust_environment(root):
    # Public registry/toolchain only; no inherited Cargo tokens, agent sockets,
    # credentials, shell settings or global cache lookup.
    return dict(PATH=str(TOOLCHAIN / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
                CARGO_HOME=str(directory(TOOLING / 'cargo-home')),
                RUSTUP_HOME=str(directory(TOOLING / 'rustup-home')),
                RUSTC=str(TOOLCHAIN / 'bin/rustc'), RUSTDOC=str(TOOLCHAIN / 'bin/rustdoc'),
                CARGO_TARGET_DIR=str(directory(TOOLING / 'target')), CARGO_INCREMENTAL='0', CARGO_BUILD_JOBS='4',
                CARGO_REGISTRIES_CRATES_IO_PROTOCOL='sparse', MACOSX_DEPLOYMENT_TARGET='15.0',
                TMPDIR=str(TOOLING / 'tmp'), LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')


def exiting_child_after_denied_signal(child, seconds=.5):
    """macOS can deny signalling an already-exiting group. Require wait4 proof.

    Never turn EPERM alone into completion or retry against a different PID.
    Returns status/RSS only after reaping this exact direct child.
    """
    until=time.monotonic()+seconds
    while True:
        found,status,stats=os.wait4(child.pid,os.WNOHANG)
        if found:
            child.returncode=os.waitstatus_to_exitcode(status)
            return status,stats
        if time.monotonic()>=until:return None
        time.sleep(.01)


def dispose_owned_child(child):
    if child.stdin is not None and not child.stdin.closed:
        child.stdin.close()
    if child.returncode is not None:
        return
    began = time.monotonic()
    for delay, sig in [(0, signal.SIGTERM), (3, signal.SIGKILL)]:
        while time.monotonic() - began < delay:
            found, status, _ = os.wait4(child.pid, os.WNOHANG)
            if found:
                child.returncode = os.waitstatus_to_exitcode(status)
                return
            time.sleep(.02)
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            if exiting_child_after_denied_signal(child) is not None:return
            raise RuntimeError('Exact owned child remains after denied signal; completion unavailable')
    while time.monotonic() - began < 8:
        found, status, _ = os.wait4(child.pid, os.WNOHANG)
        if found:
            child.returncode = os.waitstatus_to_exitcode(status)
            return
        time.sleep(.02)
    raise RuntimeError('Owned SSH-profile child has not exited')


def run(command, root, label, timeout=300, input_bytes=None, cwd=REPO, rust=False, native=False,
        observer=None, independent_observer=False, *, controlled_stdin=False):
    """Own one generated process group, bounded outputs, actual exit and RSS.

    A controlled native child may receive at most two observer-supplied
    messages of at most 128 bytes each through its already-owned stdin pipe.
    """
    if input_bytes is not None and len(input_bytes) > MIB:
        raise RuntimeError('Generated tool input cap')
    if independent_observer and observer is None:
        raise RuntimeError('Independent observation requires an explicit bounded callback')
    if controlled_stdin and (input_bytes is not None or observer is None
                             or independent_observer or not native):
        raise RuntimeError('Controlled native input requires one direct observer')
    stdout = root / 'evidence' / (label + '.stdout')
    stderr = root / 'evidence' / (label + '.stderr')
    began = time.monotonic()
    failure = None
    stopping = None
    forced = False
    retries = 0
    measurement_failure = None
    owned_observer = None
    with stdout.open('xb') as out, stderr.open('xb') as err, ExitStack() as cleanup:
        env = rust_environment(root) if rust else environment(root)
        if native:
            env.update(MAC_EXPLORER_TEST_ROOT=str(root), MAC_EXPLORER_STATE_ROOT=str(root/'state'), MAC_EXPLORER_CACHE_ROOT=str(root/'cache'))
        child = subprocess.Popen(command, cwd=cwd, env=env,
                                 stdin=subprocess.PIPE if input_bytes is not None or controlled_stdin else subprocess.DEVNULL,
                                 stdout=out, stderr=err, start_new_session=True)
        cleanup.callback(dispose_owned_child, child)
        d.put(root/'evidence'/(label+'.started.json'),dict(pid=child.pid,ownedGroup=child.pid,directChild=True))
        if independent_observer:
            from owned_observer import OwnedObserver
            owned_observer = OwnedObserver(child, observer)
            # LIFO cleanup joins the real callback before another helper is
            # allowed to reap/dispose the exact Popen object and its PID.
            cleanup.callback(owned_observer.close)
        offset = 0
        control_pending = b''; control_offset = 0
        control_messages = 0; control_messages_sent = 0; control_bytes = 0
        if input_bytes is not None or controlled_stdin:
            os.set_blocking(child.stdin.fileno(), False)
        last_check = 0
        while True:
            found, status, stats = owned_observer.reap() if owned_observer is not None else os.wait4(child.pid, os.WNOHANG)
            if found:
                child.returncode = os.waitstatus_to_exitcode(status)
                break
            now = time.monotonic()
            if owned_observer is not None and owned_observer.failure is not None and failure is None:
                failure = 'Independent child observer failed'
            if observer is not None and not independent_observer and failure is None:
                message = observer(child.pid)
                if controlled_stdin and message is not None:
                    if type(message) is not bytes or not 0 < len(message) <= 128 \
                            or control_messages >= 2 or control_pending:
                        raise RuntimeError('Controlled native input bound or sequence differs')
                    control_pending = message
                    control_messages += 1
            if input_bytes is not None and not child.stdin.closed:
                try:
                    if offset < len(input_bytes):
                        offset += os.write(child.stdin.fileno(), input_bytes[offset:offset+8192])
                    if offset == len(input_bytes):
                        child.stdin.close()
                except BlockingIOError:
                    pass
                except BrokenPipeError:
                    child.stdin.close()
                    if failure is None:
                        failure = 'Generated process closed bounded input early'
            if controlled_stdin and control_pending and not child.stdin.closed:
                try:
                    control_offset += os.write(child.stdin.fileno(),
                                               control_pending[control_offset:])
                    if control_offset == len(control_pending):
                        control_bytes += control_offset
                        control_messages_sent += 1
                        control_pending = b''; control_offset = 0
                except BlockingIOError:
                    pass
                except BrokenPipeError:
                    child.stdin.close()
                    if failure is None:
                        failure = 'Generated process closed controlled input early'
            if failure is None and (now - began > timeout or stdout.stat().st_size + stderr.stat().st_size > 4 * MIB):
                failure = 'Generated process deadline/output bound'
            if failure is None and now - last_check > .5:
                try:
                    # Snapshot races are retried as a whole, never undercounted.
                    for attempt in range(3):
                        try:
                            audit()
                            if d.measure(root)['bytes'] > 128 * MIB:
                                raise RuntimeError('SSH-profile case bound')
                            break
                        except FileNotFoundError as error:
                            path = Path(error.filename or '')
                            owned = path.is_relative_to(root / 'cache')
                            owned |= any(str(path).startswith(str(TOOLING / area) + '/')
                                         for area in ['swift', 'clang', 'target', 'native-contracts', 'adaptive-contracts', 'tmp'])
                            owned |= retryable_generated_history_path(path,root)
                            # Cargo atomically replaces owned object/dep-info
                            # outputs, not only files ending in .tmp. Retry the
                            # WHOLE accounting snapshot; never skip that entry.
                            if not owned or attempt == 2:
                                raise
                            retries += 1
                            time.sleep(.01)
                except Exception as error:
                    path=Path(getattr(error,'filename','')or'')
                    measurement_failure={'type':type(error).__name__,'ownedCaseCache':path.is_relative_to(root/'cache'),'ownedTooling':path.is_relative_to(TOOLING)}
                    if path.is_relative_to(root):measurement_failure['relativeCasePath']=str(path.relative_to(root))
                    elif path.is_relative_to(TOOLING):measurement_failure['relativeToolingPath']=str(path.relative_to(TOOLING))
                    failure = type(error).__name__ + ': resource measurement or bound'
                last_check = now
            if failure is not None and stopping is None:
                stopping = now
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    if owned_observer is not None: owned_observer.close()
                    exited=exiting_child_after_denied_signal(child)
                    if exited is None:raise RuntimeError('Exact owned child remains after denied stop')
                    status,stats=exited;break
            if stopping is not None and now - stopping > 3 and not forced:
                forced = True
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    if owned_observer is not None: owned_observer.close()
                    exited=exiting_child_after_denied_signal(child)
                    if exited is None:raise RuntimeError('Exact owned child remains after denied containment')
                    status,stats=exited;break
            if stopping is not None and now - stopping > 8:
                raise RuntimeError('Owned SSH-profile process group remains')
            time.sleep(.02)
    if child.stdin is not None and not child.stdin.closed:
        child.stdin.close()
    if controlled_stdin and control_pending and failure is None:
        failure = 'Generated controlled input was not delivered'
    if owned_observer is not None and owned_observer.failure is not None and failure is None:
        failure = 'Independent child observer failed'
    result = {'passed': child.returncode == 0 and failure is None, 'actualExit': child.returncode,
              'seconds': time.monotonic() - began, 'peakRSSBytes': stats.ru_maxrss,
              'contained': stopping is not None, 'forced': forced, 'failure': failure,
              'measurementFailure': measurement_failure, 'measurementRetries': retries,
              'stdoutSHA256': hashlib.sha256(stdout.read_bytes()).hexdigest(),
              'stderrSHA256': hashlib.sha256(stderr.read_bytes()).hexdigest()}
    if owned_observer is not None: result['observer'] = owned_observer.proof()
    if controlled_stdin:
        result['controlledStdinMessages'] = control_messages_sent
        result['controlledStdinBytes'] = control_bytes
    d.put(root / 'evidence' / (label + '.process.json'), result)
    return result, stdout, stderr


def retryable_generated_history_path(path,root):
    """Only a marked J test's atomic history marker may retry a full snapshot.

    Nothing is omitted from accounting. A third failed snapshot still stops the
    exact child; missing source data, other jobs and personal paths stay errors.
    """
    try:
        parts=path.relative_to(root/'source/UploadFixtures').parts
        if len(parts)!=3 or str(__import__('uuid').UUID(parts[0])).upper()!=parts[0]or parts[1:]!=('upload-history','pending.json'):return False
        if root.parent!=d.ROOT or root.resolve()!=root:return False
        marker=json.loads((root/'reservation.json').read_bytes());inputs=json.loads((root/'inputs.json').read_bytes())
        return marker.get('action')=='routed-folder-upload-local-contracts'and marker.get('packet')=='traverse-development-v1'and inputs.get('routedFolder')is True
    except(ValueError,OSError,KeyError):return False
