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
import sys
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import development as development_owner
from build_architecture import named
from distribution import remote_editor_qa, signed_local_qa

ROOT = REPO / '.build/traverse-development'
PREFIX = 'local.macexplorer.archive-drive.qa.'
CASE_ENV = 'MAC_EXPLORER_ARCHIVE_DRIVE_QA_CASE'
ACTION = 'archive-drive-qa-developer-id'
PACKET = 'archive-drive-qa-developer-id-v1'
TEAM = remote_editor_qa.DEVELOPER_ID_TEAM
ARCHITECTURE = named('arm64')
NAME = 'Traverse Archive and Drive Review (Generated)'
PHASE_CEILING = {'archive-warm': 1, 'archive-cold': 1, 'drive-read-only': 1}
SUITE_JOBS = {'authored': 12, 'tar-members': 42}


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
    admission = owned_json(case / 'evidence/archive-drive-admission.json')
    if admission.get('archiveSuite') == 'tar-members':
        info['TraverseArchiveDriveQualificationSuite'] = 'tar-members'
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
    member_suite = admission.get('archiveSuite') == 'tar-members'
    expected_admission = dict(packet=PACKET, case=tag, bundleIdentifier=identifier(tag),
        caseRoot=str(case), generatedOperationRoot=str(case / 'source/Operation Root'),
        repoLocalLibrary=str(case / 'source/Library'),
        signingIdentity=admission.get('signingIdentity'), teamIdentifier=TEAM,
        phaseLaunchCeiling=PHASE_CEILING)
    if member_suite:
        expected_admission['archiveSuite'] = 'tar-members'
    if admission != expected_admission \
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


def prepare(tag: str, suite: str = 'authored') -> dict:
    if suite not in SUITE_JOBS:
        raise ValueError('Unknown archive/drive QA suite')
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
    admission = dict(packet=PACKET, case=tag,
        bundleIdentifier=identifier(tag), caseRoot=str(case),
        generatedOperationRoot=str(case / 'source/Operation Root'),
        repoLocalLibrary=str(case / 'source/Library'), signingIdentity=identity,
        teamIdentifier=TEAM, phaseLaunchCeiling=PHASE_CEILING)
    if suite == 'tar-members':
        admission['archiveSuite'] = suite
    put(case / 'evidence/archive-drive-admission.json', admission)
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
    return signed_local_qa.source_inventory((
        'tools/distribution/archive_drive_qa.py',
        'tools/distribution/drive_image_qa.py',
    ))


def inspect(tag: str) -> dict:
    case, admission = admitted_case(tag)
    def role_info_valid(info: dict) -> bool:
        return info.get('TraverseArchiveDriveQualificationCase') == tag \
            and info.get('TraverseArchiveDriveQualificationRoot') == str(case) \
            and info.get('TraverseArchiveDriveQualificationOnly') is True \
            and info.get('TraverseArchiveDriveQualificationSuite', 'authored') == admission.get('archiveSuite', 'authored') \
            and not any(key.startswith('TraverseDriveImageQualification') for key in info)
    return signed_local_qa.inspect(case, admission, identifier(tag), role_info_valid,
                                   source_inventory, 'Archive/drive QA')


def issue_phase(tag: str, phase: str) -> dict:
    """Issue one exact attempt only after an owner scope and signed seal exist."""
    if phase not in PHASE_CEILING:
        raise ValueError('Unknown archive/drive QA phase')
    case, admission = admitted_case(tag)
    suite = admission.get('archiveSuite', 'authored')
    jobs = SUITE_JOBS[suite]
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
    if suite == 'tar-members':
        expected_keys.add('archiveSuite')
        expected_keys.add('generatedFixtureEntriesMaximum')
        if scope.get('archiveSuite') != suite \
                or type(scope.get('generatedFixtureEntriesMaximum')) is not int \
                or scope['generatedFixtureEntriesMaximum'] != 192:
            raise ValueError('Archive member QA runtime suite differs')
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
            or scope['archiveForwardJobsMaximum'] != jobs \
            or type(scope['archiveColdUndosMaximum']) is not int \
            or scope['archiveColdUndosMaximum'] != jobs \
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
    return signed_local_qa.build(case, tag, admission, 'ArchiveDrive.xcconfig',
        source_inventory, lambda: inspect(tag), put, 'Archive/drive QA')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'build', 'inspect', 'issue-phase'])
    parser.add_argument('--case', required=True)
    parser.add_argument('--phase', choices=sorted(PHASE_CEILING))
    parser.add_argument('--suite', choices=sorted(SUITE_JOBS))
    args = parser.parse_args()
    if (args.action == 'issue-phase') != (args.phase is not None):
        parser.error('--phase is required only for issue-phase')
    if args.suite is not None and args.action != 'prepare':
        parser.error('--suite is available only for prepare')
    result = prepare(args.case, args.suite or 'authored') if args.action == 'prepare' else build(args.case) if args.action == 'build' \
        else issue_phase(args.case, args.phase) if args.action == 'issue-phase' else inspect(args.case)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result.get('passed') is False:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
