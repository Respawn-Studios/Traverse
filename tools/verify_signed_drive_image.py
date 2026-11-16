#!/usr/bin/env python3
"""One bounded signed APFS image visit; default action is review only.

Execution needs an exact reviewed scope hash. It makes one 1 GiB generated
image, one normal attach, at most one APFS Add and one Format, one cold
read-only launch, and one normal detach after all checks settle. Failures
preserve the image, attachment, job and receipts; there is no retry or force.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'tools'))
from dev import require_unlocked_console
from distribution import drive_image_qa, signed_local_qa
from runtime_diagnostics import inspect as inspect_runtime
from verify_drive_lifecycle import Fixture, build_preparation_probe


def owned_result(case: Path, name: str) -> dict:
    return drive_image_qa.owned_json(case / 'evidence' / name, maximum=1 << 20)


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


def post_format(fixture: Fixture, result: dict) -> dict:
    if result.get('passed') is not True or result.get('submitted') is not True \
            or result.get('targetMarkerRemoved') is not True \
            or result.get('siblingMarkerPreserved') is not True \
            or result.get('unrelatedMountsUnchanged') is not True:
        raise RuntimeError('Native APFS Format result did not establish its postconditions')
    sibling_id = result['siblingUUID']
    formatted_id = result['formattedUUID']
    graph = fixture.two_member_owned(original_uuid=sibling_id, target_uuid=formatted_id)
    sibling = graph['members'][sibling_id]
    target = graph['members'][formatted_id]
    if '/dev/' + graph['outer'] != result['outerDevice'] \
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


def run(tag: str, approved_hash: str) -> dict:
    case, _ = drive_image_qa.admitted_case(tag)
    inspected = drive_image_qa.inspect(tag)
    built = owned_result(case, 'build-result.json')
    if built.get('passed') is not True or built.get('inspected', {}).get('app') != inspected['app']:
        raise RuntimeError('Signed drive artifact differs from its sealed build')
    scope_path = case / 'evidence/runtime-scope.json'
    scope = drive_image_qa.owned_json(scope_path)
    observed_hash = hashlib.sha256(scope_path.read_bytes()).hexdigest()
    if not re.fullmatch(r'[0-9a-f]{64}', approved_hash) or approved_hash != observed_hash \
            or not drive_image_qa.valid_scope(tag, scope, inspected['app']['treeSHA256']):
        raise RuntimeError('Reviewed drive-image scope hash or expiry differs')
    private_temporary(case)
    require_unlocked_console()
    fixture = Fixture.prepared(drive_image_qa.fixture_path(tag))
    # The read-only preparation probe must build before any image or mount.
    build_preparation_probe()
    report = {'passed': False, 'case': tag, 'scopeSHA256': observed_hash,
        'imagePreserved': True, 'addCallBudget': 1, 'formatCallBudget': 1,
        'normalAttachBudget': 1, 'normalDetachBudget': 1, 'forceDetachBudget': 0,
        'physicalDriveBudget': 0, 'archiveJobBudget': 0, 'networkSessionBudget': 0,
        'trashJobBudget': 0}
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
        drive_image_qa.put(case / 'evidence/native-drive-receipt.json', fixture.run_receipt(case / 'evidence'))
        phase(case, tag, 'warm', wait_limit=300)
        outcome = owned_result(case, 'apfs-format-result.json')
        report['warmPostcheck'] = post_format(fixture, outcome)
        report['addSubmitted'] = owned_result(case, 'apfs-add-submitted.json') \
            == {'phase': 'submitted', 'request': 'one-apfs-volume-add'}
        report['formatSubmitted'] = owned_result(case, 'apfs-format-submitted.json') \
            == {'phase': 'submitted', 'request': 'one-apfs-volume-erase'}
        if not report['addSubmitted'] or not report['formatSubmitted']:
            raise RuntimeError('Exact generated APFS submission receipts missing')
        drive_image_qa.put(case / 'evidence/host-drive-image-warm-postcheck.json',
            {'passed': True, 'jobID': outcome['jobID'], **report['warmPostcheck']})
        job = case / 'source/Library/Application Support' / drive_image_qa.identifier(tag) \
            / 'drive-jobs/native-drive-job-v1.json'
        before = hashlib.sha256(job.read_bytes()).hexdigest()
        phase(case, tag, 'cold', wait_limit=300)
        cold = owned_result(case, 'apfs-format-cold-result.json')
        if set(cold) != {'passed', 'jobID', 'unresolved', 'admissionHeld',
                         'recordUnchanged', 'compatibleInspection'} \
                or cold.get('passed') is not True or cold.get('jobID') != outcome['jobID'] \
                or cold.get('unresolved') is not True or cold.get('admissionHeld') is not True \
                or cold.get('recordUnchanged') is not True \
                or type(cold.get('compatibleInspection')) is not bool \
                or hashlib.sha256(job.read_bytes()).hexdigest() != before:
            raise RuntimeError('Cold unresolved job or admission changed')
        report['coldPostcheck'] = post_format(fixture, outcome)
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
    case, _ = drive_image_qa.admitted_case(tag)
    inspected = drive_image_qa.inspect(tag)
    built = owned_result(case, 'build-result.json')
    if built.get('passed') is not True or built.get('inspected', {}).get('app') != inspected['app']:
        raise RuntimeError('Signed drive artifact differs from its sealed build')
    if (case / 'evidence/runtime-scope.json').exists():
        raise RuntimeError('A drive scope already occupies this case')
    try:
        datetime.strptime(expires_utc, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    except ValueError:
        raise RuntimeError('Exact UTC scope expiry required') from None
    fixture = Fixture(image_bytes=drive_image_qa.IMAGE_BYTES, job=tag)
    scope = dict(packet='drive-image-runtime-scope-v1', case=tag,
        bundleIdentifier=drive_image_qa.identifier(tag), caseRoot=str(case),
        fixtureRoot=str(fixture.root), artifactTreeSHA256=inspected['app']['treeSHA256'],
        expiresUTC=expires_utc, phaseLaunchCeiling=drive_image_qa.PHASE_CEILING,
        imageBytes=drive_image_qa.IMAGE_BYTES, normalAttachMaximum=1, normalDetachMaximum=1,
        forceDetachMaximum=0, apfsAddMaximum=1, apfsFormatMaximum=1,
        driveMutationMaximum=2, physicalDriveMaximum=0, archiveJobsMaximum=0,
        networkSessionsMaximum=0, trashJobsMaximum=0)
    if not drive_image_qa.valid_scope(tag, scope, inspected['app']['treeSHA256']):
        raise RuntimeError('Proposed drive scope failed exact validation')
    path = case / 'evidence/runtime-scope.json'
    drive_image_qa.put(path, scope)
    return {'case': tag, 'scopeSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'fixtureRoot': str(fixture.root), 'imageExists': False,
        'appLaunches': 0, 'driveMutations': 0}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['review', 'prepare-scope', 'execute'])
    parser.add_argument('--case', required=True)
    parser.add_argument('--expires-utc')
    parser.add_argument('--approved-scope-sha256')
    args = parser.parse_args()
    if args.action == 'review':
        print(json.dumps({'case': drive_image_qa.canonical(args.case),
            'plan': 'one passive pre-image visit; one generated 1 GiB image and normal attach; '
                    'at most one Add and one Format; one cold read-only unresolved-job visit; '
                    'normal detach only after exact postchecks; no retry or force'},
            indent=2, sort_keys=True))
        return
    if args.action == 'prepare-scope':
        if args.approved_scope_sha256 or not args.expires_utc:
            parser.error('prepare-scope requires --expires-utc only')
        result = prepare_scope(args.case, args.expires_utc)
    else:
        if args.expires_utc or not args.approved_scope_sha256:
            parser.error('execute requires --approved-scope-sha256 only')
        result = run(args.case, args.approved_scope_sha256)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
