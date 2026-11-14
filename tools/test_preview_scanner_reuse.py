#!/usr/bin/env python3
"""Source-only scanner donation controls; no native build or signing service."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
import dev
import preview


class PreviewScannerReuseTests(unittest.TestCase):
    def setUp(self):
        parent = preview.d.REPO / '.build/test-fixtures'
        parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='preview-scanner-', dir=parent)
        self.root = Path(self.temporary.name)
        self.addCleanup(self.finish_fixture)
        self.signer = '3FAFAC05E68A576A7D23B1DF71A939955375ECAD'
        self.team = 'CDLNJRG82U'
        self.profile = '1C04223A-4025-4F1C-ABFE-001CBA2928BA'
        self.proof = dict(input=dict(schema=4, sources={'main.rs': 'source-sha'}), binary_sha256='unsigned-sha')
        self.donor = self.root / 'Installed.app'
        self.helper = self.donor / 'Contents/Helpers/storage-scanner-worker'
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b'previous signed scanner bytes')
        (self.donor / 'Contents/Resources').mkdir()
        (self.donor / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier=preview.IDENTIFIER, MacExplorerDistributionChannel=preview.CHANNEL,
            MacExplorerReviewCase=self.profile, MacExplorerScannerProvenance=preview.SCANNER_FORMAT,
            CFBundleShortVersionString='0.1.4', CFBundleVersion='63')))
        def signed_parent(argv):
            display = b'Identifier=local.macexplorer.preview\nTeamIdentifier=CDLNJRG82U\nAuthority=Apple Development: Mock\n'
            return subprocess.CompletedProcess(argv, 0, b'', display if '-d' in argv else b'')
        self.command_patch = mock.patch.object(preview, 'command', side_effect=signed_parent)
        self.command_patch.start(); self.addCleanup(self.command_patch.stop)
        actual_digest = preview.d.digest
        self.digest_calls = []
        def digest(path):
            self.digest_calls.append(str(path))
            return 'codesign-tool-sha' if str(path) == '/usr/bin/codesign' else actual_digest(path)
        self.digest_patch = mock.patch.object(preview.d, 'digest', side_effect=digest)
        self.digest_patch.start(); self.addCleanup(self.digest_patch.stop)
        self.signature_patch = mock.patch.object(preview.scanner, 'signed_facts', return_value={})
        self.signature_patch.start(); self.addCleanup(self.signature_patch.stop)
        self.signing = preview.scanner_signing_input(self.signer, self.team)

    def finish_fixture(self):
        result = self._outcome.result
        failures = list(result.failures) + list(result.errors)
        failures += [(case, error) for case, error in getattr(self._outcome, 'errors', []) if error is not None]
        failed = any(case is self or getattr(case, 'test_case', None) is self for case, _ in failures)
        if failed:
            self.temporary._finalizer.detach()
            print('Retained failed owned fixture: ' + str(self.root), file=sys.stderr)
        else:
            self.temporary.cleanup()

    def write_manifest(self, **changes):
        value = dict(format='preview-scanner-v1', profileCase=self.profile, version='0.1.4', build='63',
                     inputSHA256=preview.scanner_input_digest(self.proof), binarySHA256=self.proof['binary_sha256'],
                     signing=self.signing, helperSHA256=hashlib.sha256(self.helper.read_bytes()).hexdigest())
        value.update(changes)
        (self.donor / 'Contents/Resources' / preview.SCANNER_PROVENANCE).write_text(json.dumps(value))

    def target(self):
        app = self.root / 'New.app'
        helper = app / 'Contents/Helpers/storage-scanner-worker'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b'ordinary product scanner')
        (app / 'Contents/Resources').mkdir()
        return app, helper

    def test_first_adoption_signs_and_seals_provenance(self):
        app, helper = self.target()
        with mock.patch.object(preview, 'command', return_value=subprocess.CompletedProcess([], 0)) as sign:
            self.assertFalse(preview.seal_scanner(app, self.signer, self.team, self.proof, None,
                                                   self.profile, '0.1.4', '64'))
        self.assertEqual(sign.call_count, 1)
        self.assertEqual(sign.call_args.args[0][0:2], ['/usr/bin/codesign', '--force'])
        record = json.loads((app / 'Contents/Resources' / preview.SCANNER_PROVENANCE).read_bytes())
        self.assertEqual(record['helperSHA256'], hashlib.sha256(helper.read_bytes()).hexdigest())
        self.assertEqual(record['binarySHA256'], self.proof['binary_sha256'])

    def test_matching_donor_preserves_exact_signed_bytes(self):
        self.write_manifest()
        selected = preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)
        self.assertEqual(selected, (self.helper, hashlib.sha256(self.helper.read_bytes()).hexdigest()))
        app, helper = self.target()
        with mock.patch.object(preview, 'command', side_effect=AssertionError('must not re-sign donor')):
            self.assertTrue(preview.seal_scanner(app, self.signer, self.team, self.proof, selected,
                                                  self.profile, '0.1.4', '64'))
        self.assertEqual(helper.read_bytes(), self.helper.read_bytes())

    def test_changed_inputs_refuse_donation_and_tampering_stops(self):
        self.write_manifest()
        changed = dict(self.proof, binary_sha256='changed')
        self.assertIsNone(preview.scanner_donor(self.donor, changed, self.profile, self.signing))
        changed_signer = dict(self.signing, identity='0' * 40)
        self.assertIsNone(preview.scanner_donor(self.donor, self.proof, self.profile, changed_signer))
        self.helper.write_bytes(b'tampered scanner')
        with self.assertRaisesRegex(RuntimeError, 'changed after provenance'):
            preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)

    def test_donor_checks_parent_seal_and_exact_info_each_time(self):
        self.write_manifest()
        with mock.patch.object(preview, 'command', side_effect=subprocess.CalledProcessError(1, 'codesign')):
            with self.assertRaises(subprocess.CalledProcessError):
                preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)
        with mock.patch.object(preview, 'command', return_value=subprocess.CompletedProcess(
                [], 0, b'', b'Identifier=local.macexplorer.preview\nTeamIdentifier=not set\nSignature=adhoc\n')):
            with self.assertRaisesRegex(RuntimeError, 'parent signing identity'):
                preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)
        info_path = self.donor / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['MacExplorerDistributionChannel'] = 'other'
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, 'exact Preview profile'):
            preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)
        info['MacExplorerDistributionChannel'] = preview.CHANNEL
        info['MacExplorerScannerProvenance'] = 'other'
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, 'marker changed'):
            preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)

    def test_missing_donor_receipt_fresh_sign_path_requires_no_marker(self):
        info_path = self.donor / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        del info[preview.SCANNER_INFO_KEY]
        info_path.write_bytes(plistlib.dumps(info))
        self.assertIsNone(preview.scanner_donor(self.donor, self.proof, self.profile, self.signing))
        info[preview.SCANNER_INFO_KEY] = preview.SCANNER_FORMAT
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, 'marker has no provenance'):
            preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)

    def test_redirected_donor_refused_before_file_body_read(self):
        self.write_manifest()
        private = self.root / 'private-data'; private.write_bytes(b'never read this')
        self.helper.unlink(); self.helper.symlink_to(private)
        with self.assertRaisesRegex(ValueError, 'redirected'):
            preview.scanner_donor(self.donor, self.proof, self.profile, self.signing)
        self.assertNotIn(str(private), self.digest_calls)

    def test_native_package_requires_current_scanner_provenance_before_allocation(self):
        with mock.patch.object(preview, 'checked_case', return_value=self.root), \
                mock.patch.object(preview, 'inventory', return_value={}), \
                mock.patch.object(preview.d, 'native_sources', return_value={}), \
                mock.patch.object(preview.scanner, 'embedded_provenance', return_value=None), \
                mock.patch.object(dev, 'BUILD', self.root), \
                mock.patch.object(dev, 'local_directory', side_effect=AssertionError('artifact allocated')) as allocate, \
                mock.patch.object(preview, 'seal_bundle', side_effect=AssertionError('signed')) as sign:
            with self.assertRaisesRegex(RuntimeError, 'Current scanner provenance required'):
                preview.package_native('Release', '0.1.4', '64', self.profile, repository_profile=True)
        allocate.assert_not_called()
        sign.assert_not_called()


if __name__ == '__main__': unittest.main(verbosity=2, failfast=True)
