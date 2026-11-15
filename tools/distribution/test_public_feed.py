import hashlib
import datetime
from email.utils import parsedate_to_datetime
import copy
import json
import tempfile
import unittest
import xml.etree.ElementTree as XML
from pathlib import Path
from unittest import mock

from distribution import direct_feed, public_feed, release_candidate


class PublicFeedTests(unittest.TestCase):
    def test_feed_preparation_time_is_independent_of_the_display_date(self):
        item, info, entry = self.direct_fixture()
        item['edSignature'] = 'A' * 86 + '=='
        app = public_feed.public_app_record(info, item, item['admission']['appCDHash'],
                                            public_feed.FeedEdition.DIRECT)
        manifest = dict(artifact=item, app=app,
            sourceKit=dict(sha256='d' * 64, bytes=500, sourceCommit='e' * 40,
                           sourceSelection='contributor-v1', sourceManifestSHA256='f' * 64),
            note=dict(bytes=70, edSignature='B' * 86 + '=='),
            releaseDate='2026-11-15', feedPreparedAtUTC='2026-11-14T20:00:00Z',
            buildSourceSHA256={'App/MacExplorer/App.swift':'1' * 64})
        body = public_feed.canonical_feed(manifest, public_feed.FeedEdition.DIRECT)
        published = XML.fromstring(body).findtext('./channel/item/pubDate')
        self.assertEqual(parsedate_to_datetime(published),
                         datetime.datetime(2026,11,14,20,tzinfo=datetime.timezone.utc))
        for timestamp in (None, '2026-11-14', '2026-11-14T25:00:00Z',
                          '2026-11-14T20:00:00+00:00'):
            with self.subTest(timestamp=timestamp), self.assertRaises(ValueError):
                public_feed.canonical_feed(dict(manifest,feedPreparedAtUTC=timestamp),
                                           public_feed.FeedEdition.DIRECT)

    @staticmethod
    def fixture():
        version, build = '0.1.3', '90'
        proof = dict(schema=1, team='CDLNJRG82U', bundleID='com.respawnstudios.traverse',
                     version=version, build=build, channel='Developer ID', gatekeeper='accepted',
                     stapled=True, timestamped=True, appCDHash='a' * 40,
                     container='dmg', containerGatekeeper='accepted', containerStapled=True)
        item = dict(id='traverse-0-1-3-90-arm64', filename='Traverse-0.1.3-90-arm64.dmg',
                    bytes=128, sha256='b' * 64, version=version, build=build,
                    architecture='arm64', minimumOS='15.0', admission=proof)
        info = dict(TraversePublicUpdaterVersion='2.10.0', CFBundleIdentifier=proof['bundleID'],
                    CFBundleShortVersionString=version, CFBundleVersion=build,
                    MacExplorerDistributionChannel='developer-id', MacExplorerAccessPolicy='sandbox-selected-v1',
                    SUFeedURL=public_feed.FEED_URL, SUPublicEDKey=public_feed.PUBLIC_KEY)
        entry = dict(version=version, build=90, state='preview', date='2026-11-14',
                     title='Generated < & >', summary='Generated only', changes=['No <script> content'])
        return item, info, entry

    @staticmethod
    def direct_fixture():
        item, info, entry = PublicFeedTests.fixture()
        info.pop('TraversePublicUpdaterVersion')
        info.update(TraverseDirectPublicUpdaterVersion='2.10.0',
                    TraverseDirectStorageNamespace=public_feed.DIRECT_STORAGE_NAMESPACE,
                    TraverseDriveHealthServiceVersion=1,
                    MacExplorerReleasePurpose=release_candidate.DIRECT_SHIPPING_PURPOSE,
                    MacExplorerAccessPolicy='local-user-v1', MacExplorerStorageMode='portable',
                    MacExplorerFolderServices='public-folders-service-v1',
                    SUFeedURL=public_feed.DIRECT_FEED_URL,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUSignedFeedFailureExpirationInterval=0, SUScheduledCheckInterval=21600,
                    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                    SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
                    SUEnableJavaScript=False)
        return item, info, entry

    def test_direct_feed_has_fixed_route_and_signed_identity_distinct_from_scoped(self):
        item, info, entry = self.direct_fixture()
        item['edSignature'] = 'A' * 86 + '=='
        app = public_feed.public_app_record(info, item, item['admission']['appCDHash'],
                                            public_feed.FeedEdition.DIRECT)
        source = dict(filename='d' * 64 + '.tar.gz', bytes=500, sha256='d' * 64,
                      format='traverse-source-kit-v1', sourceCommit='e' * 40,
                      sourceSelection='contributor-v1', sourceManifestSHA256='f' * 64)
        manifest = dict(artifact=item, app=app, sourceKit=source,
                        note=dict(filename='90.html', bytes=70, sha256='c' * 64,
                                  edSignature='B' * 86 + '=='), releaseDate=entry['date'],
                        buildSourceSHA256={'App/MacExplorer/App.swift': '1' * 64})
        body = public_feed.canonical_feed(manifest, public_feed.FeedEdition.DIRECT)
        self.assertIn(public_feed.DIRECT_FEED_URL.rsplit('/', 1)[0].encode() + b'/archives/', body)
        self.assertIn(b'mode="direct-public-updater-v1"', body)
        self.assertIn(b'accessPolicy="local-user-v1" storageNamespace="com.respawnstudios.traverse.direct"', body)
        self.assertIn(b'releasePurpose="direct-shipping-v1"', body)
        self.assertNotIn(b'/public-updates/', body)
        with self.assertRaises(ValueError): public_feed.canonical_feed(manifest)
        with self.assertRaises(ValueError): public_feed.public_app_record(info, item,
            item['admission']['appCDHash'])
        for changed in (dict(info,TraverseDirectStorageNamespace='com.respawnstudios.traverse'),
                        dict(info,MacExplorerReleasePurpose='qualification'),
                        dict(TraverseDriveHealthServiceVersion=True),
                        dict(TraverseDriveHealthServiceVersion=2),
                        dict(SUEnableInstallerLauncherService=False),
                        dict(SUFeedURL=public_feed.FEED_URL),
                        dict(TraversePublicUpdaterVersion='2.10.0')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                public_feed.public_app_record(dict(info, **changed), item,
                    item['admission']['appCDHash'], public_feed.FeedEdition.DIRECT)
        with self.assertRaises(ValueError):
            public_feed.public_app_record(
                {key:value for key,value in info.items() if key!='MacExplorerReleasePurpose'},
                item,item['admission']['appCDHash'],public_feed.FeedEdition.DIRECT)
        with self.assertRaises(ValueError): public_feed.public_app_record(info, item, 'f' * 40,
            public_feed.FeedEdition.DIRECT)

    def test_direct_feed_rejects_qualification_before_signer_or_source_access(self):
        item, info, entry = self.direct_fixture()
        hypothetical = release_candidate.configuration(channel='developer-id',policy='local-user-v1',
            version=item['version'],build=item['build'],shipping=True,public_updater=True)
        public_feed.admit_artifact(hypothetical, item, entry, public_feed.FeedEdition.DIRECT)
        with self.assertRaises(ValueError): public_feed.admit_artifact(hypothetical, item, entry)
        base = dict(channel='developer-id', accessPolicy='local-user-v1',
                    publicUpdater=True, qualificationOnly=True,
                    versionOverride=dict(version=item['version'], build=item['build']))
        for direct_case in (dict(base,localReviewOnly=True),
                            dict(base,shippingCandidate=True),
                            dict(hypothetical,releasePurpose='qualification')):
            with self.assertRaises(ValueError):
                public_feed.admit_artifact(direct_case, item, entry, public_feed.FeedEdition.DIRECT)
            with self.subTest(direct_case=direct_case), \
                 mock.patch.object(public_feed.source_capsule, 'read_at',
                                   return_value=json.dumps(direct_case).encode()) as read, \
                 mock.patch.object(public_feed.sparkle, 'verify') as sparkle, \
                 mock.patch.object(public_feed, 'inspect_source') as source, \
                 mock.patch.object(public_feed.subprocess, 'check_output') as signer:
                with self.assertRaises(ValueError):
                    direct_feed.prepare(Path('/generated/case'), Path('/generated/source-kit.tar.gz'))
                self.assertEqual(read.call_count, 1)
                sparkle.assert_not_called(); source.assert_not_called(); signer.assert_not_called()

    def test_canonical_public_feed_binds_one_app_dmg_note_source_and_build_table(self):
        item, info, entry = self.fixture()
        item['edSignature'] = 'A' * 86 + '=='
        note = dict(filename='90.html', bytes=70, sha256='c' * 64, edSignature='B' * 86 + '==')
        source = dict(filename='d' * 64 + '.tar.gz', bytes=500, sha256='d' * 64,
                      format='traverse-source-kit-v1', sourceCommit='e' * 40,
                      sourceSelection='contributor-v1', sourceManifestSHA256='f' * 64)
        inputs = {'App/MacExplorer/App.swift': '1' * 64, 'Packages/ExplorerKit/Package.swift': '2' * 64}
        manifest = dict(artifact=item, app=public_feed.public_app_record(info, item, item['admission']['appCDHash']),
                        sourceKit=source, note=note, releaseDate=entry['date'], buildSourceSHA256=inputs)
        body = public_feed.canonical_feed(manifest)
        tree = XML.fromstring(body)
        ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle',
              'traverse': 'https://respawn-studios.com/ns/traverse-updates/1'}
        rows = tree.findall('./channel/item')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].find('sparkle:version', ns).text, '90')
        self.assertEqual(rows[0].find('sparkle:hardwareRequirements', ns).text, 'arm64')
        self.assertEqual(rows[0].find('traverse:app', ns).attrib['mode'], 'public-updater-v1')
        self.assertEqual(rows[0].find('traverse:source', ns).attrib['buildInputsSHA256'],
                         public_feed.build_inputs_sha256(inputs))
        self.assertIn(b'Sat, 14 Nov 2026 12:00:00 +0000', body)
        self.assertNotIn(b'/products/traverse/updates/', body)
        self.assertNotIn(b'private beta', body)

    def test_public_app_and_artifact_receipts_reject_private_or_unqualified_modes(self):
        item, info, entry = self.fixture()
        checked = dict(channel='developer-id', accessPolicy='sandbox-selected-v1',
                       publicUpdater=True, shippingCandidate=True,
                       versionOverride=dict(version=item['version'], build=item['build']))
        public_feed.admit_artifact(checked, item, entry)
        public_feed.public_app_record(info, item, item['admission']['appCDHash'])
        for changed in [dict(checked, privateUpdater=True), dict(checked, shippingCandidate=False),
                        dict(checked, channel='app-store')]:
            with self.assertRaises(ValueError):
                public_feed.admit_artifact(changed, item, entry)
        for changed in [dict(info, TraversePrivateUpdaterVersion='2.10.0'),
                        dict(info, SUFeedURL=public_feed.ORIGIN + '/products/traverse/updates/appcast.xml'),
                        dict(info, TraversePublicUpdaterVersion='')]:
            with self.assertRaises(ValueError):
                public_feed.public_app_record(changed, item, item['admission']['appCDHash'])
        with self.assertRaisesRegex(ValueError, 'scoped public updater'):
            public_feed.public_app_record(info, item, 'f' * 40)
        changed = dict(item, admission=dict(item['admission'], containerStapled=False))
        with self.assertRaises(ValueError):
            public_feed.admit_artifact(checked, changed, entry)

    def test_inspected_source_kit_must_cover_exact_build_input_hashes(self):
        root = public_feed.REPO / '.build/source-release'
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='public-feed-test-', dir=root) as directory:
            path = Path(directory) / 'Generated-source-kit.tar.gz'
            path.write_bytes(b'Generated source-kit-shaped bytes; no project source.')
            inputs = {'App/MacExplorer/App.swift': 'a' * 64, 'Packages/ExplorerKit/Package.swift': 'b' * 64}
            inspected = dict(format='traverse-source-kit-v1', bytes=path.stat().st_size,
                             sha256=hashlib.sha256(path.read_bytes()).hexdigest(), sourceCommit='c' * 40,
                             sourceSelection='contributor-v1', sourceManifestSHA256='d' * 64,
                             projectSourceSHA256=dict(inputs, **{'README.md': 'e' * 64}))
            source = public_feed.source_record(path, inspected, inputs)
            self.assertEqual(source['filename'], inspected['sha256'] + '.tar.gz')
            with self.assertRaisesRegex(ValueError, 'does not match'):
                public_feed.source_record(path, dict(inspected, projectSourceSHA256={'README.md': 'e' * 64}), inputs)
            with self.assertRaises(ValueError):
                public_feed.build_inputs_sha256({'../outside': 'a' * 64})

    def test_existing_public_release_policy_refuses_prepare_before_signer_or_source_read(self):
        base = dict(channel='developer-id', accessPolicy='sandbox-selected-v1',
                    publicUpdater=True, versionOverride=dict(version='0.1.3', build='90'))
        for purpose, error in [('localReviewOnly', 'shipping case'),
                               ('shippingCandidate', 'exact purpose')]:
            with self.subTest(purpose=purpose), \
                    mock.patch.object(public_feed.source_capsule, 'read_at',
                                      return_value=json.dumps(dict(base, **{purpose: True})).encode()) as read, \
                    mock.patch.object(public_feed.sparkle, 'verify') as sparkle, \
                    mock.patch.object(public_feed, 'inspect_source') as source, \
                    mock.patch.object(public_feed.subprocess, 'check_output') as signer:
                with self.assertRaisesRegex(ValueError, error):
                    public_feed.prepare(Path('/generated/case'), Path('/generated/source-kit.tar.gz'))
                self.assertEqual(read.call_count, 1)
                sparkle.assert_not_called(); source.assert_not_called(); signer.assert_not_called()

    @staticmethod
    def cask_fixture():
        item, info, entry = PublicFeedTests.direct_fixture()
        item['edSignature'] = 'A' * 86 + '=='
        checked = release_candidate.configuration(channel='developer-id',policy='local-user-v1',
            version=item['version'],build=item['build'],shipping=True,public_updater=True)
        catalog = dict(schema=1, channel='direct-public-free-v1', publicKey=public_feed.PUBLIC_KEY,
                       artifact=item, app=public_feed.public_app_record(info, item,
                           item['admission']['appCDHash'], public_feed.FeedEdition.DIRECT),
                       sourceKit=dict(sha256='d' * 64, bytes=500, sourceCommit='e' * 40,
                                      sourceSelection='contributor-v1', sourceManifestSHA256='f' * 64),
                       note=dict(bytes=70, edSignature='B' * 86 + '=='), releaseDate=entry['date'],
                       buildSourceSHA256={'App/MacExplorer/App.swift': '1' * 64})
        return checked, catalog, entry

    def test_cask_uses_admitted_identity_and_fixed_official_route(self):
        checked, catalog, entry = self.cask_fixture()
        recipe = public_feed.render_cask(checked, catalog, entry).decode()
        self.assertIn('version "0.1.3,90"', recipe)
        self.assertIn('sha256 "' + catalog['artifact']['sha256'] + '"', recipe)
        self.assertIn('url "' + public_feed.DIRECT_BASE + '/archives/' + 'b' * 64 + '.dmg"', recipe)
        self.assertIn('depends_on arch: :arm64', recipe)
        self.assertIn('depends_on macos: :sequoia', recipe)
        self.assertIn('app "Traverse.app"', recipe)
        for forbidden in ('zap', ':no_check', 'quarantine', 'preflight', 'postflight', 'uninstall', 'system '):
            self.assertNotIn(forbidden, recipe)
        changes = [('artifact', 'version', '0.1.3";system("bad")'),
                   ('artifact', 'build', '91'), ('artifact', 'architecture', 'x86_64'),
                   ('artifact', 'minimumOS', '14.0'), ('artifact', 'sha256', 'not-a-checksum'),
                   ('app', 'version', '0.1.4'), ('app', 'releasePurpose', 'qualification'),
                   ('app', 'feedURL', public_feed.FEED_URL),
                   ('app', 'feedURL', 'https://other.example/appcast.xml')]
        for section, key, value in changes:
            changed = copy.deepcopy(catalog); changed[section][key] = value
            with self.subTest(section=section, key=key, value=value), self.assertRaises(ValueError):
                public_feed.render_cask(checked, changed, entry)
        with self.assertRaises(ValueError):
            public_feed.render_cask(dict(checked, localReviewOnly=True), catalog, entry)

    def test_intel_feed_and_homebrew_pair_require_the_matching_case_and_source(self):
        arm=self.cask_fixture()
        checked,catalog,entry=copy.deepcopy(arm)
        checked['architecture']='x86_64'
        item=catalog['artifact'];item.update(architecture='x86_64',sha256='9'*64,
            id=item['id'].removesuffix('arm64')+'x86_64',
            filename=item['filename'].removesuffix('arm64.dmg')+'x86_64.dmg')
        catalog['app'].update(architecture='x86_64',
            feedURL=public_feed.edition_contract(public_feed.FeedEdition.DIRECT,'x86_64')['feed'])
        intel=(checked,catalog,entry)
        body=public_feed.canonical_feed(catalog,public_feed.FeedEdition.DIRECT)
        self.assertIn(b'/direct-updates-intel/archives/',body)
        self.assertNotIn(b'hardwareRequirements',body)
        recipe=public_feed.render_cask_pair(arm,intel).decode()
        self.assertIn('on_arm do',recipe);self.assertIn('on_intel do',recipe)
        self.assertNotIn('depends_on arch:',recipe)
        self.assertIn('9'*64,recipe)
        with self.assertRaises(ValueError):public_feed.admit_artifact(arm[0],item,entry,public_feed.FeedEdition.DIRECT)
        wrong=copy.deepcopy(intel);wrong[1]['sourceKit']['sha256']='0'*64
        with self.assertRaises(ValueError):public_feed.render_cask_pair(arm,wrong)
        wrong=copy.deepcopy(intel);wrong[1]['app']['feedURL']=public_feed.DIRECT_FEED_URL
        with self.assertRaises(ValueError):public_feed.render_cask_pair(arm,wrong)

    def test_cask_retains_shipping_hold_before_any_artifact_or_signer_access(self):
        checked, _, _ = self.cask_fixture()
        for config in (dict(checked, releasePurpose='qualification'),
                       dict(checked, shippingCandidate=False, localReviewOnly=True)):
            with self.subTest(config=config), mock.patch.object(public_feed.source_capsule, 'read_at',
                    return_value=json.dumps(config).encode()) as read, \
                    mock.patch.object(public_feed.private_feed, 'verify_signature') as verify, \
                    mock.patch.object(public_feed.subprocess, 'check_output') as signer:
                with self.assertRaises(ValueError):
                    public_feed.prepare_cask(Path('/generated/case'))
                self.assertEqual(read.call_count, 1)
                verify.assert_not_called(); signer.assert_not_called()

    def test_cask_checks_prepared_feed_and_actual_dmg_before_exclusive_local_output(self):
        root = public_feed.REPO / '.build/traverse-release'
        root.mkdir(parents=True, exist_ok=True)
        for mismatch in (None, 'receipt', 'feed', 'dmg'):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory(prefix='cask-test-', dir=root) as temp:
                case = Path(temp); output = case / 'direct-updates'; output.mkdir(); (case / 'dmg').mkdir()
                checked, catalog, entry = self.cask_fixture()
                image = b'Generated DMG fixture only'
                catalog['artifact'].update(bytes=len(image), sha256=hashlib.sha256(image).hexdigest())
                canonical = public_feed.canonical_feed(catalog, public_feed.FeedEdition.DIRECT)
                feed = canonical + (f'<!-- sparkle-signatures:\nedSignature: {"C" * 86}==\n'
                                    f'length: {len(canonical)}\n-->\n').encode()
                catalog['feed'] = dict(filename='appcast.xml', bytes=len(feed), sha256=hashlib.sha256(feed).hexdigest())
                item = catalog['artifact']
                receipt = dict(passed=True, binarySourceInputsMatched=True, artifactSHA256=item['sha256'],
                               sourceKitSHA256=catalog['sourceKit']['sha256'], version=item['version'], build=item['build'])
                if mismatch == 'receipt': receipt['build'] = '91'
                (output / 'prepared.json').write_text(json.dumps(receipt))
                (output / 'direct-updates.json').write_text(json.dumps(catalog))
                (output / 'appcast.xml').write_bytes(feed + (b'changed' if mismatch == 'feed' else b''))
                (output / 'feed-signature-input.bin').write_bytes(canonical)
                (case / 'dmg/manifest.json').write_text(json.dumps(dict(schema=1, artifacts=[
                    {key: value for key, value in item.items() if key != 'edSignature'}])))
                (case / 'dmg' / item['filename']).write_bytes(image + (b'changed' if mismatch == 'dmg' else b''))
                (case / 'configuration.json').write_text(json.dumps(checked))
                with mock.patch.object(public_feed.private_feed, 'frozen_history', return_value=dict(releases=[entry])), \
                        mock.patch.object(public_feed.private_feed, 'verify_signature'):
                    if mismatch:
                        with self.assertRaises(ValueError): public_feed.prepare_cask(case)
                        self.assertFalse((output / 'traverse.rb').exists())
                    else:
                        path = public_feed.prepare_cask(case)
                        self.assertEqual(path.read_bytes(), public_feed.render_cask(checked, catalog, entry))
                        with self.assertRaises(FileExistsError): public_feed.prepare_cask(case)


if __name__ == '__main__':
    unittest.main()
