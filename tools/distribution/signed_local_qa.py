#!/usr/bin/env python3
"""Build/sign/inspect mechanics for exact nonshipping local Release roles.

Role-specific identity, source inventory and runtime ceilings stay in each
role module. No function here grants a runtime visit.
"""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import stat
import subprocess
import time
from typing import Callable

import development as development_owner
from distribution import remote_editor_qa
from distribution.preflight import entitlements, signing
from distribution.traverse_packet import TOOLING, CLANG_CACHE, SWIFT_CACHE, directory
from native_build_inputs import digest, source_inputs

REPO = Path(__file__).resolve().parents[2]
TEAM = remote_editor_qa.DEVELOPER_ID_TEAM
ARCH = 'arm64'


def _bounded_owned_tree(root: Path, *, maximum_bytes: int, maximum_entries: int) -> dict[str, int]:
    """Count generated case files without reading their contents or following links."""
    facts = root.lstat()
    if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_mode & 0o077:
        raise ValueError('Generated runtime root is not private and owned')
    total = entries = 0
    def fail(error: OSError) -> None:
        raise error
    for parent, directories, files in os.walk(root, followlinks=False, onerror=fail):
        parent_facts = Path(parent).lstat()
        if not stat.S_ISDIR(parent_facts.st_mode) or parent_facts.st_uid != os.getuid():
            raise ValueError('Generated runtime directory changed')
        for name in directories + files:
            item = (Path(parent) / name).lstat()
            if item.st_uid != os.getuid() or not (stat.S_ISDIR(item.st_mode)
                    or stat.S_ISREG(item.st_mode) and item.st_nlink == 1):
                raise ValueError('Generated runtime item is unowned, linked or unsupported')
            entries += 1
            if stat.S_ISREG(item.st_mode):
                total += item.st_size
            if entries > maximum_entries or total > maximum_bytes:
                raise ValueError('Generated runtime resource ceiling exceeded')
    return {'bytes': total, 'entries': entries}


def audit_runtime_case(case: Path, *, log: Path | None = None) -> dict:
    """Small shared signed-role profile/evidence budget; image bytes live elsewhere."""
    profile = _bounded_owned_tree(case / 'source/Library',
        maximum_bytes=64 << 20, maximum_entries=1024)
    evidence = _bounded_owned_tree(case / 'evidence',
        maximum_bytes=16 << 20, maximum_entries=128)
    if log is not None and os.path.lexists(log):
        facts = log.lstat()
        if log.parent != case / 'evidence' or not stat.S_ISREG(facts.st_mode) \
                or facts.st_uid != os.getuid() or facts.st_nlink != 1 \
                or stat.S_IMODE(facts.st_mode) != 0o600 or facts.st_size > 4 << 20:
            raise ValueError('Generated phase log identity or 4 MiB ceiling changed')
    return {'profile': profile, 'evidence': evidence}


def source_inventory(extra: tuple[str, ...]) -> dict[str, str]:
    values = dict(source_inputs())
    names = (
        'Distribution/Info.plist',
        'Distribution/DirectParent.entitlements',
        'tools/distribution/signed_local_qa.py',
        'tools/build_storage_worker.py',
        'tools/distribution/sandbox.py',
        'tools/distribution/remote_editor_qa.py',
    ) + extra
    for name in names:
        values[name] = digest(REPO / name)
    return dict(sorted(values.items()))


def inspect(case: Path, admission: dict, identifier: str,
            role_info_valid: Callable[[dict], bool],
            inventory: Callable[[], dict[str, str]], label: str,
            *, require_current_source: bool = True) -> dict:
    from distribution import helper_symbols
    from distribution.sandbox import compiled_tree_receipt

    app = case / 'Products/Release/Mac Explorer.app'
    input_path = case / 'evidence/build-inputs.json'
    facts = input_path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077 or facts.st_size > (1 << 20):
        raise ValueError(f'{label} build input receipt unavailable')
    import json
    inputs = json.loads(input_path.read_bytes())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    scanner = app / 'Contents/Helpers/storage-scanner-worker'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--deep', str(app)],
                   capture_output=True, check=True, timeout=30)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(scanner)],
                   capture_output=True, check=True, timeout=30)
    parent = signing(app)
    child = signing(scanner)
    parent_arches = subprocess.run(['/usr/bin/lipo', '-archs',
        str(app / 'Contents/MacOS/Mac Explorer')], check=True, capture_output=True,
        text=True, timeout=30).stdout.strip().split()
    scanner_arches = subprocess.run(['/usr/bin/lipo', '-archs', str(scanner)],
        check=True, capture_output=True, text=True, timeout=30).stdout.strip().split()
    helpers = sorted(p.name for p in scanner.parent.iterdir())
    symbols = {name: compiled_tree_receipt(case / 'Products/Release' / name)
        for name in ['Mac Explorer.app.dSYM', 'storage-scanner-worker.dSYM']
        if (case / 'Products/Release' / name).is_dir()
        and not (case / 'Products/Release' / name).is_symlink()}
    symbol_match = {
        'parent': helper_symbols.validate(app / 'Contents/MacOS/Mac Explorer',
            case / 'Products/Release/Mac Explorer.app.dSYM'),
        'scanner': helper_symbols.validate(scanner,
            case / 'Products/Release/storage-scanner-worker.dSYM'),
    }
    current_source_match = inputs.get('sourceSHA256') == inventory()
    checks = dict(identity=info.get('CFBundleIdentifier') == identifier
            and parent['Identifier'] == identifier,
        case=role_info_valid(info),
        channel=info.get('MacExplorerDistributionChannel') == 'qualification'
            and info.get('MacExplorerAccessPolicy') == 'local-user-v1'
            and info.get('MacExplorerStorageMode') == 'portable'
            and info.get('TraverseArchiveDriveArchitecture',
                         info.get('TraverseDriveImageArchitecture')) == ARCH,
        thinArchitecture=parent_arches == [ARCH] and scanner_arches == [ARCH],
        noShippingMetadata=not any(key in info for key in ['MacExplorerReleasePurpose',
            'TraversePublicUpdaterVersion', 'TraversePrivateUpdaterVersion']),
        noFinderRegistration='CFBundleDocumentTypes' not in info and 'CFBundleURLTypes' not in info,
        noNetworkHelpers=helpers == ['storage-scanner-worker'],
        exactSymbols=set(symbols) == {'Mac Explorer.app.dSYM', 'storage-scanner-worker.dSYM'},
        emptyParentRights=entitlements(app) == {}, emptyScannerRights=entitlements(scanner) == {},
        hardenedParent=parent['runtime'] is True, hardenedScanner=child['runtime'] is True,
        developerID=parent['TeamIdentifier'] == TEAM and child['TeamIdentifier'] == TEAM
            and parent['authorities'] and parent['authorities'][0].startswith('Developer ID Application: '),
        noDebugShim=not (app / 'Contents/MacOS/Mac Explorer.debug.dylib').exists())
    if require_current_source:
        checks['sourceMatch'] = current_source_match
    result = dict(passed=all(checks.values()), checks=checks,
                  currentSourceMatch=current_source_match,
                  sourceInputs=len(inputs.get('sourceSHA256', {})),
                  app=compiled_tree_receipt(app), symbols=symbols,
                  symbolMatch=symbol_match, signer=admission['signingIdentity'])
    if not result['passed']:
        raise ValueError(f'{label} artifact inspection failed')
    return result


def build(case: Path, tag: str, admission: dict, config_leaf: str,
          inventory: Callable[[], dict[str, str]],
          inspect_role: Callable[[], dict], put: Callable[[Path, dict], None], label: str) -> dict:
    if (case / 'evidence/build-result.json').exists() or (case / 'Products').exists():
        raise ValueError(f'{label} built case is immutable')
    # Embedding cannot repair a stale prepared dependency. Refuse before
    # compiling the app, so its caller can prepare the shared framework once.
    from build_crash_reporter import verify_prepared
    verify_prepared()
    source = inventory()
    put(case / 'evidence/build-inputs.json', dict(sourceSHA256=source,
        sourceInputs=len(source), case=tag, bundleIdentifier=admission['bundleIdentifier'],
        appLaunches=0, driveMutations=0))
    tooling = TOOLING
    product = case / 'Products/Release'
    for path in [tooling / 'tmp', tooling / 'packages', tooling / 'package-cache',
                 CLANG_CACHE, SWIFT_CACHE, product]:
        directory(path)
    env = os.environ.copy()
    env.pop('CFFIXED_USER_HOME', None)
    env.update(TMPDIR=str(tooling / 'tmp') + '/',
        CLANG_MODULE_CACHE_PATH=str(CLANG_CACHE),
        SWIFTPM_MODULECACHE_OVERRIDE=str(SWIFT_CACHE),
        SWIFTPM_NETRC_DATA='')
    command = ['/usr/bin/xcodebuild', '-project', str(REPO / 'MacExplorer.xcodeproj'),
        '-scheme', 'MacExplorer', '-configuration', 'Release',
        '-destination', 'platform=macOS,arch=' + ARCH,
        '-xcconfig', str(case / config_leaf),
        '-derivedDataPath', str(REPO / '.build/xcode-release'),
        '-clonedSourcePackagesDirPath', str(tooling / 'packages'), '-skipPackageUpdates',
        '-disableAutomaticPackageResolution', '-disablePackageRepositoryCache',
        '-packageCachePath', str(tooling / 'package-cache'), '-packageAuthorizationProvider', 'netrc',
        '-jobs', '4', 'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=' + admission['signingIdentity'],
        'DEVELOPMENT_TEAM=' + TEAM, 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
        'ARCHS=' + ARCH, 'TRAVERSE_BUILD_ARCH=' + ARCH,
        'ONLY_ACTIVE_ARCH=YES',
        'OTHER_CODE_SIGN_FLAGS=--timestamp=none', 'CONFIGURATION_BUILD_DIR=' + str(product),
        'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'COMPILER_INDEX_STORE_ENABLE=NO',
        'CLANG_MODULE_CACHE_PATH=' + str(CLANG_CACHE),
        'SWIFT_MODULE_CACHE_PATH=' + str(SWIFT_CACHE), 'build']
    started = time.monotonic()
    failure = None
    log = case / 'evidence/build.log'
    with log.open('xb') as output:
        child = subprocess.Popen(command, cwd=REPO, env=env, stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        while child.poll() is None:
            if time.monotonic() - started > 1200 or log.stat().st_size > (32 << 20):
                failure = 'Build deadline or log limit reached'
            if failure is None:
                try:
                    development_owner.audit()
                    from distribution.sandbox import editor_release_audit
                    editor_release_audit(case)
                except Exception as error:
                    failure = 'Build resource audit failed: ' + type(error).__name__
            if failure is not None:
                child.terminate()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
                break
            time.sleep(1)
    result = dict(case=tag, actualBuildExit=child.returncode, elapsedSeconds=time.monotonic()-started,
                  appLaunches=0, driveMutations=0, log=str(log.relative_to(REPO)))
    if child.returncode != 0 or failure is not None:
        result.update(passed=False, failure=failure or 'Xcode build failed')
        put(case / 'evidence/build-result.json', result)
        return result
    if inventory() != source:
        result.update(passed=False, failure='Source changed during build')
        put(case / 'evidence/build-result.json', result)
        return result
    try:
        app = product / 'Mac Explorer.app'
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', admission['signingIdentity'],
            '--timestamp=none', '--options', 'runtime', '--entitlements',
            str(REPO / 'Distribution/DirectParent.entitlements'), str(app)],
            capture_output=True, check=True, timeout=30, stdin=subprocess.DEVNULL)
        for artifact in [app, product / 'Mac Explorer.app.dSYM', product / 'storage-scanner-worker.dSYM']:
            if not artifact.is_dir() or artifact.is_symlink():
                raise ValueError(f'Missing exact {label} app or symbols')
        inspected = inspect_role()
        result.update(passed=True, inspected=inspected)
    except Exception as error:
        result.update(passed=False, failure='Signing or inspection failed',
                      failureType=type(error).__name__)
    put(case / 'evidence/build-result.json', result)
    return result
