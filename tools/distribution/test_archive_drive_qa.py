"""Offline phase admission regressions; no signing, process, app or device calls."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import uuid
from types import SimpleNamespace
import plistlib

import archive_drive_qa as qa
from distribution import drive_image_qa as drive, signed_local_qa as signed_local
import native_checks
import verify_signed_drive_image as signed_drive


class SignedDrivePostcheckTests(unittest.TestCase):
    def outcome(self):
        return dict(passed=True, submitted=True, targetMarkerRemoved=True,
            siblingMarkerPreserved=True, unrelatedMountsUnchanged=True,
            completionContract='observed-native-v2', jobVersion=2, nativeCompletionObserved=True,
            siblingUUID="sibling", formattedUUID="formatted", outerDevice="/dev/disk21",
            siblingDevice="disk22s1", formattedName="Generated", siblingMarkerInode=42)

    def fixture(self, *, marker_changed=False):
        class Fixture:
            def two_member_owned(self, **kwargs):
                return dict(outer="/dev/disk21", members={
                    "sibling": dict(device="disk22s1", mount="/generated/sibling", mountDevice=19),
                    "formatted": dict(device="disk22s2", mount="/generated/target", mountDevice=20, name="Generated")})
            def member_marker(self, mount, name, **kwargs):
                return (19, 43 if marker_changed else 42) if mount == "/generated/sibling" else None
        return Fixture()

    def test_absolute_owned_device_is_not_prefixed_twice(self):
        self.assertEqual(signed_drive.post_format(self.fixture(), self.outcome(),
            drive.CaseMode.GENERATED)["outerDevice"], "/dev/disk21")

    def test_different_device_and_changed_sibling_still_refuse(self):
        outcome = self.outcome()
        outcome["outerDevice"] = "/dev/disk99"
        with self.assertRaisesRegex(RuntimeError, "graph changed"):
            signed_drive.post_format(self.fixture(), outcome, drive.CaseMode.GENERATED)
        with self.assertRaisesRegex(RuntimeError, "marker postcondition"):
            signed_drive.post_format(self.fixture(marker_changed=True), self.outcome(), drive.CaseMode.GENERATED)

    def test_app_model_requires_its_own_warm_and_cold_results(self):
        mode = drive.CaseMode.APP_MODEL
        warm = dict(self.outcome(), completionContract='observed-native-v3', jobVersion=3,
            model='ApplicationAPFSVolumeFormat', typedGestureClaimed=False, ordinaryEnabled=False)
        cold = dict(passed=True, jobID='job', completionContract='observed-native-v3', jobVersion=3,
            resolvedNativeCompletion=True, admissionHeld=True, recordUnchanged=True,
            unresolvedPromotion=False, allMutationCapabilitiesHeld=True,
            siblingMarkerPreserved=True, targetMarkerAbsent=True, ordinaryEnabled=False)
        self.assertTrue(signed_drive.post_format(self.fixture(), warm, mode)['targetMarkerRemoved'])
        self.assertTrue(signed_drive.valid_cold_result(cold, 'job', mode))
        with self.assertRaisesRegex(RuntimeError, 'postconditions'):
            signed_drive.post_format(self.fixture(), self.outcome(), mode)
        self.assertFalse(signed_drive.valid_cold_result(cold, 'job', drive.CaseMode.GENERATED))
        self.assertFalse(signed_drive.valid_cold_result(dict(cold, ordinaryEnabled=True), 'job', mode))
        self.assertFalse(signed_drive.valid_cold_result(dict(cold, recordUnchanged=1), 'job', mode))

    def test_app_model_job_binds_the_added_member_and_exact_image_owner(self):
        image = qa.REPO / '.build/fixtures/generated/fixture.dmg'
        receipt = dict(fixtureDevice=1, fixtureInode=2, imageDevice=1, imageInode=3, outerMediaID=4)
        owner = dict(imagePath=str(image), parentDevice=1, parentInode=2, imageDevice=1,
            imageInode=3, outerMediaID=4, imageBytes=1 << 30, ownerUID=os.geteuid(), outerDevice='disk21')
        saved = dict(version=3, id='job', replacementID='formatted', phase='observedNativeCompletion',
            ordinaryImageOwner=owner, snapshot={'targetID': 'added'}, nativeCompletion=dict(
                version=1, nativeExitStatus=0, replacementID='formatted', intentSHA256='a' * 64))
        warm = dict(self.outcome(), jobID='job')
        def verify(record):
            signed_drive.verify_warm_job(record, warm, drive.CaseMode.APP_MODEL,
                image=image, receipt=receipt, added_uuid='added')
        verify(saved)
        for altered in (dict(saved, ordinaryImageOwner=dict(owner, imageInode=5)),
                        dict(saved, snapshot={'targetID': 'sibling'}), dict(saved, owner={})):
            with self.assertRaisesRegex(RuntimeError, 'exact generated target'):
                verify(altered)


class DetachedImageInfoScopeTests(unittest.TestCase):
    """Pure schema and cross-mode refusal checks; no image tool calls."""

    def test_projection_bounds_literals_and_requires_an_explicit_boolean(self):
        secret = '/private/generated-sensitive-image-path'
        value = signed_drive.detached_imageinfo_projection({
            'Format': 'RAW', 'image-type': secret, 'system-image': False,
            'Properties': {'image-path': secret}, 'image-path': secret})
        self.assertEqual(value['format'], {'present': True, 'type': 'string', 'literal': 'RAW'})
        self.assertEqual(value['imageType'], {'present': True, 'type': 'string', 'literal': 'other'})
        self.assertEqual(value['systemImage'], {'present': True, 'type': 'boolean', 'value': False})
        self.assertEqual(value['properties'], {'present': True, 'type': 'dictionary'})
        self.assertNotIn(secret, json.dumps(value))
        raw = signed_drive.detached_imageinfo_projection({'Format': 'RAW*', 'image-type': 'raw disk image'})
        self.assertEqual(raw['format']['literal'], 'RAW*')
        self.assertEqual(raw['imageType']['literal'], 'raw disk image')
        self.assertEqual(raw['systemImage'], {'present': False, 'type': 'missing'})
        for source, expected_type in [({}, 'missing'), ({'system-image': 0}, 'integer'),
                                      ({'system-image': 'false'}, 'string')]:
            field = signed_drive.detached_imageinfo_projection(source)['systemImage']
            self.assertEqual(field['type'], expected_type)
            self.assertNotIn('value', field)
        with self.assertRaisesRegex(ValueError, 'not an object'):
            signed_drive.detached_imageinfo_projection([])

    def test_v1_attach_scope_cannot_authorize_detached_imageinfo(self):
        parent = qa.REPO / '.build/tmp'
        parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='detached-imageinfo-scope-', dir=parent) as temporary:
            root = Path(temporary)
            tag = str(uuid.uuid4()).upper()
            record = root / tag
            record.mkdir(mode=0o700)
            case = root / 'case' / tag
            fixture = SimpleNamespace(root=root / 'fixture', attachment=lambda: None)
            expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
            facts = {'imageDevice': 1, 'imageInode': 2, 'imageModifiedNS': 3, 'imageChangedNS': 4}
            with patch.object(signed_drive, 'SCHEMA_ROOT', root), \
                 patch.object(signed_drive, 'retained_schema_source', return_value=(case, fixture, {})), \
                 patch.object(signed_drive, 'schema_image_facts', return_value=facts), \
                 patch.object(signed_drive, 'schema_input_hashes', return_value={'source': 'a' * 64}), \
                 patch.object(signed_drive, 'tool') as image_tool:
                old = signed_drive.schema_scope(tag, expiry, case, fixture)
                new = signed_drive.detached_imageinfo_scope(tag, expiry, case, fixture)
                self.assertNotEqual(old, new)
                self.assertEqual(new['packet'], signed_drive.DETACHED_IMAGEINFO_PACKET)
                self.assertEqual((new['imageInfoMaximum'], new['normalAttachMaximum'],
                                  new['normalDetachMaximum']), (1, 0, 0))
                drive.put(record / 'scope.json', old)
                approved = hashlib.sha256((record / 'scope.json').read_bytes()).hexdigest()
                with self.assertRaisesRegex(RuntimeError, 'scope or retained inputs changed'):
                    signed_drive.execute_detached_imageinfo_scope(tag, tag, approved)
                image_tool.assert_not_called()
                self.assertFalse((record / 'attempt.json').exists())
                self.assertFalse((record / 'terminal.json').exists())
                reverse_id = str(uuid.uuid4()).upper()
                reverse = root / reverse_id
                reverse.mkdir(mode=0o700)
                drive.put(reverse / 'scope.json', signed_drive.detached_imageinfo_scope(reverse_id, expiry, case, fixture))
                reverse_hash = hashlib.sha256((reverse / 'scope.json').read_bytes()).hexdigest()
                with self.assertRaisesRegex(RuntimeError, 'controller inputs changed'):
                    signed_drive.execute_schema_scope(tag, reverse_id, reverse_hash)
                image_tool.assert_not_called()
                self.assertFalse((reverse / 'attempt.json').exists())

    def test_one_shot_records_tool_failure_and_postflight_drift_without_cleanup(self):
        parent = qa.REPO / '.build/tmp'
        parent.mkdir(exist_ok=True)
        for scenario in ['completed', 'toolFailure', 'invalidPlist', 'oversize', 'fileDrift', 'attached']:
            with self.subTest(scenario=scenario), \
                 tempfile.TemporaryDirectory(prefix='detached-imageinfo-terminal-', dir=parent) as temporary:
                root = Path(temporary)
                tag = str(uuid.uuid4()).upper()
                record = root / tag
                record.mkdir(mode=0o700)
                case = root / 'case' / tag
                facts = {'imageDevice': 1, 'imageInode': 2, 'imageModifiedNS': 3, 'imageChangedNS': 4}
                attachment = [None]
                fixture = SimpleNamespace(root=root / 'fixture', image=root / 'fixture.dmg',
                                          attachment=lambda: attachment[0])
                expiry = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')

                def inquiry(arguments, *, timeout):
                    self.assertEqual(arguments, ['/usr/bin/hdiutil', 'imageinfo', '-plist', str(fixture.image)])
                    self.assertEqual(timeout, 30)
                    self.assertTrue((record / 'attempt.json').exists())
                    if scenario == 'toolFailure':
                        raise RuntimeError('Generated failure')
                    if scenario == 'fileDrift':
                        facts['imageModifiedNS'] += 1
                    if scenario == 'attached':
                        attachment[0] = ('generated-device',)
                    if scenario == 'invalidPlist':
                        return b'not a plist'
                    if scenario == 'oversize':
                        return b'x' * (signed_drive.DETACHED_IMAGEINFO_LIMIT + 1)
                    return plistlib.dumps({'Format': 'RAW', 'system-image': False})

                with patch.object(signed_drive, 'SCHEMA_ROOT', root), \
                     patch.object(signed_drive, 'retained_schema_source', return_value=(case, fixture, {})), \
                     patch.object(signed_drive, 'schema_image_facts', side_effect=lambda _: dict(facts)), \
                     patch.object(signed_drive, 'schema_input_hashes', return_value={'source': 'a' * 64}), \
                     patch.object(signed_drive, 'require_unlocked_console'), \
                     patch.object(signed_drive, 'tool', side_effect=inquiry) as image_tool:
                    scope = signed_drive.detached_imageinfo_scope(tag, expiry, case, fixture)
                    drive.put(record / 'scope.json', scope)
                    approved = hashlib.sha256((record / 'scope.json').read_bytes()).hexdigest()
                    if scenario == 'completed':
                        signed_drive.execute_detached_imageinfo_scope(tag, tag, approved)
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'retain image and evidence'):
                            signed_drive.execute_detached_imageinfo_scope(tag, tag, approved)
                    terminal = drive.owned_json(record / 'terminal.json', maximum=8192)
                    self.assertEqual(terminal['passed'], scenario == 'completed')
                    self.assertFalse(terminal['ordinaryFormatQualified'])
                    self.assertEqual((terminal['explicitAttachCalls'], terminal['explicitDetachCalls']), (0, 0))
                    self.assertEqual(terminal['imageFactsUnchanged'], scenario != 'fileDrift')
                    self.assertEqual(terminal['attachmentAfter'], 'attached' if scenario == 'attached' else 'detached')
                    self.assertEqual(image_tool.call_count, 1)
                    self.assertEqual(hashlib.sha256((record / 'scope.json').read_bytes()).hexdigest(), approved)
                    image_tool.reset_mock()
                    with self.assertRaises(RuntimeError):
                        signed_drive.execute_detached_imageinfo_scope(tag, tag, approved)
                    image_tool.assert_not_called()


class FrozenDriveArtifactTests(unittest.TestCase):
    """Offline receipt and provenance checks; no process or device launches."""
    def setUp(self):
        parent = qa.REPO / '.build/tmp'
        parent.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='drive-frozen-', dir=parent)
        self.addCleanup(temporary.cleanup)
        self.tag = str(uuid.uuid4()).upper()
        self.case = Path(temporary.name) / self.tag
        self.identifier = drive.identifier(self.tag)
        app = self.case / 'Products/Release/Mac Explorer.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Helpers').mkdir()
        (app / 'Contents/MacOS/Mac Explorer').write_bytes(b'generated app')
        (app / 'Contents/Helpers/storage-scanner-worker').write_bytes(b'generated worker')
        for name in ('Mac Explorer.app.dSYM', 'storage-scanner-worker.dSYM'):
            (self.case / 'Products/Release' / name).mkdir()
        with (app / 'Contents/Info.plist').open('wb') as output:
            plistlib.dump(dict(CFBundleIdentifier=self.identifier,
                MacExplorerDistributionChannel='qualification', MacExplorerAccessPolicy='local-user-v1',
                MacExplorerStorageMode='portable', TraverseDriveImageArchitecture='arm64'), output)
        (self.case / 'evidence').mkdir(mode=0o700)
        self.source = {'App/MacExplorer/Generated.swift': 'a' * 64}
        qa.put(self.case / 'evidence/build-inputs.json', dict(sourceSHA256=self.source,
            sourceInputs=1, case=self.tag, bundleIdentifier=self.identifier,
            appLaunches=0, driveMutations=0))

    def observed(self, *, current_source=False, require_current_source=True):
        signer = dict(Identifier=self.identifier, runtime=True,
            TeamIdentifier=signed_local.TEAM, authorities=['Developer ID Application: Generated'])
        worker = dict(signer, Identifier='generated.worker')
        tree = lambda path: {'treeSHA256': ('b' if path.suffix == '.app' else 'c') * 64}
        with patch.object(signed_local.subprocess, 'run', return_value=SimpleNamespace(stdout='arm64')), \
             patch.object(signed_local, 'signing', side_effect=[signer, worker]), \
             patch.object(signed_local, 'entitlements', return_value={}), \
             patch('distribution.sandbox.compiled_tree_receipt', side_effect=tree), \
             patch('distribution.helper_symbols.validate', return_value={'UUIDs': ['generated'], 'hasCompileUnits': True}):
            return signed_local.inspect(self.case, {'signingIdentity': 'D' * 40}, self.identifier,
                lambda info: True, lambda: self.source if current_source else {'different': 'e' * 64},
                'Generated drive', require_current_source=require_current_source)

    def test_frozen_inspector_keeps_signed_checks_when_source_changes(self):
        with self.assertRaisesRegex(ValueError, 'artifact inspection failed'):
            self.observed(current_source=False)
        observed = self.observed(current_source=True)
        self.assertTrue(observed['passed'])
        self.assertTrue(observed['currentSourceMatch'])
        self.assertTrue(observed['checks']['sourceMatch'])
        sealed = dict(observed)
        qa.put(self.case / 'evidence/build-result.json', dict(case=self.tag, passed=True,
            actualBuildExit=0, appLaunches=0, driveMutations=0, inspected=sealed))
        with patch.object(drive, 'case_path', return_value=self.case):
            frozen = self.observed(current_source=False, require_current_source=False)
            self.assertFalse(frozen['currentSourceMatch'])
            self.assertNotIn('sourceMatch', frozen['checks'])
            self.assertEqual(set(drive.sealed_build_provenance(self.tag, frozen)),
                             {'buildInputsSHA256', 'buildResultSHA256'})
            changed = dict(frozen, app={'treeSHA256': 'f' * 64})
            with self.assertRaisesRegex(ValueError, 'artifact differs from build'):
                drive.sealed_build_provenance(self.tag, changed)

    def test_controller_receipt_refuses_a_changed_live_input(self):
        packet = {'packet': drive.CONTROLLER_PACKET,
                  'sourceSHA256': {'tools/verify_signed_drive_image.py': 'a' * 64}}
        qa.put(self.case / 'evidence/execution-controller-inputs.json', packet)
        with patch.object(drive, 'case_path', return_value=self.case), \
             patch.object(drive, 'controller_packet', return_value=packet):
            provenance = drive.current_controller_provenance(self.tag)
        self.assertEqual(provenance['controllerInputsCount'], 1)
        with patch.object(drive, 'case_path', return_value=self.case), \
             patch.object(drive, 'controller_packet', return_value=dict(packet, sourceSHA256={'changed': 'b' * 64})):
            with self.assertRaisesRegex(ValueError, 'controller or probe inputs changed'):
                drive.current_controller_provenance(self.tag)

    def test_controller_inventory_covers_host_imports_and_compiled_probe(self):
        paths = set(drive.execution_controller_inputs())
        self.assertTrue({'tools/verify_signed_drive_image.py', 'tools/verify_drive_lifecycle.py',
            'tools/dev.py', 'tools/development.py', 'tools/distribution/preflight.py',
            'tools/distribution/signed_local_qa.py', 'tools/DrivePreparationProbe.swift',
            'Packages/ExplorerKit/Sources/LocalStorage/VolumeInspection.swift'} <= paths)

    def exercise_phase_permit(self, mode, packet, permit_packet, contract, scope_fields):
        fixture = self.case.parent / ('drive-lifecycle-' + self.tag)
        fixture.mkdir(mode=0o700)
        qa.put(fixture / 'owner.json', {'jobID': self.tag, 'bytes': drive.IMAGE_BYTES})
        app_hash = 'b' * 64
        provenance = dict(buildInputsSHA256='c' * 64, buildResultSHA256='d' * 64,
            controllerInputsSHA256='e' * 64, controllerInputsCount=100)
        scope = dict(packet=packet, case=self.tag,
            bundleIdentifier=self.identifier, caseRoot=str(self.case), fixtureRoot=str(fixture),
            artifactTreeSHA256=app_hash, **provenance,
            expiresUTC=(datetime.now(timezone.utc) + timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'),
            phaseLaunchCeiling=dict(drive.PHASE_CEILING), formatCompletionContract=contract, **scope_fields,
            imageBytes=drive.IMAGE_BYTES, normalAttachMaximum=1, normalDetachMaximum=1,
            forceDetachMaximum=0, apfsAddMaximum=1, apfsFormatMaximum=1,
            driveMutationMaximum=2, physicalDriveMaximum=0,
            archiveJobsMaximum=0, networkSessionsMaximum=0, trashJobsMaximum=0)
        qa.put(self.case / 'evidence/runtime-scope.json', scope)
        with patch.object(drive, 'case_path', return_value=self.case), \
             patch.object(drive, 'fixture_path', return_value=fixture):
            self.assertTrue(drive.valid_scope(self.tag, scope, app_hash, provenance, mode))
            other_mode = drive.CaseMode.APP_MODEL if mode is drive.CaseMode.GENERATED else drive.CaseMode.GENERATED
            self.assertFalse(drive.valid_scope(self.tag, scope, app_hash, provenance, other_mode))
            self.assertFalse(drive.valid_scope(self.tag,
                dict(scope, packet='drive-image-runtime-scope-v2'), app_hash, provenance, mode))
            self.assertFalse(drive.valid_scope(self.tag, scope, app_hash,
                dict(provenance, controllerInputsSHA256='f' * 64), mode))
            for count in (0, 513):
                self.assertFalse(drive.valid_scope(self.tag,
                    dict(scope, controllerInputsCount=count), app_hash,
                    dict(provenance, controllerInputsCount=count), mode))
            self.assertTrue(drive.valid_scope(self.tag,
                dict(scope, controllerInputsCount=512), app_hash,
                dict(provenance, controllerInputsCount=512), mode))
            self.assertFalse(drive.valid_scope(self.tag, dict(scope,
                phaseLaunchCeiling={'pre-image': True, 'warm': 1, 'cold': 1}), app_hash, provenance, mode))
        with patch.object(drive, 'case_path', return_value=self.case), \
             patch.object(drive, 'fixture_path', return_value=fixture), \
             patch.object(drive, 'admitted_case', return_value=(self.case, scope_fields)), \
             patch.object(drive, 'inspect', return_value={'app': {'treeSHA256': app_hash}}), \
             patch.object(drive, 'sealed_build_provenance', return_value={
                 key: provenance[key] for key in ('buildInputsSHA256', 'buildResultSHA256')}), \
             patch.object(drive, 'current_controller_provenance', return_value={
                 key: provenance[key] for key in ('controllerInputsSHA256', 'controllerInputsCount')}):
            issued = drive.issue_phase(self.tag, 'pre-image')
        permit = json.loads((qa.REPO / issued['permit']).read_bytes())
        self.assertEqual(permit['packet'], permit_packet)
        self.assertEqual(permit['scopeSHA256'],
            hashlib.sha256((self.case / 'evidence/runtime-scope.json').read_bytes()).hexdigest())
        self.assertEqual({key: permit[key] for key in ('buildInputsSHA256', 'buildResultSHA256',
                         'controllerInputsSHA256')}, {key: provenance[key] for key in (
                         'buildInputsSHA256', 'buildResultSHA256', 'controllerInputsSHA256')})

    def test_v3_phase_permit_binds_all_frozen_receipts_before_launch(self):
        self.exercise_phase_permit(drive.CaseMode.GENERATED, 'drive-image-runtime-scope-v3',
            'drive-image-phase-permit-v3', 'observed-native-v2', {})

    def test_v4_phase_permit_requires_app_model_scope_and_preserves_budgets(self):
        self.exercise_phase_permit(drive.CaseMode.APP_MODEL, 'drive-image-runtime-scope-v4',
            'drive-image-phase-permit-v4', 'observed-native-v3', {'caseMode': 'ordinary-format-v3'})


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
    def run_receiver(self, *, six_routes=False, wrong_route=False, extra_output=False, finder_metadata=False,
                     recovery_fault=None):
        temporary = tempfile.TemporaryDirectory(prefix='finder-receiver-', dir=qa.REPO / '.build/tmp')
        self.addCleanup(temporary.cleanup)
        case = Path(temporary.name)
        (case / 'source').mkdir()
        (case / 'evidence').mkdir()
        parents = [case / 'source' / name for name in ('TAR', 'GZIP', 'BZIP2')][:3 if six_routes else 1]
        for parent in parents:
            parent.mkdir()
        journal = case / "source/operation-recovery/journal.sqlite"
        if six_routes:
            journal.parent.mkdir(mode=0o700)
            with sqlite3.connect(journal) as connection:
                connection.execute("CREATE TABLE jobs(id TEXT,state TEXT,head BLOB,checksum TEXT)")
                connection.execute("CREATE TABLE areas(job TEXT,ordinal INTEGER,payload BLOB,checksum TEXT)")
                connection.execute("CREATE TABLE steps(job TEXT,ordinal INTEGER,payload BLOB,checksum TEXT)")
            journal.chmod(0o600)
        routes = tuple((f'{index}/{kind}', kind, parent) for index, parent in enumerate(parents) for kind in ('file', 'folder'))
        output = (case / 'evidence/log').open('wb')
        self.addCleanup(output.close)
        owner = self
        records = {}
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
                    ident = str(uuid.uuid4()).upper()
                    values["recordID"] = ident
                    records[ident] = (17 if kind == "file" else 16,
                        parent / ("Generated Promise.txt" if kind == "file" else "Generated Folder"))
                    area = parent / (".mac-explorer-recovery-" + str(uuid.uuid4()).upper())
                    area.mkdir(mode=0o700)
                    marker = area / ".mac-explorer-recovery-v1"
                    marker.write_bytes(("MacExplorer recovery v1\n" + (str(uuid.uuid4()).upper() if recovery_fault == "marker" else ident)
                        + "\nRetained until explicit cleanup.\n").encode())
                    marker.chmod(0o600)
                    if recovery_fault == "symlink":
                        alternate = case / "source/marker-target"
                        marker.rename(alternate)
                        marker.symlink_to(alternate)
                    if recovery_fault == "mode":
                        area.chmod(0o755)
                    if recovery_fault == "payload":
                        (area / "payload").write_bytes(b"Not yet undone")
                    if recovery_fault == "journal-mode":
                        journal.chmod(0o644)
                    facts = area.lstat()
                    head = json.dumps(dict(id=ident, state="preparing" if recovery_fault == "state" else "committed",
                        operation="Extract TAR", version=17 if kind == "file" else 16)).encode()
                    payload = json.dumps(dict(url=area.as_uri()+"/",
                        identity=dict(device=facts.st_dev,inode=facts.st_ino + (1 if recovery_fault == "inode" else 0),mode=facts.st_mode))).encode()
                    step = json.dumps(dict(source=(area/"payload").as_uri(),
                        destination=(parent/("Unexpected.txt" if recovery_fault == "step" else "Generated Promise.txt" if kind=="file" else "Generated Folder")).as_uri(),
                        undone=False)).encode()
                    with sqlite3.connect(journal) as connection:
                        connection.execute("INSERT INTO jobs VALUES(?,?,?,?)",
                            (ident,"preparing" if recovery_fault == "state" else "committed",head,hashlib.sha256(head).hexdigest()))
                        connection.execute("INSERT INTO areas VALUES(?,?,?,?)",
                            (ident,0,payload,"0"*64 if recovery_fault == "checksum" else hashlib.sha256(payload).hexdigest()))
                        connection.execute("INSERT INTO steps VALUES(?,?,?,?)",
                            (ident,0,step,hashlib.sha256(step).hexdigest()))
                    if recovery_fault == "forged":
                        (parent / (".mac-explorer-recovery-" + str(uuid.uuid4()).upper())).mkdir(mode=0o700)
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
                destination=parents[0], archive_routes=routes if six_routes else None,
                archive_journal=journal if six_routes else None, signal_on_uncertainty=False)
        self.assertEqual(result.returncode, 0)
        receipt = json.loads((case / 'evidence/finder-receiver.json').read_bytes())
        self.assertTrue(receipt['passed'])
        self.assertEqual(receipt['controlMessages'], len(routes))
        return case, journal, parents, records

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

    def test_recovery_marker_for_another_record_is_not_acknowledged(self):
        with self.assertRaisesRegex(RuntimeError, "marker differs"):
            self.run_receiver(six_routes=True, recovery_fault="marker")

    def test_recovery_checksum_must_match(self):
        with self.assertRaisesRegex(RuntimeError, "area checksum"):
            self.run_receiver(six_routes=True, recovery_fault="checksum")

    def test_uncommitted_recovery_is_not_acknowledged(self):
        with self.assertRaisesRegex(RuntimeError, "record contract"):
            self.run_receiver(six_routes=True, recovery_fault="state")

    def test_unknown_recovery_prefix_is_not_ignored(self):
        with self.assertRaisesRegex(RuntimeError, "extra output"):
            self.run_receiver(six_routes=True, recovery_fault="forged")


    def test_recovery_area_must_stay_private_and_keep_its_identity(self):
        for fault in ("mode", "inode"):
            with self.subTest(fault=fault), self.assertRaisesRegex(RuntimeError, "area identity"):
                self.run_receiver(six_routes=True, recovery_fault=fault)

    def test_recovery_marker_cannot_be_redirected(self):
        with self.assertRaisesRegex(RuntimeError, "Redirected"):
            self.run_receiver(six_routes=True, recovery_fault="symlink")

    def test_warm_area_cannot_already_contain_payload(self):
        with self.assertRaisesRegex(RuntimeError, "area contents"):
            self.run_receiver(six_routes=True, recovery_fault="payload")

    def test_step_must_name_the_exact_delivered_destination(self):
        with self.assertRaisesRegex(RuntimeError, "step path"):
            self.run_receiver(six_routes=True, recovery_fault="step")

    def test_cold_namespace_keeps_exact_recorded_payload_areas(self):
        case, journal, parents, records = self.run_receiver(six_routes=True)
        areas = native_checks._finder_recovery_areas(journal, records, set(parents))
        for area, witness in areas.items():
            records[witness.record_id][1].rename(area / "payload")
        with sqlite3.connect(journal) as connection:
            for ident, payload in connection.execute("SELECT id,head FROM jobs").fetchall():
                head = json.loads(payload); head["state"] = "undone"
                encoded = json.dumps(head).encode()
                connection.execute("UPDATE jobs SET state=?,head=?,checksum=? WHERE id=?",
                    ("undone", encoded, hashlib.sha256(encoded).hexdigest(), ident))
            for ident, payload in connection.execute("SELECT job,payload FROM steps").fetchall():
                step = json.loads(payload); step["undone"] = True
                encoded = json.dumps(step).encode()
                connection.execute("UPDATE steps SET payload=?,checksum=? WHERE job=?",
                    (encoded, hashlib.sha256(encoded).hexdigest(), ident))
        cold = native_checks._finder_recovery_areas(journal, records, set(parents), state="undone")
        self.assertEqual(cold, areas)
        for parent in parents:
            self.assertEqual(native_checks._finder_payload_names(parent, recovery_areas=cold), set())
        area = next(iter(cold))
        (area / "unexpected").write_bytes(b"Not part of the recorded payload")
        with self.assertRaisesRegex(RuntimeError, "area contents"):
            native_checks._finder_recovery_areas(journal, records, set(parents), state="undone")

    def test_known_area_cannot_disappear_or_be_replaced_after_journal_read(self):
        case, journal, parents, records = self.run_receiver(six_routes=True)
        areas = native_checks._finder_recovery_areas(journal, records, set(parents))
        area = next(iter(areas))
        moved = case / "source/Retained area"
        area.rename(moved)
        with self.assertRaisesRegex(RuntimeError, "area is missing"):
            native_checks._finder_payload_names(area.parent, recovery_areas=areas)
        area.mkdir(mode=0o700)
        (area / ".mac-explorer-recovery-v1").write_bytes((moved / ".mac-explorer-recovery-v1").read_bytes())
        with self.assertRaisesRegex(RuntimeError, "changed before namespace"):
            native_checks._finder_payload_names(area.parent, recovery_areas=areas)

    def test_journal_must_remain_private(self):
        with self.assertRaisesRegex(RuntimeError, "not private"):
            self.run_receiver(six_routes=True, recovery_fault="journal-mode")


if __name__ == '__main__':
    unittest.main()
