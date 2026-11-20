#!/usr/bin/env python3
"""One bounded signed APFS image packet.

Execution needs an exact reviewed scope hash. It makes one 1 GiB generated
image, one normal attach, at most one APFS Add and one Format, one cold
read-only completion inspection, and one normal detach after all checks settle. Failures
preserve the image, attachment, job and receipts; there is no retry or force.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'tools'))
from dev import require_unlocked_console
from distribution import drive_image_qa, signed_local_qa
from runtime_diagnostics import inspect as inspect_runtime
from verify_drive_lifecycle import Fixture, build_preparation_probe
from verify_integrity_volume import tool

SCHEMA_ROOT = REPO / '.build/drive-image-schema-probes'
SCHEMA_PACKET = 'ordinary-image-retained-schema-v1'
DETACHED_IMAGEINFO_PACKET = 'ordinary-image-detached-imageinfo-v1'
DETACHED_IMAGEINFO_LIMIT = 2 << 20


def owned_result(case: Path, name: str) -> dict:
    return drive_image_qa.owned_json(case / 'evidence' / name, maximum=1 << 20)


def ordinary_image_schema(item: dict, *, image_path: str, selected_device: str) -> dict:
    """Project only parser-relevant types/literals; never expose plist paths."""
    def boolean(key: str) -> bool | str:
        value = item.get(key)
        return value if type(value) is bool else 'missing' if key not in item else 'wrongType'

    def path_relation(key: str, allowed: str) -> str:
        if key not in item:
            return 'absent'
        value = item[key]
        return 'allowed' if type(value) is str and value == allowed else 'other'

    image_type = item.get('image-type')
    entities = item.get('system-entities')
    entries = [entity.get('dev-entry') for entity in entities] if type(entities) is list \
        and all(type(entity) is dict for entity in entities) else []
    valid_entries = (type(entities) is list and len(entries) == len(entities)
        and all(type(entry) is str and re.fullmatch(r'/dev/disk[0-9]{1,6}(s[0-9]{1,6}){0,2}', entry)
                for entry in entries) and len(entries) == len(set(entries)))
    outer = bool(entries and re.fullmatch(r'/dev/disk[0-9]{1,6}', entries[0]))
    selected = '/dev/' + selected_device in entries
    alias = path_relation('image-alias', image_path)
    shadow = path_relation('shadow-path', '<none>')
    image_shadow = path_relation('image-shadow-path', '<none>')
    uid = item.get('owner-uid')
    uid_match = type(uid) is int and uid == os.geteuid()
    path_match = item.get('image-path') == image_path
    image_type_state = ('read/write disk image' if image_type == 'read/write disk image'
                        else 'missing' if 'image-type' not in item else 'other')
    result = {'schemaObserved': True, 'imagePathMatched': path_match,
        'imageType': image_type_state, 'writeable': boolean('writeable'),
        'imageEncrypted': boolean('image-encrypted'), 'systemImage': boolean('system-image'),
        'ownerUIDMatched': uid_match, 'imageAlias': alias,
        'shadowPath': shadow, 'imageShadowPath': image_shadow,
        'systemEntitiesCount': len(entries), 'validEntityNames': valid_entries,
        'outerEntityShape': outer, 'selectedEntityPresent': selected}
    result['parserFieldsCompatible'] = bool(path_match and image_type_state == 'read/write disk image'
        and result['writeable'] is True and result['imageEncrypted'] is False
        and result['systemImage'] is False and uid_match and alias in ('absent', 'allowed')
        and shadow in ('absent', 'allowed') and image_shadow in ('absent', 'allowed')
        and valid_entries and outer and selected)
    return result


def detached_imageinfo_projection(item: dict) -> dict:
    """Retain only fixed schema facts, never arbitrary imageinfo plist values."""
    if type(item) is not dict:
        raise ValueError('Detached imageinfo plist is not an object')

    def field(key: str, literals: tuple[str, ...] = ()) -> dict:
        if key not in item:
            return {'present': False, 'type': 'missing'}
        value = item[key]
        kind = ('boolean' if type(value) is bool else 'string' if type(value) is str
                else 'integer' if type(value) is int else 'dictionary' if type(value) is dict
                else 'array' if type(value) is list else 'data' if type(value) is bytes
                else 'date' if type(value) is datetime else 'other')
        result = {'present': True, 'type': kind}
        if literals and kind == 'string':
            result['literal'] = value if value in literals else 'other'
        if key == 'system-image' and kind == 'boolean':
            result['value'] = value
        return result

    formats = ('RAW', 'RAW*', 'UDRW', 'raw disk image',
               'read/write disk image', 'read/write raw disk image')
    return {'format': field('Format', formats), 'formatLowercase': field('format', formats),
            'imageType': field('image-type', formats), 'systemImage': field('system-image'),
            'writeable': field('writeable'), 'imageEncrypted': field('image-encrypted'),
            'ownerUID': field('owner-uid'), 'imagePath': field('image-path'),
            'imageAlias': field('image-alias'), 'shadowPath': field('shadow-path'),
            'imageShadowPath': field('image-shadow-path'),
            'systemEntities': field('system-entities'), 'properties': field('Properties')}


def retained_schema_source(tag: str) -> tuple[Path, Fixture, dict]:
    case, _ = drive_image_qa.admitted_case(tag)
    old = owned_result(case, 'host-drive-image-result.json')
    outcome = owned_result(case, 'apfs-format-result.json')
    receipt = owned_result(case, 'native-drive-receipt.json')
    if (old.get('passed') is not True or old.get('normalDetach') is not True
            or old.get('case') != tag or old.get('warmPostcheck') != old.get('coldPostcheck')
            or outcome.get('passed') is not True or outcome.get('jobVersion') != 2
            or old.get('warmPostcheck', {}).get('siblingUUID') != outcome.get('siblingUUID')
            or old.get('warmPostcheck', {}).get('formattedUUID') != outcome.get('formattedUUID')
            or outcome.get('siblingMarkerPreserved') is not True
            or outcome.get('targetMarkerRemoved') is not True
            or receipt.get('jobID') != tag):
        raise RuntimeError('Retained signed generated-image result is not qualified for schema inspection')
    fixture = Fixture.preserved(drive_image_qa.fixture_path(tag))
    if (fixture.root_id != (receipt.get('fixtureDevice'), receipt.get('fixtureInode'))
            or fixture.image_id != (receipt.get('imageDevice'), receipt.get('imageInode'))
            or fixture.image_bytes != drive_image_qa.IMAGE_BYTES):
        raise RuntimeError('Retained generated-image file identity changed')
    return case, fixture, outcome


def retained_schema_graph(fixture: Fixture, outcome: dict) -> dict:
    """Reprove exact members and both generated markers before normal detach."""
    graph = fixture.two_member_owned(original_uuid=outcome['siblingUUID'], target_uuid=outcome['formattedUUID'])
    sibling = graph['members'][outcome['siblingUUID']]
    target = graph['members'][outcome['formattedUUID']]
    if (fixture.member_marker(sibling['mount'], '.mac-explorer-drive-owner',
            expected_device=sibling['device'], expected_uuid=outcome['siblingUUID'],
            expected_mount_device=sibling['mountDevice'])
            != (sibling['mountDevice'], outcome['siblingMarkerInode'])
            or fixture.member_marker(target['mount'], '.mac-explorer-format-target',
                expected_device=target['device'], expected_uuid=outcome['formattedUUID'],
                expected_mount_device=target['mountDevice']) is not None):
        raise RuntimeError('Retained generated-image markers changed')
    return graph


def inspect_attached_ordinary_schema(tag: str) -> dict:
    """Read one already attached, previously qualified generated image only.

    This action never creates, attaches, detaches, launches or formats anything.
    A separate owner scope must account for an attachment before this can read
    a detached retained image. No raw global hdiutil plist is persisted.
    """
    _, fixture, outcome = retained_schema_source(tag)
    before = fixture.attachment()
    if before is None:
        raise RuntimeError('Retained generated image is detached; no schema was observed or attached')
    graph = retained_schema_graph(fixture, outcome)
    target = graph['members'][outcome['formattedUUID']]
    raw = tool(['/usr/bin/hdiutil', 'info', '-plist'])
    if len(raw) > 2 << 20:
        raise RuntimeError('Global hdiutil info exceeds ordinary parser limit')
    parsed = plistlib.loads(raw)
    if type(parsed) is not dict or type(parsed.get('images')) is not list:
        raise RuntimeError('Global hdiutil info has no image table')
    images = parsed['images']
    if len(images) > 256:
        raise RuntimeError('Global hdiutil image table exceeds ordinary parser limit')
    matches = [value for value in images if type(value) is dict
               and value.get('image-path') == str(fixture.image)]
    if len(matches) != 1 or matches[0] != before or fixture.attachment() != before:
        raise RuntimeError('Retained image attachment changed during schema inspection')
    result = ordinary_image_schema(matches[0], image_path=str(fixture.image),
                                   selected_device=target['device'])
    fixture.validate()
    return {'sourceCase': tag, **result, 'witnessRuntimeQualification': 'not exercised'}


def schema_input_hashes(case: Path) -> dict:
    paths = [REPO / name for name in (
        'tools/verify_signed_drive_image.py', 'tools/verify_drive_lifecycle.py',
        'tools/verify_integrity_volume.py', 'tools/distribution/drive_image_qa.py',
        'tools/distribution/archive_drive_qa.py',
        'Packages/ExplorerKit/Sources/LocalStorage/APFSAttachedImageIdentity.swift')]
    paths += [case / 'evidence' / name for name in (
        'host-drive-image-result.json', 'apfs-format-result.json', 'native-drive-receipt.json')]
    paths.append(drive_image_qa.fixture_path(case.name) / 'owner.json')
    return {str(path.relative_to(REPO)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def schema_image_facts(fixture: Fixture) -> dict:
    fixture.validate()
    value = fixture.image.lstat()
    if (not stat.S_ISREG(value.st_mode) or value.st_uid != os.geteuid()
            or value.st_nlink != 1 or value.st_size != drive_image_qa.IMAGE_BYTES):
        raise RuntimeError('Retained image file facts changed')
    return {'rootDevice': fixture.root_id[0], 'rootInode': fixture.root_id[1],
            'imageDevice': fixture.image_id[0], 'imageInode': fixture.image_id[1],
            'imageBytes': value.st_size, 'imageOwnerUID': value.st_uid,
            'imageModifiedNS': value.st_mtime_ns, 'imageChangedNS': value.st_ctime_ns}


def schema_scope(record_id: str, expires_utc: str, case: Path, fixture: Fixture) -> dict:
    return {'packet': SCHEMA_PACKET, 'recordID': record_id,
            'sourceCase': case.name,
            'sourceCaseRoot': str(case), 'fixtureRoot': str(fixture.root),
            'imageFacts': schema_image_facts(fixture), 'inputSHA256': schema_input_hashes(case),
            'expiresUTC': expires_utc, 'imageCreateMaximum': 0,
            'normalAttachMaximum': 1, 'normalDetachMaximum': 1,
            'apfsAddMaximum': 0, 'apfsFormatMaximum': 0, 'appLaunchMaximum': 0,
            'forceDetachMaximum': 0, 'physicalDriveMaximum': 0,
            'networkSessionMaximum': 0, 'trashJobMaximum': 0, 'archiveJobMaximum': 0}


def detached_imageinfo_scope(record_id: str, expires_utc: str, case: Path, fixture: Fixture) -> dict:
    """Separate byte contract: a v1 attach scope cannot authorize imageinfo."""
    return {'packet': DETACHED_IMAGEINFO_PACKET, 'recordID': record_id,
            'sourceCase': case.name, 'sourceCaseRoot': str(case),
            'fixtureRoot': str(fixture.root), 'imageFacts': schema_image_facts(fixture),
            'inputSHA256': schema_input_hashes(case), 'expiresUTC': expires_utc,
            'imageInfoMaximum': 1, 'imageCreateMaximum': 0,
            'normalAttachMaximum': 0, 'normalDetachMaximum': 0,
            'apfsAddMaximum': 0, 'apfsFormatMaximum': 0, 'appLaunchMaximum': 0,
            'forceDetachMaximum': 0, 'physicalDriveMaximum': 0,
            'networkSessionMaximum': 0, 'trashJobMaximum': 0, 'archiveJobMaximum': 0}


def schema_expiry(value: str) -> datetime:
    try:
        return datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise RuntimeError('Exact schema-scope UTC expiry required') from None


def sync_schema_record(record: Path) -> None:
    directory = os.open(record, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def prepare_schema_scope(tag: str, expires_utc: str) -> dict:
    deadline = schema_expiry(expires_utc)
    remaining = (deadline - datetime.now(timezone.utc)).total_seconds()
    if not 0 < remaining <= 24 * 3600:
        raise RuntimeError('Schema-scope expiry must be within 24 hours')
    case, fixture, _ = retained_schema_source(tag)
    if fixture.attachment() is not None:
        raise RuntimeError('Retained image must be detached before preparing a new schema scope')
    if SCHEMA_ROOT.resolve() != SCHEMA_ROOT:
        raise RuntimeError('Redirected schema-probe root')
    SCHEMA_ROOT.mkdir(mode=0o700, exist_ok=True)
    drive_image_qa.owned_directory(SCHEMA_ROOT)
    record_id = str(uuid.uuid4()).upper()
    record = SCHEMA_ROOT / record_id
    record.mkdir(mode=0o700)
    drive_image_qa.owned_directory(record)
    scope = schema_scope(record_id, expires_utc, case, fixture)
    drive_image_qa.put(record / 'scope.json', scope)
    sync_schema_record(record)
    return {'recordID': record_id,
            'scopeSHA256': hashlib.sha256((record / 'scope.json').read_bytes()).hexdigest(),
            'sourceCase': tag, 'imageAlreadyExists': True, 'imageCurrentlyAttached': False,
            'normalAttachMaximum': 1, 'normalDetachMaximum': 1,
            'appLaunchMaximum': 0, 'apfsAddMaximum': 0, 'apfsFormatMaximum': 0,
            'executed': False}


def prepare_detached_imageinfo_scope(tag: str, expires_utc: str) -> dict:
    deadline = schema_expiry(expires_utc)
    remaining = (deadline - datetime.now(timezone.utc)).total_seconds()
    if not 0 < remaining <= 24 * 3600:
        raise RuntimeError('Detached imageinfo scope expiry must be within 24 hours')
    case, fixture, _ = retained_schema_source(tag)
    if fixture.attachment() is not None:
        raise RuntimeError('Retained image must be detached before preparing imageinfo scope')
    if SCHEMA_ROOT.resolve() != SCHEMA_ROOT:
        raise RuntimeError('Redirected schema-probe root')
    SCHEMA_ROOT.mkdir(mode=0o700, exist_ok=True)
    drive_image_qa.owned_directory(SCHEMA_ROOT)
    record_id = str(uuid.uuid4()).upper()
    record = SCHEMA_ROOT / record_id
    record.mkdir(mode=0o700)
    drive_image_qa.owned_directory(record)
    scope = detached_imageinfo_scope(record_id, expires_utc, case, fixture)
    drive_image_qa.put(record / 'scope.json', scope)
    sync_schema_record(record)
    return {'recordID': record_id,
            'scopeSHA256': hashlib.sha256((record / 'scope.json').read_bytes()).hexdigest(),
            'sourceCase': tag, 'imageAlreadyExists': True, 'imageCurrentlyAttached': False,
            'imageInfoMaximum': 1, 'normalAttachMaximum': 0, 'normalDetachMaximum': 0,
            'appLaunchMaximum': 0, 'apfsAddMaximum': 0, 'apfsFormatMaximum': 0,
            'executed': False}


def execute_detached_imageinfo_scope(tag: str, record_id: str, approved_hash: str) -> dict:
    if not re.fullmatch(r'[0-9a-f]{64}', approved_hash):
        raise RuntimeError('Exact reviewed detached imageinfo scope SHA-256 required')
    if SCHEMA_ROOT.resolve() != SCHEMA_ROOT:
        raise RuntimeError('Redirected schema-probe root')
    drive_image_qa.owned_directory(SCHEMA_ROOT)
    record = SCHEMA_ROOT / drive_image_qa.canonical(record_id)
    drive_image_qa.owned_directory(record)
    scope_path = record / 'scope.json'
    scope = drive_image_qa.owned_json(scope_path, maximum=8192)
    if hashlib.sha256(scope_path.read_bytes()).hexdigest() != approved_hash:
        raise RuntimeError('Reviewed detached imageinfo scope hash changed')
    if datetime.now(timezone.utc) >= schema_expiry(scope.get('expiresUTC')):
        raise RuntimeError('Reviewed detached imageinfo scope expired')
    case, fixture, _ = retained_schema_source(tag)
    if scope != detached_imageinfo_scope(record_id, scope['expiresUTC'], case, fixture):
        raise RuntimeError('Detached imageinfo scope or retained inputs changed')
    before_attachment = fixture.attachment()
    before_facts = schema_image_facts(fixture)
    if before_attachment is not None or before_facts != scope['imageFacts']:
        raise RuntimeError('Detached imageinfo preflight changed')
    if (record / 'attempt.json').exists() or (record / 'terminal.json').exists():
        raise RuntimeError('Detached imageinfo observation is one-shot')
    require_unlocked_console()
    drive_image_qa.put(record / 'attempt.json',
                       {'recordID': record_id, 'sourceCase': tag, 'attempt': 1,
                        'stage': 'before-imageinfo', 'explicitAttachCalls': 0,
                        'explicitDetachCalls': 0, 'appLaunches': 0})
    sync_schema_record(record)

    raw: bytes | None = None
    tool_error: str | None = None
    try:
        raw = tool(['/usr/bin/hdiutil', 'imageinfo', '-plist', str(fixture.image)], timeout=30)
    except Exception as error:
        tool_error = type(error).__name__
    # Postconditions run even when imageinfo fails. Never detach an attachment
    # that this read-only scope did not authorize us to create or own.
    attachment_after = 'unknown'
    attachment_error: str | None = None
    try:
        attachment_after = 'detached' if fixture.attachment() is None else 'attached'
    except Exception as error:
        attachment_error = type(error).__name__
    facts_unchanged = False
    facts_error: str | None = None
    try:
        facts_unchanged = schema_image_facts(fixture) == before_facts
    except Exception as error:
        facts_error = type(error).__name__
    observation: dict | None = None
    parse_error: str | None = None
    if raw is not None:
        if len(raw) > DETACHED_IMAGEINFO_LIMIT:
            parse_error = 'OutputLimit'
        else:
            try:
                observation = detached_imageinfo_projection(plistlib.loads(raw))
            except Exception as error:
                parse_error = type(error).__name__
    passed = (tool_error is None and parse_error is None and observation is not None
              and attachment_after == 'detached' and facts_unchanged)
    stage = ('completed' if passed else 'postcheck-uncertain'
             if attachment_after != 'detached' or not facts_unchanged else 'imageinfo-failed')
    result = {'passed': passed, 'stage': stage, 'recordID': record_id,
              'sourceCase': tag, 'observation': observation,
              'toolErrorType': tool_error, 'parseErrorType': parse_error,
              'attachmentErrorType': attachment_error, 'imageFactsErrorType': facts_error,
              'attachmentBefore': 'detached', 'attachmentAfter': attachment_after,
              'imageFactsUnchanged': facts_unchanged, 'imagePreserved': facts_unchanged,
              'imageInfoAttempted': True, 'explicitAttachCalls': 0, 'explicitDetachCalls': 0,
              'transientAttachmentCoverage': 'not exercised',
              'imageCreateCalls': 0, 'appLaunches': 0, 'apfsAddCalls': 0, 'apfsFormatCalls': 0,
              'ordinaryFormatQualified': False}
    drive_image_qa.put(record / 'terminal.json', result)
    sync_schema_record(record)
    if not passed:
        raise RuntimeError('Detached imageinfo observation failed or changed; retain image and evidence')
    return result


def execute_schema_scope(tag: str, record_id: str, approved_hash: str) -> dict:
    if not re.fullmatch(r'[0-9a-f]{64}', approved_hash):
        raise RuntimeError('Exact reviewed schema-scope SHA-256 required')
    if SCHEMA_ROOT.resolve() != SCHEMA_ROOT:
        raise RuntimeError('Redirected schema-probe root')
    drive_image_qa.owned_directory(SCHEMA_ROOT)
    record = SCHEMA_ROOT / drive_image_qa.canonical(record_id)
    drive_image_qa.owned_directory(record)
    scope_path = record / 'scope.json'
    scope = drive_image_qa.owned_json(scope_path, maximum=8192)
    if hashlib.sha256(scope_path.read_bytes()).hexdigest() != approved_hash:
        raise RuntimeError('Reviewed schema-scope hash changed')
    if datetime.now(timezone.utc) >= schema_expiry(scope.get('expiresUTC')):
        raise RuntimeError('Reviewed schema scope expired')
    case, fixture, outcome = retained_schema_source(tag)
    if scope != schema_scope(record_id, scope['expiresUTC'], case, fixture):
        raise RuntimeError('Retained image, case evidence or controller inputs changed')
    if fixture.attachment() is not None:
        raise RuntimeError('Retained image was already attached before scoped observation')
    if (record / 'attempt.json').exists() or (record / 'terminal.json').exists():
        raise RuntimeError('Schema observation is one-shot; previous attempt retained')
    require_unlocked_console()
    drive_image_qa.put(record / 'attempt.json',
        {'recordID': record_id, 'sourceCase': tag, 'attempt': 1,
         'stage': 'before-normal-attach', 'appLaunches': 0,
         'apfsAddCalls': 0, 'apfsFormatCalls': 0})
    sync_schema_record(record)
    stage = 'normal-attach'
    attach_attempted = False
    detach_attempted = False
    observation: dict | None = None
    observation_error: str | None = None
    try:
        attach_attempted = True
        fixture.attach_preserved_two_member(original_uuid=outcome['siblingUUID'],
                                            target_uuid=outcome['formattedUUID'])
        stage = 'allowlisted-schema-observation'
        try:
            observation = inspect_attached_ordinary_schema(tag)
        except Exception as error:
            observation_error = type(error).__name__
        # Even an unsupported parser schema may detach normally. A lost owner,
        # member or marker makes detachment uncertain and preserves the mount.
        stage = 'pre-detach-owner-revalidation'
        retained_schema_graph(fixture, outcome)
        fixture.validate()
        stage = 'normal-detach'
        detach_attempted = True
        fixture.detach_owned()
        if fixture.attachment() is not None:
            raise RuntimeError('Exact retained image still attached after normal detach')
        result = {'passed': observation is not None, 'stage': 'completed',
                  'recordID': record_id, 'sourceCase': tag,
                  'schema': observation, 'observationErrorType': observation_error,
                  'normalAttachCalls': 1, 'normalDetachCalls': 1,
                  'imageCreateCalls': 0, 'appLaunches': 0,
                  'apfsAddCalls': 0, 'apfsFormatCalls': 0,
                  'ordinaryFormatQualified': False, 'imagePreserved': True}
        drive_image_qa.put(record / 'terminal.json', result)
        sync_schema_record(record)
        return result
    except Exception as error:
        result = {'passed': False, 'stage': stage, 'recordID': record_id,
                  'sourceCase': tag, 'errorType': type(error).__name__,
                  'normalAttachAttempted': attach_attempted,
                  'normalDetachAttempted': detach_attempted,
                  'appLaunches': 0, 'apfsAddCalls': 0, 'apfsFormatCalls': 0,
                  'ordinaryFormatQualified': False, 'imagePreserved': True}
        drive_image_qa.put(record / 'terminal.json', result)
        sync_schema_record(record)
        raise RuntimeError('Schema observation failed; retain exact generated image and evidence') from None


def private_temporary(case: Path) -> Path:
    """Keep this host, its device tools, and the signed app inside one case."""
    temporary = case / 'source/Library/tmp'
    temporary.mkdir(mode=0o700, exist_ok=True)
    drive_image_qa.owned_directory(temporary)
    os.environ.pop('CFFIXED_USER_HOME', None)
    os.environ['TMPDIR'] = str(temporary) + '/'
    return temporary


def submitted_child_may_be_outstanding(case: Path) -> bool:
    evidence = case / 'evidence'
    for action in ('add', 'format'):
        submission = evidence / ('apfs-' + action + '-submitted.json')
        terminal = evidence / ('apfs-' + action + '-terminal.json')
        if not terminal.exists() and submission.exists():
            expected = {'phase': 'submitted', 'request': 'one-apfs-volume-'
                        + ('add' if action == 'add' else 'erase')}
            if drive_image_qa.owned_json(submission) == expected:
                return True
    return False


def phase(case: Path, tag: str, name: str, *, wait_limit: int) -> dict:
    before = signed_local_qa.audit_runtime_case(case)
    drive_image_qa.issue_phase(tag, name)
    signed_local_qa.audit_runtime_case(case)
    app = case / 'Products/Release/Mac Explorer.app/Contents/MacOS/Mac Explorer'
    env = os.environ.copy()
    env['MAC_EXPLORER_TEST_ROOT'] = str(case)
    log = case / 'evidence' / ('host-drive-image-' + name + '.log')
    command = [str(app), '--verify-ui', '--check-drive-image-qa', '--phase', name]
    started = time.monotonic()
    descriptor = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        os.fchmod(output.fileno(), 0o600)
        signed_local_qa.audit_runtime_case(case, log=log)
        process = subprocess.Popen(command, cwd=REPO, env=env, stdin=subprocess.DEVNULL,
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        drive_image_qa.put(case / 'evidence' / ('host-drive-image-' + name + '-launch.json'),
            {'phase': name, 'pid': process.pid, 'attempt': 1, 'case': tag, 'before': before})
        try:
            while process.poll() is None:
                signed_local_qa.audit_runtime_case(case, log=log)
                elapsed = time.monotonic() - started
                if elapsed > wait_limit and not (name == 'warm' and submitted_child_may_be_outstanding(case)):
                    raise RuntimeError('Signed phase deadline reached with no outstanding native child witness')
                time.sleep(1)
            after = signed_local_qa.audit_runtime_case(case, log=log)
        except Exception as error:
            # A submitted native child cannot be cancelled. Preserve this app,
            # image, job and attachment for inspection, without retry or detach.
            drive_image_qa.put(case / 'evidence' / ('host-drive-image-' + name + '-uncertain.json'),
                {'phase': name, 'pid': process.pid, 'errorType': type(error).__name__,
                 'elapsedSeconds': time.monotonic() - started})
            raise
    result = owned_result(case, 'drive-image-' + name + '-result.json')
    diagnostics = inspect_runtime(log)
    drive_image_qa.put(case / 'evidence' / ('host-drive-image-' + name + '-diagnostics.json'), diagnostics)
    passed = process.returncode == 0 and result.get('passed') is True \
        and result.get('phase') == name and result.get('stage') == 'completed' \
        and result.get('pid') == process.pid and diagnostics.get('passed') is True
    receipt = dict(phase=name, pid=process.pid, exitCode=process.returncode,
        elapsedSeconds=time.monotonic()-started, before=before, after=after,
        result=result, diagnosticsPassed=diagnostics.get('passed'),
        passed=passed)
    drive_image_qa.put(case / 'evidence' / ('host-drive-image-' + name + '-receipt.json'), receipt)
    if not passed:
        raise RuntimeError('Signed ' + name + ' phase failed; exact generated evidence retained')
    return receipt


def post_format(fixture: Fixture, result: dict, mode: drive_image_qa.CaseMode) -> dict:
    if result.get('passed') is not True or result.get('submitted') is not True \
            or not mode.matches_format_result(result) \
            or result.get('targetMarkerRemoved') is not True \
            or result.get('siblingMarkerPreserved') is not True \
            or result.get('unrelatedMountsUnchanged') is not True:
        raise RuntimeError('Native APFS Format result did not establish its postconditions')
    sibling_id = result['siblingUUID']
    formatted_id = result['formattedUUID']
    graph = fixture.two_member_owned(original_uuid=sibling_id, target_uuid=formatted_id)
    sibling = graph['members'][sibling_id]
    target = graph['members'][formatted_id]
    if graph['outer'] != result['outerDevice'] \
            or sibling['device'] != result['siblingDevice'] \
            or target['name'] != result['formattedName']:
        raise RuntimeError('Generated APFS image graph changed after signed process')
    sibling_marker = fixture.member_marker(sibling['mount'], '.mac-explorer-drive-owner',
        expected_device=sibling['device'], expected_uuid=sibling_id,
        expected_mount_device=sibling['mountDevice'])
    target_marker = fixture.member_marker(target['mount'], '.mac-explorer-format-target',
        expected_device=target['device'], expected_uuid=formatted_id,
        expected_mount_device=target['mountDevice'])
    if sibling_marker != (sibling['mountDevice'], result['siblingMarkerInode']) or target_marker is not None:
        raise RuntimeError('Generated APFS marker postcondition changed')
    return dict(siblingUUID=sibling_id, formattedUUID=formatted_id,
        outerDevice=result['outerDevice'], siblingMarkerPreserved=True,
        targetMarkerRemoved=True)


def verify_warm_job(saved: dict, outcome: dict, mode: drive_image_qa.CaseMode,
                    *, image: Path, receipt: dict, added_uuid: str) -> None:
    completion = saved.get('nativeCompletion')
    if type(saved.get('version')) is not int or saved['version'] != mode.job_version \
            or saved.get('phase') != 'observedNativeCompletion' \
            or saved.get('id') != outcome['jobID'] \
            or saved.get('replacementID') != outcome['formattedUUID'] \
            or not isinstance(completion, dict) or type(completion.get('version')) is not int \
            or completion['version'] != 1 or completion.get('replacementID') != outcome['formattedUUID'] \
            or type(completion.get('nativeExitStatus')) is not int or completion['nativeExitStatus'] != 0 \
            or not (completion.get('nativeErrorCode') is None
                    or type(completion['nativeErrorCode']) is int and completion['nativeErrorCode'] == 0) \
            or not isinstance(completion.get('intentSHA256'), str) \
            or not re.fullmatch(r'[0-9a-f]{64}', completion['intentSHA256']):
        raise RuntimeError('Warm native completion was not durably bound to the exact generated job')
    if mode is drive_image_qa.CaseMode.APP_MODEL:
        expected_owner = dict(imagePath=str(image), parentDevice=receipt['fixtureDevice'],
            parentInode=receipt['fixtureInode'], imageDevice=receipt['imageDevice'],
            imageInode=receipt['imageInode'], imageBytes=drive_image_qa.IMAGE_BYTES,
            ownerUID=os.geteuid(), outerDevice=outcome['outerDevice'].removeprefix('/dev/'),
            outerMediaID=receipt['outerMediaID'])
        owner = saved.get('ordinaryImageOwner')
        snapshot = saved.get('snapshot')
        if ('owner' in saved or not isinstance(owner, dict) or set(owner) != set(expected_owner)
                or any(type(owner[key]) is not type(value) or owner[key] != value
                       for key, value in expected_owner.items())
                or not isinstance(snapshot, dict) or snapshot.get('targetID') != added_uuid
                or added_uuid in (outcome['siblingUUID'], outcome['formattedUUID'])):
            raise RuntimeError('Warm App model intent did not own the exact generated target')


def valid_cold_result(result: dict, job_id: str, mode: drive_image_qa.CaseMode) -> bool:
    expected = dict(passed=True, jobID=job_id, completionContract=mode.contract,
        resolvedNativeCompletion=True, admissionHeld=True, recordUnchanged=True,
        unresolvedPromotion=False, allMutationCapabilitiesHeld=True,
        siblingMarkerPreserved=True, targetMarkerAbsent=True)
    if mode is drive_image_qa.CaseMode.APP_MODEL:
        expected.update(jobVersion=mode.job_version, ordinaryEnabled=False)
    return set(result) == set(expected) and all(type(result[k]) is type(v) and result[k] == v
        for k, v in expected.items())


def run(tag: str, approved_hash: str) -> dict:
    case, admission = drive_image_qa.admitted_case(tag)
    mode = drive_image_qa.CaseMode.from_admission(admission)
    inspected = drive_image_qa.inspect(tag, frozen=True)
    provenance = {**drive_image_qa.sealed_build_provenance(tag, inspected),
                  **drive_image_qa.current_controller_provenance(tag)}
    scope_path = case / 'evidence/runtime-scope.json'
    scope = drive_image_qa.owned_json(scope_path)
    observed_hash = hashlib.sha256(scope_path.read_bytes()).hexdigest()
    if not re.fullmatch(r'[0-9a-f]{64}', approved_hash) or approved_hash != observed_hash \
            or not drive_image_qa.valid_scope(tag, scope, inspected['app']['treeSHA256'], provenance, mode):
        raise RuntimeError('Reviewed drive-image scope hash or expiry differs')
    private_temporary(case)
    require_unlocked_console()
    fixture = Fixture.prepared(drive_image_qa.fixture_path(tag))
    # The read-only preparation probe must build before any image or mount.
    build_preparation_probe()
    report = {'passed': False, 'case': tag, 'scopeSHA256': observed_hash,
        'currentSourceMatch': inspected['currentSourceMatch'],
        'imagePreserved': True, 'addCallBudget': 1, 'formatCallBudget': 1,
        'normalAttachBudget': 1, 'normalDetachBudget': 1, 'forceDetachBudget': 0,
        'physicalDriveBudget': 0, 'archiveJobBudget': 0, 'networkSessionBudget': 0,
        'trashJobBudget': 0}
    if mode is drive_image_qa.CaseMode.APP_MODEL:
        report.update(mode.identity)
    try:
        phase(case, tag, 'pre-image', wait_limit=300)
        pre = owned_result(case, 'drive-image-pre-image-review.json')
        if pre != {'passed': True, 'cleanAdmission': True, 'imageAbsent': True,
                   'recorderCreated': False, 'jobUnchanged': True} \
                or os.path.lexists(fixture.image):
            raise RuntimeError('Passive pre-image admission did not remain clean')
        fixture.validate()
        fixture.create()  # One RAW 1 GiB image, normal attach and exact marker.
        fixture.validate()
        receipt = fixture.run_receipt(case / 'evidence')
        drive_image_qa.put(case / 'evidence/native-drive-receipt.json', receipt)
        phase(case, tag, 'warm', wait_limit=300)
        outcome = owned_result(case, 'apfs-format-result.json')
        report['warmPostcheck'] = post_format(fixture, outcome, mode)
        report['addSubmitted'] = owned_result(case, 'apfs-add-submitted.json') \
            == {'phase': 'submitted', 'request': 'one-apfs-volume-add'}
        report['formatSubmitted'] = owned_result(case, 'apfs-format-submitted.json') \
            == {'phase': 'submitted', 'request': 'one-apfs-volume-erase'}
        if not report['addSubmitted'] or not report['formatSubmitted']:
            raise RuntimeError('Exact generated APFS submission receipts missing')
        job = case / 'source/Library/Application Support' / drive_image_qa.identifier(tag) \
            / 'drive-jobs/native-drive-job-v1.json'
        saved = drive_image_qa.owned_json(job, maximum=65_536)
        added = owned_result(case, 'apfs-add-terminal.json')
        verify_warm_job(saved, outcome, mode, image=fixture.image, receipt=receipt,
            added_uuid=drive_image_qa.canonical(added['createdUUID']))
        before = hashlib.sha256(job.read_bytes()).hexdigest()
        drive_image_qa.put(case / 'evidence/host-drive-image-warm-postcheck.json',
            {'passed': True, 'jobID': outcome['jobID'], 'jobSHA256': before,
             **report['warmPostcheck']})
        phase(case, tag, 'cold', wait_limit=300)
        cold = owned_result(case, 'apfs-format-cold-result.json')
        if not valid_cold_result(cold, outcome['jobID'], mode) \
                or hashlib.sha256(job.read_bytes()).hexdigest() != before:
            raise RuntimeError('Cold native completion, marker or admission changed')
        report['coldPostcheck'] = post_format(fixture, outcome, mode)
        report['jobSHA256'] = before
        # The matching image and native jobs have settled. Normal detach only.
        fixture.detach_owned()
        report['normalDetach'] = True
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
        drive_image_qa.put(case / 'evidence/host-drive-image-result.json', report)
        raise
    drive_image_qa.put(case / 'evidence/host-drive-image-result.json', report)
    return report


def prepare_scope(tag: str, expires_utc: str) -> dict:
    case, admission = drive_image_qa.admitted_case(tag)
    mode = drive_image_qa.CaseMode.from_admission(admission)
    inspected = drive_image_qa.inspect(tag)
    provenance = drive_image_qa.sealed_build_provenance(tag, inspected)
    if (case / 'evidence/runtime-scope.json').exists():
        raise RuntimeError('A drive scope already occupies this case')
    try:
        datetime.strptime(expires_utc, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except ValueError:
        raise RuntimeError('Exact UTC scope expiry required') from None
    controller = drive_image_qa.controller_packet()
    controller_data = drive_image_qa.controller_bytes(controller)
    provenance.update(controllerInputsSHA256=hashlib.sha256(controller_data).hexdigest(),
                      controllerInputsCount=len(controller['sourceSHA256']))
    app_hash = inspected['app']['treeSHA256']
    scope = drive_image_qa.runtime_scope(tag, app_hash, provenance, mode, expires_utc)
    if not drive_image_qa.valid_scope(tag, scope, app_hash, provenance, mode):
        raise RuntimeError('Proposed drive scope failed exact validation')
    path = case / 'evidence/runtime-scope.json'
    drive_image_qa.put(case / 'evidence/execution-controller-inputs.json', controller)
    if drive_image_qa.current_controller_provenance(tag) != {
            key: provenance[key] for key in ('controllerInputsSHA256', 'controllerInputsCount')}:
        raise RuntimeError('Drive controller inputs changed while preparing scope')
    drive_image_qa.put(path, scope)
    return {'case': tag, 'scopeSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'fixtureRoot': scope['fixtureRoot'], 'imageExists': False,
        'appLaunches': 0, 'driveMutations': 0}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['review', 'prepare-scope', 'execute',
                                           'inspect-attached-schema', 'prepare-schema-scope', 'execute-schema-scope',
                                           'prepare-detached-imageinfo-scope', 'execute-detached-imageinfo-scope'])
    parser.add_argument('--case', required=True)
    parser.add_argument('--expires-utc')
    parser.add_argument('--approved-scope-sha256')
    parser.add_argument('--record-id')
    args = parser.parse_args()
    if args.action == 'inspect-attached-schema':
        if args.expires_utc or args.approved_scope_sha256 or args.record_id:
            parser.error('inspect-attached-schema takes no mutation scope arguments')
        print(json.dumps({**inspect_attached_ordinary_schema(drive_image_qa.canonical(args.case)),
                          'appLaunches': 0, 'normalAttachCalls': 0, 'normalDetachCalls': 0,
                          'apfsAddCalls': 0, 'apfsFormatCalls': 0,
                          'ordinaryFormatQualified': False}, indent=2, sort_keys=True))
        return
    if args.action == 'prepare-schema-scope':
        if args.record_id or args.approved_scope_sha256 or not args.expires_utc:
            parser.error('prepare-schema-scope requires --expires-utc only')
        result = prepare_schema_scope(drive_image_qa.canonical(args.case), args.expires_utc)
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    if args.action == 'execute-schema-scope':
        if args.expires_utc or not args.record_id or not args.approved_scope_sha256:
            parser.error('execute-schema-scope requires --record-id and --approved-scope-sha256 only')
        result = execute_schema_scope(drive_image_qa.canonical(args.case), args.record_id,
                                      args.approved_scope_sha256)
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    if args.action == 'prepare-detached-imageinfo-scope':
        if args.record_id or args.approved_scope_sha256 or not args.expires_utc:
            parser.error('prepare-detached-imageinfo-scope requires --expires-utc only')
        result = prepare_detached_imageinfo_scope(drive_image_qa.canonical(args.case), args.expires_utc)
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    if args.action == 'execute-detached-imageinfo-scope':
        if args.expires_utc or not args.record_id or not args.approved_scope_sha256:
            parser.error('execute-detached-imageinfo-scope requires --record-id and --approved-scope-sha256 only')
        result = execute_detached_imageinfo_scope(drive_image_qa.canonical(args.case), args.record_id,
                                                  args.approved_scope_sha256)
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    if args.action == 'review':
        if args.expires_utc or args.approved_scope_sha256 or args.record_id:
            parser.error('review takes no scope arguments')
        print(json.dumps({'case': drive_image_qa.canonical(args.case),
            'plan': 'one passive pre-image visit; one generated 1 GiB image and normal attach; '
                    'at most one Add and one Format; one cold read-only native-completion visit; '
                    'normal detach only after exact postchecks; no retry or force'},
            indent=2, sort_keys=True))
        return
    if args.action == 'prepare-scope':
        if args.record_id or args.approved_scope_sha256 or not args.expires_utc:
            parser.error('prepare-scope requires --expires-utc only')
        result = prepare_scope(args.case, args.expires_utc)
    else:
        if args.record_id or args.expires_utc or not args.approved_scope_sha256:
            parser.error('execute requires --approved-scope-sha256 only')
        result = run(args.case, args.approved_scope_sha256)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
