#!/usr/bin/env python3
"""One distinct nonshipping signed Release role for an owned APFS image.

Prepare/build/inspect and phase issuance do not create or attach an image.
The host runtime owner is verify_signed_drive_image.py.
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

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import development as development_owner
from distribution import archive_drive_qa, remote_editor_qa, signed_local_qa

ROOT = REPO / '.build/traverse-development'
PREFIX = 'local.macexplorer.drive-image.qa.'
CASE_ENV = 'MAC_EXPLORER_DRIVE_IMAGE_QA_CASE'
ACTION = 'drive-image-qa-developer-id'
PACKET = 'drive-image-qa-developer-id-v1'
TEAM = remote_editor_qa.DEVELOPER_ID_TEAM
NAME = 'Traverse Drive Image Review (Generated)'
PHASE_CEILING = {'pre-image': 1, 'warm': 1, 'cold': 1}
IMAGE_BYTES = 1 << 30
canonical = archive_drive_qa.canonical
owned_directory = archive_drive_qa.owned_directory
owned_json = archive_drive_qa.owned_json
put = archive_drive_qa.put


def identifier(tag: str) -> str:
    return PREFIX + canonical(tag).lower().replace('-', '')


def case_path(tag: str) -> Path:
    return ROOT / canonical(tag)


def fixture_path(tag: str) -> Path:
    return REPO / '.build/fixtures' / ('drive-lifecycle-' + canonical(tag))


def expected_info(case: Path) -> dict:
    info = plistlib.loads((REPO / 'Distribution/Info.plist').read_bytes())
    for key in ['CFBundleDocumentTypes', 'CFBundleURLTypes', 'MacExplorerReleasePurpose',
                'TraversePublicUpdaterVersion', 'TraversePrivateUpdaterVersion']:
        info.pop(key, None)
    info.update(CFBundleDisplayName=NAME, CFBundleName=NAME,
        MacExplorerDistributionChannel='qualification', MacExplorerAccessPolicy='local-user-v1',
        MacExplorerStorageMode='portable', TraverseDriveImageQualificationOnly=True,
        TraverseDriveImageQualificationCase=case.name,
        TraverseDriveImageQualificationRoot=str(case),
        TraverseDriveImageArchitecture='arm64')
    return info


def expected_config(case: Path) -> str:
    return '\n'.join([
        'PRODUCT_BUNDLE_IDENTIFIER = ' + identifier(case.name),
        'INFOPLIST_FILE = ' + str(case / 'DriveImageInfo.plist'),
        'CODE_SIGN_STYLE = Manual',
        'ENABLE_APP_SANDBOX = NO',
        'ENABLE_HARDENED_RUNTIME = YES',
        'CODE_SIGN_ENTITLEMENTS = ' + str(REPO / 'Distribution/DirectParent.entitlements'),
        'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAC_EXPLORER_DISTRIBUTION TRAVERSE_DRIVE_IMAGE_QA',
        'MAC_EXPLORER_DISTRIBUTION_CHANNEL = qualification',
        'MAC_EXPLORER_ACCESS_POLICY = local-user-v1',
        'MAC_EXPLORER_HELPER_OUTPUT_PROFILE = local-only',
        'TRAVERSE_BUILD_ARCH = arm64',
        CASE_ENV + ' = ' + case.name,
        'MAC_EXPLORER_DISTRIBUTION_COPYRIGHT = Generated qualification only',
        'ENABLE_DEBUG_DYLIB = NO',
        '',
    ])


def admitted_case(tag: str) -> tuple[Path, dict]:
    case = case_path(tag)
    if case.resolve() != case:
        raise ValueError('Redirected drive-image QA case')
    for path in [case, case / 'source', case / 'source/Library', case / 'evidence']:
        owned_directory(path)
    reservation = owned_json(case / 'reservation.json')
    if reservation != {'packet': 'traverse-development-v1', 'action': ACTION,
                       'master': development_owner.MASTER.name}:
        raise ValueError('Wrong drive-image QA reservation')
    admission = owned_json(case / 'evidence/drive-image-admission.json')
    if set(admission) != {'packet', 'case', 'bundleIdentifier', 'caseRoot',
                         'fixtureRoot', 'repoLocalLibrary', 'signingIdentity',
                         'teamIdentifier', 'phaseLaunchCeiling'} \
            or admission != dict(packet=PACKET, case=tag, bundleIdentifier=identifier(tag),
                caseRoot=str(case), fixtureRoot=str(fixture_path(tag)),
                repoLocalLibrary=str(case / 'source/Library'),
                signingIdentity=admission.get('signingIdentity'), teamIdentifier=TEAM,
                phaseLaunchCeiling=PHASE_CEILING) \
            or not isinstance(admission['signingIdentity'], str) \
            or len(admission['signingIdentity']) != 40 \
            or any(ch not in '0123456789ABCDEF' for ch in admission['signingIdentity']):
        raise ValueError('Drive-image QA admission differs')
    info_path = case / 'DriveImageInfo.plist'
    facts = info_path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077 \
            or plistlib.loads(info_path.read_bytes()) != expected_info(case):
        raise ValueError('Drive-image QA Info differs')
    config_path = case / 'DriveImage.xcconfig'
    facts = config_path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077 \
            or config_path.read_text() != expected_config(case):
        raise ValueError('Drive-image QA build configuration differs')
    return case, admission


def admitted_build(env: dict[str, str]) -> Path | None:
    tag = env.get(CASE_ENV, '')
    bundle = env.get('PRODUCT_BUNDLE_IDENTIFIER', '')
    if not tag:
        if bundle.startswith(PREFIX):
            raise ValueError('Drive-image QA identity needs its exact case')
        return None
    case, admission = admitted_case(tag)
    conditions = env.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
    excluded = {'DEBUG', 'TRAVERSE_ARCHIVE_DRIVE_QA', 'TRAVERSE_SFTP_EDITOR_QA',
                'TRAVERSE_LOCAL_USER_DIRECT', 'TRAVERSE_PUBLIC_UPDATER',
                'TRAVERSE_PRIVATE_UPDATER', 'MAC_EXPLORER_DIRECT_ACCESS_QUALIFICATION'}
    target = Path(env.get('TARGET_BUILD_DIR', '/'))
    if bundle != identifier(tag) or env.get('CONFIGURATION') != 'Release' \
            or target != case / 'Products/Release' or target.resolve() != target \
            or env.get('CONTENTS_FOLDER_PATH') != 'Mac Explorer.app/Contents' \
            or env.get('ARCHS') != 'arm64' or env.get('ONLY_ACTIVE_ARCH') != 'YES' \
            or env.get('TRAVERSE_BUILD_ARCH') != 'arm64' \
            or env.get('ENABLE_APP_SANDBOX') != 'NO' \
            or env.get('ENABLE_HARDENED_RUNTIME') != 'YES' \
            or env.get('CODE_SIGN_INJECT_BASE_ENTITLEMENTS') != 'NO' \
            or env.get('MAC_EXPLORER_DISTRIBUTION_CHANNEL') != 'qualification' \
            or env.get('MAC_EXPLORER_ACCESS_POLICY') != 'local-user-v1' \
            or env.get('MAC_EXPLORER_HELPER_OUTPUT_PROFILE') != 'local-only' \
            or set(conditions) != {'MAC_EXPLORER_DISTRIBUTION', 'TRAVERSE_DRIVE_IMAGE_QA'} \
            or excluded.intersection(conditions) \
            or env.get('DEVELOPMENT_TEAM') != TEAM \
            or env.get('EXPANDED_CODE_SIGN_IDENTITY') != admission['signingIdentity'] \
            or Path(env.get('CODE_SIGN_ENTITLEMENTS', '/')).resolve() \
                != (REPO / 'Distribution/DirectParent.entitlements'):
        raise ValueError('Drive-image QA build identity, rights or output differs')
    return case


def prepare(tag: str) -> dict:
    case = case_path(tag)
    owned_directory(ROOT, private=False)
    owned_directory(development_owner.MASTER)
    if case.exists() or case.is_symlink():
        raise ValueError('Fresh drive-image QA case required')
    development_owner.audit()
    identity = remote_editor_qa.available_developer_id_identity()
    case.mkdir(mode=0o700)
    for relative in ['source', 'source/Library', 'evidence']:
        (case / relative).mkdir(mode=0o700)
    put(case / 'reservation.json', {'packet': 'traverse-development-v1',
        'action': ACTION, 'master': development_owner.MASTER.name})
    put(case / 'evidence/drive-image-admission.json', dict(packet=PACKET, case=tag,
        bundleIdentifier=identifier(tag), caseRoot=str(case), fixtureRoot=str(fixture_path(tag)),
        repoLocalLibrary=str(case / 'source/Library'), signingIdentity=identity,
        teamIdentifier=TEAM, phaseLaunchCeiling=PHASE_CEILING))
    descriptor = os.open(case / 'DriveImageInfo.plist',
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        plistlib.dump(expected_info(case), output)
        output.flush(); os.fsync(output.fileno())
    descriptor = os.open(case / 'DriveImage.xcconfig',
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(expected_config(case)); output.flush(); os.fsync(output.fileno())
    admitted_case(tag)
    return dict(case=tag, bundleIdentifier=identifier(tag), prepared=True,
                appLaunches=0, driveMutations=0, imageCreated=False)


def source_inventory() -> dict[str, str]:
    return signed_local_qa.source_inventory((
        'tools/distribution/archive_drive_qa.py',
        'tools/distribution/drive_image_qa.py',
        'tools/verify_drive_lifecycle.py',
        'tools/verify_signed_drive_image.py',
        'tools/DrivePreparationProbe.swift',
        'tools/verify_integrity_volume.py',
        'tools/runtime_diagnostics.py',
    ))


def inspect(tag: str) -> dict:
    case, admission = admitted_case(tag)
    def role_info_valid(info: dict) -> bool:
        return info.get('TraverseDriveImageQualificationCase') == tag \
            and info.get('TraverseDriveImageQualificationRoot') == str(case) \
            and info.get('TraverseDriveImageQualificationOnly') is True \
            and not any(key.startswith('TraverseArchiveDriveQualification') for key in info)
    return signed_local_qa.inspect(case, admission, identifier(tag), role_info_valid,
                                   source_inventory, 'Drive-image QA')


def build(tag: str) -> dict:
    case, admission = admitted_case(tag)
    return signed_local_qa.build(case, tag, admission, 'DriveImage.xcconfig',
        source_inventory, lambda: inspect(tag), put, 'Drive-image QA')


def valid_scope(tag: str, scope: dict, app_hash: str) -> bool:
    case = case_path(tag)
    expected_keys = {'packet', 'case', 'bundleIdentifier', 'caseRoot', 'fixtureRoot',
                     'artifactTreeSHA256', 'expiresUTC', 'phaseLaunchCeiling',
                     'imageBytes', 'normalAttachMaximum', 'normalDetachMaximum',
                     'forceDetachMaximum', 'apfsAddMaximum', 'apfsFormatMaximum',
                     'driveMutationMaximum', 'physicalDriveMaximum',
                     'archiveJobsMaximum', 'networkSessionsMaximum', 'trashJobsMaximum'}
    try:
        expires = datetime.strptime(scope['expiresUTC'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except (KeyError, TypeError, ValueError):
        return False
    now = datetime.now(timezone.utc)
    expected = dict(packet='drive-image-runtime-scope-v1', case=tag,
        bundleIdentifier=identifier(tag), caseRoot=str(case), fixtureRoot=str(fixture_path(tag)),
        artifactTreeSHA256=app_hash, phaseLaunchCeiling=PHASE_CEILING,
        imageBytes=IMAGE_BYTES, normalAttachMaximum=1, normalDetachMaximum=1,
        forceDetachMaximum=0, apfsAddMaximum=1, apfsFormatMaximum=1,
        driveMutationMaximum=2, physicalDriveMaximum=0,
        archiveJobsMaximum=0, networkSessionsMaximum=0, trashJobsMaximum=0)
    return set(scope) == expected_keys and all(type(scope.get(k)) is type(v) and scope[k] == v
        for k, v in expected.items()) and now <= expires <= now + timedelta(hours=12)


def issue_phase(tag: str, phase: str) -> dict:
    if phase not in PHASE_CEILING:
        raise ValueError('Unknown drive-image QA phase')
    case, _ = admitted_case(tag)
    built = owned_json(case / 'evidence/build-result.json', maximum=1 << 20)
    observed = inspect(tag)
    if built.get('passed') is not True or built.get('inspected', {}).get('app') != observed['app']:
        raise ValueError('Retained signed drive artifact differs from build')
    scope_path = case / 'evidence/runtime-scope.json'
    scope = owned_json(scope_path)
    if not valid_scope(tag, scope, observed['app']['treeSHA256']):
        raise ValueError('Drive-image QA runtime scope differs')
    permit = case / 'evidence' / ('drive-image-' + phase + '-permit.json')
    consumed = case / 'evidence' / ('drive-image-' + phase + '-consumed.json')
    if permit.exists() or permit.is_symlink() or consumed.exists() or consumed.is_symlink():
        raise ValueError('Drive-image QA phase already issued or spent')
    if phase == 'pre-image':
        fixture = fixture_path(tag)
        owned_directory(fixture)
        if owned_json(fixture / 'owner.json') != {'jobID': tag, 'bytes': IMAGE_BYTES} \
                or os.path.lexists(fixture / 'fixture.dmg'):
            raise ValueError('Pre-image generated owner changed')
    else:
        prior = 'pre-image' if phase == 'warm' else 'warm'
        prior_result = owned_json(case / 'evidence' / ('drive-image-' + prior + '-result.json'))
        host_receipt = owned_json(case / 'evidence' / ('host-drive-image-' + prior + '-receipt.json'))
        if prior_result.get('passed') is not True or prior_result.get('phase') != prior \
                or prior_result.get('stage') != 'completed' \
                or host_receipt.get('passed') is not True or host_receipt.get('phase') != prior \
                or not (case / 'evidence' / ('drive-image-' + prior + '-consumed.json')).is_file():
            raise ValueError('Prior drive-image phase did not pass')
        if phase == 'cold':
            postcheck = owned_json(case / 'evidence/host-drive-image-warm-postcheck.json')
            if postcheck.get('passed') is not True \
                    or postcheck.get('jobID') != owned_json(case / 'evidence/apfs-format-result.json').get('jobID'):
                raise ValueError('Warm generated image postcheck did not pass')
    scope_hash = hashlib.sha256(scope_path.read_bytes()).hexdigest()
    put(permit, dict(packet='drive-image-phase-permit-v1', case=tag, phase=phase,
        bundleIdentifier=identifier(tag), caseRoot=str(case),
        artifactTreeSHA256=observed['app']['treeSHA256'], scopeSHA256=scope_hash,
        expiresUTC=scope['expiresUTC'], attempt=1))
    return dict(case=tag, phase=phase, issued=True, permit=str(permit.relative_to(REPO)),
                appLaunches=0, phaseAttemptsRemaining=1)


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
