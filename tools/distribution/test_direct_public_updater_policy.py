"""Pure local-user updater admission checks; no package, signing or account action."""
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
import plistlib
import json
from unittest import mock

from distribution import (direct_dmg, helper_symbols, notarize_direct_app, preflight,
                          release_candidate, sparkle, store_helpers, traverse)
from generate_project import generate


class DirectPublicUpdaterPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.info=sparkle.metadata(public=True,local_user=True)

    def test_intel_case_rejects_an_arm_app_before_notary_or_dmg_admission(self):
        root=Path(__file__).resolve().parents[2]/'.build/traverse-release'
        root.mkdir(parents=True,exist_ok=True)
        with TemporaryDirectory(dir=root) as temporary:
            case=Path(temporary)
            config=release_candidate.configuration(channel='developer-id',policy='local-user-v1',
                version='0.2.0',build='95',shipping=True,public_updater=True,architecture='x86_64')
            (case/'configuration.json').write_text(json.dumps(config))
            app=case/'export/Traverse.app';(app/'Contents').mkdir(parents=True)
            info=dict(sparkle.metadata(public=True,local_user=True,direct_shipping=True),
                CFBundleShortVersionString='0.2.0',CFBundleVersion='95',
                CFBundleIdentifier='com.respawnstudios.traverse',MacExplorerAccessPolicy='local-user-v1',
                MacExplorerDistributionChannel='developer-id')
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            with mock.patch.object(notarize_direct_app,'inspect') as inspect:
                with self.assertRaises(ValueError):notarize_direct_app.admit(case,app)
                inspect.assert_not_called()
            with self.assertRaises(ValueError):direct_dmg.qualified_metadata(case,info)
            intel=dict(info,**{key:value for key,value in sparkle.metadata(public=True,local_user=True,
                direct_shipping=True,architecture='x86_64').items() if key in ('SUFeedURL','TraverseDirectArchitecture')})
            self.assertEqual(direct_dmg.qualified_metadata(case,intel),('0.2.0','95'))

    def test_intel_metadata_binds_the_separate_feed_to_health_service_identity(self):
        info=dict(sparkle.metadata(public=True,local_user=True,direct_shipping=True,architecture='x86_64'),
            CFBundleIdentifier='com.respawnstudios.traverse',MacExplorerDistributionChannel='developer-id',
            MacExplorerAccessPolicy='local-user-v1',MacExplorerStorageMode='portable',TraverseDriveHealthServiceVersion=1)
        self.assertEqual(info['SUFeedURL'],'https://respawn-studios.com/products/traverse/direct-updates-intel/appcast.xml')
        self.assertTrue(helper_symbols.health_service_declared(info))
        for change in (dict(TraverseDirectArchitecture='arm64'),dict(SUFeedURL=self.info['SUFeedURL'])):
            with self.subTest(change=change),self.assertRaises(ValueError):helper_symbols.health_service_declared(dict(info,**change))

    def test_distinct_metadata_and_no_sandbox_installer_settings(self):
        info=self.info
        self.assertEqual(info['SUFeedURL'],
            'https://respawn-studios.com/products/traverse/direct-updates/appcast.xml')
        self.assertEqual(info['TraverseDirectPublicUpdaterVersion'],'2.10.0')
        self.assertEqual(info['TraverseDirectStorageNamespace'],'com.respawnstudios.traverse.direct')
        for key in ('TraversePublicUpdaterVersion','TraversePrivateUpdaterVersion',
                    'SUEnableInstallerLauncherService','SUEnableDownloaderService'):
            self.assertNotIn(key,info)
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertEqual(info['NSServices'][0]['NSRestricted'],True)
        self.assertNotIn(release_candidate.RELEASE_PURPOSE_KEY,info)

    def test_shipping_metadata_and_role_tag_are_distinct_from_qualification(self):
        shipping=sparkle.metadata(public=True,local_user=True,direct_shipping=True)
        self.assertEqual(shipping[release_candidate.RELEASE_PURPOSE_KEY],
                         release_candidate.DIRECT_SHIPPING_PURPOSE)
        self.assertEqual({key:value for key,value in shipping.items()
                          if key!=release_candidate.RELEASE_PURPOSE_KEY},self.info)
        for kwargs in (dict(direct_shipping=True),
                       dict(public=True,direct_shipping=True),
                       dict(local_user=True,direct_shipping=True)):
            with self.assertRaises(RuntimeError):sparkle.metadata(**kwargs)
        root=Path(__file__).resolve().parents[2]/'.build/traverse-release'
        root.mkdir(parents=True,exist_ok=True)
        with TemporaryDirectory(dir=root) as temporary:
            product=Path(temporary);app=product/'Traverse.app'
            contents=app/'Contents';contents.mkdir(parents=True)
            info_path=contents/'Info.plist'
            fields=dict(shipping,CFBundleIdentifier='com.respawnstudios.traverse',
                MacExplorerDistributionChannel='developer-id',
                MacExplorerAccessPolicy='local-user-v1')
            env=dict(PRODUCT_BUNDLE_IDENTIFIER='com.respawnstudios.traverse',
                MAC_EXPLORER_TRAVERSE_BUILD='developer-id-local-user-public-shipping-v1',
                MAC_EXPLORER_ACCESS_POLICY='local-user-v1',
                MAC_EXPLORER_DISTRIBUTION_CHANNEL='developer-id',ENABLE_APP_SANDBOX='NO',
                ENABLE_HARDENED_RUNTIME='YES',DEVELOPMENT_TEAM='CDLNJRG82U',
                EXPANDED_CODE_SIGN_IDENTITY='A'*40,TARGET_BUILD_DIR=str(product),
                CONTENTS_FOLDER_PATH='Traverse.app/Contents')
            info_path.write_bytes(plistlib.dumps(fields))
            self.assertEqual(store_helpers.configuration(app,env),'A'*40)
            for changed in (dict(fields,MacExplorerReleasePurpose='qualification'),
                            {key:value for key,value in fields.items()
                             if key!=release_candidate.RELEASE_PURPOSE_KEY}):
                info_path.write_bytes(plistlib.dumps(changed))
                with self.assertRaises(RuntimeError):store_helpers.configuration(app,env)
            info_path.write_bytes(plistlib.dumps(fields))
            with self.assertRaises(RuntimeError):store_helpers.configuration(app,
                dict(env,MAC_EXPLORER_TRAVERSE_BUILD=
                     'developer-id-local-user-public-qualification-v1'))

    def test_shipping_selects_its_project_config_and_generated_info_path(self):
        root=Path(__file__).resolve().parents[2]/'.build'
        root.mkdir(exist_ok=True)
        with TemporaryDirectory(dir=root) as temporary, \
                mock.patch.object(sparkle,'prepare') as prepared:
            project=Path(temporary)/'Traverse.xcodeproj'
            generate(destination=project,traverse=True,direct=True,
                direct_access_qualification=True,public_updater=True,direct_shipping=True)
            prepared.assert_called_once_with(public=True,local_user=True,direct_shipping=True,architecture='arm64')
            self.assertIn('Distribution/TraverseLocalUserPublicShipping.xcconfig',
                (project/'project.pbxproj').read_text())
            with mock.patch.object(traverse,'generate') as generated, \
                    mock.patch.object(traverse,'directory',side_effect=lambda path:path):
                command=traverse.project_arguments(Path(temporary),'developer-id',
                    'local-user-v1',dict(version='0.1.5',build='90'),
                    public_updater=True,direct_shipping=True)
            self.assertIn('CURRENT_PROJECT_VERSION=90',command)
            self.assertTrue(generated.call_args.kwargs['direct_shipping'])
            self.assertTrue(generated.call_args.kwargs['public_updater'])

    def test_notary_and_dmg_read_the_signed_shipping_purpose(self):
        root=Path(__file__).resolve().parents[2]/'.build/traverse-release'
        root.mkdir(parents=True,exist_ok=True)
        with TemporaryDirectory(dir=root) as temporary:
            case=Path(temporary)
            config=release_candidate.configuration(channel='developer-id',policy='local-user-v1',
                version='0.1.5',build='90',shipping=True,public_updater=True)
            (case/'configuration.json').write_text(json.dumps(config))
            app=case/'export/Traverse.app';(app/'Contents').mkdir(parents=True)
            info=dict(self.info,CFBundleShortVersionString='0.1.5',CFBundleVersion='90',
                CFBundleIdentifier='com.respawnstudios.traverse',
                MacExplorerAccessPolicy='local-user-v1',
                MacExplorerDistributionChannel='developer-id')
            for marked in (False,True):
                fields=dict(info)
                if marked:fields[release_candidate.RELEASE_PURPOSE_KEY]=release_candidate.DIRECT_SHIPPING_PURPOSE
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps(fields))
                with mock.patch.object(notarize_direct_app,'inspect',
                        return_value=dict(checks=[])) as inspected:
                    if marked:
                        self.assertEqual(notarize_direct_app.admit(case,app)[:2],('0.1.5','90'))
                        self.assertEqual(direct_dmg.qualified_metadata(case,fields),('0.1.5','90'))
                        inspected.assert_called_once()
                    else:
                        with self.assertRaises(ValueError):notarize_direct_app.admit(case,app)
                        with self.assertRaises(ValueError):direct_dmg.qualified_metadata(case,fields)
                        inspected.assert_not_called()

    def test_info_and_updater_checks_reject_cross_edition_metadata(self):
        info=dict(self.info,CFBundleIdentifier='com.respawnstudios.traverse',
            MacExplorerDistributionChannel='developer-id',MacExplorerAccessPolicy='local-user-v1',
            MacExplorerStorageMode='portable')
        def row(fields,name):
            return next(value['passed'] for value in preflight.info_checks(
                fields,'com.respawnstudios.traverse','developer-id') if value['id']==name)
        self.assertTrue(row(info,'release_purpose_boundary'))
        shipping=dict(info,MacExplorerReleasePurpose=release_candidate.DIRECT_SHIPPING_PURPOSE)
        self.assertTrue(row(shipping,'release_purpose_boundary'))
        for changed in (dict(shipping,MacExplorerReleasePurpose='other'),
                        dict(shipping,MacExplorerAccessPolicy='sandbox-selected-v1'),
                        dict(shipping,MacExplorerReviewCase='old'),
                        dict(shipping,TraverseDirectPublicUpdaterVersion=None)):
            self.assertFalse(row(changed,'release_purpose_boundary'))
        for name in ('updater_edition_boundary','folder_service_boundary','direct_storage_namespace',
                     'drive_health_edition_boundary'):
            self.assertTrue(row(info,name),name)
        for change in (dict(MacExplorerAccessPolicy='sandbox-selected-v1'),
                       dict(TraverseDirectPublicUpdaterVersion=''),
                       dict(TraversePublicUpdaterVersion=None),
                       dict(TraverseDirectStorageNamespace='com.respawnstudios.traverse'),
                       dict(TraverseDriveHealthHelperVersion=2),
                       dict(TraverseDriveHealthServiceVersion=2),
                       dict(TraverseDriveHealthServiceVersion=True)):
            self.assertFalse(row(dict(info,**change),'updater_edition_boundary'),change)
        composed=dict(info,TraverseDriveHealthServiceVersion=1)
        self.assertTrue(row(composed,'updater_edition_boundary'))
        self.assertTrue(row(composed,'drive_health_edition_boundary'))
        self.assertTrue(helper_symbols.health_service_declared(composed))
        for change in (dict(TraverseDriveHealthServiceVersion=True),
                       dict(TraverseDriveHealthHelperVersion=2),
                       dict(TraversePublicUpdaterVersion='2.10.0'),
                       dict(SUPublicEDKey='wrong'),
                       dict(SUEnableInstallerLauncherService=False),
                       dict(MacExplorerSandboxQualificationCase='unselected')):
            with self.subTest(change=change),self.assertRaises(ValueError):
                helper_symbols.health_service_declared(dict(composed,**change))
        root=Path(__file__).resolve().parents[2]/'.build'
        root.mkdir(exist_ok=True)
        with TemporaryDirectory(dir=root) as temporary:
            app=Path(temporary)/'Generated.app'
            def configuration(fields):
                return next(value['passed'] for value in preflight.updater_checks(
                    app,fields,'CDLNJRG82U','developer-id')
                    if value['id']=='updater_security_configuration')
            self.assertTrue(configuration(info))
            for change in (dict(SUFeedURL='https://respawn-studios.com/products/traverse/public-updates/appcast.xml'),
                           dict(SUEnableInstallerLauncherService=True),dict(SURequireSignedFeed=False)):
                self.assertFalse(configuration(dict(info,**change)),change)

    def test_local_user_rights_and_old_shipping_lanes_stay_closed(self):
        fields=dict(MAC_EXPLORER_TRAVERSE_BUILD='developer-id-local-user-public-qualification-v1',
            MAC_EXPLORER_ACCESS_POLICY='local-user-v1',ENABLE_APP_SANDBOX='NO')
        self.assertEqual(store_helpers.access_policy(fields),'local-user-v1')
        for changed in (dict(ENABLE_APP_SANDBOX='YES'),dict(MAC_EXPLORER_ACCESS_POLICY='sandbox-selected-v1')):
            with self.assertRaises(RuntimeError):store_helpers.access_policy(dict(fields,**changed))
        def rights(parent):
            return all(row['passed'] for row in preflight.entitlement_checks(parent,{'sftp':{}},
                expected_bundle='com.respawnstudios.traverse',policy='local-user-v1',expected_team='CDLNJRG82U'))
        self.assertTrue(rights({}))
        for parent in ({'com.apple.security.app-sandbox':True},
                       {'com.apple.security.temporary-exception.mach-lookup.global-name':['other']},
                       {'keychain-access-groups':['CDLNJRG82U.other']},
                       {'com.apple.security.get-task-allow':True}):
            self.assertFalse(rights(parent),parent)
        with self.assertRaises(ValueError):
            release_candidate.shipping_metadata(dict(channel='developer-id',accessPolicy='local-user-v1',
                publicUpdater=True,qualificationOnly=True,localReviewOnly=True,
                versionOverride=dict(version='0.1.5',build='89')),
                self.info,'developer-id')
        with self.assertRaises(ValueError):helper_symbols.health_service_declared(
            dict(self.info,TraverseDriveHealthServiceVersion=1))


if __name__=='__main__':
    unittest.main()
