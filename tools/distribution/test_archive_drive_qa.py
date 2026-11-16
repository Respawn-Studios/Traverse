"""Offline phase admission regressions; no signing, process, app or device calls."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

import archive_drive_qa as qa
import native_checks


class ArchivePhaseAdmissionTests(unittest.TestCase):
    def setUp(self):
        parent = qa.REPO / '.build/tmp'
        parent.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='archive-phase-', dir=parent)
        self.addCleanup(temporary.cleanup)
        self.tag = str(uuid.uuid4()).upper()
        self.case = Path(temporary.name) / self.tag
        (self.case / 'evidence').mkdir(parents=True, mode=0o700)
        self.app = {'treeSHA256': 'a' * 64}
        qa.put(self.case / 'evidence/build-result.json', {
            'passed': True, 'inspected': {'app': self.app}})
        self.scope = dict(packet='archive-drive-runtime-scope-v1', case=self.tag,
            bundleIdentifier=qa.identifier(self.tag), caseRoot=str(self.case),
            fixtureRoot=str(self.case / 'source/Operation Root'),
            artifactTreeSHA256=self.app['treeSHA256'],
            expiresUTC=(datetime.now(timezone.utc) + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'),
            phaseLaunchCeiling=dict(qa.PHASE_CEILING),
            archiveForwardJobsMaximum=12, archiveColdUndosMaximum=12,
            generatedFileMaximumBytes=1 << 20, generatedTotalMaximumBytes=4 << 20,
            driveMutationMaximum=0, networkSessionsMaximum=0, trashJobsMaximum=0)

    def issue(self, *, member_suite=False, promise_suite=False, phase='archive-warm'):
        qa.put(self.case / 'evidence/runtime-scope.json', self.scope)
        admission = {'archiveSuite': 'tar-promises'} if promise_suite else {'archiveSuite': 'tar-members'} if member_suite else {}
        with patch.object(qa, 'admitted_case', return_value=(self.case, admission)), \
             patch.object(qa, 'inspect', return_value={'app': self.app}):
            return qa.issue_phase(self.tag, phase)

    def assert_refused(self, *, member_suite=False):
        with self.assertRaises(ValueError):
            self.issue(member_suite=member_suite)
        self.assertFalse((self.case / 'evidence/archive-drive-archive-warm-permit.json').exists())

    def test_existing_authored_scope_retains_twelve_jobs(self):
        result = self.issue()
        permit = json.loads((qa.REPO / result['permit']).read_bytes())
        scope_bytes = (self.case / 'evidence/runtime-scope.json').read_bytes()
        self.assertEqual(permit['scopeSHA256'], hashlib.sha256(scope_bytes).hexdigest())
        self.assertEqual(permit['attempt'], 1)
        with patch.object(qa, 'admitted_case', return_value=(self.case, {})), \
             patch.object(qa, 'inspect', return_value={'app': self.app}):
            with self.assertRaises(ValueError):
                qa.issue_phase(self.tag, 'archive-warm')

    def test_member_suite_requires_its_own_exact_budget(self):
        self.scope.update(archiveSuite='tar-members', archiveForwardJobsMaximum=42,
                          archiveColdUndosMaximum=42, generatedFixtureEntriesMaximum=192)
        self.assertTrue(self.issue(member_suite=True)['issued'])

    def test_member_suite_cannot_use_the_authored_budget(self):
        self.scope.update(archiveSuite='tar-members', generatedFixtureEntriesMaximum=192)
        self.assert_refused(member_suite=True)

    def test_member_suite_cannot_widen_its_fixture_entries(self):
        self.scope.update(archiveSuite='tar-members', archiveForwardJobsMaximum=42,
                          archiveColdUndosMaximum=42, generatedFixtureEntriesMaximum=193)
        self.assert_refused(member_suite=True)

    def test_authored_suite_cannot_borrow_member_budget(self):
        self.scope.update(archiveForwardJobsMaximum=42, archiveColdUndosMaximum=42)
        self.assert_refused()

    def test_member_suite_must_be_named_in_its_scope(self):
        self.scope.update(archiveForwardJobsMaximum=42, archiveColdUndosMaximum=42)
        self.assert_refused(member_suite=True)

    def test_boolean_is_not_a_phase_attempt(self):
        self.scope['phaseLaunchCeiling']['archive-warm'] = True
        self.assert_refused()

    def test_archive_scope_cannot_grant_a_drive_mutation(self):
        self.scope['driveMutationMaximum'] = 1
        self.assert_refused()

    def promise_scope(self):
        root = self.case / 'source/Operation Root'
        root.mkdir(parents=True, mode=0o700)
        for name in ('Promise.tar', 'Promise.tar.gz', 'Promise.tar.bz2'):
            (root / name).write_bytes(b'Generated protocol fixture')
        witnesses = qa.fixture_archive_witnesses(self.case)
        self.scope.update(archiveSuite='tar-promises', archiveForwardJobsMaximum=6,
            archiveColdUndosMaximum=6, generatedFixtureEntriesMaximum=96,
            phaseLaunchCeiling=qa.phase_ceiling('tar-promises'), archiveInputSHA256={name: value['sha256'] for name,value in witnesses.items()},
            archiveInputBytesTotal=sum(value['bytes'] for value in witnesses.values()))

    def test_promise_suite_has_only_six_forward_and_cold_jobs(self):
        self.promise_scope()
        self.assertTrue(self.issue(promise_suite=True)['issued'])

    def test_promise_suite_cannot_borrow_member_budget(self):
        self.promise_scope()
        self.scope['archiveForwardJobsMaximum'] = 42
        with self.assertRaises(ValueError):
            self.issue(promise_suite=True)

    def test_promise_suite_cannot_launch_passive_drive_phase(self):
        self.promise_scope()
        with self.assertRaises(ValueError):
            self.issue(promise_suite=True, phase='drive-read-only')
        self.assertFalse((self.case / 'evidence/archive-drive-drive-read-only-permit.json').exists())

    def test_promise_suite_cannot_retain_three_phase_scope(self):
        self.promise_scope()
        self.scope['phaseLaunchCeiling'] = dict(qa.PHASE_CEILING)
        with self.assertRaises(ValueError):
            self.issue(promise_suite=True)

    def test_promise_suite_cannot_widen_fixture_entries(self):
        self.promise_scope()
        self.scope['generatedFixtureEntriesMaximum'] = 97
        with self.assertRaises(ValueError):
            self.issue(promise_suite=True)

    def test_promise_suite_refuses_a_replaced_archive_before_permit(self):
        self.promise_scope()
        (self.case / 'source/Operation Root/Promise.tar.gz').write_bytes(b'Replaced')
        with self.assertRaisesRegex(ValueError, 'hashes differ'):
            self.issue(promise_suite=True)
        self.assertFalse((self.case / 'evidence/archive-drive-archive-warm-permit.json').exists())

    def test_promise_suite_requires_all_three_presealed_sources(self):
        self.promise_scope()
        self.scope['archiveInputSHA256'].pop('Promise.tar.bz2')
        with self.assertRaisesRegex(ValueError, 'hashes differ'):
            self.issue(promise_suite=True)

    def test_promise_suite_cannot_understate_source_storage(self):
        self.promise_scope()
        self.scope['archiveInputBytesTotal'] -= 1
        with self.assertRaisesRegex(ValueError, 'byte count differs'):
            self.issue(promise_suite=True)


class FinderReceiverRouteTests(unittest.TestCase):
    """The existing native pipe must not acknowledge a different delivery."""
    def run_receiver(self, *, six_routes=False, wrong_route=False, extra_output=False, finder_metadata=False):
        temporary = tempfile.TemporaryDirectory(prefix='finder-receiver-', dir=qa.REPO / '.build/tmp')
        self.addCleanup(temporary.cleanup)
        case = Path(temporary.name)
        (case / 'source').mkdir()
        (case / 'evidence').mkdir()
        parents = [case / 'source' / name for name in ('TAR', 'GZIP', 'BZIP2')][:3 if six_routes else 1]
        for parent in parents:
            parent.mkdir()
        routes = tuple((f'{index}/{kind}', kind, parent) for index, parent in enumerate(parents) for kind in ('file', 'folder'))
        output = (case / 'evidence/log').open('wb')
        self.addCleanup(output.close)
        owner = self
        opened = set()
        processes = []
        class Process:
            returncode = None
            index = 0
            def __init__(self):
                self.stdin = self
                self.closed = False
                self.prepare()
            def event(self, event, values):
                output.write(b'TRAVERSE_PROMISE ' + json.dumps(dict(event=event, values=values)).encode() + b'\n')
            def prepare(self):
                route, kind, parent = routes[self.index]
                self.waiting = True
                values = dict(kind=kind)
                if six_routes:
                    values['route'] = 'wrong' if wrong_route else route
                self.event('ready', values)
            def deliver(self):
                if not self.waiting or routes[self.index][2] not in opened:
                    return
                self.waiting = False
                route, kind, parent = routes[self.index]
                if finder_metadata:
                    (parent / '.DS_Store').write_bytes(b'Generated Finder state')
                if kind == 'file':
                    (parent / 'Generated Promise.txt').write_bytes(b'Generated first root\n')
                else:
                    (parent / 'Generated Folder/Deep').mkdir(parents=True)
                    (parent / 'Generated Folder/Empty').mkdir()
                    (parent / 'Generated Folder/Report.txt').write_bytes(b'Generated folder member\n')
                    (parent / 'Generated Folder/Deep/More.txt').write_bytes(b'Generated nested member\n')
                if extra_output:
                    (parent / 'unexpected').write_bytes(b'x')
                values = dict(kind=kind)
                if six_routes:
                    values['route'] = 'wrong' if wrong_route else route
                self.event('write-completed', dict(values, nativeCallback=True, parentChoices=0))
            def write(self, message):
                owner.assertEqual(message, b'finish\n')
                self.index += 1
                if self.index == len(routes):
                    self.returncode = 0
                else:
                    self.prepare()
            def flush(self): pass
            def close(self):
                self.closed = True
                self.returncode = 0
            def poll(self): return self.returncode
            def wait(self, **kwargs): return self.returncode
        ticks = iter(range(10000))
        def launch(*args, **kwargs):
            process = Process()
            processes.append(process)
            return process
        def open_finder(command, **kwargs):
            opened.add(Path(command[-1]))
            processes[0].deliver()
        with patch.object(native_checks.subprocess, 'Popen', side_effect=launch), \
             patch.object(native_checks.subprocess, 'run', side_effect=open_finder), \
             patch.object(native_checks.time, 'monotonic', side_effect=lambda: next(ticks)), \
             patch.object(native_checks.time, 'sleep', side_effect=lambda _: processes[0].deliver() if processes[0].returncode is None else None):
            result = native_checks._run_generated_finder_promise(['generated'], case, {}, output, archive=True,
                destination=parents[0], archive_routes=routes if six_routes else None, signal_on_uncertainty=False)
        self.assertEqual(result.returncode, 0)
        receipt = json.loads((case / 'evidence/finder-receiver.json').read_bytes())
        self.assertTrue(receipt['passed'])
        self.assertEqual(receipt['controlMessages'], len(routes))

    def test_existing_file_folder_protocol_is_preserved(self):
        self.run_receiver()

    def test_six_deliveries_require_six_distinct_route_controls(self):
        self.run_receiver(six_routes=True)

    def test_different_native_route_is_not_acknowledged(self):
        with self.assertRaisesRegex(RuntimeError, 'phase differs'):
            self.run_receiver(six_routes=True, wrong_route=True)

    def test_extra_destination_item_is_not_acknowledged(self):
        with self.assertRaisesRegex(RuntimeError, 'extra output'):
            self.run_receiver(six_routes=True, extra_output=True)

    def test_bounded_finder_view_state_does_not_become_a_payload(self):
        self.run_receiver(six_routes=True, finder_metadata=True)


if __name__ == '__main__':
    unittest.main()
