"""Source-only public updater boundary checks; no app launch or signing."""
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from distribution import helper_symbols, preflight, sparkle
from folder_services import descriptor as folder_service_descriptor


class PublicUpdaterPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.info = sparkle.metadata(public=True)

    def test_generated_public_metadata_is_distinct_and_inherits_exact_folder_service(self):
        info = self.info
        self.assertEqual(info['SUFeedURL'],
            'https://respawn-studios.com/products/traverse/public-updates/appcast.xml')
        self.assertEqual(info['TraversePublicUpdaterVersion'], '2.10.0')
        self.assertNotIn('TraversePrivateUpdaterVersion', info)
        self.assertEqual(info['NSServices'], folder_service_descriptor('Traverse'))
        self.assertEqual(info['MacExplorerFolderServices'], 'public-folders-service-v1')
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAutomaticallyUpdate'])
        self.assertFalse(info['SUAllowsAutomaticUpdates'])
        self.assertFalse(info['SUEnableDownloaderService'])
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertEqual(info['SUSignedFeedFailureExpirationInterval'], 0)
        self.assertNotIn('Authorization', str(info))
        self.assertNotIn('Invitation', str(info))

    def test_mode_and_folder_service_admission(self):
        info = dict(self.info, MacExplorerAccessPolicy='sandbox-selected-v1')
        def row(fields, channel, identifier):
            return next(check['passed'] for check in preflight.info_checks(
                fields, 'com.respawnstudios.traverse', channel) if check['id'] == identifier)
        self.assertTrue(row(info, 'developer-id', 'updater_edition_boundary'))
        self.assertTrue(row(info, 'developer-id', 'folder_service_boundary'))
        self.assertFalse(row(info, 'app-store', 'updater_edition_boundary'))
        self.assertFalse(row(dict(info, TraversePrivateUpdaterVersion='2.10.0'),
            'developer-id', 'updater_edition_boundary'))
        self.assertFalse(row(dict(info, TraversePrivateUpdaterVersion=None),
            'developer-id', 'updater_edition_boundary'))
        self.assertFalse(row({key: value for key, value in info.items()
            if key not in ('NSServices', 'MacExplorerFolderServices')},
            'developer-id', 'folder_service_boundary'))
        self.assertFalse(row(dict(info, NSServices=folder_service_descriptor('Traverse Preview')),
            'developer-id', 'folder_service_boundary'))

    def test_public_preflight_rejects_private_feed_and_inexact_mach_rights(self):
        info = dict(self.info, MacExplorerAccessPolicy='sandbox-selected-v1')
        root = Path(__file__).resolve().parents[2] / '.build'
        with TemporaryDirectory(dir=root) as temporary:
            def admitted(fields):
                return next(check['passed'] for check in preflight.updater_checks(
                    Path(temporary) / 'Generated.app', fields, 'CDLNJRG82U', 'developer-id')
                    if check['id'] == 'updater_security_configuration')
            self.assertTrue(admitted(info))
            self.assertFalse(admitted(dict(info, SUFeedURL=
                'https://respawn-studios.com/products/traverse/updates/appcast.xml')))
            self.assertFalse(admitted(dict(info, SURequireSignedFeed=False)))
            self.assertFalse(admitted(dict(info, SUEnableAutomaticDownloads=True)))

        rights = {key: True for key in preflight.PARENT_RIGHTS}
        rights[preflight.UPDATER_MACH_RIGHT] = [
            'com.respawnstudios.traverse-spks', 'com.respawnstudios.traverse-spki']
        self.assertTrue(all(check['passed'] for check in preflight.entitlement_checks(
            rights, {}, True, 'com.respawnstudios.traverse')))
        rights[preflight.UPDATER_MACH_RIGHT].append('extra')
        self.assertFalse(all(check['passed'] for check in preflight.entitlement_checks(
            rights, {}, True, 'com.respawnstudios.traverse')))

    def test_health_service_declares_only_one_known_updater(self):
        info = dict(CFBundleIdentifier='com.respawnstudios.traverse',
            MacExplorerDistributionChannel='developer-id',
            MacExplorerAccessPolicy='sandbox-selected-v1',
            MacExplorerStorageMode='portable', TraverseDriveHealthServiceVersion=1,
            TraversePublicUpdaterVersion='2.10.0')
        self.assertTrue(helper_symbols.health_service_declared(info))
        with self.assertRaises(ValueError):
            helper_symbols.health_service_declared(dict(info, TraversePrivateUpdaterVersion=None))


if __name__ == '__main__':
    unittest.main()
