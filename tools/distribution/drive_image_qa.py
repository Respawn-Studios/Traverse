#!/usr/bin/env python3
"""One distinct nonshipping signed Release role for an owned APFS image.

Prepare/build/inspect and phase issuance do not create or attach an image.
The host runtime owner is verify_signed_drive_image.py.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from enum import Enum
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
from native_build_inputs import digest

ROOT = REPO / '.build/traverse-development'
PREFIX = 'local.macexplorer.drive-image-v3.qa.'
CASE_ENV = 'MAC_EXPLORER_DRIVE_IMAGE_QA_CASE'
ACTION = 'drive-image-qa-developer-id-v3'
PACKET = 'drive-image-qa-developer-id-v3'
CONTROLLER_PACKET = 'drive-image-execution-controller-v3'
TEAM = remote_editor_qa.DEVELOPER_ID_TEAM
NAME = 'Traverse Drive Image Review (Generated)'
PHASE_CEILING = {'pre-image': 1, 'warm': 1, 'cold': 1}
IMAGE_BYTES = 1 << 30
canonical = archive_drive_qa.canonical
owned_directory = archive_drive_qa.owned_directory
owned_json = archive_drive_qa.owned_json
put = archive_drive_qa.put


class CaseMode(Enum):
    GENERATED = ('generated-v2', 2, 'observed-native-v2',
                 'drive-image-runtime-scope-v3', 'drive-image-phase-permit-v3')
    APP_MODEL = ('ordinary-format-v3', 3, 'observed-native-v3',
                 'drive-image-runtime-scope-v4', 'drive-image-phase-permit-v4')

    def __init__(self, label: str, job_version: int, contract: str,
                 scope_packet: str, permit_packet: str):
        self.label = label
        self.job_version = job_version
        self.contract = contract
        self.scope_packet = scope_packet
        self.permit_packet = permit_packet

    @property
    def identity(self) -> dict[str, str]:
        fields = {'formatCompletionContract': self.contract}
        if self is CaseMode.APP_MODEL:
            fields['caseMode'] = self.label
        return fields

    @classmethod
    def from_admission(cls, admission: dict) -> CaseMode:
        if 'caseMode' not in admission:
            return cls.GENERATED
        if admission['caseMode'] == cls.APP_MODEL.label:
            return cls.APP_MODEL
        raise ValueError('Unknown drive-image QA case mode')

    def matches_format_result(self, result: dict) -> bool:
        return (result.get('completionContract') == self.contract
                and type(result.get('jobVersion')) is int
                and result['jobVersion'] == self.job_version
                and result.get('nativeCompletionObserved') is True
                and (self is CaseMode.GENERATED
                     or (result.get('model') == 'ApplicationAPFSVolumeFormat'
                         and result.get('typedGestureClaimed') is False
                         and result.get('ordinaryEnabled') is False)))


def identifier(tag: str) -> str:
    return PREFIX + canonical(tag).lower().replace('-', '')


def case_path(tag: str) -> Path:
    return ROOT / canonical(tag)


def fixture_path(tag: str) -> Path:
    return REPO / '.build/fixtures' / ('drive-lifecycle-' + canonical(tag))


def expected_info(case: Path, mode: CaseMode) -> dict:
    info = plistlib.loads((REPO / 'Distribution/Info.plist').read_bytes())
    for key in ['CFBundleDocumentTypes', 'CFBundleURLTypes', 'MacExplorerReleasePurpose',
                'TraversePublicUpdaterVersion', 'TraversePrivateUpdaterVersion']:
        info.pop(key, None)
    info.update(CFBundleDisplayName=NAME, CFBundleName=NAME,
        MacExplorerDistributionChannel='qualification', MacExplorerAccessPolicy='local-user-v1',
        MacExplorerStorageMode='portable', TraverseDriveImageQualificationOnly=True,
        TraverseDriveImageQualificationCase=case.name,
        TraverseDriveImageQualificationRoot=str(case),
        TraverseDriveImageArchitecture='arm64',
        TraverseDriveImageCompletionContract=mode.contract)
    if mode is CaseMode.APP_MODEL:
        info['TraverseDriveImageCaseMode'] = mode.label
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
    mode = CaseMode.from_admission(admission)
    if admission != dict(packet=PACKET, case=tag, bundleIdentifier=identifier(tag),
                caseRoot=str(case), fixtureRoot=str(fixture_path(tag)),
                repoLocalLibrary=str(case / 'source/Library'),
                signingIdentity=admission.get('signingIdentity'), teamIdentifier=TEAM,
                phaseLaunchCeiling=PHASE_CEILING, **mode.identity) \
            or not isinstance(admission['signingIdentity'], str) \
            or len(admission['signingIdentity']) != 40 \
            or any(ch not in '0123456789ABCDEF' for ch in admission['signingIdentity']):
        raise ValueError('Drive-image QA admission differs')
    info_path = case / 'DriveImageInfo.plist'
    facts = info_path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() \
            or facts.st_nlink != 1 or facts.st_mode & 0o077 \
            or plistlib.loads(info_path.read_bytes()) != expected_info(case, mode):
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


def prepare(tag: str, mode: CaseMode) -> dict:
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
        teamIdentifier=TEAM, phaseLaunchCeiling=PHASE_CEILING,
        **mode.identity))
    descriptor = os.open(case / 'DriveImageInfo.plist',
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        plistlib.dump(expected_info(case, mode), output)
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


def execution_controller_inputs() -> dict[str, str]:
    """Freeze every local Python controller and the probe's compiled Swift inputs.

    The broad Python set includes transitive and deferred imports in the live
    host/inspector path. Ordinary App and Package source may continue changing;
    the six LocalStorage files compiled into the probe remain pinned.
    """
    paths = {path for path in (REPO / 'tools').rglob('*.py')
             if all(not part.startswith('.') for part in path.relative_to(REPO / 'tools').parts)
             and not path.name.startswith('test_')}
    paths.add(REPO / 'tools/DrivePreparationProbe.swift')
    paths.update(REPO / 'Packages/ExplorerKit/Sources/LocalStorage' / name for name in (
        'VolumeLifecycle.swift', 'VolumeRemovalProtection.swift', 'MountedVolumeScope.swift',
        'NativeDeviceScope.swift', 'DriveTopology.swift', 'VolumeInspection.swift'))
    return {str(path.relative_to(REPO)): digest(path) for path in sorted(paths)}


def controller_packet() -> dict:
    return {'packet': CONTROLLER_PACKET, 'sourceSHA256': execution_controller_inputs()}


def controller_bytes(packet: dict) -> bytes:
    return (json.dumps(packet, indent=2, sort_keys=True) + '\n').encode()


def sealed_build_provenance(tag: str, observed: dict) -> dict[str, str]:
    """Match the current signed artifact to both immutable build receipts."""
    case = case_path(tag)
    inputs_path = case / 'evidence/build-inputs.json'
    result_path = case / 'evidence/build-result.json'
    inputs = owned_json(inputs_path, maximum=1 << 20)
    built = owned_json(result_path, maximum=1 << 20)
    source = inputs.get('sourceSHA256')
    sealed = built.get('inspected')
    if not isinstance(source, dict) or not source \
            or inputs.get('sourceInputs') != len(source) \
            or inputs.get('case') != tag or inputs.get('bundleIdentifier') != identifier(tag) \
            or inputs.get('appLaunches') != 0 or inputs.get('driveMutations') != 0 \
            or built.get('case') != tag or built.get('passed') is not True \
            or built.get('actualBuildExit') != 0 or built.get('appLaunches') != 0 \
            or built.get('driveMutations') != 0 or not isinstance(sealed, dict) \
            or sealed.get('passed') is not True or sealed.get('currentSourceMatch') is not True \
            or sealed.get('sourceInputs') != len(source):
        raise ValueError('Signed drive build receipts differ')
    checks = sealed.get('checks')
    if not isinstance(checks, dict) or checks.get('sourceMatch') is not True:
        raise ValueError('Signed drive build did not seal its source')
    immutable_checks = {name: value for name, value in checks.items() if name != 'sourceMatch'}
    if observed.get('checks') != immutable_checks \
            and observed.get('checks') != checks:
        raise ValueError('Signed drive artifact checks differ from build')
    for name in ('app', 'symbols', 'symbolMatch', 'signer'):
        if observed.get(name) != sealed.get(name):
            raise ValueError('Signed drive artifact differs from build')
    return {'buildInputsSHA256': hashlib.sha256(inputs_path.read_bytes()).hexdigest(),
            'buildResultSHA256': hashlib.sha256(result_path.read_bytes()).hexdigest()}


def current_controller_provenance(tag: str) -> dict[str, str | int]:
    path = case_path(tag) / 'evidence/execution-controller-inputs.json'
    recorded = owned_json(path, maximum=1 << 20)
    current = controller_packet()
    if recorded != current:
        raise ValueError('Drive-image execution controller or probe inputs changed')
    return {'controllerInputsSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'controllerInputsCount': len(current['sourceSHA256'])}


def inspect(tag: str, *, frozen: bool = False) -> dict:
    case, admission = admitted_case(tag)
    mode = CaseMode.from_admission(admission)
    def role_info_valid(info: dict) -> bool:
        return info.get('TraverseDriveImageQualificationCase') == tag \
            and info.get('TraverseDriveImageQualificationRoot') == str(case) \
            and info.get('TraverseDriveImageQualificationOnly') is True \
            and info.get('TraverseDriveImageCompletionContract') == mode.contract \
            and ('TraverseDriveImageCaseMode' not in info if mode is CaseMode.GENERATED
                 else info.get('TraverseDriveImageCaseMode') == mode.label) \
            and not any(key.startswith('TraverseArchiveDriveQualification') for key in info)
    observed = signed_local_qa.inspect(case, admission, identifier(tag), role_info_valid,
        source_inventory, 'Drive-image QA', require_current_source=not frozen)
    if frozen:
        sealed_build_provenance(tag, observed)
    return observed


def build(tag: str) -> dict:
    case, admission = admitted_case(tag)
    return signed_local_qa.build(case, tag, admission, 'DriveImage.xcconfig',
        source_inventory, lambda: inspect(tag), put, 'Drive-image QA')


def runtime_scope(tag: str, app_hash: str, provenance: dict, mode: CaseMode, expires_utc: str) -> dict:
    return dict(packet=mode.scope_packet, case=tag,
        bundleIdentifier=identifier(tag), caseRoot=str(case_path(tag)), fixtureRoot=str(fixture_path(tag)),
        artifactTreeSHA256=app_hash, **provenance, expiresUTC=expires_utc,
        phaseLaunchCeiling=PHASE_CEILING, **mode.identity,
        imageBytes=IMAGE_BYTES, normalAttachMaximum=1, normalDetachMaximum=1,
        forceDetachMaximum=0, apfsAddMaximum=1, apfsFormatMaximum=1,
        driveMutationMaximum=2, physicalDriveMaximum=0,
        archiveJobsMaximum=0, networkSessionsMaximum=0, trashJobsMaximum=0)


def valid_scope(tag: str, scope: dict, app_hash: str, provenance: dict, mode: CaseMode) -> bool:
    if set(provenance) != {'buildInputsSHA256', 'buildResultSHA256',
                           'controllerInputsSHA256', 'controllerInputsCount'} \
            or any(not isinstance(provenance[name], str) or len(provenance[name]) != 64
                   or any(char not in '0123456789abcdef' for char in provenance[name])
                   for name in ('buildInputsSHA256', 'buildResultSHA256', 'controllerInputsSHA256')) \
            or type(provenance['controllerInputsCount']) is not int \
            or not 1 <= provenance['controllerInputsCount'] <= 512:
        return False
    try:
        expires = datetime.strptime(scope['expiresUTC'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except (KeyError, TypeError, ValueError):
        return False
    now = datetime.now(timezone.utc)
    expected = runtime_scope(tag, app_hash, provenance, mode, scope['expiresUTC'])
    return (set(scope) == set(expected)
        and all(type(scope[k]) is type(v) and scope[k] == v for k, v in expected.items())
        and all(type(value) is int for value in scope['phaseLaunchCeiling'].values())
        and now <= expires <= now + timedelta(hours=12))


def issue_phase(tag: str, phase: str) -> dict:
    if phase not in PHASE_CEILING:
        raise ValueError('Unknown drive-image QA phase')
    case, admission = admitted_case(tag)
    mode = CaseMode.from_admission(admission)
    observed = inspect(tag, frozen=True)
    provenance = {**sealed_build_provenance(tag, observed), **current_controller_provenance(tag)}
    scope_path = case / 'evidence/runtime-scope.json'
    scope = owned_json(scope_path)
    if not valid_scope(tag, scope, observed['app']['treeSHA256'], provenance, mode):
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
            warm = owned_json(case / 'evidence/apfs-format-result.json')
            job = case / 'source/Library/Application Support' / identifier(tag) \
                / 'drive-jobs/native-drive-job-v1.json'
            owned_json(job, maximum=65_536)
            if postcheck.get('passed') is not True \
                    or postcheck.get('jobID') != warm.get('jobID') \
                    or postcheck.get('jobSHA256') != hashlib.sha256(job.read_bytes()).hexdigest() \
                    or not mode.matches_format_result(warm):
                raise ValueError('Warm generated image postcheck did not pass')
    scope_hash = hashlib.sha256(scope_path.read_bytes()).hexdigest()
    put(permit, dict(packet=mode.permit_packet, case=tag, phase=phase,
        bundleIdentifier=identifier(tag), caseRoot=str(case),
        artifactTreeSHA256=observed['app']['treeSHA256'], scopeSHA256=scope_hash,
        buildInputsSHA256=provenance['buildInputsSHA256'],
        buildResultSHA256=provenance['buildResultSHA256'],
        controllerInputsSHA256=provenance['controllerInputsSHA256'],
        expiresUTC=scope['expiresUTC'], attempt=1))
    return dict(case=tag, phase=phase, issued=True, permit=str(permit.relative_to(REPO)),
                appLaunches=0, phaseAttemptsRemaining=1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'build', 'inspect', 'issue-phase'])
    parser.add_argument('--case', required=True)
    parser.add_argument('--phase', choices=sorted(PHASE_CEILING))
    parser.add_argument('--case-mode', choices=[mode.label for mode in CaseMode])
    args = parser.parse_args()
    if (args.action == 'issue-phase') != (args.phase is not None):
        parser.error('--phase is required only for issue-phase')
    if args.case_mode is not None and args.action != 'prepare':
        parser.error('--case-mode is only for prepare')
    mode = next((mode for mode in CaseMode if mode.label == args.case_mode), CaseMode.GENERATED)
    result = prepare(args.case, mode) if args.action == 'prepare' else build(args.case) if args.action == 'build' \
        else issue_phase(args.case, args.phase) if args.action == 'issue-phase' else inspect(args.case)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result.get('passed') is False:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
