"""Candidate admission/reopen/artifact controls, entirely in memory."""
import unittest
from distribution import release_candidate as c


class ReleaseCandidateTests(unittest.TestCase):
    def test_public_mode_is_a_fresh_scoped_local_candidate_and_cannot_publish(self):
        request = dict(channel='developer-id', version='0.1.5', build='87', local=True, public_updater=True)
        public = c.configuration(**request)
        self.assertTrue(public['publicUpdater'])
        self.assertEqual(c.configuration(public), public)
        for action in ['prepare', 'archive', 'export']: c.admit_action(public, action)
        for action in ['notarize', 'upload']:
            with self.subTest(action=action), self.assertRaises(ValueError): c.admit_action(public, action)
        for change in [dict(private_updater=True), dict(channel='app-store'),
                       dict(local=False), dict(local=False, shipping=True)]:
            with self.subTest(change=change), self.assertRaises(ValueError): c.configuration(**dict(request, **change))
        with self.assertRaises(ValueError): c.configuration(dict(channel='developer-id'), public_updater=True)
        with self.assertRaises(ValueError): c.configuration(dict(public, publicUpdater='yes'))

    def test_local_user_public_is_a_separate_qualification_and_not_shipping_authority(self):
        request=dict(channel='developer-id',policy='local-user-v1',version='0.1.5',build='89',
            local=True,public_updater=True)
        direct=c.configuration(**request)
        self.assertTrue(direct['qualificationOnly'])
        self.assertTrue(direct['publicUpdater'])
        self.assertEqual(c.configuration(direct),direct)
        for action in ('prepare','archive','export'):c.admit_action(direct,action)
        for action in ('notarize','upload'):
            with self.assertRaises(ValueError):c.admit_action(direct,action)
        for change in (dict(private_updater=True),dict(channel='app-store')):
            with self.assertRaises(ValueError):c.configuration(**dict(request,**change))

    def test_fresh_direct_shipping_has_a_distinct_immutable_purpose(self):
        shipping=c.configuration(channel='developer-id',policy='local-user-v1',
            version='0.1.5',build='90',shipping=True,public_updater=True)
        self.assertEqual(shipping['releasePurpose'],c.DIRECT_SHIPPING_PURPOSE)
        self.assertFalse(shipping['qualificationOnly'])
        self.assertNotIn('localReviewOnly',shipping)
        self.assertEqual(c.configuration(shipping),shipping)
        for action in ('prepare','archive','export','notarize'):
            c.admit_action(shipping,action)
        for action in ('upload','anything-else'):
            with self.assertRaises(ValueError):c.admit_action(shipping,action)
        info=dict(CFBundleShortVersionString='0.1.5',CFBundleVersion='90',
            CFBundleIdentifier='com.respawnstudios.traverse',
            MacExplorerDistributionChannel='developer-id',MacExplorerAccessPolicy='local-user-v1',
            MacExplorerReleasePurpose=c.DIRECT_SHIPPING_PURPOSE)
        self.assertEqual(c.shipping_metadata(shipping,info),('0.1.5','90'))
        for changed in (dict(info,MacExplorerReleasePurpose='review'),
                        {key:value for key,value in info.items() if key!=c.RELEASE_PURPOSE_KEY},
                        dict(info,MacExplorerAccessPolicy='sandbox-selected-v1')):
            with self.assertRaises(ValueError):c.shipping_metadata(shipping,changed)
        for changed in (dict(shipping,releasePurpose='review'),
                        {key:value for key,value in shipping.items() if key!='releasePurpose'},
                        dict(shipping,qualificationOnly=True),
                        dict(shipping,localReviewOnly=True)):
            with self.assertRaises(ValueError):c.configuration(changed)
        old=c.configuration(channel='developer-id',policy='local-user-v1',
            version='0.1.5',build='89',local=True,public_updater=True)
        with self.assertRaises(ValueError):c.configuration(old,shipping=True)
        with self.assertRaises(ValueError):c.shipping_metadata(old,info)

    def test_private_updates_are_direct_only_and_cannot_be_promoted_into_old_cases(self):
        saved=c.configuration(channel='developer-id',private_updater=True,local=True,version='0.1.3',build='9')
        self.assertTrue(saved['privateUpdater'])
        self.assertEqual(c.configuration(saved),saved)
        for changes in [dict(channel='app-store',private_updater=True),
            dict(channel='developer-id',policy='local-user-v1',private_updater=True)]:
            with self.assertRaises(ValueError):c.configuration(**changes)
        with self.assertRaises(ValueError):c.configuration(dict(channel='developer-id'),private_updater=True)
        with self.assertRaises(ValueError):c.configuration(dict(channel='app-store',privateUpdater=True))
        with self.assertRaises(ValueError):c.configuration(dict(channel='developer-id',privateUpdater=1))
    def test_old_cases_keep_their_channel_and_no_command_line_version(self):
        for saved in [dict(channel='app-store'), dict(channel='developer-id',accessPolicy='sandbox-selected-v1')]:
            self.assertEqual(c.configuration(saved), saved)
            self.assertEqual(c.settings(None), [])

    def test_numeric_inputs_are_complete_ascii_unambiguous_and_bounded(self):
        self.assertEqual(c.version_override('0.1.3','4'),dict(version='0.1.3',build='4'))
        for version,build in [('0.1.3',None),(None,'4'),('0.1','4'),('0.1.3.4','4'),('00.1.3','4'),('0.1.3','04'),
                              ('0.1.3','0'),('0.1.3','-4'),('0.1.3','2147483648'),('0.1.3','4\n'),('0.1.3\n','4'),
                              ('0.1.3','４'),('0.1.$(touch x)','4'),('0.1.3;bad','4'),('0.1.3',4),(3,'4')]:
            with self.subTest(version=version,build=build),self.assertRaises(ValueError):c.version_override(version,build)

    def test_overrides_require_explicit_local_and_cannot_be_lost_on_reopen(self):
        with self.assertRaises(ValueError):c.configuration(version='0.1.3',build='4')
        with self.assertRaises(ValueError):c.configuration(local=True)
        saved=c.configuration(channel='developer-id',version='0.1.3',build='4',local=True)
        self.assertEqual(c.configuration(saved),saved)
        self.assertEqual(c.configuration(saved,version='0.1.3',build='4',local=True),saved)
        self.assertEqual(c.settings(saved['versionOverride']),['MARKETING_VERSION=0.1.3','CURRENT_PROJECT_VERSION=4'])
        for changes in [dict(channel='app-store'),dict(policy='local-user-v1'),dict(version='0.1.4',build='4'),dict(version='0.1.3',build='5')]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):c.configuration(saved,**changes)

    def test_old_case_cannot_be_reinterpreted_as_a_candidate(self):
        old=dict(channel='developer-id',accessPolicy='sandbox-selected-v1')
        for changes in [dict(local=True),dict(local=True,version='0.1.3',build='4'),dict(version='0.1.3',build='4')]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):c.configuration(old,**changes)

    def test_local_candidate_refuses_external_actions_before_the_runner(self):
        saved=c.configuration(channel='developer-id',version='0.1.3',build='4',local=True)
        for action in ['prepare','archive','export']:c.admit_action(saved,action)
        for action in ['upload','notarize','anything-else']:
            with self.subTest(action=action),self.assertRaises(ValueError):c.admit_action(saved,action)
        for action in ['upload','notarize']:c.admit_action(dict(channel='app-store'),action)

    def test_shipping_is_fresh_explicit_versioned_and_sandboxed(self):
        shipping=c.configuration(channel='developer-id',version='0.1.3',build='6',shipping=True)
        self.assertEqual(c.configuration(shipping),shipping)
        self.assertEqual(c.configuration(shipping,shipping=True,version='0.1.3',build='6'),shipping)
        self.assertNotIn('localReviewOnly',shipping)
        for action in ['prepare','archive','export','notarize']:c.admit_action(shipping,action)
        for changes in [dict(local=True),dict(version='0.1.4',build='6'),dict(channel='app-store')]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):c.configuration(shipping,**changes)
        for kwargs in [dict(shipping=True),dict(shipping=True,local=True,version='0.1.3',build='6'),
                       dict(shipping=True,policy='local-user-v1',channel='developer-id',version='0.1.3',build='6')]:
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):c.configuration(**kwargs)

    def test_local_and_legacy_cases_cannot_gain_shipping_authority_on_reopen(self):
        local=c.configuration(channel='developer-id',version='0.1.3',build='5',local=True)
        for saved in [local,dict(channel='developer-id'),dict(channel='app-store')]:
            with self.subTest(saved=saved),self.assertRaises(ValueError):c.configuration(saved,shipping=True)
        with self.assertRaises(ValueError):c.configuration(dict(local,shippingCandidate=True))
        c.admit_action(local,'export')
        with self.assertRaises(ValueError):c.admit_action(local,'notarize')

    def test_packaging_requires_actual_shipping_artifact_metadata(self):
        saved=c.configuration(channel='developer-id',version='0.1.3',build='6',shipping=True)
        info=dict(CFBundleShortVersionString='0.1.3',CFBundleVersion='6',CFBundleIdentifier='com.respawnstudios.traverse',
                  MacExplorerAccessPolicy='sandbox-selected-v1',MacExplorerDistributionChannel='developer-id')
        self.assertEqual(c.shipping_metadata(saved,info),('0.1.3','6'))
        for change in [dict(CFBundleVersion='5'),dict(CFBundleVersion=6),dict(CFBundleIdentifier='local.traverse.generated'),
                       dict(MacExplorerAccessPolicy='local-user-v1'),dict(MacExplorerDistributionChannel='app-store')]:
            with self.subTest(change=change),self.assertRaises(ValueError):c.shipping_metadata(saved,dict(info,**change))
        for old in [dict(channel='developer-id'),c.configuration(channel='developer-id',version='0.1.3',build='6',local=True)]:
            with self.subTest(old=old),self.assertRaises(ValueError):c.shipping_metadata(old,info)

    def test_tampered_incomplete_and_cross_policy_configurations_refuse(self):
        for config in [dict(channel='unknown'),dict(channel='app-store',accessPolicy='local-user-v1'),
                       dict(channel='developer-id',versionOverride={'version':'0.1.3','build':'4'}),
                       dict(channel='developer-id',localReviewOnly=True),
                       dict(channel='developer-id',localReviewOnly=True,versionOverride={'version':'0.1.3','build':'4','extra':1}),
                       dict(channel='developer-id',accessPolicy='unknown')]:
            with self.subTest(config=config),self.assertRaises(ValueError):c.configuration(config)

    def test_observed_bundle_cannot_inherit_a_requested_version_by_assumption(self):
        wanted=c.version_override('0.1.3','4')
        c.verify_observed(dict(CFBundleShortVersionString='0.1.3',CFBundleVersion='4'),wanted)
        for info in [{},dict(CFBundleShortVersionString='0.1.2',CFBundleVersion='4'),
                     dict(CFBundleShortVersionString='0.1.3',CFBundleVersion='3'),
                     dict(CFBundleShortVersionString='0.1.3',CFBundleVersion=4)]:
            with self.subTest(info=info),self.assertRaises(ValueError):c.verify_observed(info,wanted)


if __name__=='__main__':unittest.main()
