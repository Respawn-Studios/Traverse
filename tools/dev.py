#!/usr/bin/env python3
"""Reproducible, checkout-isolated development commands. No third-party tools."""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
import plistlib
import re
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import time
import uuid
import zipfile

sys.dont_write_bytecode = True
from generate_project import generate
from runtime_diagnostics import inspect as inspect_runtime_diagnostics
from native_build_inputs import product_inputs, source_inputs
from distribution.release_notes import verify_bundled as verify_release_notes
from distribution.artifact_files import read as read_artifact
from build_architecture import ARCHITECTURES, host, named

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
APP = BUILD / "xcode/Build/Products/Debug/Mac Explorer.app"
MARKER = ".mac-explorer-fixture.json"
FIXTURE_VERSION = 1


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")


def local_directory(relative: str) -> Path:
    """Refuse symlink redirection of any generated/cache/output directory."""
    path = BUILD
    for segment in ("", *Path(relative).parts):
        if segment:
            path /= segment
        if path.is_symlink():
            raise ValueError(f"Refusing a redirected development directory: {path}")
        path.mkdir(exist_ok=True)
        if not path.is_dir():
            raise ValueError(f"Development path is not a directory: {path}")
    return path


def private_runtime_directory(name: str) -> Path:
    """Prepare only the two app-owned leaves that hold private development data."""
    if name not in ("runtime", "runtime-cache"):
        raise ValueError("Unknown private development directory")
    local_directory("")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    base_fd = os.open(BUILD, flags)
    try:
        if os.fstat(base_fd).st_uid != os.geteuid():
            raise ValueError("Development build root has a different owner")
        try:
            os.mkdir(name, mode=0o700, dir_fd=base_fd)
        except FileExistsError:
            pass
        try:
            leaf_fd = os.open(name, flags, dir_fd=base_fd)
        except OSError as error:
            raise ValueError("Private development directory is redirected or unavailable") from error
        try:
            before = os.fstat(leaf_fd)
            if not stat.S_ISDIR(before.st_mode) or before.st_uid != os.geteuid():
                raise ValueError("Private development directory has a different owner or type")
            if stat.S_IMODE(before.st_mode) != 0o700:
                os.fchmod(leaf_fd, 0o700)
            after = os.fstat(leaf_fd)
            named = os.stat(name, dir_fd=base_fd, follow_symlinks=False)
            if not stat.S_ISDIR(after.st_mode) or after.st_uid != os.geteuid() \
                    or stat.S_IMODE(after.st_mode) != 0o700 \
                    or (named.st_dev, named.st_ino) != (after.st_dev, after.st_ino):
                raise ValueError("Private development directory changed during preparation")
        finally:
            os.close(leaf_fd)
    finally:
        os.close(base_fd)
    return BUILD / name


def environment(*, tooling: bool = True) -> dict[str, str]:
    env = os.environ.copy()
    env.update({
        "TMPDIR": str(local_directory("tmp")) + "/",
        "MAC_EXPLORER_STATE_ROOT": str(private_runtime_directory("runtime")),
        "MAC_EXPLORER_CACHE_ROOT": str(private_runtime_directory("runtime-cache")),
        "MAC_EXPLORER_TEST_ROOT": str(local_directory("test-fixtures")),
    })
    if tooling:
        env.update({
            # Foundation's per-process user directory confines Xcode's
            # embedded SwiftPM caches/discovery. HOME itself is untouched.
            "CFFIXED_USER_HOME": str(local_directory("xcode-user")),
            "CLANG_MODULE_CACHE_PATH": str(local_directory("compiler-cache/clang")),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(local_directory("compiler-cache/swift")),
            "SWIFTPM_NETRC_DATA": "",
        })
    else:
        # The running browser must see the real user's Home/Favorites. Never
        # pass the build-only Foundation shim into the application process.
        env.pop("CFFIXED_USER_HOME", None)
    return env


def execute(arguments: list[str], label: str, timeout: int | None = None,
            *, tooling: bool = True, awaits_report: bool = False, fixture_root: Path | None = None) -> Path:
    env = environment(tooling=tooling)
    if fixture_root is not None:
        fixture_root = fixture_root.absolute()
        case = fixture_root.parent
        if fixture_root.name != 'source' or case.parent != BUILD / 'overnight-foundation' \
            or str(uuid.UUID(case.name)).upper() != case.name or fixture_root.resolve() != fixture_root \
            or not fixture_root.is_dir() or not (case / 'reservation.json').is_file() or (case / 'reservation.json').is_symlink():
            raise ValueError('A reserved generated foundation source root is required')
        env['MAC_EXPLORER_TEST_ROOT'] = str(fixture_root)
    log = local_directory("logs") / f"{label}-{stamp()}.log"
    started = time.monotonic()
    print(f"{label}: running; log {log}", flush=True)
    with log.open("xb") as output:
        try:
            result = subprocess.run(arguments, cwd=ROOT, env=env, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"{label} timed out; full output: {log}") from error
    if result.returncode:
        # Logs contain build diagnostics and fixture-only verification output. Keep
        # console output compact; the full ignored file remains inspectable.
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if re.search(r"\b(?:fatal )?error:", line)]
        excerpt = errors[-12:] + lines[-8:] if errors else lines[-24:]
        print("\n".join(line if len(line) <= 400 else line[:400] + " …" for line in excerpt), file=sys.stderr)
        raise RuntimeError(f"{label} failed ({result.returncode}); full output: {log}")
    verdict = "process completed" if awaits_report else "passed"
    print(f"{label}: {verdict} in {time.monotonic() - started:.2f}s; log {log}")
    return log


def check_source_backups() -> None:
    # Xcode's synchronized groups can copy an untracked editor backup as a
    # resource. Git's ignore policy alone does not prevent shipping that file.
    if any(path.is_file() and (path.suffix in (".orig", ".rej", ".bak") or path.name.endswith("~"))
           for path in (ROOT / "App/MacExplorer").rglob("*")):
        raise RuntimeError("Move source backups into an ignored build root before building the app.")


def build(*, preserve_project: bool = True, configuration: str = "debug", architecture: str | None = None) -> None:
    if configuration not in ("debug", "release"):
        raise ValueError("Unknown native build configuration")
    target = host() if architecture is None else named(architecture)
    check_source_backups()
    verify_release_notes()
    # Check reviewed generated inputs before paying for a native compile.
    # Embedding repeats these guards; neither step silently regenerates them.
    execute([sys.executable, "-B", str(ROOT / "tools/smb_reader/vendor_verified_source.py")],
            "verify-network-provenance", timeout=30, tooling=False)
    from distribution.notices import verify_outputs
    verify_outputs()
    from build_crash_reporter import prepare as prepare_crash_reporter
    prepare_crash_reporter()
    if not preserve_project or not (ROOT / "MacExplorer.xcodeproj/project.pbxproj").is_file():
        generate()
    derived = local_directory("xcode" if configuration == "debug" else "xcode-release")
    application = derived / "Build/Products" / configuration.title() / "Mac Explorer.app"
    packages = local_directory("source-packages")
    result = local_directory("results") / f"build-{stamp()}.xcresult"
    sources = source_inputs()
    build_log = execute([
        "xcodebuild", "-project", str(ROOT / "MacExplorer.xcodeproj"),
        "-scheme", "MacExplorer", "-configuration", configuration.title(), "-destination", f"platform=macOS,arch={target.name}",
        "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
        "-resultBundlePath", str(result), "-skipPackageUpdates", "-disableAutomaticPackageResolution",
        "-disablePackageRepositoryCache", "-packageCachePath", str(local_directory("package-cache")),
        "-packageAuthorizationProvider", "netrc", "-jobs", "4",
        "CODE_SIGN_STYLE=Manual",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "ONLY_ACTIVE_ARCH=YES", f"ARCHS={target.name}", f"TRAVERSE_BUILD_ARCH={target.name}",
        "OTHER_SWIFT_FLAGS=$(inherited) -j4 -driver-batch-count 4",
        f"CLANG_MODULE_CACHE_PATH={local_directory('compiler-cache/xcode')}",
        f"SWIFT_MODULE_CACHE_PATH={local_directory('compiler-cache/xcode-swift')}",
        "build",
    ], "build" if configuration == "debug" else "build-release")
    if not application.is_dir():
        raise RuntimeError(f"Build succeeded without the expected native application: {application}")
    signature_log = execute(["codesign", "--verify", "--strict", str(application)], "verify-signature")
    products = product_inputs(application)
    if sources != source_inputs():
        raise RuntimeError(f"Native build inputs changed during compilation; retain {build_log} and rebuild current source.")
    # One current manifest, not a new copied build graph or per-run artifact.
    # Consumers pin this record and the exact product before any live check.
    manifest = local_directory("results") / f"current-build-{configuration}.json"
    temporary = manifest.with_name(manifest.name + "." + uuid.uuid4().hex)
    value = dict(format="traverse-native-build-v1", passed=True, configuration=configuration.title(), architecture=target.name,
                 application=str(application), sourceSHA256=sources, productSHA256=products,
                 buildLog=str(build_log.relative_to(ROOT)), signatureLog=str(signature_log.relative_to(ROOT)),
                 sourceUnchanged=True, completedUTC=datetime.now(timezone.utc).isoformat())
    with temporary.open("x") as output:
        os.chmod(temporary, 0o600)
        json.dump(value, output, indent=2); output.write("\n"); output.flush(); os.fsync(output.fileno())
    os.replace(temporary, manifest)
    print(f"Current build manifest: {manifest}")
    print(f"Development application: {application}")


def compiled_debug_inputs(*, require_current_source: bool = False) -> tuple[bytes, dict]:
    """Bind reused app checks to one successful ordinary build receipt."""
    raw = (BUILD / "results/current-build-debug.json").read_bytes()
    value = json.loads(raw)
    if value.get("format") != "traverse-native-build-v1" or value.get("passed") is not True \
            or value.get("configuration") != "Debug" or value.get("application") != str(APP) \
            or value.get("productSHA256") != product_inputs(APP):
        raise RuntimeError("Build the ordinary Debug app before its native check")
    if require_current_source and value.get("sourceSHA256") != source_inputs():
        raise RuntimeError("The ordinary Debug build is stale; build current source before verify-ui")
    return raw, value


def generated_test_fixture_roots() -> set[Path]:
    """Only these generated families become disposable after a passing run."""
    roots = set()
    for base, prefix in (
        (ROOT / "Packages/ExplorerKit/.build/test-fixtures", "guarded-trash-"),
        (BUILD / "test-fixtures", "local-storage-"),
        (BUILD / "test-fixtures", "retained-native-"),
        (BUILD / "test-fixtures", "file-memory-move-"),
        (BUILD / "test-fixtures/file-memory-store", ""),
    ):
        if not base.exists():
            continue
        if base.resolve() != base:
            raise ValueError("Refusing redirected generated test fixtures")
        for path in base.glob(prefix + "*"):
            try:
                uuid.UUID(path.name.removeprefix(prefix))
            except ValueError:
                continue
            value = path.lstat()
            if stat.S_ISDIR(value.st_mode) and value.st_uid == os.geteuid() and not value.st_mode & 0o077:
                roots.add(path)
    # The responsiveness suite uses the historical grouped-copy namespace,
    # which also contains separately retained qualification runs. Only its new
    # package-specific marker admits success-only disposal; old cases and the
    # standalone qualification runners never acquire this marker.
    base = BUILD / "grouped-copy-production"
    if base.exists():
        if base.resolve() != base:
            raise ValueError("Refusing redirected grouped-copy test fixtures")
        for path in base.iterdir():
            try:
                if str(uuid.UUID(path.name)) != path.name:
                    continue
            except ValueError:
                continue
            value = path.lstat()
            if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or value.st_mode & 0o077:
                continue
            matched = True
            for name, header in ((".qualification-owner", "MacExplorer grouped production qualification v1"),
                                 (".package-test-owner", "MacExplorer package responsiveness fixture v1")):
                expected = f"{header}\n{path.name}\n".encode()
                try:
                    fd = os.open(path / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
                    try:
                        facts = os.fstat(fd)
                        matched = (stat.S_ISREG(facts.st_mode) and facts.st_uid == os.geteuid()
                                   and facts.st_nlink == 1 and facts.st_size == len(expected)
                                   and os.read(fd, len(expected) + 1) == expected)
                    finally:
                        os.close(fd)
                except OSError:
                    matched = False
                if not matched:
                    break
            if matched:
                roots.add(path)
    return roots


def test(filter_expression: str | None, configuration: str = "debug", *, serial: bool = False, fixture_root: Path | None = None) -> Path:
    if configuration not in ("debug", "release"):
        raise ValueError("Unknown SwiftPM build configuration")
    scratch = "swift-tests" if configuration == "debug" else "swift-tests-release"
    command = [
        "xcrun", "swift", "test", "--package-path", str(ROOT / "Packages/ExplorerKit"),
        "--configuration", configuration,
        "--scratch-path", str(local_directory(scratch)),
        "--cache-path", str(local_directory("swift-cache")),
        "--config-path", str(local_directory("swift-config")),
        "--security-path", str(local_directory("swift-security")),
        "--swift-sdks-path", str(local_directory("swift-sdks")),
        "--disable-keychain", "--disable-netrc", "--disable-dependency-cache",
        "--manifest-cache", "local", "--disable-automatic-resolution", "--jobs", "4",
        "--disable-index-store",
        "-Xswiftc", "-warnings-as-errors",
        "-Xswiftc", "-module-cache-path", "-Xswiftc", str(local_directory("compiler-cache/swift")),
        "--xunit-output", str(local_directory("results") / f"tests-{configuration}-{stamp()}.xml"),
    ]
    if filter_expression:
        command.extend(["--filter", filter_expression])
    # The whole baseline includes process-global diagnostics and fixture
    # accounting that observes other tests' files. Run it once with exclusive
    # in-process ownership; independent focused suites can still run in parallel.
    if serial or not filter_expression:
        command.append("--no-parallel")
    # Debug and Release share generated fixture ownership as well as caches.
    # Serialize the whole run, including its success-only disposal, across chats.
    lock = os.open(local_directory("locks") / "package-tests.lock",
                   os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        facts = os.fstat(lock)
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.geteuid() or facts.st_nlink != 1 or facts.st_mode & 0o077:
            raise ValueError("Refusing an unexpected package-test lock")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Waiting for the current package-test run to drain…", flush=True)
            fcntl.flock(lock, fcntl.LOCK_EX)
        prior_fixtures = generated_test_fixture_roots()
        log = execute(command, "test", timeout=300, fixture_root=fixture_root)
        if "error: unable to attach DB:" in log.read_text():
            raise RuntimeError(f"Shared build-database collision; test result is not accepted: {log}")
        # Failed runs retain their fixtures. Only the completed, exclusive run
        # can dispose its new generated roots; never touch real Trash.
        completed_fixtures = generated_test_fixture_roots() - prior_fixtures
        for path in sorted(completed_fixtures):
            shutil.rmtree(path)
        if completed_fixtures:
            print(f"Disposed {len(completed_fixtures)} successful generated test fixture roots")
        return log
    finally:
        os.close(lock)


def validate_fixture(path: Path) -> dict:
    fixtures = local_directory("fixtures")
    if path.is_symlink() or path.parent.resolve() != fixtures.resolve():
        raise ValueError("Fixture must be an owned immediate child of .build/fixtures.")
    marker = path / MARKER
    if marker.is_symlink() or not marker.is_file():
        raise ValueError("Fixture has no regular ownership marker; refusing to use it.")
    data = json.loads(marker.read_text())
    if data.get("generator") != "mac-explorer-dev" or data.get("version") != FIXTURE_VERSION or not data.get("complete"):
        raise ValueError("Fixture is incomplete or belongs to another generator; leave it intact and choose another count.")
    return data


def fixture(count: int) -> Path:
    if count < 0 or count > 1_000_000:
        raise ValueError("Fixture plain-file count must be between 0 and 1000000.")
    parent = local_directory("fixtures")
    target = parent / f"listing-{count}"
    if target.exists() or target.is_symlink():
        existing = validate_fixture(target)
        if existing.get("plainFileCount") != count:
            raise ValueError("Existing fixture metadata does not match the requested count.")
        print(f"Reusing owned fixture: {target}")
        return target
    target.mkdir()  # Never overwrite, empty, or remove an existing directory.
    metadata = {"generator": "mac-explorer-dev", "version": FIXTURE_VERSION,
                "plainFileCount": count, "complete": False}
    with (target / MARKER).open("x") as marker:
        json.dump(metadata, marker, indent=2)
    started = time.monotonic()
    # Empty fixture bodies make listing size independent from storage throughput.
    for index in range(count):
        descriptor = os.open(target / f"Item {index:06d}.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
    for name in ("Résumé – नमस्ते – 日本語.txt", ".hidden-item", "space & quote ' item.txt"):
        (target / name).touch(exist_ok=False)
    package = target / "Example.app/Contents"
    package.mkdir(parents=True)
    (package / "Info.plist").write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>Fixture</string></dict></plist>')
    tree = target / "Folder A/Child/Grandchild"
    tree.mkdir(parents=True)
    (target / "Empty Folder").mkdir()
    (tree / "nested.txt").touch(exist_ok=False)
    (target / "Folder link").symlink_to("Folder A", target_is_directory=True)
    (target / "Broken link").symlink_to("missing-fixture-target")
    metadata.update({"complete": True, "creationSeconds": round(time.monotonic() - started, 6),
                     "extras": ["unicode", "hidden", "package", "directory-tree", "symlink", "broken-symlink"]})
    (target / MARKER).write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Created {count} plain files and edge-case fixtures in {metadata['creationSeconds']:.2f}s: {target}")
    return target


def validate_grouped_recovery_fixture(path: Path, *, require_journal: bool = True) -> None:
    """Metadata-only authority checks matching the App's two typed fixture shapes."""
    def directory(candidate: Path, *, private: bool = True) -> None:
        value = candidate.lstat()
        if (candidate != candidate.resolve() or not stat.S_ISDIR(value.st_mode)
                or value.st_uid != os.geteuid() or (private and value.st_mode & 0o077)):
            raise ValueError("Copied-file review refused a redirected or unowned fixture directory.")

    def marker(candidate: Path, maximum: int) -> bytes:
        directory(candidate.parent)
        fd = os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            before = os.fstat(fd)
            if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                    or before.st_nlink != 1 or before.st_mode & 0o077 or not 0 <= before.st_size <= maximum):
                raise ValueError("Copied-file review refused an unsafe ownership marker.")
            value = b""
            while True:
                block = os.read(fd, maximum + 1)
                if not block:
                    break
                value += block
                if len(value) > maximum:
                    raise ValueError("Copied-file fixture ownership marker exceeded its bound.")
            after, linked = os.fstat(fd), candidate.lstat()
            fields = ("st_dev", "st_ino", "st_size", "st_mode", "st_uid", "st_mtime_ns")
            if (any(getattr(before, key) != getattr(after, key) for key in fields)
                    or after.st_nlink != 1 or (linked.st_dev, linked.st_ino) != (after.st_dev, after.st_ino)):
                raise ValueError("Copied-file fixture ownership marker changed during validation.")
            return value
        finally:
            os.close(fd)

    def canonical_uuid(text: str) -> bool:
        try:
            return str(uuid.UUID(text)) == text
        except ValueError:
            return False

    directory(path)
    fixtures, run = path.parent, path.parent.parent
    if fixtures == BUILD / "fixtures":
        directory(fixtures)
        data = json.loads(marker(path / MARKER, 4096))
        if data.get("generator") != "mac-explorer-dev" or data.get("version") != 1 or data.get("complete") is not True:
            raise ValueError("Copied-file review refused an incomplete development fixture.")
    else:
        if (fixtures.name != "fixtures" or run.parent != BUILD / "grouped-copy-production"
                or not canonical_uuid(run.name) or not path.name.startswith("copy-")
                or not canonical_uuid(path.name[5:])):
            raise ValueError("Copied-file review requires an exact generated production fixture topology.")
        for candidate in (run.parent, run, fixtures):
            directory(candidate)
        if marker(run / ".qualification-owner", 256) != f"MacExplorer grouped production qualification v1\n{run.name}\n".encode():
            raise ValueError("Copied-file review refused a mismatched qualification marker.")
        if marker(path / ".owned-grouped-production-fixture", 256) != f"MacExplorer generated grouped production fixture v1\n{path.name}\n".encode():
            raise ValueError("Copied-file review refused a mismatched generated fixture marker.")
    for name in (("source", "destination", "journal") if require_journal else ("source", "destination")):
        directory(path / name)


def verify_grouped_copy_queue(fixture_path: str, skip_build: bool) -> None:
    """Exercise actual Paste routing in an externally seeded generated root."""
    path = Path(fixture_path).absolute()
    validate_grouped_recovery_fixture(path, require_journal=False)
    if path.parent.parent.parent != BUILD / "grouped-copy-production":
        raise ValueError("Preview queue requires an original production-worker fixture.")
    if not skip_build:
        build()
    if not APP.is_dir():
        raise RuntimeError("Development app is missing; run the build command first.")
    validate_grouped_recovery_fixture(path, require_journal=False)
    evidence = local_directory("evidence") / f"grouped-queue-ui-{stamp()}"
    evidence.mkdir()
    command = [str(APP / "Contents/MacOS/Mac Explorer"), "-ApplePersistenceIgnoreState", "YES",
               "--verify-ui", "--offscreen", "--verify-grouped-copy-queue", "--fixture-root", str(path),
               "--evidence-root", str(evidence)]
    log = execute(command, "verify-grouped-copy-queue", timeout=300, tooling=False, awaits_report=True)
    diagnostics = inspect_runtime_diagnostics(log)
    (evidence / "runtime-diagnostics.json").write_text(json.dumps(diagnostics, indent=2, sort_keys=True) + "\n")
    report = evidence / "ui-verification.json"
    if not report.is_file():
        raise RuntimeError("Preview queue exited without its required native report.")
    result = json.loads(report.read_text())
    if result.get("passed") is not True or result.get("mode") != "grouped-copy-queue-controlled":
        raise RuntimeError(f"Preview queue verification failed; inspect {report}")
    if diagnostics["passed"] is not True:
        raise RuntimeError(f"Preview queue emitted correctness diagnostics; inspect {evidence / 'runtime-diagnostics.json'}")


def verify_grouped_recovery(fixture_path: str, record: str, items: int, skip_build: bool,
                            action: str | None, undo: bool, journal: str | None) -> None:
    """Use an original worker seed; default is observational, never auto-resume."""
    path = Path(fixture_path).absolute()
    validate_grouped_recovery_fixture(path)
    record_id = str(uuid.UUID(record))
    if not 1 <= items <= 1024 or (action is not None and undo):
        raise ValueError("Choose 1–1,024 members and at most one explicit copied-file action.")
    expected_journal = path / "journal"
    if journal is not None and Path(journal).absolute() != expected_journal:
        raise ValueError("Copied-file review accepts only the fixture's exact journal directory.")
    if not skip_build:
        build()
    if not APP.is_dir():
        raise RuntimeError("Development app is missing; run the build command first.")
    # Validate again immediately before launch after a potentially lengthy build.
    validate_grouped_recovery_fixture(path)
    evidence = local_directory("evidence") / f"grouped-recovery-ui-{stamp()}"
    evidence.mkdir()
    command = [str(APP / "Contents/MacOS/Mac Explorer"), "-ApplePersistenceIgnoreState", "YES",
               "--verify-ui", "--offscreen", "--verify-grouped-recovery", "--fixture-root", str(path),
               "--evidence-root", str(evidence), "--grouped-journal", str(expected_journal),
               "--grouped-record", record_id, "--grouped-items", str(items)]
    if action is not None:
        command.extend(["--grouped-action", action])
    if undo:
        command.append("--grouped-undo")
    log = execute(command, "verify-grouped-recovery", timeout=300, tooling=False, awaits_report=True)
    diagnostics = inspect_runtime_diagnostics(log)
    (evidence / "runtime-diagnostics.json").write_text(json.dumps(diagnostics, indent=2, sort_keys=True) + "\n")
    report = evidence / "ui-verification.json"
    if not report.is_file():
        raise RuntimeError("Copied-file app verification exited without its required report.")
    result = json.loads(report.read_text())
    if result.get("passed") is not True or result.get("mode") != "grouped-copy-recovery-controlled":
        raise RuntimeError(f"Copied-file native verification failed; inspect {report}")
    if diagnostics["passed"] is not True:
        raise RuntimeError(f"Copied-file native checks emitted correctness diagnostics; inspect {evidence / 'runtime-diagnostics.json'}")
    print(f"Copied-file controlled native checks passed; evidence: {evidence}")


def verify_ui(count: int, fixture_path: str | None, skip_build: bool, offscreen: bool = False,
              launcher: str = "direct", qualify_permissions: str | None = None,
              qualify_trash: bool = False, qualify_folder_access: bool = False,
              qualify_glass: bool = False, check_presentation: bool = False,
              qualify_trash_fixture: bool = False, restore_trash_fixture: str | None = None,
              check_chrome: bool = False, check_workspace: bool = False, qualify_permission_retry: bool = False,
              check_everyday: bool = False, check_sidebar: bool = False, layout_matrix: bool = False, check_substantial: bool = False,
              check_tabs: bool = False, check_rename: bool = False, check_polish: bool = False,
              qualify_search_index: str | None = None, profile_rename: bool = False, check_queue: bool = False,
              check_drag_tracking: bool = False, check_address: bool = False, check_analysis: bool = False) -> None:
    if check_tabs or check_rename or check_polish or qualify_search_index or profile_rename or check_queue or check_drag_tracking or check_address or check_analysis:
        if sum((check_tabs, check_rename, check_polish, bool(qualify_search_index), profile_rename, check_queue, check_drag_tracking, check_address, check_analysis)) != 1 or any((qualify_permissions, qualify_trash, qualify_trash_fixture, restore_trash_fixture,
                                               qualify_folder_access, qualify_glass, check_presentation, check_chrome, check_workspace,
                                               qualify_permission_retry, check_everyday, check_sidebar, layout_matrix, check_substantial)):
            raise ValueError("Focused workflow checks require one separate generated-fixture mode.")
    if check_substantial and (qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture or qualify_folder_access or qualify_glass or check_presentation or check_chrome or check_workspace or qualify_permission_retry or check_everyday or check_sidebar or layout_matrix):
        raise ValueError("Substantial workflow checks require their own generated-fixture mode.")
    if layout_matrix and not check_sidebar:
        raise ValueError("Layout matrix requires --check-sidebar.")
    if check_sidebar and (qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture
                          or qualify_folder_access or qualify_glass or check_presentation or check_chrome
                          or check_workspace or qualify_permission_retry or check_everyday):
        raise ValueError("Sidebar checks require their own generated-fixture mode.")
    if check_everyday and (qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture
                          or qualify_folder_access or qualify_glass or check_presentation or check_chrome or check_workspace or qualify_permission_retry):
        raise ValueError("Everyday workflow checks require their own generated-fixture mode.")
    if qualify_permission_retry and (offscreen or qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture
                                     or qualify_folder_access or qualify_glass or check_presentation or check_chrome or check_workspace):
        raise ValueError("Permission retry requires its own foreground qualification mode.")
    if qualify_permission_retry and launcher != "launchservices":
        raise ValueError("Permission retry requires --launcher launchservices so it is not a direct child of the development host.")
    if check_workspace and (qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture
                            or qualify_folder_access or qualify_glass or check_presentation or check_chrome):
        raise ValueError("Workspace-only checks cannot be combined with other qualification modes.")
    if check_chrome and (qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture
                         or qualify_folder_access or qualify_glass or check_presentation):
        raise ValueError("Chrome-only checks cannot be combined with other qualification modes.")
    if restore_trash_fixture and (not offscreen or qualify_permissions or qualify_trash or qualify_trash_fixture
                                  or qualify_folder_access or qualify_glass or check_presentation):
        raise ValueError("Receipt recovery requires offscreen mode alone, separate from qualification or presentation flags.")
    if qualify_trash and qualify_trash_fixture:
        raise ValueError("Choose either human Trash qualification or explicit owned-fixture Trash qualification.")
    if offscreen and (qualify_permissions or qualify_trash or qualify_folder_access or qualify_glass):
        raise ValueError("Permissions, folder chooser, human Trash confirmation, and compositor glass require interactive mode; only explicit owned-fixture Trash API qualification supports offscreen.")
    if check_presentation and (qualify_permissions or qualify_trash or qualify_trash_fixture or qualify_folder_access or qualify_glass):
        raise ValueError("Presentation-only checks cannot be combined with foreground qualification flags.")
    if not skip_build:
        build()
    if not APP.is_dir():
        raise RuntimeError("Development app is missing; run the build command first.")
    compiled_bytes, compiled = compiled_debug_inputs(require_current_source=True)
    if fixture_path:
        path = Path(fixture_path).absolute()
        validate_fixture(path)
    else:
        path = fixture(count)
    evidence = local_directory("evidence") / f"ui-{stamp()}"
    evidence.mkdir()
    (evidence / "compiled-inputs.json").write_bytes(compiled_bytes)
    application = APP
    if qualify_permissions or qualify_permission_retry or qualify_folder_access or qualify_glass or qualify_trash:
        review = local_directory("review-apps") / f"qualification-{stamp()}"
        review.mkdir()
        application = review / "Mac Explorer.app"
        execute(["/usr/bin/ditto", str(APP), str(application)], "snapshot-qualification", tooling=False)
        execute(["codesign", "--verify", "--strict", str(application)], "verify-qualification-signature", tooling=False)
    # Direct mode preserves the exact child exit status and ignored log. AppKit
    # activation remains a separately checked interactive precondition. Never
    # silently retry a failed LaunchServices launch and risk duplicate instances.
    use_launch_services = launcher == "launchservices"
    # Explicit verification launches discard only AppKit's app-window restore
    # state. Our isolated session/bookmark stores are separate and untouched.
    command = ["open", "-n", "-W", "-F"] if use_launch_services else [str(application / "Contents/MacOS/Mac Explorer")]
    native_env = environment(tooling=False)
    if use_launch_services:
        for key in ("TMPDIR", "MAC_EXPLORER_STATE_ROOT", "MAC_EXPLORER_CACHE_ROOT", "MAC_EXPLORER_TEST_ROOT"):
            command.extend(["--env", f"{key}={native_env[key]}"])
        if native_env.get("MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS") == "1":
            command.extend(["--env", "MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS=1"])
        # On this host stdout/stderr redirection makes LaunchServices return
        # -10810, while the same launch with only --env succeeds. Native JSON
        # remains mandatory; open's success is never accepted as test success.
        command.extend([str(application), "--args"])
    # Argument-domain overrides apply to this verification process only; no
    # defaults command or persistent/system setting is written. The explicit
    # test session/bookmark stores are independent of AppKit window restoration.
    command.extend(["-ApplePersistenceIgnoreState", "YES", "--verify-ui", "--fixture-root", str(path), "--evidence-root", str(evidence)])
    if offscreen:
        command.append("--offscreen")
    if qualify_permissions:
        command.extend(["--qualify-permissions", qualify_permissions])
    if qualify_trash:
        command.append("--qualify-trash")
    if qualify_trash_fixture:
        command.append("--qualify-trash-fixture")
    if restore_trash_fixture:
        command.extend(["--restore-trash-fixture", str(Path(restore_trash_fixture).absolute())])
    if qualify_folder_access:
        command.append("--qualify-folder-access")
    if qualify_glass:
        command.append("--qualify-glass")
    if check_presentation:
        command.append("--check-presentation")
    if check_chrome:
        command.append("--check-chrome")
    if check_substantial:
        command.append("--check-substantial")
    if check_tabs:
        command.append("--check-tabs")
    if check_rename:
        command.append("--check-rename")
    if check_polish:
        command.append("--check-polish")
    if check_queue:
        command.append("--check-queue")
    if check_drag_tracking:
        command.append("--check-drag-tracking")
    if check_address:
        command.append("--check-address")
    if check_analysis:
        command.append("--check-analysis")
    if qualify_search_index:
        command.extend(["--qualify-search-index", str(Path(qualify_search_index).absolute())])
    if profile_rename:
        command.append("--profile-rename")
    if check_workspace:
        command.append("--check-workspace")
    if qualify_permission_retry:
        command.append("--qualify-permission-retry")
    if check_everyday:
        command.append("--check-everyday")
    if check_sidebar:
        command.append("--check-sidebar")
    if layout_matrix:
        command.append("--layout-matrix")
    interactive_qualification = bool(qualify_permissions or qualify_trash or qualify_trash_fixture or restore_trash_fixture or qualify_folder_access or qualify_glass or qualify_permission_retry)
    # A full 100k-entry regression revisits the large folder throughout tab,
    # filter and presentation checks. Keep a finite larger whole-run budget;
    # individual native wait conditions retain their own bounded deadlines.
    log = execute(command, "verify-ui", timeout=900 if interactive_qualification or count >= 100000 else 300,
                  tooling=False, awaits_report=True)
    diagnostics = inspect_runtime_diagnostics(log)
    if use_launch_services:
        diagnostics["scope"] = "LaunchServices launcher stdout/stderr only; application stdout/stderr was not captured"
        diagnostics["notExercised"].append("Application stdout/stderr for this LaunchServices launch")
    (evidence / "runtime-diagnostics.json").write_text(json.dumps(diagnostics, indent=2, sort_keys=True) + "\n")
    report = evidence / "ui-verification.json"
    if not report.is_file():
        raise RuntimeError(f"Application exited without its required UI verification report: {report}")
    result = json.loads(report.read_text())
    if result.get("passed") is not True:
        raise RuntimeError(f"Native UI verification failed: {result.get('failure', result.get('status', 'unknown failure'))}; report: {report}")
    if diagnostics["passed"] is not True:
        raise RuntimeError(f"Native checks emitted correctness diagnostics; inspect {evidence / 'runtime-diagnostics.json'}")
    if compiled["productSHA256"] != product_inputs(application):
        raise RuntimeError("The checked app changed during native acceptance")
    print("Native UI checks and captured runtime diagnostics: passed")
    print(f"UI evidence: {evidence}")


def run_application(launcher: str) -> None:
    if launcher == "launchservices":
        execute(["open", "-n", str(APP)], "run", tooling=False)
        return
    log = local_directory("logs") / f"run-{stamp()}.log"
    with log.open("xb") as output:
        process = subprocess.Popen([str(APP / "Contents/MacOS/Mac Explorer")], cwd=ROOT,
                                   env=environment(tooling=False), stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True, close_fds=True)
    print(f"Started own development app process {process.pid}; log {log}")


def verify_folder_reopen(skip_build: bool, count: int) -> None:
    """One human picker, then an independent native process using the same signed app."""
    if not skip_build:
        build()
    if not APP.is_dir():
        raise RuntimeError("Development app is missing; run the build command first.")
    listing = fixture(count)
    snapshot = local_directory("review-apps") / f"folder-reopen-{stamp()}"
    snapshot.mkdir()
    app = snapshot / "Mac Explorer.app"
    execute(["/usr/bin/ditto", str(APP), str(app)], "snapshot-folder-reopen", tooling=False)
    execute(["codesign", "--verify", "--strict", str(app)], "verify-reopen-signature", tooling=False)
    code = [Path("Contents/MacOS/Mac Explorer"), Path("Contents/MacOS/Mac Explorer.debug.dylib"),
            Path("Contents/_CodeSignature/CodeResources"), Path("Contents/Info.plist")]
    hashes = {str(path): hashlib.sha256((app / path).read_bytes()).hexdigest() for path in code}
    reports = []
    receipt = None
    for phase in ("prepare", "resume"):
        evidence = local_directory("evidence") / f"ui-folder-reopen-{phase}-{stamp()}"
        evidence.mkdir()
        command = [str(app / "Contents/MacOS/Mac Explorer"), "-ApplePersistenceIgnoreState", "YES", "--verify-ui", "--fixture-root", str(listing),
                   "--evidence-root", str(evidence)]
        if phase == "prepare":
            command.append("--qualify-folder-reopen")
        else:
            command.extend(["--resume-folder-access", str(receipt)])
        execute(command, "folder-reopen-" + phase, timeout=900, tooling=False)
        native = json.loads((evidence / "ui-verification.json").read_text())
        receipt = evidence / "folder-reopen-qualification.json"
        observed = json.loads(receipt.read_text())
        expected = "remembered-awaiting-independent-app-reopen" if phase == "prepare" else "independent-app-reopen-metadata-and-forget-qualified"
        if native.get("passed") is not True or observed.get("status") != expected:
            raise RuntimeError(f"Folder {phase} was not qualified; inspect {evidence}")
        reports.append({"evidence": str(evidence), "receipt": observed})
    for path, expected in hashes.items():
        if hashlib.sha256((app / path).read_bytes()).hexdigest() != expected:
            raise RuntimeError("The qualification app changed during reopening; no retention claim made.")
    prepared, reopened = [item["receipt"] for item in reports]
    if prepared["preparedProcess"] == reopened["reopenedProcess"] or prepared["reference"] != reopened["reference"]:
        raise RuntimeError("Folder reopening did not establish independent-process reference retention.")
    result = {"passed": True, "mode": "independent-native-folder-reopen", "application": str(app), "codeSHA256": hashes,
              "phases": reports, "protectedFolderConsentRetentionQualified": False, "rebuildRetentionQualified": False}
    result_file = snapshot / "folder-reopen-result.json"
    result_file.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Native folder remember/reopen/read/forget passed; evidence {result_file}")


def require_unlocked_console() -> None:
    """Defer visual work before allocating fixtures or opening hidden windows."""
    values = plistlib.loads(subprocess.check_output(["/usr/sbin/ioreg", "-n", "Root", "-d1", "-a"], timeout=5))
    console = (values if isinstance(values, dict) else values[0]).get("IOConsoleUsers", [])
    if not console or any(value.get("CGSSessionScreenIsLocked", False) for value in console):
        raise RuntimeError("Visual check deferred: Mac is locked or console state is unavailable; no app was launched")


def verify_stopped_marked_archive_creation(case: Path) -> Path:
    """Load only the existing independent stopped-case verifier for this command."""
    from native_checks import verify_stopped_marked_archive_creation as verify_stopped
    return verify_stopped(case)


def native_check(*args, **options) -> Path:
    """Load the existing runtime-only feature runner only for this command."""
    from native_checks import native_check as run_native_check
    return run_native_check(*args, **options)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    native_build = subcommands.add_parser("build", help="Build the native app and verify local signature; create a project if missing.")
    native_build.add_argument("--configuration", choices=("debug", "release"), default="debug",
                              help="Native optimization configuration; Release uses separate build products.")
    native_build.add_argument("--arch", choices=tuple(ARCHITECTURES), default=host().name,
                              help="Build the app and every bundled helper for this Mac architecture.")
    native_build.add_argument("--preserve-project", action="store_true",
                              help="Build the existing Xcode project without regenerating owner edits.")
    native_build.add_argument("--regenerate-project", action="store_false", dest="preserve_project",
                              help="Explicitly replace the Xcode project with deterministic generated configuration.")
    native_build.set_defaults(preserve_project=True)
    tests = subcommands.add_parser("test", help="Run reusable package tests with repo-local fixtures/caches.")
    tests.add_argument("--filter", help="Swift test filter expression.")
    tests.add_argument("--serial", action="store_true", help="Serialize a focused selection; the complete baseline is always serial.")
    tests.add_argument("--configuration", choices=("debug", "release"), default="debug",
                       help="SwiftPM optimization configuration; Release uses a separate scratch directory.")
    focused = subcommands.add_parser("native-check", help="Run an existing feature check using the ordinary app and generated files.")
    focused.add_argument("feature", choices=("startup-analysis", "sidebar-layout", "local-editor", "operation-access", "archive-pane", "archive-export", "trash-command", "remote-properties", "support-details", "transfer-diagnostics", "clipboard-admission", "connection-fields", "server-prompts", "sftp-profiles", "editor-preferences", "drive-benchmark", "drive-status", "editor-lines", "tar-archive", "compressed-tar", "create-zip", "create-tar", "create-targz", "create-tarbz2", "batch-rename", "selection-group", "zip-add-copy", "zip-rename-copy", "zip-rename-folder-copy", "zip-remove-copy", "zip-remove-folder-copy", "zip-update-rename", "zip-update-tracked", "zip-update-native", "zip-editor-native", "zip-editor-native-recovery", "tar-editor", "tar-gzip-editor", "tar-bzip2-editor", "zip-update-new-folder", "zip-update-duplicate", "zip-update-move", "zip-update-copy", "zip-new-folder-copy", "zip-update-folder", "zip-update-remove", "zip-update-empty", "zip-update-add", "analysis-persistence", "settings-motion", "help-motion", "tool-windows", "window-lifecycle", "pane-motion", "storage-chart", "folder-default", "hover-summary", "connection-metadata", "sftp-batch-download", "sftp-group-upload", "smb-transfer-menus", "connect-model", "smb-connected-uploads", "sftp-connected-actions"))
    focused.add_argument("--archive-format", choices=("zip", "tar", "tar.gz", "tar.bz2"), default="zip",
                         help="Concrete format for the shared archive-export callback/Finder flow.")
    focused.add_argument("--skip-build", action="store_true")
    focused.add_argument("--offscreen", action="store_true",
                         help="Supported generated functional flows without visual, motion or foreground-input qualification.")
    focused.add_argument("--interactive", action="store_true", help="Keep a supported generated review open for native interaction.")
    focused.add_argument("--motion", action="store_true", help="Use the existing native motion recorder.")
    focused.add_argument("--promise-flow", action="store_true",
                         help="Use the existing SFTP receive flow for direct native callbacks; no real server or receiver drag by default.")
    focused.add_argument("--external-promise-receiver", action="store_true",
                         help="Use generated SFTP or archive rows for actual Finder delivery and Undo; no server or signed acceptance.")
    focused.add_argument("--folder-flow", action="store_true",
                         help="Use the same SFTP receive flow for a folder drop, Cancel, collision and cold Undo; no real server.")
    focused.add_argument("--public-tree", action="store_true",
                         help="Use the default-held public-property folder candidate in the existing generated archive/SFTP flow.")
    focused.add_argument("--public-archive", action="store_true",
                         help="Use the separate held TAR tree/file candidates in the existing plain/compressed TAR flow.")
    focused.add_argument("--marked-source-create", action="store_true",
                         help="Use generated marked ZIP/TAR sources in the ordinary app with a second-process cold Undo.")
    focused.add_argument("--incremental-analysis", action="store_true",
                         help="Use the exact older successful generated tree for changed-folder refresh and cold reopen; no network or personal files.")
    focused.add_argument("--connection-phase", choices=("address", "find", "selection", "persistence", "completion", "escape", "viewport", "pin-readiness"), default="persistence",
                         help="Reuse the existing connection-metadata flow for a focused native browser phase; no real server.")
    focused.add_argument("--large-interface", action="store_true", help="Check supported archive, connection, Settings and Help surfaces at 150%% in Light appearance.")
    focused.add_argument("--motion-mode", choices=("full", "reduced", "off"), default="full",
                         help="Motion preference for the Settings/Help native checks.")
    focused.add_argument("--generated-port", type=int,
                         help="Already-scoped loopback SMB listener for smb-connected-uploads; reads its generated secret only from stdin and starts no server.")
    focused.add_argument("--generated-fingerprint", help="Exact public fingerprint of the already-approved generated SFTP test server.")
    focused.add_argument("--generated-flow", choices=("uploads", "uploads-folders", "uploads-new-items", "file-actions", "directory-actions", "file-actions-move", "file-actions-cut", "file-actions-copy", "editor-original", "download-drops", "download-drops-gestures", "download-drops-folder", "remote-moves", "remote-cut"), default="uploads",
                         help="Run Upload, folder/New Item or selected-file actions; none starts a server.")
    focused.add_argument("--sample-health", action="store_true", help="Add at most five read-only internal-drive readings to drive-status.")
    focused.add_argument("--random-benchmark", action="store_true", help="Exercise the 4 KiB random workload in drive-benchmark.")
    focused.add_argument("--quick-mix-benchmark", action="store_true",
                         help="Exercise the fixed sequential plus 4 KiB random Quick Mix in the existing generated drive-benchmark flow.")
    stopped_archive = subcommands.add_parser("verify-stopped-marked-archive-create",
        help="Finish only the independent final check of an existing generated marked ZIP/TAR case; no build or App launch.")
    stopped_archive.add_argument("case", type=Path)
    run = subcommands.add_parser("run", help="Build and launch a new instance of this development app.")
    run.add_argument("--skip-build", action="store_true")
    run.add_argument("--launcher", choices=("direct", "launchservices"), default="direct",
                     help="Launch own development app directly (default) or through LaunchServices; no fallback.")
    reopen = subcommands.add_parser("verify-folder-reopen", help="Remember the generated fixture through the real picker, exit, reopen in a fresh native process, verify metadata and forget its isolated record.")
    reopen.add_argument("--skip-build", action="store_true")
    reopen.add_argument("--count", type=int, default=1000)
    fixtures = subcommands.add_parser("fixture", help="Create/reuse an owned, deterministic directory listing.")
    fixtures.add_argument("count", type=int, nargs="?", default=1000, help="Plain file count (default 1000).")
    grouped_queue = subcommands.add_parser("verify-grouped-copy-queue",
        help="Controlled actual Paste/Queue preview routing in a fresh original marked production-worker fixture; owner routing remains closed.")
    grouped_queue.add_argument("--fixture-root", required=True, help="Original freshly seeded production fixture with no copied destinations.")
    grouped_queue.add_argument("--skip-build", action="store_true")
    grouped = subcommands.add_parser("verify-grouped-recovery",
        help="Controlled native copied-file review of an existing marked process-worker catalog; inspect-only by default.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Use the ORIGINAL generated process fixture; never relocate its sealed catalog.
Expected production topology:
  .build/grouped-copy-production/<run-uuid>/fixtures/copy-<fixture-uuid>/journal
The frozen worker must first seed/execute the fixture under its original
MAC_EXPLORER_GROUPED_PRODUCTION_RUN_ROOT. For example, its positional arguments:
  production-worker seed <fixture> 33
  production-worker forward <fixture> strict memberPublished 0 0 process_crash -
The second command intentionally exits 86 after publishing member 0; preserve its
JSON recordID receipt. Then invoke:
  python3 tools/dev.py verify-grouped-recovery --fixture-root <fixture> \\
    --record <recordID> --items 33 --skip-build
Add --action confirmCopies only for explicit native confirmation of that seed.
Other seeds: groupSealed/0/-/process_crash/- for finishReview; completed forward
for --undo; recovery-worker undo/<fixture>/<recordID>/none/reverseRenamed/
process_crash/32 for a 33-item confirmUndo seed. Respect each worker's exact
original run ENV and source/binary receipts. This command never creates seeds,
never enables ordinary grouped-copy routing, and retains all fixture data.
""")
    grouped.add_argument("--fixture-root", required=True, help="Original exact marked generated fixture directory.")
    grouped.add_argument("--journal", help="Optional explicit path; must equal <fixture-root>/journal.")
    grouped.add_argument("--record", required=True, help="Grouped job UUID from the frozen worker receipt.")
    grouped.add_argument("--items", type=int, required=True, help="Expected complete member count, 1–1,024.")
    grouped.add_argument("--skip-build", action="store_true")
    grouped_action = grouped.add_mutually_exclusive_group()
    grouped_action.add_argument("--action", choices=("confirmCopies", "confirmUndo", "finishReview"),
                                help="Explicitly activate this available native confirmation button once.")
    grouped_action.add_argument("--undo", action="store_true", help="Explicitly activate fresh guarded native Undo once.")
    ui = subcommands.add_parser("verify-ui", help="Run native app verification against generated fixtures only.")
    ui.add_argument("--count", type=int, default=1000)
    ui.add_argument("--fixture-root", help="Existing owned directory immediately under .build/fixtures.")
    ui.add_argument("--skip-build", action="store_true")
    ui.add_argument("--offscreen", action="store_true", help="Controlled native renders/commands without foreground input qualification.")
    ui.add_argument("--launcher", choices=("direct", "launchservices"), default="direct",
                    help="Native launch mechanism (default direct); never retries by another mechanism.")
    ui.add_argument("--qualify-permissions", choices=("Downloads",),
                    help="Explicit human-assisted shallow Downloads metadata/count qualification.")
    ui.add_argument("--qualify-permission-retry", action="store_true",
                    help="Separate human-assisted Mac Explorer Downloads toggle off/on and native Retry check; read-only instance.")
    ui.add_argument("--qualify-trash", action="store_true",
                    help="Human-confirmed real Trash/restore qualification using a new owned UUID fixture only.")
    ui.add_argument("--qualify-trash-fixture", action="store_true",
                    help="Explicit real Trash/restore API check of its own new UUID fixture, foreground or offscreen; no confirmation dialog or browser selection.")
    ui.add_argument("--restore-trash-fixture", metavar="RECEIPT",
                    help="Offscreen-only recovery of an exact prior owned Trash fixture receipt; creates no new Trash payload.")
    ui.add_argument("--qualify-folder-access", action="store_true",
                    help="Explicit human folder-panel/bookmark qualification using the owned fixture only.")
    ui.add_argument("--qualify-glass", action="store_true",
                    help="Explicit interactive compositor capture of this verification window only.")
    ui.add_argument("--check-presentation", action="store_true",
                    help="Quick native presentation regression loop; supported interactive or offscreen.")
    ui.add_argument("--check-chrome", action="store_true",
                    help="Quick native chrome opacity and address display/editor geometry checks; owned fixtures only.")
    ui.add_argument("--check-workspace", action="store_true",
                    help="Native isolated session, remembered reference, folder refresh and material region checks.")
    ui.add_argument("--check-everyday", action="store_true",
                    help="Focused generated-fixture drag, Open With/share, results and continuation checks.")
    ui.add_argument("--check-sidebar", action="store_true",
                    help="Focused native outline disclosure/label alignment measurement and render.")
    ui.add_argument("--check-substantial", action="store_true",
                    help="Native pane, preview, behavior, pins, scoped metadata search and snapshot integrity checks.")
    ui.add_argument("--check-tabs", action="store_true",
                    help="Focused native tab-close, management and drag geometry regression checks.")
    ui.add_argument("--check-rename", action="store_true",
                    help="Focused native generated-fixture rename selection, extension and latency checks.")
    ui.add_argument("--check-polish", action="store_true",
                    help="Focused native drive spacing, hover and clipboard feedback checks.")
    ui.add_argument("--check-queue", action="store_true",
                    help="Focused native session queue, access lifetime, prompt and clipboard checks on generated fixtures.")
    ui.add_argument("--check-address", action="store_true",
                    help="Isolated address completion, search locations and quiet startup recovery checks.")
    ui.add_argument("--check-analysis", action="store_true",
                    help="Signed bundled scanner, analyzer window and folder summary checks on generated fixtures only.")
    ui.add_argument("--check-drag-tracking", action="store_true",
                    help="Isolated native eventTracking-mode drag preparation checks; no physical Finder delivery.")
    ui.add_argument("--qualify-search-index", metavar="FIXTURE_RECEIPT",
                    help="Explicit owner-approved generated internal/external Downloads filename-index qualification; no index changes.")
    ui.add_argument("--profile-rename", action="store_true",
                    help="Generated-fixture no-UI recoverable rename and separate raw-syscall diagnostic measurements.")
    ui.add_argument("--layout-matrix", action="store_true",
                    help="With --check-sidebar, inspect Light/Dark, Solid/Glass, widths and expanded/collapsed groups.")
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(preserve_project=args.preserve_project, configuration=args.configuration, architecture=args.arch)
        elif args.command == "test":
            test(args.filter, args.configuration, serial=args.serial)
        elif args.command == "native-check":
            zip_edit = args.feature.startswith("zip-")
            if args.offscreen and not zip_edit and args.feature not in ("archive-export", "tar-archive", "compressed-tar", "create-zip", "create-tar", "create-targz", "create-tarbz2", "tar-editor", "tar-gzip-editor", "tar-bzip2-editor", "batch-rename", "editor-preferences", "smb-transfer-menus", "connect-model", "sftp-group-upload", "transfer-diagnostics", "clipboard-admission", "support-details", "analysis-persistence", "operation-access"):
                parser.error("Offscreen functional checks apply only to archive, editor, saved-analysis, diagnostics and connection menu/model flows")
            if args.interactive and (args.feature not in ("sidebar-layout", "smb-transfer-menus", "sftp-group-upload", "zip-update-move", "tar-editor") or args.offscreen):
                parser.error("Interactive review requires a visible sidebar, SMB menu or SFTP destination flow")
            if args.motion and args.feature not in ("sidebar-layout", "connection-fields", "analysis-persistence", "sftp-batch-download", "drive-benchmark", "drive-status", "editor-preferences", "remote-properties"):
                parser.error("Motion recording applies to sidebar, connection fields, analysis, transfer, benchmark and editor checks")
            if args.large_interface and not zip_edit and args.feature not in ("archive-pane", "tar-archive", "compressed-tar", "create-zip", "create-tar", "create-targz", "create-tarbz2", "tar-editor", "tar-gzip-editor", "tar-bzip2-editor", "batch-rename", "selection-group", "settings-motion", "help-motion", "tool-windows", "pane-motion", "sftp-profiles", "storage-chart", "sftp-batch-download", "sftp-group-upload", "drive-benchmark", "drive-status", "editor-preferences"):
                parser.error("Large-interface review applies to supported archive, connection, Settings and Help checks")
            if args.motion_mode != "full" and args.feature not in ("settings-motion", "help-motion", "tool-windows", "pane-motion", "sftp-profiles", "storage-chart", "selection-group"):
                parser.error("The motion preference applies to Settings, Help, tool-window and grouping checks")
            native_check(args.feature, skip_build=args.skip_build, interactive=args.interactive, motion=args.motion,
                         large_interface=args.large_interface, motion_mode=args.motion_mode, offscreen=args.offscreen,
                         generated_port=args.generated_port, generated_fingerprint=args.generated_fingerprint,
                         private_input=sys.stdin.buffer.readline(130) if args.feature == "smb-connected-uploads" else None,
                         generated_flow=args.generated_flow, sample_health=args.sample_health, random_benchmark=args.random_benchmark,
                         quick_mix_benchmark=args.quick_mix_benchmark,
                         promise_flow=args.promise_flow, folder_flow=args.folder_flow,
                         external_promise_receiver=args.external_promise_receiver,
                         public_tree=args.public_tree, public_archive=args.public_archive,
                         incremental_analysis=args.incremental_analysis, connection_phase=args.connection_phase,
                         marked_source_create=args.marked_source_create, archive_format=args.archive_format)
        elif args.command == "verify-stopped-marked-archive-create":
            receipt = verify_stopped_marked_archive_creation(args.case)
            print(f"Independent marked archive creation check passed; evidence {receipt}")
        elif args.command == "fixture":
            fixture(args.count)
        elif args.command == "verify-folder-reopen":
            verify_folder_reopen(args.skip_build, args.count)
        elif args.command == "verify-grouped-copy-queue":
            verify_grouped_copy_queue(args.fixture_root, args.skip_build)
        elif args.command == "verify-grouped-recovery":
            verify_grouped_recovery(args.fixture_root, args.record, args.items, args.skip_build,
                                    args.action, args.undo, args.journal)
        elif args.command == "verify-ui":
            verify_ui(args.count, args.fixture_root, args.skip_build, args.offscreen, args.launcher,
                      args.qualify_permissions, args.qualify_trash, args.qualify_folder_access,
                      args.qualify_glass, args.check_presentation, args.qualify_trash_fixture, args.restore_trash_fixture, args.check_chrome, args.check_workspace, args.qualify_permission_retry, args.check_everyday, args.check_sidebar, args.layout_matrix, args.check_substantial, args.check_tabs, args.check_rename, args.check_polish, args.qualify_search_index, args.profile_rename, args.check_queue, args.check_drag_tracking, args.check_address, args.check_analysis)
        elif args.command == "run":
            if not args.skip_build:
                build()
            if not APP.is_dir():
                raise RuntimeError("Development app is missing; run the build command first.")
            run_application(args.launcher)
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
