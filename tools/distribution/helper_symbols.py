#!/usr/bin/env python3
"""Check matching debug symbols for the declared bundled release helpers."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import uuid

REPO = Path(__file__).resolve().parents[2]
HELPERS = ('storage-scanner-worker', 'smb-browser-worker',
           'smb-resolver-worker', 'sftp-metadata-worker')
POLICY = 'optimized-line-tables-packed-v1'
RUST_SOURCE_PATH_POLICY = 'release-rust-repository-prefix-v1'
MAX_SYMBOL_BYTES = 128 << 20
HEALTH_HELPER = 'drive-health-worker'
HEALTH_VERSION_KEY = 'TraverseDriveHealthHelperVersion'
HEALTH_QA_CASE = '9309F6A1-E7A3-45C2-A864-0CBF02880D63'
HEALTH_SERVICE_VERSION_KEY = 'TraverseDriveHealthServiceVersion'
HEALTH_SERVICE_EXECUTABLE = 'drive-health-service'
HEALTH_SERVICE_LEAF = 'drive-health-service.xpc'


def health_declared(info: dict) -> bool:
    """Older packages retain four roles; v2 is an explicit inherited lane."""
    if not isinstance(info, dict):
        raise ValueError('Malformed helper parent metadata')
    if HEALTH_VERSION_KEY not in info:
        return False
    if HEALTH_SERVICE_VERSION_KEY in info:
        raise ValueError('Drive-health worker and service declarations cannot mix')
    from . import remote_editor_qa
    parent = info.get('CFBundleIdentifier')
    channel = info.get('MacExplorerDistributionChannel')
    valid = parent == 'com.respawnstudios.traverse' and channel == 'developer-id'
    if isinstance(parent, str) and parent.startswith(remote_editor_qa.PREFIX):
        case = info.get('MacExplorerSandboxQualificationCase')
        valid = channel == 'qualification' and case == HEALTH_QA_CASE and parent == remote_editor_qa.identifier(case)
    if type(info[HEALTH_VERSION_KEY]) is not int or info[HEALTH_VERSION_KEY] != 2 \
            or info.get('MacExplorerAccessPolicy') != 'sandbox-selected-v1' or not valid:
        raise ValueError('Unrecognized inherited drive-health declaration')
    return True


def health_service_declared(info: dict) -> bool:
    """Only the exact QA or Developer ID product may declare this service."""
    if not isinstance(info, dict):
        raise ValueError('Malformed drive-health service parent metadata')
    if HEALTH_SERVICE_VERSION_KEY not in info:
        return False
    from . import remote_editor_qa, store_helpers
    case = info.get('MacExplorerSandboxQualificationCase')
    parent = info.get('CFBundleIdentifier')
    channel = info.get('MacExplorerDistributionChannel')
    private_updater = info.get('TraversePrivateUpdaterVersion')
    public_updater = info.get('TraversePublicUpdaterVersion')
    valid_updater = 'TraverseDirectPublicUpdaterVersion' not in info and (('TraversePrivateUpdaterVersion' not in info \
        and 'TraversePublicUpdaterVersion' not in info) \
        or (private_updater == '2.10.0' and 'TraversePublicUpdaterVersion' not in info) \
        or (public_updater == '2.10.0' and 'TraversePrivateUpdaterVersion' not in info))
    qa = case == HEALTH_QA_CASE and parent == remote_editor_qa.identifier(HEALTH_QA_CASE) \
        and channel == 'qualification' and 'TraversePrivateUpdaterVersion' not in info \
        and 'TraversePublicUpdaterVersion' not in info \
        and 'TraverseDirectStorageNamespace' not in info \
        and info.get('MacExplorerAccessPolicy') == store_helpers.SCOPED and valid_updater
    scoped_product = 'MacExplorerSandboxQualificationCase' not in info \
        and parent == store_helpers.PARENT and channel == 'developer-id' \
        and 'TraverseDirectStorageNamespace' not in info \
        and info.get('MacExplorerAccessPolicy') == store_helpers.SCOPED and valid_updater
    from build_architecture import direct_app_architecture
    direct_keys = dict(TraverseDirectPublicUpdaterVersion='2.10.0',
        TraverseDirectStorageNamespace='com.respawnstudios.traverse.direct',
        MacExplorerFolderServices='public-folders-service-v1',
        SUFeedURL=direct_app_architecture(info).direct_feed_url,
        SUPublicEDKey='MG4sBFr76ad6D4nGo+i2VuZ4hxVMEQZToBUjYyui3IA=',
        SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
        SUSignedFeedFailureExpirationInterval=0, SUScheduledCheckInterval=21600,
        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
        SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
        SUEnableJavaScript=False)
    from folder_services import valid as folder_services_valid
    direct_product = 'MacExplorerSandboxQualificationCase' not in info \
        and parent == store_helpers.PARENT and channel == 'developer-id' \
        and info.get('MacExplorerAccessPolicy') == store_helpers.LOCAL \
        and 'TraversePrivateUpdaterVersion' not in info and 'TraversePublicUpdaterVersion' not in info \
        and all(type(info.get(key)) is type(value) and info[key] == value
                for key, value in direct_keys.items()) \
        and {key for key in info if key.startswith('SU')} == {key for key in direct_keys if key.startswith('SU')} \
        and folder_services_valid(info) \
        and not any(key in info for key in ('MacExplorerPreviewFolderServices',
            'MacExplorerDevelopmentStateRoot', 'MacExplorerDevelopmentCacheRoot',
            'SUEnableInstallerLauncherService', 'SUEnableDownloaderService'))
    if type(info[HEALTH_SERVICE_VERSION_KEY]) is not int or info[HEALTH_SERVICE_VERSION_KEY] != 1 \
            or HEALTH_VERSION_KEY in info \
            or info.get('MacExplorerStorageMode') != 'portable' \
            or 'MacExplorerReviewCase' in info \
            or not (qa or scoped_product or direct_product):
        raise ValueError('Unrecognized drive-health service declaration')
    return True


def requested(env: dict[str, str]) -> bool:
    from . import remote_editor_qa
    qa = remote_editor_qa.admitted_build(env)
    return env.get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.respawnstudios.traverse' or qa is not None


def rust_source_path_arguments(enabled: bool) -> tuple[str, ...]:
    """Remap compiler source locations only for symbol-bearing ordinary workers."""
    if not enabled:
        return ()
    source = str(REPO)
    if '=' in source or '\x1f' in source:
        raise ValueError('Repository path cannot form an unambiguous Rust flag')
    return (f'--remap-path-prefix={source}=traverse-source',)


def rust_source_path_fingerprint(enabled: bool) -> dict:
    if not enabled:
        return {}
    return {'rustSourcePath': {'policy': RUST_SOURCE_PATH_POLICY,
                               'arguments': list(rust_source_path_arguments(True))}}


def apply_cargo_rust_source_path_policy(env: dict[str, str], enabled: bool) -> None:
    """Cargo's encoded flag field preserves spaces in the source checkout path."""
    arguments = rust_source_path_arguments(enabled)
    if not arguments:
        return
    if 'RUSTFLAGS' in env or 'CARGO_ENCODED_RUSTFLAGS' in env:
        raise ValueError('Unreviewed Rust flags in sanitized Cargo environment')
    env['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join(arguments)


def build_path(path: Path) -> None:
    if not path.is_absolute() or not path.is_relative_to(REPO / '.build'):
        raise ValueError('Symbols must stay inside the isolated build root')
    current = REPO
    for part in path.relative_to(REPO).parts:
        current /= part
        if current.is_symlink():
            raise ValueError('Redirected symbol path')
        if current.exists():
            facts = current.lstat()
            if facts.st_uid != os.getuid() or facts.st_mode & 0o022:
                raise ValueError('Unowned or writable symbol path')


def symbol_file(bundle: Path) -> Path:
    build_path(bundle)
    if not bundle.is_dir() or bundle.suffix != '.dSYM':
        raise ValueError('Missing debug-symbol bundle')
    count = total = 0
    for parent, dirs, files in os.walk(bundle, followlinks=False):
        for name in dirs + files:
            p = Path(parent) / name
            facts = p.lstat()
            count += 1
            if count > 128 or facts.st_uid != os.getuid() or facts.st_mode & 0o022 \
                    or not (stat.S_ISDIR(facts.st_mode) or stat.S_ISREG(facts.st_mode)):
                raise ValueError('Unsafe debug-symbol bundle')
            if stat.S_ISREG(facts.st_mode):
                if facts.st_nlink != 1:
                    raise ValueError('Shared debug-symbol file')
                total += facts.st_size
                if total > MAX_SYMBOL_BYTES:
                    raise ValueError('Debug-symbol bundle exceeds bound')
    directory = bundle / 'Contents/Resources/DWARF'
    entries = list(directory.iterdir())
    if len(entries) != 1 or not entries[0].is_file():
        raise ValueError('Expected one helper DWARF file')
    return entries[0]


def cargo_bundle(binary: Path) -> Path:
    """Resolve only Cargo's exact private release/deps symbol reference.

    Cargo publishes the ordinary executable as a file but the adjacent dSYM as
    one relative symlink to its hashed deps bundle. This allowance applies to
    these two compiler outputs only, never archived or installed artifacts.
    """
    build_path(binary)
    expected_roots = {REPO / '.build/traverse-release/tooling' / name / 'release'
                      for name in ('rust-smb', 'rust-sftp')}
    expected_roots |= {REPO / '.build/traverse-release/tooling' / name / target / 'release'
                       for name in ('rust-smb', 'rust-sftp')
                       for target in ('aarch64-apple-darwin', 'x86_64-apple-darwin')}
    if binary.parent not in expected_roots:
        raise ValueError('Unknown Cargo symbol output root')
    bundle = binary.with_name(binary.name + '.dSYM')
    if not bundle.is_symlink():
        return bundle
    facts = bundle.lstat()
    if facts.st_uid != os.getuid() or facts.st_nlink != 1 or facts.st_size > 256:
        raise ValueError('Unsafe Cargo symbol reference')
    target = os.readlink(bundle)
    name = re.escape(binary.name.replace('-', '_'))
    if not re.fullmatch(r'deps/' + name + r'-[0-9a-f]{16}\.dSYM', target):
        raise ValueError('Unrecognized Cargo symbol reference')
    resolved = binary.parent / target
    build_path(resolved)
    return resolved


def uuids(path: Path) -> dict[str, str]:
    result = subprocess.run(['/usr/bin/xcrun', 'dwarfdump', '--uuid', str(path)],
                            check=True, capture_output=True, text=True, timeout=20)
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        match = re.fullmatch(r'UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) .+', line)
        if not match or match[2] in values:
            raise ValueError('Unrecognized or repeated Mach-O UUID')
        values[match[2]] = match[1].upper()
    if not values:
        raise ValueError('Missing Mach-O UUID')
    return values


def validate(binary: Path, bundle: Path) -> dict:
    build_path(binary)
    if not binary.is_file() or binary.stat().st_nlink != 1:
        raise ValueError('Missing or shared symbol source binary')
    dwarf = symbol_file(bundle)
    identifiers = uuids(binary)
    if identifiers != uuids(dwarf):
        raise ValueError('Helper/dSYM UUID mismatch')
    # A UUID-only empty bundle can still be produced by dsymutil for a binary
    # compiled without debug information. UUID parity alone is insufficient.
    info = subprocess.run(['/usr/bin/xcrun', 'dwarfdump', '--show-form', '--debug-info',
                           '--recurse-depth=0', str(dwarf)],
                          check=True, capture_output=True, text=True, timeout=20)
    if 'DW_TAG_compile_unit' not in info.stdout:
        raise ValueError('Helper dSYM contains no debug compilation units')
    return {'UUIDs': identifiers, 'hasCompileUnits': True}


def copy_bundle(source_binary: Path, source_bundle: Path,
                target_binary: Path, destination: Path) -> dict:
    """Copy a compiler-owned bundle to its helper name; retain failed stages."""
    proof = validate(source_binary, source_bundle)
    build_path(target_binary); build_path(destination)
    if uuids(target_binary) != proof['UUIDs']:
        raise ValueError('Installed helper differs from its symbol source')
    if destination.exists():
        try:
            return validate(target_binary, destination)
        except ValueError:
            # A previous UUID is normal for an incremental generated build.
            # Validate ownership/tree bounds before moving that exact bundle.
            symbol_file(destination)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    stage_root = destination.parent / '.helper-symbol-staging'
    build_path(stage_root); stage_root.mkdir(mode=0o700, exist_ok=True)
    if len(list(stage_root.iterdir())) >= 64:
        raise ValueError('Retained symbol-stage limit reached')
    stage = stage_root / str(uuid.uuid4()).upper()
    stage.mkdir(mode=0o700)
    candidate = stage / destination.name
    previous = stage / 'previous.dSYM'
    moved_old = False
    try:
        shutil.copytree(source_bundle, candidate, symlinks=False)
        original = symbol_file(candidate)
        renamed = original.with_name(target_binary.name)
        if renamed != original:
            original.rename(renamed)
        info = candidate / 'Contents/Info.plist'
        fields = plistlib.loads(info.read_bytes())
        fields['CFBundleIdentifier'] = 'com.apple.xcode.dsym.' + target_binary.name
        info.write_bytes(plistlib.dumps(fields))
        validate(target_binary, candidate)
        if destination.exists():
            symbol_file(destination)
            destination.rename(previous); moved_old = True
        try:
            candidate.rename(destination)
        except Exception:
            if moved_old:
                previous.rename(destination); moved_old = False
            raise
        if moved_old:
            # Only the fully checked prior generated bundle in this new stage.
            shutil.rmtree(previous)
        stage.rmdir()
        return proof
    except Exception as error:
        with (stage / 'failure.json').open('x') as output:
            json.dump({'passed': False, 'errorType': type(error).__name__}, output)
        raise


def publish_for_xcode(source: Path, installed: Path, env: dict[str, str]) -> None:
    if not requested(env):
        return
    folder_text = env.get('DWARF_DSYM_FOLDER_PATH', '')
    if not folder_text:
        raise ValueError('Distribution helper requires the Xcode dSYM output folder')
    folder = Path(folder_text)
    build_path(folder)
    roles = HELPERS
    if installed.name == HEALTH_HELPER:
        app = installed.parent.parent.parent
        info_path = app / 'Contents/Info.plist'
        build_path(info_path)
        info = plistlib.loads(info_path.read_bytes())
        if health_declared(info):
            roles += (HEALTH_HELPER,)
    elif installed.name == HEALTH_SERVICE_EXECUTABLE:
        app = installed.parents[5]
        if installed != app / 'Contents/XPCServices' / HEALTH_SERVICE_LEAF / 'Contents/MacOS' / HEALTH_SERVICE_EXECUTABLE:
            raise ValueError('Drive-health service symbol target differs')
        info_path = app / 'Contents/Info.plist'
        build_path(info_path)
        if health_service_declared(plistlib.loads(info_path.read_bytes())):
            roles += (HEALTH_SERVICE_EXECUTABLE,)
    if installed.name not in roles:
        raise ValueError('Unknown distribution helper symbol role')
    copy_bundle(source, source.with_name(source.name + '.dSYM'), installed,
                folder / (installed.name + '.dSYM'))


def retain_crash_reporter_symbols(archive: Path) -> dict:
    """Retain the exact prepared dependency symbols beside Xcode's app/helpers."""
    from build_crash_reporter import FRAMEWORK, SYMBOLS, verify_prepared
    build_path(archive)
    if archive.suffix != '.xcarchive' or not archive.is_dir():
        raise ValueError('Expected an exact repo-local archive')
    verify_prepared()
    source = FRAMEWORK / 'Versions/A/CrashReporter'
    installed = archive / 'Products/Applications/Traverse.app/Contents/Frameworks/CrashReporter.framework/Versions/A/CrashReporter'
    return copy_bundle(source, SYMBOLS, installed, archive / 'dSYMs/CrashReporter.framework.dSYM')


def inspect_archive(archive: Path) -> dict:
    if not archive.is_relative_to(REPO / '.build') or archive.resolve() != archive \
            or archive.suffix != '.xcarchive' or not archive.is_dir():
        raise ValueError('Expected an exact repo-local archive')
    app = archive / 'Products/Applications/Traverse.app'
    rows = []
    info_path = app / 'Contents/Info.plist'
    build_path(info_path)
    info = plistlib.loads(info_path.read_bytes())
    roles = HELPERS + ((HEALTH_HELPER,) if health_declared(info) else ())
    for name in roles:
        binary = app / 'Contents/Helpers' / name
        dwarf = archive / 'dSYMs' / (name + '.dSYM') / 'Contents/Resources/DWARF' / name
        item = {'helper': name, 'passed': False}
        try:
            build_path(binary); build_path(dwarf)
        except ValueError as error:
            item['reason'] = str(error)
            rows.append(item)
            continue
        if binary.is_symlink() or not binary.is_file():
            item['reason'] = 'Missing or redirected helper'
        elif dwarf.resolve() != dwarf or not dwarf.is_file():
            item['reason'] = 'Missing or redirected helper dSYM'
            item['binaryUUIDs'] = uuids(binary)
        else:
            try:
                proof = validate(binary, dwarf.parent.parent.parent.parent)
                item.update(proof, passed=True)
            except ValueError as error:
                item['reason'] = str(error)
        rows.append(item)
    if health_service_declared(info):
        name = HEALTH_SERVICE_EXECUTABLE
        binary = app / 'Contents/XPCServices' / HEALTH_SERVICE_LEAF / 'Contents/MacOS' / name
        dwarf = archive / 'dSYMs' / (name + '.dSYM') / 'Contents/Resources/DWARF' / name
        item = {'helper': name, 'passed': False}
        try:
            build_path(binary); build_path(dwarf)
            if binary.is_symlink() or not binary.is_file() or dwarf.resolve() != dwarf or not dwarf.is_file():
                item['reason'] = 'Missing or redirected service binary/symbols'
            else:
                item.update(validate(binary, dwarf.parent.parent.parent.parent), passed=True)
        except ValueError as error:
            item['reason'] = str(error)
        rows.append(item)
    images = []
    framework = app / 'Contents/Frameworks/CrashReporter.framework'
    # Older retained archives predate the dependency. New archive construction
    # requires it through retain_crash_reporter_symbols before this inspection.
    if framework.exists() or framework.is_symlink():
        for name, binary, bundle in (
            ('Traverse', app / 'Contents/MacOS/Traverse', archive / 'dSYMs/Traverse.app.dSYM'),
            ('CrashReporter', framework / 'Versions/A/CrashReporter', archive / 'dSYMs/CrashReporter.framework.dSYM'),
        ):
            item = {'image': name, 'passed': False}
            try:
                item.update(validate(binary, bundle), passed=True)
            except ValueError as error:
                item['reason'] = str(error)
            images.append(item)
    return {'passed': all(row['passed'] for row in rows + images), 'helpers': rows, 'images': images}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    args = parser.parse_args()
    result = inspect_archive(args.archive.absolute())
    print(json.dumps(result, indent=2))
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
