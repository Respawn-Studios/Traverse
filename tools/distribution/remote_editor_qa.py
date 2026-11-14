"""Exact generated Release sandbox identity for remote-editor QA only.

This is a local, hardened qualification lane with a case-bound ad-hoc or
Developer ID signer. Production store signing stays in store_helpers.py.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
from typing import Mapping
import uuid

REPO = Path(__file__).resolve().parents[2]
# Share the ordinary Release products as well as its derived directory. The
# sealed review app/symbols are retained in their case before this app is removed;
# package linker objects/modules remain one reusable incremental product set.
STAGING_PRODUCT = REPO / '.build/xcode-release/Build/Products/Release'
PREFIX = 'local.macexplorer.sandbox.remote-editor.'
ACTION = 'sandbox-remote-editor-release'
DEVELOPER_ID_ACTION = 'sandbox-remote-editor-developer-id'
CASE_ENV = 'MAC_EXPLORER_SANDBOX_REMOTE_EDITOR_RELEASE_CASE'
CHANNEL = 'qualification'
POLICY = 'sandbox-selected-v1'
ADMISSION = 'remote-editor-release-admission.json'
PACKET = 'sandbox-remote-editor-release-v1'
DEVELOPER_ID_PACKET = 'sandbox-remote-editor-developer-id-v1'
DEVELOPER_ID_TEAM = 'CDLNJRG82U'
ADDITIVE_ROOT_TRASH_CASE = '345C4751-4E71-437A-BE8B-6CF18527F77D'
ADDITIVE_ROOT_TRASH_CONDITION = 'TRAVERSE_OWNED_TRASH_ROOT_ADD_QA'
ROLE_IDENTIFIERS = {
    'browser': 'com.respawnstudios.traverse.smb.browser',
    'resolver': 'com.respawnstudios.traverse.smb.resolver',
    'sftp': 'com.respawnstudios.traverse.sftp.metadata',
}
HELPER_RIGHTS = {'com.apple.security.app-sandbox': True,
                 'com.apple.security.inherit': True}


def _canonical(value: str) -> str:
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)).upper() != value:
            raise ValueError('Noncanonical remote editor QA case')
    except (ValueError, AttributeError):
        raise ValueError('Invalid remote editor QA case') from None
    return value


def identifier(case: str) -> str:
    return PREFIX + _canonical(case).lower().replace('-', '')


def compilation_conditions(case: Path) -> str:
    """One case-bound definition shared by admission and the actual compiler."""
    tag = _canonical(case.name)
    conditions = ['MAC_EXPLORER_DISTRIBUTION', 'TRAVERSE_SFTP_EDITOR_QA']
    if tag == ADDITIVE_ROOT_TRASH_CASE:
        conditions.append(ADDITIVE_ROOT_TRASH_CONDITION)
    return ' '.join(conditions)


def _owned_json(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ValueError('Remote editor QA admission file unavailable')
    facts = path.stat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_nlink != 1 \
            or facts.st_size > 4096 or facts.st_mode & 0o022:
        raise ValueError('Unsafe remote editor QA admission file')
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError('Invalid remote editor QA admission document')
    return value


def available_developer_id_identity() -> str:
    """Select only the one configured Developer ID Application certificate."""
    result = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                            capture_output=True, text=True, timeout=30, check=True)
    matches = re.findall(
        r'\b([0-9A-Fa-f]{40})\s+"Developer ID Application: [^"\n]+ \('
        + DEVELOPER_ID_TEAM + r'\)"', result.stdout)
    if len(matches) != 1:
        raise ValueError('Exactly one configured Developer ID Application identity is required')
    return matches[0].upper()


def signer(case: Path) -> tuple[str, str]:
    """One immutable case selection; never infer a signing fallback."""
    reservation = _owned_json(case / 'reservation.json')
    admission = _owned_json(case / 'evidence' / ADMISSION)
    action = reservation.get('action')
    if reservation == {'packet': 'traverse-development-v1', 'action': ACTION}:
        if set(admission) != {'packet', 'case', 'bundleIdentifier', 'buildAndInspectOnly',
                              'priorOSContainerAbsent', 'generatedOperationRoot'} \
                or admission.get('packet') != PACKET:
            raise ValueError('Ad-hoc remote editor QA admission differs')
        return '-', 'adhoc'
    if reservation == {'packet': 'traverse-development-v1', 'action': DEVELOPER_ID_ACTION}:
        identity = admission.get('signingIdentity')
        if set(admission) != {'packet', 'case', 'bundleIdentifier', 'buildAndInspectOnly',
                              'priorOSContainerAbsent', 'generatedOperationRoot',
                              'signingIdentity', 'teamIdentifier'} \
                or admission.get('packet') != DEVELOPER_ID_PACKET \
                or admission.get('teamIdentifier') != DEVELOPER_ID_TEAM \
                or not isinstance(identity, str) \
                or re.fullmatch(r'[0-9A-F]{40}', identity) is None:
            raise ValueError('Developer ID remote editor QA admission differs')
        return identity, DEVELOPER_ID_TEAM
    raise ValueError('Unknown remote editor QA purpose')


def admitted_build(env: Mapping[str, str]) -> Path | None:
    """Return the one owned case, or reject every malformed QA claim."""
    tag = env.get(CASE_ENV, '')
    parent = env.get('PRODUCT_BUNDLE_IDENTIFIER', '')
    if not tag:
        if parent.startswith(PREFIX):
            raise ValueError('Remote editor QA identity requires its exact case')
        return None
    case = REPO / '.build/traverse-development' / _canonical(tag)
    product = case / 'Products/Release'
    target = Path(env.get('TARGET_BUILD_DIR', '/'))
    identity, team = signer(case)
    conditions = env.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
    if case.resolve() != case or not case.is_dir() or case.is_symlink() \
            or case.stat().st_uid != os.getuid() or case.stat().st_mode & 0o077 \
            or env.get('MAC_EXPLORER_SANDBOX_FOUNDATION_CASE') \
            or env.get('MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE') \
            or parent != identifier(tag) or env.get('CONFIGURATION') != 'Release' \
            or target not in (product, STAGING_PRODUCT) or target.resolve() != target \
            or env.get('CONTENTS_FOLDER_PATH') != 'Mac Explorer.app/Contents' \
            or env.get('ENABLE_APP_SANDBOX') != 'YES' \
            or env.get('ENABLE_HARDENED_RUNTIME') != 'YES' \
            or env.get('MAC_EXPLORER_DISTRIBUTION_CHANNEL') != CHANNEL \
            or env.get('MAC_EXPLORER_ACCESS_POLICY') != POLICY \
            or env.get('DEVELOPMENT_TEAM', '') != ('' if team == 'adhoc' else team) \
            or (env.get('EXPANDED_CODE_SIGN_IDENTITY', '-') not in ('', '-')
                if team == 'adhoc' else env.get('EXPANDED_CODE_SIGN_IDENTITY') != identity) \
            or 'TRAVERSE_SFTP_EDITOR_QA' not in conditions \
            or (ADDITIVE_ROOT_TRASH_CONDITION in conditions) != (tag == ADDITIVE_ROOT_TRASH_CASE):
        raise ValueError('Remote editor QA output, identity, signing or feature differs')
    admission = _owned_json(case / 'evidence' / ADMISSION)
    if admission.get('case') != tag \
            or admission.get('bundleIdentifier') != parent \
            or admission.get('buildAndInspectOnly') is not True \
            or admission.get('priorOSContainerAbsent') is not True \
            or admission.get('generatedOperationRoot') != str(case / 'source/Operation Root'):
        raise ValueError('Remote editor QA purpose or evidence differs')
    app = target / 'Mac Explorer.app'
    if app.resolve() != app or app.is_symlink():
        raise ValueError('Redirected remote editor QA product')
    info = app / 'Contents/Info.plist'
    if info.is_symlink():
        raise ValueError('Unsafe remote editor QA Info.plist')
    if info.is_file():
        if info.stat().st_nlink != 1:
            raise ValueError('Unsafe remote editor QA Info.plist')
        fields = plistlib.loads(info.read_bytes())
        if fields.get('CFBundleIdentifier') != parent \
                or fields.get('MacExplorerSandboxQualificationCase') != tag \
                or fields.get('MacExplorerDistributionChannel') != CHANNEL \
                or fields.get('MacExplorerAccessPolicy') != POLICY \
                or fields.get('MacExplorerStorageMode') != 'portable':
            raise ValueError('Remote editor QA installed metadata differs')
    return case


def _helper_digest(path: Path, role: str, team: str) -> str:
    limits = {'browser': 4 << 20, 'resolver': 2 << 20, 'sftp': 8 << 20}
    if path.is_symlink() or not path.is_file():
        raise ValueError('Missing remote editor QA helper')
    facts = path.stat()
    if facts.st_uid != os.getuid() or facts.st_nlink != 1 or not 0 < facts.st_size <= limits[role]:
        raise ValueError('Unsafe remote editor QA helper')
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)],
                   check=True, capture_output=True, timeout=30)
    result = subprocess.run(['/usr/bin/codesign', '-d', '-vv', str(path)],
                            check=True, capture_output=True, timeout=30)
    lines = result.stderr.decode().splitlines()
    fields = dict(line.split('=', 1) for line in lines if '=' in line)
    directory = next((line for line in lines if line.startswith('CodeDirectory ')), '')
    flags = re.search(r'\bflags=0x([0-9A-Fa-f]+)(?:\(|\b)', directory)
    authorities = [line.split('=', 1)[1] for line in lines if line.startswith('Authority=')]
    signer_ok = (fields.get('Signature') == 'adhoc'
                 and fields.get('TeamIdentifier') in (None, 'not set')) if team == 'adhoc' else (
                     fields.get('Signature') != 'adhoc'
                     and fields.get('TeamIdentifier') == DEVELOPER_ID_TEAM
                     and bool(authorities)
                     and authorities[0].startswith('Developer ID Application: '))
    code_flags = int(flags.group(1), 16) if flags else 0
    if fields.get('Identifier') != ROLE_IDENTIFIERS[role] \
            or not signer_ok or code_flags & 0x10000 != 0x10000 \
            or bool(code_flags & 0x2) != (team == 'adhoc'):
        raise ValueError('Remote editor QA helper identity or runtime differs')
    rights = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(path)],
                            check=True, capture_output=True, timeout=30)
    if (plistlib.loads(rights.stdout) if rights.stdout.strip() else {}) != HELPER_RIGHTS:
        raise ValueError('Remote editor QA helper rights differ')
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def write_manifest(app: Path, roles: Mapping[str, Path], case: Path) -> Path:
    """Seal the exact QA role map after each helper has been signed and checked."""
    names = set(roles)
    target = Path(os.environ.get('TARGET_BUILD_DIR', '/'))
    if names not in ({'browser', 'resolver'}, {'sftp'}) \
            or app != target / 'Mac Explorer.app' or app.resolve() != app or app.is_symlink() \
            or case != admitted_build(os.environ):
        raise ValueError('Remote editor QA helper family or product differs')
    resource = app / 'Contents/Resources'
    if resource.is_symlink() or not resource.is_dir() or resource.stat().st_uid != os.getuid():
        raise ValueError('Unsafe remote editor QA resources')
    manifest = resource / ('SFTPHelperManifest.plist' if names == {'sftp'} else 'SMBHelperManifest.plist')
    if manifest.is_symlink() or manifest.exists() and (not manifest.is_file() or manifest.stat().st_nlink != 1
                                                    or manifest.stat().st_uid != os.getuid()):
        raise ValueError('Unsafe remote editor QA manifest destination')
    basenames = {'browser': 'smb-browser-worker', 'resolver': 'smb-resolver-worker',
                 'sftp': 'sftp-metadata-worker'}
    if any(path != app / 'Contents/Helpers' / basenames[role] for role, path in roles.items()):
        raise ValueError('Remote editor QA helper role path differs')
    _, team = signer(case)
    entries = {role: {'identifier': ROLE_IDENTIFIERS[role], 'sha256': _helper_digest(path, role, team)}
               for role, path in sorted(roles.items())}
    fields = dict(version=1, channel=CHANNEL, parentIdentifier=identifier(case.name),
                  teamIdentifier=team, roles=entries, case=case.name)
    stage = manifest.with_name('.' + manifest.name + '-' + str(uuid.uuid4()).upper())
    descriptor = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(plistlib.dumps(fields)); output.flush(); os.fsync(output.fileno())
    os.replace(stage, manifest)
    return manifest
