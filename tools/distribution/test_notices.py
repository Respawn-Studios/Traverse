"""Retained generated filesystem/parser controls, with no network/credentials."""
import os
import json
import io
import tarfile
from datetime import datetime,timedelta,timezone
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from distribution import notices,bundle_notices
from distribution import preflight

class MetadataPathControls(unittest.TestCase):
    def test_unexpected_volume_paths_refuse_without_rejecting_the_portable_hint(self):
        for value in ['/Volumes/Other/fixture','file:///Volumes/Other/fixture','/Users/Example/fixture']:
            with self.subTest(value=value):
                self.assertTrue(preflight.machine_path_in_metadata(value))
                checks={row['id']:row['passed'] for row in preflight.info_checks({'GeneratedPath':value},'com.generated.Traverse')}
                self.assertFalse(checks['no_unexpanded_or_machine_paths'])
        self.assertFalse(preflight.machine_path_in_metadata('file:///tmp/generated'))
        for data in [b'/Volumes/Other/fixture',b'/Volumes/TraverseExtra',b'/Volumes/Traverse/fixture',b'/Users/Example/fixture',b'.build/fixture']:
            with self.subTest(data=data):
                self.assertTrue(preflight.machine_path_in_metadata(data,allowed_volume_hint=b'/Volumes/Traverse'))
        self.assertFalse(preflight.machine_path_in_metadata(b'alias:/Volumes/Traverse\x00/.background/background.png',
            allowed_volume_hint=b'/Volumes/Traverse'))

class NoticeControls(unittest.TestCase):
    def setUp(self):
        base=Path(os.environ['MAC_EXPLORER_NOTICE_TEST_ROOT'])
        repo=Path(__file__).resolve().parents[2]
        case=base.parent
        focused=repo/'.build/notice-regression'
        if base.name!='source' or case.parent not in [repo/'.build/overnight-foundation',repo/'.build/b11-native-qualification',focused] or base.resolve()!=base \
            or str(uuid.UUID(case.name)).upper()!=case.name or not (case/'reservation.json').is_file():raise RuntimeError('Generated notice test root required')
        if case.parent==focused and json.loads((case/'reservation.json').read_bytes())!={'packet':'notice-regression-v1','bytes':4<<20,'entries':256}:
            raise RuntimeError('Exact notice regression reservation required')
        self.root=base/str(uuid.uuid4()).upper();self.root.mkdir(mode=0o700)
    def test_graph_merge_preserves_version_and_rejects_conflicting_notices(self):
        component=dict(name='generated',version='1',declaredLicense='MIT',notices=[dict(name='LICENSE',sha256='a'*64)],graphs=['smb'])
        second={**component,'graphs':['sftp']}
        merged,texts,locks=notices.merge_components([([component],{'a'*64:'generated license'},dict(role='smb')),([second],{'a'*64:'generated license'},dict(role='sftp'))])
        self.assertEqual(len(merged),1);self.assertEqual(merged[0]['graphs'],['sftp','smb']);self.assertEqual(len(locks),2)
        with self.assertRaises(RuntimeError):notices.merge_components([([component],{},{}),([{**second,'declaredLicense':'other'}],{},{})])
        with self.assertRaises(RuntimeError):notices.merge_components([([] ,{'a':'one'},{}),([] ,{'a':'two'},{})])
        versions,_,_=notices.merge_components([([component,{**second,'version':'2'}],{},{})]);self.assertEqual(len(versions),2)
    def test_supplement_requires_published_vcs_and_exact_text(self):
        root=self.root/'LicenseSupplements';root.mkdir();source=self.root/'Published';source.mkdir()
        vcs={'git':{'sha1':'1'*40,'dirty':True},'path_in_vcs':'generated'};data=json.dumps(vcs).encode();(source/'.cargo_vcs_info.json').write_bytes(data)
        directory=root/'generated-1';directory.mkdir();text=b'generated license';(directory/'LICENSE').write_bytes(text)
        record=dict(name='generated',version='1',archiveSHA256='a'*64,publishedVCS=vcs,notices=[dict(name='LICENSE',sha256=notices.sha(text),url='https://example.invalid/recorded',origin='recorded-upstream-base-revision')])
        (root/'index.json').write_text(json.dumps(dict(version=1,entries=[record])))
        with mock.patch.object(notices,'OUTPUT',self.root):
            values,_,provenance=notices.supplemental_notices(source,dict(name='generated',version='1'),{('generated','1'):'a'*64},{'.cargo_vcs_info.json':notices.sha(data)})
            self.assertEqual(len(values),1);self.assertTrue(provenance['git']['dirty'])
            (directory/'LICENSE').write_bytes(b'changed')
            with self.assertRaises(RuntimeError):notices.supplemental_notices(source,dict(name='generated',version='1'),{('generated','1'):'a'*64},{'.cargo_vcs_info.json':notices.sha(data)})
    def test_exact_lock_identity_and_checksum(self):
        checksum='a'*64
        raw=('version = 4\n[[package]]\nname = "one"\nversion = "1.2.3"\nchecksum = "'+checksum+'"\n').encode()
        self.assertEqual(notices.lock_checksums(raw),{('one','1.2.3'):checksum})
        for bad in [b'no packages',raw+raw,raw.replace(b'"1.2.3"',b'1.2'),raw.replace(checksum.encode(),b'bad'),raw+b'name = "again"\n']:
            with self.assertRaises(RuntimeError):notices.lock_checksums(bad)
    def test_pinned_ring_nested_notices_match_published_archive(self):
        tooling=self.root/'tooling'
        index='generated-index'
        directory=tooling/'cargo-home/registry/src'/index/'ring-0.17.14'
        directory.mkdir(parents=True)
        members={'Cargo.toml':b'[package]\nname = "ring"\nversion = "0.17.14"\n',
                 'LICENSE':b'generated top-level notice',
                 'src/polyfill/once_cell/LICENSE-APACHE':b'generated nested Apache notice',
                 'src/polyfill/once_cell/LICENSE-MIT':b'generated nested MIT notice',
                 'third_party/fiat/LICENSE':b'generated fiat notice'}
        for name,data in members.items():
            path=directory/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        stream=io.BytesIO()
        with tarfile.open(fileobj=stream,mode='w:gz') as archive:
            for name,data in members.items():
                info=tarfile.TarInfo('ring-0.17.14/'+name);info.size=len(data)
                archive.addfile(info,io.BytesIO(data))
        cache=tooling/'cargo-home/registry/cache'/index;cache.mkdir(parents=True)
        content=stream.getvalue();(cache/'ring-0.17.14.crate').write_bytes(content)
        package={'name':'ring','version':'0.17.14'}
        checks=notices.registry_notices(directory,package,{('ring','0.17.14'):notices.sha(content)},tooling)
        self.assertEqual(set(checks),set(members))
        with self.assertRaises(RuntimeError):notices.notice_paths(directory,{'name':'ring','version':'0.17.15'})
        nested=directory/'third_party/fiat/LICENSE';nested.write_bytes(b'changed notice')
        with self.assertRaises(RuntimeError):notices.registry_notices(directory,package,{('ring','0.17.14'):notices.sha(content)},tooling)
        nested.unlink()
        with self.assertRaises(RuntimeError):notices.registry_notices(directory,package,{('ring','0.17.14'):notices.sha(content)},tooling)
    def test_legal_text_preserves_text_and_entities_without_running_markup(self):
        parser=notices.PlainLegalText();parser.feed('<h1>License</h1><pre>A &amp; B\nCopyright &lt;name&gt;</pre><script>never execute</script>')
        found=''.join(parser.parts)
        self.assertIn('A & B\nCopyright <name>',found);self.assertNotIn('never execute',found)
    def test_bounded_regular_reads_refuse_links_and_size(self):
        file=self.root/'notice.txt';file.write_bytes(b'generated notice')
        self.assertEqual(notices.read(file),b'generated notice')
        link=self.root/'link.txt';link.symlink_to(file)
        with self.assertRaises(RuntimeError):notices.read(link)
        with self.assertRaises(RuntimeError):notices.read(file,4)
    def test_bundle_replaces_only_exact_generated_resources(self):
        app=self.root/'Generated.app';resources=app/'Contents/Resources';resources.mkdir(parents=True)
        unrelated=resources/'other.txt';unrelated.write_bytes(b'preserve')
        for name in ['ThirdPartyNotices.txt','ThirdPartyManifest.json']:(resources/name).write_bytes(b'old generated resource')
        with mock.patch.object(bundle_notices,'verify_outputs',return_value=(b'new generated notice',b'{"version":1}')):
            self.assertEqual(bundle_notices.embed(app),len(b'new generated notice'))
        self.assertEqual((resources/'ThirdPartyNotices.txt').read_bytes(),b'new generated notice')
        self.assertEqual((resources/'TraverseLicense.txt').read_bytes(),(Path(__file__).resolve().parents[2]/'LICENSE').read_bytes())
        self.assertEqual(unrelated.read_bytes(),b'preserve')
        self.assertEqual(sorted(p.name for p in self.root.iterdir()),['Generated.app'])
    def test_redirected_resources_are_refused_without_writing_target(self):
        app=self.root/'Generated.app';(app/'Contents').mkdir(parents=True)
        target=self.root/'target';target.mkdir();(app/'Contents/Resources').symlink_to(target,target_is_directory=True)
        with mock.patch.object(bundle_notices,'verify_outputs',return_value=(b'notice',b'{}')):
            with self.assertRaises(RuntimeError):bundle_notices.embed(app)
        self.assertEqual(list(target.iterdir()),[])
    def test_development_info_never_becomes_upload_metadata(self):
        value={'CFBundleIdentifier':'local.macexplorer.development','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1',
            'MacExplorerDevelopmentStateRoot':'/Volumes/Generated/.build/state'}
        checks={row['id']:row['passed'] for row in preflight.info_checks(value,'local.macexplorer.development')}
        self.assertFalse(checks['final_bundle_identity']);self.assertFalse(checks['portable_storage'])
        self.assertFalse(checks['no_development_qualifications']);self.assertFalse(checks['no_unexpanded_or_machine_paths'])
        self.assertTrue(checks['version_and_build'])
        value['CFBundleIdentifier']='com.generated.Explorer';value['MacExplorerStorageMode']='portable'
        value['MacExplorerDistributionChannel']='candidate'
        checks={row['id']:row['passed'] for row in preflight.info_checks(value,'com.generated.Explorer')}
        self.assertTrue(checks['final_bundle_identity']);self.assertFalse(checks['distribution_runtime_channel'])
    def test_extra_or_missing_helper_entitlements_refuse(self):
        parent={key:True for key in preflight.PARENT_RIGHTS}
        valid={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
        self.assertTrue(all(row['passed'] for row in preflight.entitlement_checks(parent,{'one':valid})))
        for child in [{},{**valid,'com.apple.security.get-task-allow':True},{**valid,'com.apple.security.inherit':False}]:
            self.assertFalse(all(row['passed'] for row in preflight.entitlement_checks(parent,{'one':child})))
        parent['com.apple.security.temporary-exception.files.absolute-path.read-write']=['/']
        self.assertFalse(all(row['passed'] for row in preflight.entitlement_checks(parent,{'one':valid})))
    def test_profile_team_identity_and_expiry_are_distinct(self):
        now=datetime.now(timezone.utc);team='AAAAAAAAAA';bundle='com.generated.Explorer'
        profile={'Entitlements':{'com.apple.application-identifier':team+'.'+bundle},'TeamIdentifier':[team],
            'ExpirationDate':now+timedelta(days=1)}
        self.assertTrue(all(row['passed'] for row in preflight.profile_checks(profile,bundle,team,now)))
        for changed in [{**profile,'ExpirationDate':now-timedelta(seconds=1)},{**profile,'TeamIdentifier':'AAAAAAAAAA'},
            {**profile,'Entitlements':{'com.apple.application-identifier':team+'.other'}},{**profile,'Entitlements':[]}]:
            self.assertFalse(all(row['passed'] for row in preflight.profile_checks(changed,bundle,team,now)))

if __name__=='__main__':unittest.main()
