#!/usr/bin/env python3
"""Root-only standalone native regression; all boards/fixtures are generated.

The ignored draft is execution-refused. After review/promotion root may open the
explicit gate. No general pasteboard, App launch, owner files or cleanup.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time
import uuid

EXECUTION_REVIEWED = True
ROOT = Path(__file__).resolve().parents[1]
MARKER = b'mac-explorer-clipboard-publication-v1\n'
NOISE = b'sandbox_extension_consume failed: 1'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked(path, *, directory=False, private=False):
    # No symlink component, including ancestors of the trusted checkout.
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise RuntimeError('symlinkComponent')
    info = path.lstat()
    if directory != stat.S_ISDIR(info.st_mode):
        raise RuntimeError('entryKind')
    if info.st_uid != os.getuid():
        raise RuntimeError('entryOwner')
    if not directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
        raise RuntimeError('entryLinks')
    if private and stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise RuntimeError('entryMode')
    return info


def fresh_dir(path):
    path.mkdir(mode=0o700)
    checked(path, directory=True, private=True)


def exclusive_write(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(data)
    checked(path, private=True)


def main():
    parser = argparse.ArgumentParser()
    parser.parse_args()
    if not EXECUTION_REVIEWED:
        raise SystemExit('executionRefused: draft requires root review/promotion')
    checked(ROOT, directory=True)
    if not (ROOT / 'App/MacExplorer/Browser/BrowserViewController.swift').is_file():
        raise SystemExit('trustedRepositoryLayout')
    build = ROOT / '.build'
    checked(build, directory=True)
    base = build / 'clipboard-publication-qualification'
    if not base.exists():
        fresh_dir(base)
        exclusive_write(base / '.owner', b'mac-explorer-clipboard-publication-runs-v1\n')
    checked(base, directory=True, private=True)
    checked(base / '.owner', private=True)
    if (base / '.owner').read_bytes() != b'mac-explorer-clipboard-publication-runs-v1\n':
        raise RuntimeError('unmarkedRoot')
    # Retained namespace cap; no adoption, cleanup or existing-run mutation.
    retained = 0
    with os.scandir(base) as entries:
        for index, entry in enumerate(entries):
            if index >= 65:
                raise RuntimeError('retainedRunCap')
            if entry.name != '.owner':
                if str(uuid.UUID(entry.name)) != entry.name:
                    raise RuntimeError('retainedRunName')
                checked(Path(entry.path), directory=True, private=True)
                retained += 1
        if retained >= 64:
            raise RuntimeError('newRunCap')
    run = base / str(uuid.uuid4())
    fresh_dir(run)
    report = {'schema': 1, 'ok': False, 'gate': 'reviewed', 'commands': [], 'sources': [], 'cases': []}
    report_path = run / 'report.json'
    stage = 'snapshot'
    try:
        snapshot = run / 'sources'; fresh_dir(snapshot)
        cache = run / 'module-cache'; fresh_dir(cache)
        temp = run / 'tmp'; fresh_dir(temp)
        fixtures = run / 'fixtures'; fresh_dir(fixtures)
        helper = ROOT / 'App/MacExplorer/Browser/BrowserClipboard.swift'
        worker = ROOT / 'tools/ClipboardPublicationWorker.swift'
        frozen_files = []
        binary_proof = None

        def identity(info):
            return (info.st_dev, info.st_ino, info.st_uid, info.st_mode, info.st_nlink,
                    info.st_size, info.st_mtime_ns)

        for source, name in ((helper, helper.name), (worker, worker.name), (Path(__file__).resolve(), 'runner.py')):
            checked(source)
            data = source.read_bytes()
            if len(data) > 128 * 1024:
                raise RuntimeError('sourceBound')
            target = snapshot / name
            exclusive_write(target, data)
            expected = digest(data)
            frozen_files.append((source, target, expected, identity(checked(source)), identity(checked(target, private=True))))
            report['sources'].append({'relative': str(source.relative_to(ROOT)), 'snapshot': name, 'sha256': expected})

        def verify_frozen():
            for source, target, expected, source_identity, snapshot_identity in frozen_files:
                source_info = checked(source)
                target_info = checked(target, private=True)
                if (identity(source_info) != source_identity or identity(target_info) != snapshot_identity
                        or source_info.st_size > 128 * 1024 or target_info.st_size > 128 * 1024
                        or digest(source.read_bytes()) != expected or digest(target.read_bytes()) != expected):
                    raise RuntimeError('frozenSourceChanged')
            if binary_proof is not None:
                expected_hash, expected_identity = binary_proof
                info = checked(binary)
                if identity(info) != expected_identity or digest(binary.read_bytes()) != expected_hash:
                    raise RuntimeError('frozenBinaryChanged')
        compiler = '/usr/bin/xcrun'
        binary = run / 'worker'
        environment = os.environ.copy()
        environment.update({'TMPDIR': str(temp), 'CLANG_MODULE_CACHE_PATH': str(cache),
                            'SWIFT_MODULECACHE_PATH': str(cache)})

        def command(argv, label, timeout):
            verify_frozen()
            started = time.monotonic()
            timed_out = None
            result = None
            try:
                result = subprocess.run(argv, cwd=ROOT, env=environment, capture_output=True, timeout=timeout)
                stdout, stderr = result.stdout, result.stderr
            except subprocess.TimeoutExpired as error:
                # subprocess.run has killed and waited for this owned child.
                # Preserve raw partial output and receipt before rethrowing.
                timed_out = error
                stdout, stderr = error.stdout or b'', error.stderr or b''
            frozen_error = None
            try:
                verify_frozen()
            except Exception as error:
                frozen_error = error
            exclusive_write(run / (label + '.stdout'), stdout)
            exclusive_write(run / (label + '.stderr'), stderr)
            record = {'label': label, 'argv': argv, 'status': result.returncode if result is not None else None,
                      'timedOut': timed_out is not None, 'timeoutSeconds': timeout,
                      'frozenBefore': True, 'frozenAfter': frozen_error is None,
                      'milliseconds': (time.monotonic() - started) * 1000,
                      'stdoutSHA256': digest(stdout), 'stderrSHA256': digest(stderr),
                      'consumeErrorCount': stderr.count(NOISE)}
            report['commands'].append(record)
            exclusive_write(run / (label + '.receipt.json'),
                            json.dumps(record, sort_keys=True, indent=2).encode() + b'\n')
            if timed_out is not None:
                raise timed_out
            if frozen_error is not None:
                raise frozen_error
            return result, record

        stage = 'compile'
        result, _ = command([compiler, 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                             '-DDEBUG', '-parse-as-library', '-module-cache-path', str(cache),
                             str(snapshot / helper.name), str(snapshot / worker.name), '-o', str(binary)],
                            'compile', 180)
        if result.returncode:
            raise RuntimeError('compile')
        checked(binary)
        report['binarySHA256'] = digest(binary.read_bytes())
        binary_proof = (report['binarySHA256'], identity(checked(binary)))
        verify_frozen()
        # Two causal first-read controls in fresh processes, no log filtering.
        cases = [('owned', 1, 0), ('owned', 33, 0), ('owned', 1024, 0),
                 ('nativeFirst', 2, 2), ('rawFirst', 2, 2), ('largeUnowned', 1025, None), ('semantics', 2, None)]
        for ordinal, (mode, count, expected_noise) in enumerate(cases):
            stage = mode
            fixture = fixtures / str(uuid.uuid4()); fresh_dir(fixture)
            source = fixture / 'source'; fresh_dir(source)
            exclusive_write(fixture / '.clipboard-publication-fixture', MARKER)
            for member in range(count):
                exclusive_write(source / f'generated-{member}.dat', b'x')
            result, record = command([str(binary), mode, str(fixture), str(count)], f'{ordinal:02d}-{mode}', 60)
            try:
                actual = json.loads(result.stdout)
            except (ValueError, UnicodeError) as error:
                raise RuntimeError('workerJSON') from error
            expected = {'mode': mode, 'count': count, 'expectedConsumeErrorCount': expected_noise,
                        'actual': actual, 'actualConsumeErrorCount': record['consumeErrorCount']}
            report['cases'].append(expected)
            if result.returncode or actual.get('ok') is not True or actual.get('count') != count:
                raise RuntimeError('workerAssertion')
            if mode == 'largeUnowned' and (actual.get('unownedNativePublication') is not True
                                            or actual.get('ownedReceipt') is not False
                                            or actual.get('nativeDecoderRoute') is not True):
                raise RuntimeError('largePublicationOracle')
            if expected_noise is not None and record['consumeErrorCount'] != expected_noise:
                raise RuntimeError('nativeNoiseOracle')
        verify_frozen()
        report['ok'] = True
    except Exception as error:
        # Constant error kind, no exception path/content text.
        report['failure'] = {'stage': stage, 'kind': type(error).__name__}
    finally:
        exclusive_write(report_path, json.dumps(report, sort_keys=True, indent=2).encode() + b'\n')
    print(json.dumps({'ok': report['ok'], 'report': str(report_path)}))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    try:
        result = main()
    except Exception:
        print(json.dumps({'ok': False, 'stage': 'admission', 'error': 'unsafeOrUnavailable'}))
        result = 1
    raise SystemExit(result)
