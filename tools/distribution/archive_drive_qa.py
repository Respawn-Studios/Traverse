#!/usr/bin/env python3
"""Build and inspect one generated archive/drive review using MacExplorer Release.

This is a nonshipping Developer ID role. Runtime phases have separate host
admission; prepare/build/inspect never launch the app or mutate a drive.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import development as development_owner
from build_architecture import named
from distribution import remote_editor_qa
from distribution.preflight import entitlements, signing
from distribution.traverse_packet import TOOLING, CLANG_CACHE, SWIFT_CACHE, directory
from native_build_inputs import digest, source_inputs

ROOT = REPO / '.build/traverse-development'
PREFIX = 'local.macexplorer.archive-drive.qa.'
CASE_ENV = 'MAC_EXPLORER_ARCHIVE_DRIVE_QA_CASE'
ACTION = 'archive-drive-qa-developer-id'
PACKET = 'archive-drive-qa-developer-id-v1'
TEAM = remote_editor_qa.DEVELOPER_ID_TEAM
ARCHITECTURE = named('arm64')
NAME = 'Traverse Archive and Drive Review (Generated)'
PHASE_CEILING = {'archive-warm': 1, 'archive-cold': 1, 'drive-read-only': 1}


def canonical(value: str) -> str:
    try:
        if str(uuid.UUID(value)).upper() != value:
            raise ValueError('Noncanonical case')
    except (TypeError, AttributeError, ValueError):
        raise ValueError('Canonical archive/drive QA UUID required') from None
    return value


def identifier(case: str) -> str:
    return PREFIX + canonical(case).lower().replace('-', '')


def owned_directory(path: Path, *, private: bool = True) -> None:
    facts = path.lstat()
    if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid() \
            or private and facts.st_mode & 0o077:
        raise ValueError(f'Unsafe archive/drive QA directory: {path}')


def owned_json(path: Path, maximum: int = 4096) -> dict:
    facts = path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077 or facts.st_size > maximum:
        raise ValueError(f'Unsafe archive/drive QA record: {path}')
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError('Archive/drive QA record is not an object')
    return value


def put(path: Path, value: dict) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())


def case_path(tag: str) -> Path:
    return ROOT / canonical(tag)


def expected_info(case: Path) -> dict:
    info = plistlib.loads((REPO / 'Distribution/Info.plist').read_bytes())
    for key in ['CFBundleDocumentTypes', 'CFBundleURLTypes', 'MacExplorerReleasePurpose',
                'TraversePublicUpdaterVersion', 'TraversePrivateUpdaterVersion']:
        info.pop(key, None)
    info.update(CFBundleDisplayName=NAME, CFBundleName=NAME,
        MacExplorerDistributionChannel='qualification', MacExplorerAccessPolicy='local-user-v1',
        MacExplorerStorageMode='portable', TraverseArchiveDriveQualificationOnly=True,
        TraverseArchiveDriveQualificationCase=case.name,
        TraverseArchiveDriveQualificationRoot=str(case),
        TraverseArchiveDriveArchitecture=ARCHITECTURE.name)
    return info


def expected_config(case: Path) -> str:
    return '\n'.join([
        'PRODUCT_BUNDLE_IDENTIFIER = ' + identifier(case.name),
        'INFOPLIST_FILE = ' + str(case / 'ArchiveDriveInfo.plist'),
        'CODE_SIGN_STYLE = Manual',
        'ENABLE_APP_SANDBOX = NO',
        'ENABLE_HARDENED_RUNTIME = YES',
        'CODE_SIGN_ENTITLEMENTS = ' + str(REPO / 'Distribution/DirectParent.entitlements'),
        'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAC_EXPLORER_DISTRIBUTION TRAVERSE_ARCHIVE_DRIVE_QA',
        'MAC_EXPLORER_DISTRIBUTION_CHANNEL = qualification',
        'MAC_EXPLORER_ACCESS_POLICY = local-user-v1',
        'MAC_EXPLORER_HELPER_OUTPUT_PROFILE = local-only',
        'TRAVERSE_BUILD_ARCH = ' + ARCHITECTURE.name,
        CASE_ENV + ' = ' + case.name,
        'MAC_EXPLORER_DISTRIBUTION_COPYRIGHT = Generated qualification only',
        'ENABLE_DEBUG_DYLIB = NO',
        '',
    ])


def admitted_case(tag: str) -> tuple[Path, dict]:
    case = case_path(tag)
    if case.resolve() != case:
        raise ValueError('Redirected archive/drive QA case')
    for path in [case, case / 'source', case / 'source/Operation Root',
                 case / 'source/Library', case / 'evidence']:
        owned_directory(path)
    reservation = owned_json(case / 'reservation.json')
    if reservation != {'packet': 'traverse-development-v1', 'action': ACTION,
                       'master': development_owner.MASTER.name}:
        raise ValueError('Wrong archive/drive QA reservation')
    admission = owned_json(case / 'evidence/archive-drive-admission.json')
    if set(admission) != {'packet', 'case', 'bundleIdentifier', 'caseRoot',
                         'generatedOperationRoot', 'repoLocalLibrary', 'signingIdentity',
                         'teamIdentifier', 'phaseLaunchCeiling'} \
            or admission != dict(packet=PACKET, case=tag, bundleIdentifier=identifier(tag),
                caseRoot=str(case), generatedOperationRoot=str(case / 'source/Operation Root'),
                repoLocalLibrary=str(case / 'source/Library'),
                signingIdentity=admission.get('signingIdentity'), teamIdentifier=TEAM,
                phaseLaunchCeiling=PHASE_CEILING) \
            or not isinstance(admission['signingIdentity'], str) \
            or len(admission['signingIdentity']) != 40 \
            or any(ch not in '0123456789ABCDEF' for ch in admission['signingIdentity']):
        raise ValueError('Archive/drive QA admission differs')
    info_path = case / 'ArchiveDriveInfo.plist'
    facts = info_path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077:
        raise ValueError('Unsafe archive/drive QA Info')
    info = plistlib.loads(info_path.read_bytes())
    if info != expected_info(case):
        raise ValueError('Archive/drive QA bundle metadata differs')
    config_path = case / 'ArchiveDrive.xcconfig'
    facts = config_path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077 \
            or config_path.read_text() != expected_config(case):
        raise ValueError('Archive/drive QA build configuration differs')
    return case, admission


def admitted_build(env: dict[str, str]) -> Path | None:
    """Invoked inside Xcode's existing scanner phase before any helper embed."""
    tag = env.get(CASE_ENV, '')
    bundle = env.get('PRODUCT_BUNDLE_IDENTIFIER', '')
    if not tag:
        if bundle.startswith(PREFIX):
            raise ValueError('Archive/drive QA identity needs its exact case')
        return None
    case, admission = admitted_case(tag)
    conditions = env.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
    excluded = {'DEBUG', 'TRAVERSE_SFTP_EDITOR_QA', 'TRAVERSE_LOCAL_USER_DIRECT',
                'TRAVERSE_PUBLIC_UPDATER', 'TRAVERSE_PRIVATE_UPDATER',
                'MAC_EXPLORER_DIRECT_ACCESS_QUALIFICATION'}
    target = Path(env.get('TARGET_BUILD_DIR', '/'))
    if bundle != identifier(tag) or env.get('CONFIGURATION') != 'Release' \
            or target != case / 'Products/Release' or target.resolve() != target \
            or env.get('CONTENTS_FOLDER_PATH') != 'Mac Explorer.app/Contents' \
            or env.get('ARCHS') != ARCHITECTURE.name or env.get('ONLY_ACTIVE_ARCH') != 'YES' \
            or env.get('TRAVERSE_BUILD_ARCH') != ARCHITECTURE.name \
            or env.get('ENABLE_APP_SANDBOX') != 'NO' \
            or env.get('ENABLE_HARDENED_RUNTIME') != 'YES' \
            or env.get('CODE_SIGN_INJECT_BASE_ENTITLEMENTS') != 'NO' \
            or env.get('MAC_EXPLORER_DISTRIBUTION_CHANNEL') != 'qualification' \
            or env.get('MAC_EXPLORER_ACCESS_POLICY') != 'local-user-v1' \
            or env.get('MAC_EXPLORER_HELPER_OUTPUT_PROFILE') != 'local-only' \
            or set(conditions) != {'MAC_EXPLORER_DISTRIBUTION', 'TRAVERSE_ARCHIVE_DRIVE_QA'} \
            or excluded.intersection(conditions) \
            or env.get('DEVELOPMENT_TEAM') != TEAM \
            or env.get('EXPANDED_CODE_SIGN_IDENTITY') != admission['signingIdentity'] \
            or Path(env.get('CODE_SIGN_ENTITLEMENTS', '/')).resolve() != (REPO / 'Distribution/DirectParent.entitlements'):
        raise ValueError('Archive/drive QA build identity, rights or output differs')
    return case


def prepare(tag: str) -> dict:
    case = case_path(tag)
    owned_directory(ROOT, private=False)
    owned_directory(development_owner.MASTER)
    if case.exists() or case.is_symlink():
        raise ValueError('Fresh archive/drive QA case required')
    development_owner.audit()
    identity = remote_editor_qa.available_developer_id_identity()
    case.mkdir(mode=0o700)
    for relative in ['source', 'source/Operation Root', 'source/Library', 'evidence']:
        (case / relative).mkdir(mode=0o700)
    put(case / 'reservation.json', {'packet': 'traverse-development-v1',
        'action': ACTION, 'master': development_owner.MASTER.name})
    put(case / 'evidence/archive-drive-admission.json', dict(packet=PACKET, case=tag,
        bundleIdentifier=identifier(tag), caseRoot=str(case),
        generatedOperationRoot=str(case / 'source/Operation Root'),
        repoLocalLibrary=str(case / 'source/Library'), signingIdentity=identity,
        teamIdentifier=TEAM, phaseLaunchCeiling=PHASE_CEILING))
    info = expected_info(case)
    descriptor = os.open(case / 'ArchiveDriveInfo.plist', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        plistlib.dump(info, output)
        output.flush(); os.fsync(output.fileno())
    config = expected_config(case)
    descriptor = os.open(case / 'ArchiveDrive.xcconfig', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(config); output.flush(); os.fsync(output.fileno())
    admitted_case(tag)
    return dict(case=tag, bundleIdentifier=identifier(tag), prepared=True,
                appLaunches=0, driveMutations=0, archiveMutations=0)


def source_inventory() -> dict[str, str]:
    values = dict(source_inputs())
    for name in ['Distribution/Info.plist', 'Distribution/DirectParent.entitlements',
                 'tools/distribution/archive_drive_qa.py', 'tools/build_storage_worker.py',
                 'tools/distribution/sandbox.py', 'tools/distribution/remote_editor_qa.py']:
        values[name] = digest(REPO / name)
    return dict(sorted(values.items()))


def inspect(tag: str) -> dict:
    case, admission = admitted_case(tag)
    from distribution import helper_symbols
    from distribution.sandbox import compiled_tree_receipt
    app = case / 'Products/Release/Mac Explorer.app'
    inputs = owned_json(case / 'evidence/build-inputs.json', maximum=1 << 20)
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
    checks = dict(identity=info.get('CFBundleIdentifier') == identifier(tag)
            and parent['Identifier'] == identifier(tag),
        case=info.get('TraverseArchiveDriveQualificationCase') == tag
            and info.get('TraverseArchiveDriveQualificationRoot') == str(case)
            and info.get('TraverseArchiveDriveQualificationOnly') is True,
        channel=info.get('MacExplorerDistributionChannel') == 'qualification'
            and info.get('MacExplorerAccessPolicy') == 'local-user-v1'
            and info.get('MacExplorerStorageMode') == 'portable'
            and info.get('TraverseArchiveDriveArchitecture') == ARCHITECTURE.name,
        thinArchitecture=parent_arches == [ARCHITECTURE.name]
            and scanner_arches == [ARCHITECTURE.name],
        noShippingMetadata=not any(key in info for key in ['MacExplorerReleasePurpose',
            'TraversePublicUpdaterVersion', 'TraversePrivateUpdaterVersion']),
        noFinderRegistration='CFBundleDocumentTypes' not in info and 'CFBundleURLTypes' not in info,
        noNetworkHelpers=helpers == ['storage-scanner-worker'],
        exactSymbols=set(symbols) == {'Mac Explorer.app.dSYM', 'storage-scanner-worker.dSYM'},
        emptyParentRights=entitlements(app) == {}, emptyScannerRights=entitlements(scanner) == {},
        hardenedParent=parent['runtime'] is True, hardenedScanner=child['runtime'] is True,
        developerID=parent['TeamIdentifier'] == TEAM and child['TeamIdentifier'] == TEAM
            and parent['authorities'] and parent['authorities'][0].startswith('Developer ID Application: '),
        noDebugShim=not (app / 'Contents/MacOS/Mac Explorer.debug.dylib').exists(),
        sourceMatch=inputs.get('sourceSHA256') == source_inventory())
    result = dict(passed=all(checks.values()), checks=checks, sourceInputs=len(inputs.get('sourceSHA256', {})),
                  app=compiled_tree_receipt(app), symbols=symbols,
                  symbolMatch=symbol_match,
                  signer=admission['signingIdentity'])
    if not result['passed']:
        raise ValueError('Archive/drive QA artifact inspection failed')
    return result


def issue_phase(tag: str, phase: str) -> dict:
    """Issue one exact attempt only after an owner scope and signed seal exist."""
    if phase not in PHASE_CEILING:
        raise ValueError('Unknown archive/drive QA phase')
    case, _ = admitted_case(tag)
    built = owned_json(case / 'evidence/build-result.json', maximum=1 << 20)
    observed = inspect(tag)
    if built.get('passed') is not True \
            or built.get('inspected', {}).get('app') != observed['app']:
        raise ValueError('Retained signed artifact differs from the build result')
    scope_path = case / 'evidence/runtime-scope.json'
    scope = owned_json(scope_path)
    expected_keys = {'packet', 'case', 'bundleIdentifier', 'caseRoot', 'fixtureRoot',
                     'artifactTreeSHA256', 'expiresUTC', 'phaseLaunchCeiling',
                     'archiveForwardJobsMaximum', 'archiveColdUndosMaximum',
                     'generatedFileMaximumBytes', 'generatedTotalMaximumBytes',
                     'driveMutationMaximum', 'networkSessionsMaximum', 'trashJobsMaximum'}
    try:
        expires = datetime.strptime(scope['expiresUTC'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except (KeyError, TypeError, ValueError):
        raise ValueError('Invalid archive/drive QA runtime deadline') from None
    now = datetime.now(timezone.utc)
    if set(scope) != expected_keys or scope['packet'] != 'archive-drive-runtime-scope-v1' \
            or scope['case'] != tag or scope['bundleIdentifier'] != identifier(tag) \
            or scope['caseRoot'] != str(case) \
            or scope['fixtureRoot'] != str(case / 'source/Operation Root') \
            or scope['artifactTreeSHA256'] != observed['app']['treeSHA256'] \
            or scope['phaseLaunchCeiling'] != PHASE_CEILING \
            or any(type(value) is not int for value in scope['phaseLaunchCeiling'].values()) \
            or type(scope['archiveForwardJobsMaximum']) is not int \
            or scope['archiveForwardJobsMaximum'] != 12 \
            or type(scope['archiveColdUndosMaximum']) is not int \
            or scope['archiveColdUndosMaximum'] != 12 \
            or type(scope['generatedFileMaximumBytes']) is not int \
            or not 1 <= scope['generatedFileMaximumBytes'] <= (1 << 20) \
            or type(scope['generatedTotalMaximumBytes']) is not int \
            or not scope['generatedFileMaximumBytes'] <= scope['generatedTotalMaximumBytes'] <= (4 << 20) \
            or type(scope['driveMutationMaximum']) is not int or scope['driveMutationMaximum'] != 0 \
            or type(scope['networkSessionsMaximum']) is not int or scope['networkSessionsMaximum'] != 0 \
            or type(scope['trashJobsMaximum']) is not int or scope['trashJobsMaximum'] != 0 \
            or not now <= expires <= now + timedelta(hours=12):
        raise ValueError('Archive/drive QA runtime scope differs')
    permit = case / 'evidence' / ('archive-drive-' + phase + '-permit.json')
    consumed = case / 'evidence' / ('archive-drive-' + phase + '-consumed.json')
    if permit.exists() or permit.is_symlink() or consumed.exists() or consumed.is_symlink():
        raise ValueError('Archive/drive QA phase already issued or spent')
    scope_hash = hashlib.sha256(scope_path.read_bytes()).hexdigest()
    put(permit, dict(packet='archive-drive-phase-permit-v1', case=tag, phase=phase,
        bundleIdentifier=identifier(tag), caseRoot=str(case),
        artifactTreeSHA256=observed['app']['treeSHA256'], scopeSHA256=scope_hash,
        expiresUTC=scope['expiresUTC'], attempt=1))
    return dict(case=tag, phase=phase, issued=True, permit=str(permit.relative_to(REPO)),
                appLaunches=0, phaseAttemptsRemaining=1)


def build(tag: str) -> dict:
    case, admission = admitted_case(tag)
    if (case / 'evidence/build-result.json').exists():
        raise ValueError('A built case is immutable; reserve another for a rebuild')
    if (case / 'Products').exists():
        raise ValueError('A retained product already occupies this case')
    source = source_inventory()
    put(case / 'evidence/build-inputs.json', dict(sourceSHA256=source,
        sourceInputs=len(source), case=tag, bundleIdentifier=identifier(tag),
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
        '-destination', 'platform=macOS,arch=' + ARCHITECTURE.name,
        '-xcconfig', str(case / 'ArchiveDrive.xcconfig'),
        '-derivedDataPath', str(REPO / '.build/xcode-release'),
        '-clonedSourcePackagesDirPath', str(tooling / 'packages'), '-skipPackageUpdates',
        '-disableAutomaticPackageResolution', '-disablePackageRepositoryCache',
        '-packageCachePath', str(tooling / 'package-cache'), '-packageAuthorizationProvider', 'netrc',
        '-jobs', '4', 'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=' + admission['signingIdentity'],
        'DEVELOPMENT_TEAM=' + TEAM, 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
        'ARCHS=' + ARCHITECTURE.name, 'TRAVERSE_BUILD_ARCH=' + ARCHITECTURE.name,
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
    if source_inventory() != source:
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
                raise ValueError('Missing exact archive/drive QA app or symbols')
        inspected = inspect(tag)
        result.update(passed=True, inspected=inspected)
    except Exception as error:
        result.update(passed=False, failure='Signing or inspection failed',
                      failureType=type(error).__name__)
    put(case / 'evidence/build-result.json', result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'build', 'inspect', 'issue-phase'])
    parser.add_argument('--case', required=True)
    parser.add_argument('--phase', choices=sorted(PHASE_CEILING))
    args = parser.parse_args()
    if (args.action == 'issue-phase') != (args.phase is not None):
        parser.error('--phase is required only for issue-phase')
    result = prepare(args.case) if args.action == 'prepare' else build(args.case) if args.action == 'build' \
        else issue_phase(args.case, args.phase) if args.action == 'issue-phase' else inspect(args.case)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result.get('passed') is False:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
