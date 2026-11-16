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

    def issue(self, *, member_suite=False):
        qa.put(self.case / 'evidence/runtime-scope.json', self.scope)
        admission = {'archiveSuite': 'tar-members'} if member_suite else {}
        with patch.object(qa, 'admitted_case', return_value=(self.case, admission)), \
             patch.object(qa, 'inspect', return_value={'app': self.app}):
            return qa.issue_phase(self.tag, 'archive-warm')

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


if __name__ == '__main__':
    unittest.main()
