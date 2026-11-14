"""No account, signing or filesystem grants: exact composition controls."""
import unittest
from unittest import mock
from pathlib import Path
import store_helpers as helpers
import remote_editor_qa as qa


class AccessPolicyTests(unittest.TestCase):
    def test_only_explicit_matching_tags_and_sandbox_settings_are_admitted(self):
        for tag in ['app-store-v1', 'developer-id-v1', 'developer-id-local-user-qualification-v1']:
            wanted = helpers.LOCAL if 'qualification' in tag else helpers.SCOPED
            env = dict(MAC_EXPLORER_TRAVERSE_BUILD=tag, MAC_EXPLORER_ACCESS_POLICY=wanted,
                ENABLE_APP_SANDBOX='NO' if wanted == helpers.LOCAL else 'YES')
            self.assertEqual(helpers.access_policy(env), wanted)
            for key, value in [('MAC_EXPLORER_ACCESS_POLICY',None), ('MAC_EXPLORER_ACCESS_POLICY','unknown'),
                ('MAC_EXPLORER_TRAVERSE_BUILD','development'), ('ENABLE_APP_SANDBOX','MAYBE'),
                ('MAC_EXPLORER_ACCESS_POLICY', helpers.SCOPED if wanted == helpers.LOCAL else helpers.LOCAL)]:
                with self.subTest(tag=tag,key=key):
                    with self.assertRaises(RuntimeError): helpers.access_policy({**env,key:value})

    def test_direct_helpers_have_no_inherit_or_sandbox_exception_rights(self):
        self.assertEqual(helpers.helper_rights(helpers.LOCAL), {})
        self.assertEqual(helpers.helper_rights(helpers.SCOPED), {'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True})
        with self.assertRaises(RuntimeError): helpers.helper_rights('developer-id')

    def test_case_bound_qa_signer_has_no_ad_hoc_fallback(self):
        baseline = dict(packet=qa.PACKET, case='A', bundleIdentifier='B', buildAndInspectOnly=True,
            priorOSContainerAbsent=True, generatedOperationRoot='C')
        reservation = dict(packet='traverse-development-v1', action=qa.ACTION)
        with mock.patch.object(qa, '_owned_json', side_effect=[reservation, baseline]):
            self.assertEqual(qa.signer(Path('/unused')), ('-', 'adhoc'))
        signed = dict(baseline, packet=qa.DEVELOPER_ID_PACKET,
            signingIdentity='A' * 40, teamIdentifier=qa.DEVELOPER_ID_TEAM)
        reservation['action'] = qa.DEVELOPER_ID_ACTION
        with mock.patch.object(qa, '_owned_json', side_effect=[reservation, signed]):
            self.assertEqual(qa.signer(Path('/unused')), ('A' * 40, qa.DEVELOPER_ID_TEAM))
        for change in [dict(teamIdentifier='AAAAAAAAAA'), dict(signingIdentity='-'),
                       dict(extraRight=True)]:
            with self.subTest(change=change), mock.patch.object(qa, '_owned_json',
                    side_effect=[reservation, {**signed, **change}]):
                with self.assertRaises(ValueError): qa.signer(Path('/unused'))

    def test_developer_id_selection_requires_one_exact_team_certificate(self):
        valid = '  1) ' + 'A' * 40 + ' "Developer ID Application: Example (CDLNJRG82U)"\n'
        result = mock.Mock(stdout=valid)
        with mock.patch.object(qa.subprocess, 'run', return_value=result):
            self.assertEqual(qa.available_developer_id_identity(), 'A' * 40)
        for output in ['', valid + valid,
                       valid.replace('Developer ID Application:', 'Apple Development:'),
                       valid.replace('CDLNJRG82U', 'AAAAAAAAAA')]:
            with self.subTest(output=output), mock.patch.object(qa.subprocess, 'run',
                    return_value=mock.Mock(stdout=output)):
                with self.assertRaises(ValueError): qa.available_developer_id_identity()


if __name__ == '__main__': unittest.main()
