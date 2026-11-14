"""Both explicit policies retain negative gates, without signing or accounts."""
import unittest
from contextlib import ExitStack, contextmanager, nullcontext
import hashlib
import json
import plistlib
import subprocess
import sys
from tempfile import TemporaryDirectory
from unittest import mock
from pathlib import Path
from datetime import datetime,timedelta,timezone
import uuid
from distribution import preflight as p


@contextmanager
def generated_health_export(*, direct=False):
    """One disposable unsigned archive/export pair; code signing is mocked."""
    import build_drive_health_worker as health
    with TemporaryDirectory(dir=health.ROOT/'.build') as temporary, \
            mock.patch.object(health,'ROOT',Path(temporary)):
        root=Path(temporary)
        case=root/'.build/traverse-release'/str(uuid.uuid4()).upper()
        (case/'source').mkdir(parents=True)
        archive=case/'Traverse-1.xcarchive/Products/Applications/Traverse.app'
        exported=case/'export-1/Traverse.app'
        parent=health.store_helpers.PARENT;service_id=health.service_identifier(parent)
        if direct:
            from distribution import sparkle
            info=dict(sparkle.metadata(public=True,local_user=True),
                CFBundleIdentifier=parent,CFBundleShortVersionString='0.1.4',CFBundleVersion='69',
                MacExplorerDistributionChannel='developer-id',MacExplorerStorageMode='portable',
                MacExplorerAccessPolicy='local-user-v1',TraverseDriveHealthServiceVersion=1)
        else:
            info=dict(CFBundleIdentifier=parent,CFBundleShortVersionString='0.1.4',CFBundleVersion='69',
                MacExplorerDistributionChannel='developer-id',MacExplorerStorageMode='portable',
                MacExplorerAccessPolicy='sandbox-selected-v1',TraverseDriveHealthServiceVersion=1,
                TraversePrivateUpdaterVersion='2.10.0')
        info_path=archive/'Contents/Info.plist';info_path.parent.mkdir(parents=True)
        info_path.write_bytes(plistlib.dumps(info))
        service=archive/'Contents/XPCServices'/health.SERVICE_LEAF
        binary=service/'Contents/MacOS'/health.SERVICE_EXECUTABLE
        binary.parent.mkdir(parents=True)
        image=b'generated archived health service; never executed'
        binary.write_bytes(image)
        (service/'Contents/Info.plist').write_bytes(plistlib.dumps(health.service_info(service_id)))
        manifest=dict(format='drive-health-xpc-developer-id-v1',parentIdentifier=parent,
            serviceIdentifier=service_id,teamIdentifier=health.store_helpers.TEAM,
            channel='developer-id',accessPolicy=(health.store_helpers.LOCAL if direct
                else health.store_helpers.SCOPED),
            parentRequirement=health.role_requirement(parent),sha256=hashlib.sha256(image).hexdigest(),
            serviceCDHash='a'*40)
        manifest_path=archive/'Contents/Resources'/health.SERVICE_MANIFEST
        manifest_path.parent.mkdir();manifest_path.write_bytes(plistlib.dumps(manifest))
        import shutil
        shutil.copytree(archive,exported)
        archive_service=service;export_service=exported/'Contents/XPCServices'/health.SERVICE_LEAF
        parent_rights={} if direct else {key:True for key in p.PARENT_RIGHTS}
        if not direct:parent_rights[p.UPDATER_MACH_RIGHT]=[parent+'-spks',parent+'-spki']
        state=dict(archive_parent=dict(Identifier=parent,TeamIdentifier=health.store_helpers.TEAM,
            runtime=True,timestamped=False,authorities=['Apple Development: Generated'],cdhash='b'*40),
            archive_child=dict(Identifier=service_id,TeamIdentifier=health.store_helpers.TEAM,
                runtime=True,timestamped=False,authorities=['Apple Development: Generated'],cdhash='a'*40),
            export_parent=dict(Identifier=parent,TeamIdentifier=health.store_helpers.TEAM,
                runtime=True,timestamped=True,authorities=['Developer ID Application: Generated'],cdhash='c'*40),
            export_child=dict(Identifier=service_id,TeamIdentifier=health.store_helpers.TEAM,
                runtime=True,timestamped=False,authorities=['Apple Development: Generated'],cdhash='a'*40),
            archive_rights=parent_rights.copy(),export_rights=parent_rights.copy(),
            archive_child_leaf='A'*40,export_child_leaf='A'*40)
        def signing(path):
            key={archive:'archive_parent',archive_service:'archive_child',exported:'export_parent',
                export_service:'export_child'}[path]
            return state[key]
        def rights(path):
            return state['archive_rights'] if path==archive else state['export_rights'] if path==exported else {}
        def leaf(path,_scratch):
            return ('A'*40 if path==archive else state['archive_child_leaf'] if path==archive_service
                else 'B'*40 if path==exported else state['export_child_leaf'])
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(p,'signing',side_effect=signing))
            stack.enter_context(mock.patch.object(p,'entitlements',side_effect=rights))
            stack.enter_context(mock.patch.object(health,'_leaf_signer',side_effect=leaf))
            stack.enter_context(mock.patch.object(health,'_strict_verify'))
            stack.enter_context(mock.patch.object(health,'_designated_requirement',return_value='designated => generated'))
            stack.enter_context(mock.patch.object(health.helper_symbols,'uuids',return_value={'arm64':str(uuid.uuid4()).upper()}))
            yield health,case,archive,exported,state


class CandidatePreflightTests(unittest.TestCase):
    def test_development_cache_key_is_rejected_from_distribution_metadata(self):
        info = dict(CFBundleIdentifier="com.respawnstudios.traverse", MacExplorerStorageMode="portable",
                    MacExplorerDevelopmentCacheRoot="/Generated/.build/runtime-cache")
        checks = {row["id"]: row["passed"] for row in p.info_checks(info, info["CFBundleIdentifier"], "developer-id")}
        self.assertFalse(checks["no_development_qualifications"])

    def test_health_service_declaration_separates_qa_and_developer_id_product(self):
        from distribution import helper_symbols as symbols
        from distribution import remote_editor_qa
        tag=symbols.HEALTH_QA_CASE
        info=dict(CFBundleIdentifier=remote_editor_qa.identifier(tag),
            MacExplorerDistributionChannel='qualification',MacExplorerSandboxQualificationCase=tag,
            MacExplorerStorageMode='portable',MacExplorerAccessPolicy='sandbox-selected-v1',
            TraverseDriveHealthServiceVersion=1)
        self.assertTrue(symbols.health_service_declared(info))
        self.assertFalse(symbols.health_declared(info))
        for changed in [dict(TraverseDriveHealthServiceVersion=True),
                        dict(TraverseDriveHealthServiceVersion=2),
                        dict(TraverseDriveHealthHelperVersion=2),
                        dict(MacExplorerDistributionChannel='developer-id'),
                        dict(CFBundleIdentifier='com.respawnstudios.traverse'),
                        dict(MacExplorerSandboxQualificationCase='345C4751-4E71-437A-BE8B-6CF18527F77D')]:
            with self.subTest(changed=changed),self.assertRaises(ValueError):
                symbols.health_service_declared({**info,**changed})
        with self.assertRaises(ValueError):
            symbols.health_declared({**info,symbols.HEALTH_VERSION_KEY:2})
        self.assertFalse(p.health_info_admitted(info,info['CFBundleIdentifier'],'qualification'))
        product=dict(CFBundleIdentifier='com.respawnstudios.traverse',
            MacExplorerDistributionChannel='developer-id',MacExplorerStorageMode='portable',
            MacExplorerAccessPolicy='sandbox-selected-v1',TraverseDriveHealthServiceVersion=1,
            TraversePrivateUpdaterVersion='2.10.0')
        self.assertTrue(symbols.health_service_declared(product))
        self.assertFalse(symbols.health_declared(product))
        self.assertTrue(p.health_info_admitted(product,product['CFBundleIdentifier'],'developer-id'))
        self.assertTrue(symbols.health_service_declared({key:value for key,value in product.items()
            if key!='TraversePrivateUpdaterVersion'}))
        self.assertFalse(p.health_info_admitted(product,product['CFBundleIdentifier'],'app-store'))
        self.assertFalse(p.health_info_admitted(info,product['CFBundleIdentifier'],'developer-id'))
        for changed in [dict(TraverseDriveHealthServiceVersion=True),
                        dict(TraverseDriveHealthHelperVersion=2),
                        dict(MacExplorerDistributionChannel='app-store'),
                        dict(MacExplorerSandboxQualificationCase=tag),
                        dict(MacExplorerReviewCase=tag),
                        dict(MacExplorerAccessPolicy='local-user-v1'),
                        dict(TraversePrivateUpdaterVersion='wrong')]:
            with self.subTest(changed=changed),self.assertRaises(ValueError):
                symbols.health_service_declared({**product,**changed})

    def test_health_service_preflight_inspects_shape_but_retains_distribution_hold(self):
        from distribution import helper_symbols as symbols
        from distribution import remote_editor_qa
        tag=symbols.HEALTH_QA_CASE;parent=remote_editor_qa.identifier(tag);team='CDLNJRG82U'
        info=dict(CFBundleIdentifier=parent,MacExplorerDistributionChannel='qualification',
            MacExplorerSandboxQualificationCase=tag,MacExplorerStorageMode='portable',
            MacExplorerAccessPolicy='sandbox-selected-v1',TraverseDriveHealthServiceVersion=1)
        with TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'.build') as temporary:
            app=Path(temporary)/'Generated.app'
            service=app/'Contents/XPCServices'/symbols.HEALTH_SERVICE_LEAF
            binary=service/'Contents/MacOS'/symbols.HEALTH_SERVICE_EXECUTABLE
            binary.parent.mkdir(parents=True)
            image=b'generated XPC bytes; no native execution';binary.write_bytes(image)
            plist=dict(CFBundleIdentifier=parent+'.drive.health.xpc',
                CFBundleExecutable=symbols.HEALTH_SERVICE_EXECUTABLE,CFBundlePackageType='XPC!',
                CFBundleShortVersionString='1.0',CFBundleVersion='1',LSMinimumSystemVersion='15.0',
                XPCService={'ServiceType':'Application','RunLoopType':'dispatch_main'})
            (service/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
            manifest=dict(format='drive-health-xpc-qa-v1',parentIdentifier=parent,
                serviceIdentifier=parent+'.drive.health.xpc',teamIdentifier=team,channel='qualification',
                accessPolicy='sandbox-selected-v1',reviewCase=tag,
                parentRequirement=p.health_role_requirement(parent,team),
                sha256=hashlib.sha256(image).hexdigest(),serviceCDHash='a'*40)
            manifest_path=app/'Contents/Resources/DriveHealthServiceManifest.plist'
            manifest_path.parent.mkdir()
            def inspect(value):
                manifest_path.write_bytes(plistlib.dumps(value))
                signature=dict(Identifier=parent+'.drive.health.xpc',TeamIdentifier=team,runtime=True,
                    cdhash='a'*40,authorities=['Developer ID Application: Generated'],timestamped=False)
                with mock.patch.object(p,'signing',return_value=signature), \
                     mock.patch.object(p,'entitlements',return_value={}), \
                     mock.patch.object(p,'command',return_value=type('Result',(),dict(returncode=0))()):
                    return p.drive_health_checks(app,info,parent,team,'qualification')
            checks=inspect(manifest)
            self.assertTrue(checks[0]['passed'])
            self.assertFalse(checks[1]['passed'])
            self.assertFalse(inspect({**manifest,'parentRequirement':'anchor apple generic'})[0]['passed'])
            worker=app/'Contents/Helpers/drive-health-worker';worker.parent.mkdir()
            worker.write_bytes(b'wrong mixed role')
            self.assertFalse(inspect(manifest)[0]['passed'])
            worker.unlink()
            self.assertFalse(all(row['passed'] for row in p.drive_health_checks(app,{},parent,team,'developer-id')))

    def test_developer_id_health_service_preflight_requires_exact_timestamped_shape(self):
        from distribution import helper_symbols as symbols
        parent='com.respawnstudios.traverse';team='CDLNJRG82U'
        info=dict(CFBundleIdentifier=parent,MacExplorerDistributionChannel='developer-id',
            MacExplorerStorageMode='portable',MacExplorerAccessPolicy='sandbox-selected-v1',
            TraverseDriveHealthServiceVersion=1,TraversePrivateUpdaterVersion='2.10.0')
        with TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'.build') as temporary:
            app=Path(temporary)/'Traverse.app'
            service=app/'Contents/XPCServices'/symbols.HEALTH_SERVICE_LEAF
            binary=service/'Contents/MacOS'/symbols.HEALTH_SERVICE_EXECUTABLE
            binary.parent.mkdir(parents=True)
            image=b'generated product service bytes; never executed'
            binary.write_bytes(image)
            service_info=dict(CFBundleIdentifier=parent+'.drive.health.xpc',
                CFBundleExecutable=symbols.HEALTH_SERVICE_EXECUTABLE,CFBundlePackageType='XPC!',
                CFBundleShortVersionString='1.0',CFBundleVersion='1',LSMinimumSystemVersion='15.0',
                XPCService={'ServiceType':'Application','RunLoopType':'dispatch_main'})
            (service/'Contents/Info.plist').write_bytes(plistlib.dumps(service_info))
            manifest=dict(format='drive-health-xpc-developer-id-v1',parentIdentifier=parent,
                serviceIdentifier=parent+'.drive.health.xpc',teamIdentifier=team,channel='developer-id',
                accessPolicy='sandbox-selected-v1',parentRequirement=p.health_role_requirement(parent,team),
                sha256=hashlib.sha256(image).hexdigest(),serviceCDHash='a'*40)
            manifest_path=app/'Contents/Resources/DriveHealthServiceManifest.plist'
            manifest_path.parent.mkdir()
            def inspect(value=manifest,timestamped=True,role=parent+'.drive.health.xpc'):
                manifest_path.write_bytes(plistlib.dumps(value))
                signature=dict(Identifier=role,TeamIdentifier=team,runtime=True,
                    cdhash='a'*40,authorities=['Developer ID Application: Generated'],timestamped=timestamped)
                with mock.patch.object(p,'signing',return_value=signature), \
                     mock.patch.object(p,'entitlements',return_value={}), \
                     mock.patch.object(p,'command',return_value=type('Result',(),dict(returncode=0))()):
                    return p.drive_health_checks(app,info,parent,team,'developer-id')
            self.assertTrue(all(row['passed'] for row in inspect()))
            for rows in [inspect(timestamped=False),inspect({**manifest,'reviewCase':'QA'}),
                         inspect({**manifest,'parentRequirement':'anchor apple generic'}),
                         inspect(role=parent+'.other')]:
                self.assertFalse(all(row['passed'] for row in rows))
            worker=app/'Contents/Helpers/drive-health-worker';worker.parent.mkdir()
            worker.write_bytes(b'wrong mixed role')
            self.assertFalse(all(row['passed'] for row in inspect()))

    def test_direct_public_health_service_preflight_keeps_local_user_policy(self):
        from distribution import helper_symbols as symbols, sparkle
        parent='com.respawnstudios.traverse';team='CDLNJRG82U'
        info=dict(sparkle.metadata(public=True,local_user=True),
            CFBundleIdentifier=parent,MacExplorerDistributionChannel='developer-id',
            MacExplorerStorageMode='portable',MacExplorerAccessPolicy='local-user-v1',
            TraverseDriveHealthServiceVersion=1)
        self.assertTrue(symbols.health_service_declared(info))
        with TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'.build') as temporary:
            app=Path(temporary)/'Traverse.app'
            service=app/'Contents/XPCServices'/symbols.HEALTH_SERVICE_LEAF
            binary=service/'Contents/MacOS'/symbols.HEALTH_SERVICE_EXECUTABLE
            binary.parent.mkdir(parents=True)
            image=b'generated direct service bytes; never executed'
            binary.write_bytes(image)
            service_info=dict(CFBundleIdentifier=parent+'.drive.health.xpc',
                CFBundleExecutable=symbols.HEALTH_SERVICE_EXECUTABLE,CFBundlePackageType='XPC!',
                CFBundleShortVersionString='1.0',CFBundleVersion='1',LSMinimumSystemVersion='15.0',
                XPCService={'ServiceType':'Application','RunLoopType':'dispatch_main'})
            (service/'Contents/Info.plist').write_bytes(plistlib.dumps(service_info))
            manifest=dict(format='drive-health-xpc-developer-id-v1',parentIdentifier=parent,
                serviceIdentifier=parent+'.drive.health.xpc',teamIdentifier=team,channel='developer-id',
                accessPolicy='local-user-v1',parentRequirement=p.health_role_requirement(parent,team),
                sha256=hashlib.sha256(image).hexdigest(),serviceCDHash='a'*40)
            manifest_path=app/'Contents/Resources/DriveHealthServiceManifest.plist'
            manifest_path.parent.mkdir()
            signature=dict(Identifier=parent+'.drive.health.xpc',TeamIdentifier=team,runtime=True,
                cdhash='a'*40,authorities=['Developer ID Application: Generated'],timestamped=True)
            def inspect(fields=manifest,metadata=info):
                manifest_path.write_bytes(plistlib.dumps(fields))
                with mock.patch.object(p,'signing',return_value=signature), \
                     mock.patch.object(p,'entitlements',return_value={}), \
                     mock.patch.object(p,'command',return_value=type('Result',(),dict(returncode=0))()):
                    return all(row['passed'] for row in p.drive_health_checks(app,metadata,parent,team,'developer-id'))
            self.assertTrue(inspect())
            self.assertFalse(inspect({**manifest,'accessPolicy':'sandbox-selected-v1'}))
            self.assertFalse(inspect(metadata={**info,'TraversePublicUpdaterVersion':'2.10.0'}))
            self.assertFalse(inspect(metadata={**info,'TraverseDirectStorageNamespace':'wrong'}))

    def test_health_service_full_preflight_checks_its_own_role_and_keeps_hold(self):
        from distribution import helper_symbols as symbols
        from distribution import remote_editor_qa
        parent=remote_editor_qa.identifier(symbols.HEALTH_QA_CASE);team='CDLNJRG82U'
        with TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'.build') as temporary:
            app=Path(temporary)/'Generated.app'
            info=dict(CFBundleIdentifier=parent,CFBundleExecutable='Generated',
                TraverseDriveHealthServiceVersion=1)
            path=app/'Contents/Info.plist';path.parent.mkdir(parents=True)
            path.write_bytes(plistlib.dumps(info))
            binaries=[app/'Contents/MacOS/Generated']
            binaries += [app/'Contents/Helpers'/name for name in p.HELPERS]
            service=app/'Contents/XPCServices'/symbols.HEALTH_SERVICE_LEAF/'Contents/MacOS'/symbols.HEALTH_SERVICE_EXECUTABLE
            binaries.append(service)
            for binary in binaries:
                binary.parent.mkdir(parents=True,exist_ok=True)
                binary.write_bytes(b'generated metadata fixture; never executed')
            def command(argv):
                if '-archs' in argv: output=b'arm64\n'
                elif '-L' in argv: output=b'fixture:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
                else: output=b''
                return subprocess.CompletedProcess(argv,0,stdout=output,stderr=b'')
            expected_role=parent+'.drive.health.xpc'
            for service_role,accepted in [(expected_role,True),(parent+'.other',False)]:
                with self.subTest(service_role=service_role):
                    def signing(binary):
                        identifier=(parent if binary==app else service_role if binary==service
                            else p.HELPERS[binary.name])
                        return dict(Identifier=identifier,TeamIdentifier=team,runtime=True,
                            authorities=[],timestamped=False)
                    held=p.check('health_service_distribution_hold',False,'QA service stays held.')
                    with ExitStack() as stack:
                        stack.enter_context(mock.patch.object(p,'info_checks',return_value=[]))
                        stack.enter_context(mock.patch.object(p,'drive_health_checks',return_value=[held]))
                        stack.enter_context(mock.patch.object(p,'entitlement_checks',return_value=[]))
                        stack.enter_context(mock.patch.object(p,'updater_checks',return_value=[]))
                        stack.enter_context(mock.patch.object(p,'read_target',return_value=dict(platform=1,minimumOS=[15,0,0])))
                        stack.enter_context(mock.patch.object(p,'target_admitted',return_value=True))
                        stack.enter_context(mock.patch.object(p,'command',side_effect=command))
                        stack.enter_context(mock.patch.object(p,'signing',side_effect=signing))
                        stack.enter_context(mock.patch.object(p,'entitlements',return_value={}))
                        result=p.inspect(app,parent,team,'qualification')
                    checks={row['id']:row['passed'] for row in result['checks']}
                    self.assertEqual(checks['helper_role_'+symbols.HEALTH_SERVICE_EXECUTABLE],accepted)
                    self.assertTrue(checks['helper_team_'+symbols.HEALTH_SERVICE_EXECUTABLE])
                    self.assertTrue(checks['matching_qualified_architectures'])
                    self.assertFalse(checks['health_service_distribution_hold'])
                    self.assertFalse(result['staticPreflightPassed'])
                    self.assertFalse(result['readyToUpload'])
                    self.assertEqual(result['actionsPerformed'],dict(uploaded=False,appStoreRecordCreated=False))

    def test_health_service_builder_requires_explicit_held_qa_selector(self):
        import build_drive_health_worker as health
        from distribution import remote_editor_qa
        tag=health.helper_symbols.HEALTH_QA_CASE
        case=health.ROOT/'.build/traverse-development'/tag
        app=health.ROOT/'.build/generated-health-service/Generated.app'
        parent=remote_editor_qa.identifier(tag)
        self.assertEqual(health.role_requirement(parent),p.health_role_requirement(parent,health.store_helpers.TEAM))
        env={health.SERVICE_COMPOSITION_KEY:health.SERVICE_COMPOSITION}
        with mock.patch.object(health.remote_editor_qa,'admitted_build',return_value=case), \
             mock.patch.object(health,'_embed_service',return_value=True)as selected:
            self.assertTrue(health.embed(app,environment=env))
            selected.assert_called_once_with(app,env,case)
            for changed in [{health.SERVICE_COMPOSITION_KEY:'unreviewed'},
                            {health.SERVICE_COMPOSITION_KEY:''}]:
                with self.assertRaises(ValueError):health.embed(app,environment=changed)
        with mock.patch.object(health.remote_editor_qa,'admitted_build',return_value=None), \
             mock.patch.object(health,'_embed_service')as selected:
            with self.assertRaises(ValueError):health.embed(app,environment=env)
            selected.assert_not_called()

    def test_health_service_offline_bundle_stage_keeps_worker_separate(self):
        import build_drive_health_worker as health
        from distribution import remote_editor_qa
        tag=health.helper_symbols.HEALTH_QA_CASE
        case=health.ROOT/'.build/traverse-development'/tag
        parent=remote_editor_qa.identifier(tag)
        with TemporaryDirectory(dir=health.ROOT/'.build') as temporary:
            root=Path(temporary);app=root/'Generated.app'
            resource=app/'Contents/Resources';resource.mkdir(parents=True)
            (app/'Contents/Helpers').mkdir()
            info_path=app/'Contents/Info.plist'
            info=dict(CFBundleIdentifier=parent,MacExplorerDistributionChannel='qualification',
                MacExplorerSandboxQualificationCase=tag,MacExplorerStorageMode='portable',
                MacExplorerAccessPolicy='sandbox-selected-v1')
            info_path.write_bytes(plistlib.dumps(info))
            source=root/'generated-service-source';source.write_bytes(b'generated unsigned service bytes')
            env=dict(PRODUCT_BUNDLE_IDENTIFIER=parent,TARGET_BUILD_DIR=str(root),
                CONTENTS_FOLDER_PATH='Generated.app/Contents',
                **{health.SERVICE_COMPOSITION_KEY:health.SERVICE_COMPOSITION})
            service_id=health.service_identifier(parent)
            def run(argv,**kwargs):
                if '--sign' in argv:
                    seal=Path(argv[-1])/'Contents/_CodeSignature'
                    seal.mkdir(mode=0o755)
                    (seal/'CodeResources').write_bytes(b'generated signature receipt')
                if '--entitlements' in argv:return type('Result',(),dict(stdout=b''))()
                if '--verbose=4' in argv:
                    return type('Result',(),dict(stderr='Identifier='+service_id+'\nTeamIdentifier=CDLNJRG82U\n'
                        +'flags=0x10000(runtime)\nAuthority=Developer ID Application: Generated\nCDHash='+'a'*40+'\n'))()
                return type('Result',(),dict(returncode=0))()
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(health.remote_editor_qa,'admitted_build',return_value=case))
                stack.enter_context(mock.patch.object(health.remote_editor_qa,'signer',return_value=('A'*40,'CDLNJRG82U')))
                stack.enter_context(mock.patch.object(health,'build_lock',side_effect=lambda **kw:nullcontext(root)))
                stack.enter_context(mock.patch.object(health,'_locked_build_service',return_value=source))
                stack.enter_context(mock.patch.object(health.subprocess,'run',side_effect=run))
                symbols=stack.enter_context(mock.patch.object(health.helper_symbols,'publish_for_xcode'))
                self.assertTrue(health.embed(app,environment=env))
                bundle=app/'Contents/XPCServices'/health.SERVICE_LEAF
                binary=bundle/'Contents/MacOS'/health.SERVICE_EXECUTABLE
                manifest=plistlib.loads((resource/health.SERVICE_MANIFEST).read_bytes())
                for folder in [bundle.parent,bundle,bundle/'Contents',binary.parent]:
                    self.assertEqual(folder.stat().st_mode&0o055,0o055)
                self.assertEqual(binary.stat().st_mode&0o055,0o055)
                self.assertEqual(plistlib.loads((bundle/'Contents/Info.plist').read_bytes())['CFBundlePackageType'],'XPC!')
                self.assertEqual(manifest['sha256'],hashlib.sha256(binary.read_bytes()).hexdigest())
                self.assertEqual(manifest['parentRequirement'],health.role_requirement(parent))
                self.assertEqual(manifest['serviceCDHash'],'a'*40)
                self.assertEqual(plistlib.loads(info_path.read_bytes())[health.SERVICE_VERSION_KEY],1)
                self.assertFalse((app/'Contents/Helpers/drive-health-worker').exists())
                symbols.assert_called_once()
                with self.assertRaises(ValueError):health.embed(app,environment=env)
                without_selector={key:value for key,value in env.items()if key!=health.SERVICE_COMPOSITION_KEY}
                with self.assertRaises(ValueError):health.embed(app,environment=without_selector)

    def test_developer_id_product_archives_provisional_service_without_qa_selector(self):
        import build_drive_health_worker as health
        from distribution import sparkle
        build_root=health.ROOT/'.build/traverse-release'
        build_root.mkdir(parents=True,exist_ok=True)
        parent=health.store_helpers.PARENT
        for direct,authority in [(False,'Apple Development: Generated'),
                                 (False,'Developer ID Application: Generated'),
                                 (True,'Apple Development: Generated'),
                                 (True,'Developer ID Application: Generated')]:
            with self.subTest(direct=direct,authority=authority),TemporaryDirectory(dir=build_root) as temporary:
                root=Path(temporary);app=root/'Traverse.app'
                resource=app/'Contents/Resources';resource.mkdir(parents=True)
                (app/'Contents/Helpers').mkdir()
                info_path=app/'Contents/Info.plist'
                policy=health.store_helpers.LOCAL if direct else health.store_helpers.SCOPED
                info=dict(sparkle.metadata(public=True,local_user=True) if direct else {},
                    CFBundleIdentifier=parent,MacExplorerDistributionChannel='developer-id',
                    MacExplorerStorageMode='portable',MacExplorerAccessPolicy=policy)
                if not direct:info['TraversePrivateUpdaterVersion']='2.10.0'
                info_path.write_bytes(plistlib.dumps(info))
                source=root/'generated-service-source';source.write_bytes(b'generated unsigned service bytes')
                env=dict(PRODUCT_BUNDLE_IDENTIFIER=parent,
                    MAC_EXPLORER_TRAVERSE_BUILD=('developer-id-local-user-public-qualification-v1' if direct
                        else 'developer-id-v1'),
                    MAC_EXPLORER_ACCESS_POLICY=policy,MAC_EXPLORER_DISTRIBUTION_CHANNEL='developer-id',
                    ENABLE_APP_SANDBOX='NO' if direct else 'YES',
                    ENABLE_HARDENED_RUNTIME='YES',DEVELOPMENT_TEAM='CDLNJRG82U',
                    EXPANDED_CODE_SIGN_IDENTITY='A'*40,TARGET_BUILD_DIR=str(root),
                    CONTENTS_FOLDER_PATH='Traverse.app/Contents')
                calls=[];service_id=health.service_identifier(parent)
                def run(argv,**kwargs):
                    calls.append(argv)
                    if '--sign' in argv:
                        seal=Path(argv[-1])/'Contents/_CodeSignature'
                        seal.mkdir(mode=0o755)
                        (seal/'CodeResources').write_bytes(b'generated signature receipt')
                    if '--entitlements' in argv:return type('Result',(),dict(stdout=b''))()
                    if '--verbose=4' in argv:
                        return type('Result',(),dict(stderr='Identifier='+service_id
                            +'\nTeamIdentifier=CDLNJRG82U\nflags=0x10000(runtime)\n'
                            +'Authority='+authority+'\nCDHash='+'a'*40+'\n'))()
                    return type('Result',(),dict(returncode=0))()
                with ExitStack() as stack:
                    stack.enter_context(mock.patch.object(health.remote_editor_qa,'admitted_build',return_value=None))
                    stack.enter_context(mock.patch.object(health,'build_lock',side_effect=lambda **kw:nullcontext(root)))
                    stack.enter_context(mock.patch.object(health,'_locked_build_service',return_value=source))
                    stack.enter_context(mock.patch.object(health.subprocess,'run',side_effect=run))
                    symbols=stack.enter_context(mock.patch.object(health.helper_symbols,'publish_for_xcode'))
                    with self.assertRaises(ValueError):
                        health.embed(app,environment=env,preview=('A'*40,'CDLNJRG82U','local-preview'))
                    if authority != 'Apple Development: Generated':
                        with self.assertRaises(ValueError):health.embed(app,environment=env)
                        symbols.assert_not_called()
                        self.assertNotIn(health.SERVICE_VERSION_KEY,plistlib.loads(info_path.read_bytes()))
                        continue
                    self.assertTrue(health.embed(app,environment=env))
                    manifest=plistlib.loads((resource/health.SERVICE_MANIFEST).read_bytes())
                    self.assertEqual(manifest['format'],'drive-health-xpc-developer-id-v1')
                    self.assertEqual(manifest['accessPolicy'],policy)
                    self.assertEqual(manifest['parentRequirement'],health.role_requirement(parent))
                    self.assertNotIn('reviewCase',manifest)
                    self.assertEqual(plistlib.loads(info_path.read_bytes())[health.SERVICE_VERSION_KEY],1)
                    self.assertFalse((app/'Contents/Helpers/drive-health-worker').exists())
                    symbols.assert_called_once()
                    with self.assertRaises(ValueError):health.embed(app,environment=env)
                signing=[argv for argv in calls if '--sign' in argv]
                self.assertEqual(len(signing),1)
                self.assertIn('--timestamp=none',signing[0])
                self.assertNotIn('--timestamp',signing[0])

    def test_provisional_archive_requires_same_development_signer_rights_and_fresh_hash(self):
        with generated_health_export() as (health,case,archive,_exported,state):
            proof=health.verify_provisional_archive(case,archive)
            self.assertEqual(proof['serviceCDHash'],'a'*40)
            self.assertEqual(proof['parentCDHash'],'b'*40)
            state['archive_child_leaf']='C'*40
            with self.assertRaisesRegex(ValueError,'signers differ'):
                health.verify_provisional_archive(case,archive)
            state['archive_child_leaf']='A'*40
            state['archive_child']['TeamIdentifier']='WRONGTEAM'
            with self.assertRaisesRegex(ValueError,'role, team'):
                health.verify_provisional_archive(case,archive)
            state['archive_child']['TeamIdentifier']=health.store_helpers.TEAM
            state['archive_rights'].pop('com.apple.security.app-sandbox')
            with self.assertRaisesRegex(ValueError,'rights are not admitted'):
                health.verify_provisional_archive(case,archive)
            state['archive_rights']['com.apple.security.app-sandbox']=True
            manifest_path=archive/'Contents/Resources'/health.SERVICE_MANIFEST
            manifest=plistlib.loads(manifest_path.read_bytes());manifest['sha256']='0'*64
            manifest_path.write_bytes(plistlib.dumps(manifest))
            with self.assertRaisesRegex(ValueError,'archive proof differs'):
                health.verify_provisional_archive(case,archive)

    def test_export_finalization_rebinds_service_and_reseals_parent_in_order(self):
        with generated_health_export() as (health,case,archive,exported,state):
            proof=health.verify_provisional_archive(case,archive)
            service=exported/'Contents/XPCServices'/health.SERVICE_LEAF
            binary=service/'Contents/MacOS'/health.SERVICE_EXECUTABLE
            calls=[]
            def run(argv,**_kwargs):
                calls.append(argv)
                if '--sign' in argv and Path(argv[-1])==service:
                    state['export_child'].update(authorities=['Developer ID Application: Generated'],
                        timestamped=True,cdhash='d'*40)
                    state['export_child_leaf']='B'*40
                    binary.write_bytes(b'generated final signed service; never executed')
                elif '--sign' in argv and Path(argv[-1])==exported:
                    state['export_parent']['cdhash']='e'*40
                return subprocess.CompletedProcess(argv,0,stdout=b'',stderr=b'')
            with mock.patch.object(health.subprocess,'run',side_effect=run):
                result=health.finalize_exported_product(case,archive,exported,proof)
            signing=[argv for argv in calls if '--sign' in argv]
            self.assertEqual([Path(argv[-1]) for argv in signing],[service,exported])
            self.assertIn('--timestamp',signing[0])
            self.assertIn('--preserve-metadata=identifier,entitlements,requirements,flags,runtime,launch-constraints,library-constraints',signing[1])
            self.assertNotIn('--deep',signing[1])
            manifest=plistlib.loads((exported/'Contents/Resources'/health.SERVICE_MANIFEST).read_bytes())
            self.assertEqual(manifest['sha256'],hashlib.sha256(binary.read_bytes()).hexdigest())
            self.assertEqual(manifest['serviceCDHash'],'d'*40)
            self.assertEqual(manifest['parentRequirement'],health.role_requirement(health.store_helpers.PARENT))
            self.assertEqual(result['parentCDHash'],'e'*40)
            self.assertTrue(result['strictDeepVerified'])

    def test_direct_public_archive_and_export_require_empty_parent_rights_and_exact_namespace(self):
        with generated_health_export(direct=True) as (health,case,archive,exported,state):
            proof=health.verify_provisional_archive(case,archive)
            self.assertEqual(state['archive_rights'],{})
            state['archive_rights']['com.apple.security.app-sandbox']=True
            with self.assertRaisesRegex(ValueError,'rights are not admitted'):
                health.verify_provisional_archive(case,archive)
            state['archive_rights'].clear()
            service=exported/'Contents/XPCServices'/health.SERVICE_LEAF
            binary=service/'Contents/MacOS'/health.SERVICE_EXECUTABLE
            def run(argv,**_kwargs):
                if '--sign' in argv and Path(argv[-1])==service:
                    state['export_child'].update(authorities=['Developer ID Application: Generated'],
                        timestamped=True,cdhash='d'*40)
                    state['export_child_leaf']='B'*40
                    binary.write_bytes(b'generated final direct service; never executed')
                elif '--sign' in argv and Path(argv[-1])==exported:
                    state['export_parent']['cdhash']='e'*40
                return subprocess.CompletedProcess(argv,0,stdout=b'',stderr=b'')
            with mock.patch.object(health.subprocess,'run',side_effect=run):
                result=health.finalize_exported_product(case,archive,exported,proof)
            self.assertTrue(result['strictDeepVerified'])
            manifest=plistlib.loads((exported/'Contents/Resources'/health.SERVICE_MANIFEST).read_bytes())
            self.assertEqual(manifest['accessPolicy'],'local-user-v1')
            info_path=exported/'Contents/Info.plist'
            info=plistlib.loads(info_path.read_bytes())
            info['TraverseDirectStorageNamespace']='wrong'
            info_path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                health.finalize_exported_product(case,archive,exported,proof)

    def test_export_finalization_keeps_matching_developer_id_service_signature(self):
        with generated_health_export() as (health,case,archive,exported,state):
            proof=health.verify_provisional_archive(case,archive)
            service=exported/'Contents/XPCServices'/health.SERVICE_LEAF
            binary=service/'Contents/MacOS'/health.SERVICE_EXECUTABLE
            binary.write_bytes(b'generated Xcode-resigned service; never executed')
            state['export_child'].update(authorities=['Developer ID Application: Generated'],
                timestamped=True,cdhash='d'*40)
            state['export_child_leaf']='B'*40
            signed=[]
            def run(argv,**_kwargs):
                if '--sign' in argv:
                    signed.append(Path(argv[-1]))
                    state['export_parent']['cdhash']='e'*40
                return subprocess.CompletedProcess(argv,0,stdout=b'',stderr=b'')
            with mock.patch.object(health.subprocess,'run',side_effect=run):
                result=health.finalize_exported_product(case,archive,exported,proof)
            self.assertEqual(signed,[exported])
            self.assertFalse(result['serviceResigned'])
            self.assertTrue(result['outerResealed'])
            manifest=plistlib.loads((exported/'Contents/Resources'/health.SERVICE_MANIFEST).read_bytes())
            self.assertEqual(manifest['sha256'],hashlib.sha256(binary.read_bytes()).hexdigest())

    def test_export_finalization_refuses_stale_proof_wrong_rights_and_role_before_signing(self):
        with generated_health_export() as (health,case,archive,exported,state):
            proof=health.verify_provisional_archive(case,archive)
            with mock.patch.object(health.subprocess,'run') as commands:
                with self.assertRaisesRegex(ValueError,'archive proof changed'):
                    health.finalize_exported_product(case,archive,exported,{**proof,'serviceCDHash':'0'*40})
                state['export_rights'].pop('com.apple.security.app-sandbox')
                with self.assertRaisesRegex(ValueError,'rights are not admitted'):
                    health.finalize_exported_product(case,archive,exported,proof)
                state['export_rights']['com.apple.security.app-sandbox']=True
                state['export_child']['Identifier']=health.store_helpers.PARENT+'.unselected'
                with self.assertRaisesRegex(ValueError,'service role or rights'):
                    health.finalize_exported_product(case,archive,exported,proof)
                commands.assert_not_called()

    def test_export_failure_records_exact_attempt_and_prevents_blind_repeat(self):
        from distribution import traverse
        import build_drive_health_worker as health
        with TemporaryDirectory(dir=health.ROOT/'.build') as temporary:
            root=Path(temporary)
            owner=root/'MacExplorer.xcodeproj/project.pbxproj'
            owner.parent.mkdir();owner.write_bytes(b'generated project marker')
            case=root/'.build/traverse-release'/str(uuid.uuid4()).upper()
            archive=case/'Traverse-1.xcarchive'
            info_path=archive/'Products/Applications/Traverse.app/Contents/Info.plist'
            info_path.parent.mkdir(parents=True)
            info_path.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=health.store_helpers.PARENT,
                MacExplorerDistributionChannel='developer-id',MacExplorerStorageMode='portable',
                MacExplorerAccessPolicy='sandbox-selected-v1',TraverseDriveHealthServiceVersion=1)))
            (case/'configuration.json').write_text(json.dumps(dict(channel='developer-id',
                accessPolicy='sandbox-selected-v1',qualificationOnly=False)))
            proof=dict(format='generated-proof')
            (case/'archive.json').write_text(json.dumps(dict(passed=True,
                archive=str(archive.relative_to(root)),healthServiceArchive=proof)))
            (case/'archive-inputs.json').write_text(json.dumps(dict(sourceSHA256={'fixture':'same'})))
            argv=['traverse.py','export','--case',case.name]
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(traverse,'REPO',root))
                stack.enter_context(mock.patch.object(traverse,'require_case',return_value=case))
                stack.enter_context(mock.patch.object(traverse,'sources',return_value={'fixture':'same'}))
                stack.enter_context(mock.patch.object(traverse,'audit',return_value={'artifacts':{},'tooling':{}}))
                stack.enter_context(mock.patch.object(health,'verify_provisional_archive',return_value=proof))
                build=stack.enter_context(mock.patch.object(traverse,'run',side_effect=RuntimeError('generated export stop')))
                stack.enter_context(mock.patch.object(sys,'argv',argv))
                with self.assertRaisesRegex(RuntimeError,'generated export stop'):
                    traverse.main()
                attempt=json.loads((case/'export-finalization-attempt.json').read_bytes())
                failure=json.loads((case/'export-finalization-failure.json').read_bytes())
                self.assertEqual(attempt['archive'],str(archive.relative_to(root)))
                self.assertEqual(failure['stage'],'xcode-export')
                self.assertTrue(failure['preserveExport'])
                self.assertFalse(failure['retryWithoutReview'])
                self.assertFalse((case/'export.json').exists())
                with self.assertRaisesRegex(RuntimeError,'Review the retained'):
                    traverse.main()
                self.assertEqual(build.call_count,1)

    def test_artifact_inspection_and_ssh_tools_do_not_share_legacy_packet_imports(self):
        # Use fresh interpreters: other test modules intentionally import the
        # historical SMB notice generator in this process.
        root = Path(__file__).resolve().parents[2]
        for ssh_first in (False, True):
            program = '''
import importlib, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'tools'))
def ssh():
    sys.path.insert(0, str(root / 'tools/ssh_profiles'))
    return importlib.import_module('native_transfer')
if sys.argv[2] == 'first':
    ssh()
from distribution import sandbox
from distribution import artifact_files
assert sandbox.read is artifact_files.read
module = ssh()
assert module.d is importlib.import_module('development')
assert Path(sys.modules['packet'].__file__).resolve() == root / 'tools/ssh_profiles/packet.py'
'''
            with self.subTest(ssh_first=ssh_first):
                result = subprocess.run([sys.executable, '-B', '-c', program, str(root),
                    'first' if ssh_first else 'last'], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_health_declaration_is_optional_for_legacy_and_exact_for_direct(self):
        from distribution import helper_symbols as symbols
        info=dict(CFBundleIdentifier='com.respawnstudios.traverse',
            MacExplorerDistributionChannel='developer-id',MacExplorerAccessPolicy='sandbox-selected-v1')
        self.assertFalse(symbols.health_declared(info))
        direct={**info,symbols.HEALTH_VERSION_KEY:2}
        self.assertTrue(symbols.health_declared(direct))
        self.assertTrue(p.health_info_admitted(direct,info['CFBundleIdentifier'],'developer-id'))
        self.assertFalse(p.health_info_admitted(direct,info['CFBundleIdentifier'],'app-store'))
        for changes in [{symbols.HEALTH_VERSION_KEY:True},{symbols.HEALTH_VERSION_KEY:'2'},
                        {symbols.HEALTH_VERSION_KEY:1},{'MacExplorerDistributionChannel':'app-store'},
                        {'CFBundleIdentifier':'local.macexplorer.sandbox.remote-editor.345c47514e71437abe8b6cf18527f77d',
                         'MacExplorerDistributionChannel':'qualification',
                         'MacExplorerSandboxQualificationCase':'345C4751-4E71-437A-BE8B-6CF18527F77D'},
                        {'MacExplorerAccessPolicy':'local-user-v1'},{'CFBundleIdentifier':'com.generated.other'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                symbols.health_declared({**direct,**changes})

    def test_health_preflight_checks_closed_manifest_hash_role_and_inheritance(self):
        bundle='com.respawnstudios.traverse';team='CDLNJRG82U';app=Path('/generated/Traverse.app')
        payload=b'generated helper; no native execution'
        info=dict(CFBundleIdentifier=bundle,MacExplorerDistributionChannel='developer-id',
            MacExplorerAccessPolicy='sandbox-selected-v1',TraverseDriveHealthHelperVersion=2)
        manifest=dict(format='drive-health-inherited-v2',parentIdentifier=bundle,
            helperIdentifier=bundle+'.drive.health',teamIdentifier=team,channel='developer-id',
            accessPolicy='sandbox-selected-v1',sha256=hashlib.sha256(payload).hexdigest())
        identity=dict(Identifier=bundle+'.drive.health',TeamIdentifier=team,runtime=True)
        rights={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
        def accepted(value=manifest,signer=identity,permissions=rights):
            def read(path,maximum):
                return plistlib.dumps(value) if path.suffix=='.plist' else payload
            with mock.patch.object(p,'read',side_effect=read),mock.patch.object(p,'signing',return_value=signer), \
                 mock.patch.object(p,'entitlements',return_value=permissions):
                return all(row['passed'] for row in p.drive_health_checks(app,info,bundle,team,'developer-id'))
        self.assertTrue(accepted())
        for changes in [dict(reviewCase='UNSELECTED'),dict(channel='qualification'),dict(sha256='0'*64),
                        dict(helperIdentifier='local.macexplorer.drive.health'),dict(accessPolicy='local-user-v1')]:
            self.assertFalse(accepted({**manifest,**changes}))
        for changes in [dict(runtime=False),dict(TeamIdentifier='OTHER'),dict(Identifier='wrong.role')]:
            self.assertFalse(accepted(signer={**identity,**changes}))
        for changed in [{},{**rights,'extra':True},{key:1 for key in rights}]:
            self.assertFalse(accepted(permissions=changed))
        with mock.patch.object(p,'read',side_effect=RuntimeError('redirected/missing input')):
            self.assertFalse(all(row['passed']for row in p.drive_health_checks(app,info,bundle,team,'developer-id')))
        for present in [False,True]:
            with mock.patch.object(Path,'exists',return_value=present),mock.patch.object(Path,'is_symlink',return_value=False):
                self.assertEqual(all(row['passed']for row in p.drive_health_checks(app,{},bundle,team,'developer-id')),not present)

    def test_one_health_embed_owner_preserves_preview_and_qa_worker(self):
        import build_drive_health_worker as health
        bundle='com.respawnstudios.traverse';team='CDLNJRG82U';review=health.helper_symbols.HEALTH_QA_CASE
        app=health.ROOT/'.build/generated-health-composition/Traverse.app'
        payload=b'generated signed helper'
        for lane in ['preview','qualification']:
            preview=lane=='preview';qa=lane=='qualification'
            case=health.ROOT/'.build/traverse-development'/review if qa else None
            parent='local.macexplorer.preview'if preview else bundle
            if qa:parent=health.remote_editor_qa.identifier(review)
            identifier='local.macexplorer.drive.health'if preview else bundle+'.drive.health'
            if qa:identifier=parent+'.drive.health'
            rights={}if preview else health.store_helpers.helper_rights(health.store_helpers.SCOPED)
            info=dict(CFBundleIdentifier=parent,MacExplorerDistributionChannel='qualification'if qa else'development-preview'if preview else'developer-id',
                MacExplorerAccessPolicy='sandbox-selected-v1',MacExplorerReviewCase=review)
            if qa:info['MacExplorerSandboxQualificationCase']=review
            env=dict(PRODUCT_BUNDLE_IDENTIFIER=parent,MAC_EXPLORER_TRAVERSE_BUILD='developer-id-v1',
                MAC_EXPLORER_ACCESS_POLICY='sandbox-selected-v1',TARGET_BUILD_DIR=str(app.parent),
                CONTENTS_FOLDER_PATH='Traverse.app/Contents')
            writes={}
            def read(path):
                if path.name=='Info.plist':return plistlib.dumps(info)
                if path.name=='HelperInherit.entitlements':return plistlib.dumps(rights)
                return payload
            def run(argv,**kwargs):
                if '--entitlements'in argv:return type('Result',(),dict(stdout=plistlib.dumps(rights)))()
                return type('Result',(),dict(stderr='Identifier='+identifier+'\nTeamIdentifier='+team+'\nflags=0x10000(runtime)\n'))()
            with self.subTest(lane=lane),ExitStack()as stack:
                stack.enter_context(mock.patch.object(Path,'resolve',lambda path:path))
                stack.enter_context(mock.patch.object(Path,'read_bytes',read))
                stack.enter_context(mock.patch.object(Path,'write_bytes',lambda path,data:writes.__setitem__(path,plistlib.loads(data))))
                stack.enter_context(mock.patch.object(Path,'is_dir',return_value=True))
                stack.enter_context(mock.patch.object(Path,'exists',return_value=False))
                stack.enter_context(mock.patch.object(Path,'is_symlink',return_value=False))
                stack.enter_context(mock.patch.object(health,'regular'))
                stack.enter_context(mock.patch.object(health.remote_editor_qa,'admitted_build',return_value=case))
                stack.enter_context(mock.patch.object(health.remote_editor_qa,'signer',return_value=('A'*40,team)))
                stack.enter_context(mock.patch.object(health.store_helpers,'configuration',return_value='A'*40))
                stack.enter_context(mock.patch.object(health,'build_lock',side_effect=lambda **kw:nullcontext(health.OUTPUT)))
                stack.enter_context(mock.patch.object(health,'_locked_build',return_value=health.OUTPUT/'drive-health-worker'))
                publish=stack.enter_context(mock.patch.object(health,'publish'))
                stack.enter_context(mock.patch.object(health.subprocess,'run',side_effect=run))
                symbol_copy=stack.enter_context(mock.patch.object(health.helper_symbols,'publish_for_xcode'))
                self.assertTrue(health.embed(app,environment=env,preview=('A'*40,team,review)if preview else None))
                manifest=writes[app/'Contents/Resources/DriveHealthHelperManifest.plist']
                self.assertEqual(manifest['sha256'],hashlib.sha256(payload).hexdigest())
                self.assertEqual(manifest['helperIdentifier'],identifier)
                if preview:
                    self.assertEqual(set(manifest),{'format','parentIdentifier','helperIdentifier','teamIdentifier','reviewCase','sha256'})
                    self.assertEqual(manifest['format'],'drive-health-preview-v1')
                    self.assertNotIn(app/'Contents/Info.plist',writes)
                    symbol_copy.assert_not_called()
                else:
                    expected={'format','parentIdentifier','helperIdentifier','teamIdentifier','channel','accessPolicy','sha256'}
                    if qa:expected.add('reviewCase');self.assertEqual(manifest['reviewCase'],review)
                    self.assertEqual(set(manifest),expected)
                    self.assertEqual(manifest['format'],'drive-health-inherited-v2')
                    self.assertEqual(manifest['channel'],'qualification'if qa else'developer-id')
                    self.assertEqual(writes[app/'Contents/Info.plist']['TraverseDriveHealthHelperVersion'],2)
                    self.assertTrue(health.helper_symbols.health_declared(writes[app/'Contents/Info.plist']))
                    symbol_copy.assert_called_once()
                self.assertEqual(publish.call_args.kwargs['strip_debug'],not preview)

    def test_health_embed_omits_unselected_editions_without_building(self):
        import build_drive_health_worker as health
        app=health.ROOT/'.build/generated-health-composition/Traverse.app'
        for tag,policy,parent in [('app-store-v1','sandbox-selected-v1','com.respawnstudios.traverse'),
                                 ('developer-id-local-user-qualification-v1','local-user-v1','com.respawnstudios.traverse'),
                                 ('unknown','sandbox-selected-v1','com.generated.other')]:
            env=dict(MAC_EXPLORER_TRAVERSE_BUILD=tag,MAC_EXPLORER_ACCESS_POLICY=policy,PRODUCT_BUNDLE_IDENTIFIER=parent)
            with mock.patch.object(Path,'resolve',lambda path:path),mock.patch.object(Path,'exists',return_value=False), \
                 mock.patch.object(Path,'is_symlink',return_value=False), \
                 mock.patch.object(health.remote_editor_qa,'admitted_build',return_value=None), \
                 mock.patch.object(health,'_locked_build')as build:
                self.assertFalse(health.embed(app,environment=env));build.assert_not_called()
                with mock.patch.object(Path,'exists',return_value=True),self.assertRaises(ValueError):
                    health.embed(app,environment=env)

    def test_developer_id_policy_never_accepts_adhoc_development_or_missing_timestamp(self):
        valid=dict(authorities=['Developer ID Application: Generated'],timestamped=True)
        self.assertTrue(all(row['passed'] for row in p.developer_id_checks(valid)))
        for changes in [dict(authorities=[]),dict(authorities=['Apple Development: Generated']),
                        dict(authorities='Developer ID Application: Generated'),dict(authorities=[None]),
                        dict(timestamped=False),dict(timestamped='yes')]:
            self.assertFalse(all(row['passed'] for row in p.developer_id_checks({**valid,**changes})))

    def test_app_store_identity_expiry_and_extra_entitlements_still_refuse(self):
        now=datetime.now(timezone.utc);team='GENERATED';bundle='com.generated.Traverse'
        profile=dict(Entitlements={'com.apple.application-identifier':team+'.'+bundle},TeamIdentifier=[team],ExpirationDate=now+timedelta(days=1))
        self.assertTrue(all(r['passed'] for r in p.profile_checks(profile,bundle,team,now)))
        for changed in [{**profile,'ExpirationDate':now-timedelta(seconds=1)},{**profile,'TeamIdentifier':['OTHER']},
                        {**profile,'Entitlements':{'com.apple.application-identifier':team+'.different'}}]:
            self.assertFalse(all(r['passed'] for r in p.profile_checks(changed,bundle,team,now)))
        parent={key:True for key in p.PARENT_RIGHTS};helper={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
        self.assertTrue(all(r['passed'] for r in p.entitlement_checks(parent,{'generated':helper})))
        self.assertFalse(all(r['passed'] for r in p.entitlement_checks({**parent,'com.apple.security.get-task-allow':True},{'generated':helper})))
        self.assertFalse(all(r['passed'] for r in p.entitlement_checks(parent,{'generated':{**helper,'com.apple.security.network.server':True}})))

    def test_existing_default_remains_app_store_and_cross_channel_refuses(self):
        for actual in ['app-store','developer-id','development',None]:
            info=dict(MacExplorerDistributionChannel=actual)
            default={r['id']:r['passed'] for r in p.info_checks(info,'com.generated.Traverse')}
            self.assertEqual(default['distribution_runtime_channel'],actual=='app-store')
            for wanted in ['app-store','developer-id']:
                checks={r['id']:r['passed'] for r in p.info_checks(info,'com.generated.Traverse',wanted)}
                self.assertEqual(checks['distribution_runtime_channel'],actual==wanted)
                self.assertFalse(checks['version_and_build'])
        with self.assertRaises(ValueError):p.info_checks({},'com.generated.Traverse','anything')

    def test_export_declaration_is_channel_scoped_and_never_invented(self):
        def checks(info,channel):
            return {r['id']:r for r in p.info_checks(info,'com.generated.Traverse',channel)}
        direct=checks({},'developer-id')
        self.assertNotIn('export_answer_present',direct)
        self.assertTrue(direct['export_answer_type']['passed'])
        self.assertFalse(checks({},'app-store')['export_answer_present']['passed'])
        for answer in (True,False):
            info={'ITSAppUsesNonExemptEncryption':answer}
            self.assertTrue(checks(info,'developer-id')['export_answer_type']['passed'])
            self.assertTrue(checks(info,'app-store')['export_answer_present']['passed'])
            self.assertEqual(info,{'ITSAppUsesNonExemptEncryption':answer})
        for answer in (None,0,1,'NO',[],{}):
            info={'ITSAppUsesNonExemptEncryption':answer}
            self.assertFalse(checks(info,'developer-id')['export_answer_type']['passed'])
            self.assertFalse(checks(info,'app-store')['export_answer_present']['passed'])

    def test_notarization_admission_refuses_any_failed_technical_check(self):
        from distribution import notarize_direct_app as n
        case=Path('/generated/review');app=case/'export/Traverse.app'
        def read(path):
            return plistlib.dumps({}) if path==app/'Contents/Info.plist' else b'{}'
        with mock.patch.object(Path,'is_symlink',return_value=False), \
             mock.patch.object(Path,'resolve',lambda path:path), \
             mock.patch.object(Path,'read_bytes',read), \
             mock.patch.object(n.release_candidate,'shipping_metadata',return_value=('0.1.5','75')):
            for identifier in ('export_answer_type','export_answer_present','complete_bundle_signature'):
                with self.subTest(identifier=identifier), mock.patch.object(n,'inspect',return_value={
                    'checks':[{'id':identifier,'passed':False}]}):
                    with self.assertRaisesRegex(RuntimeError,'Technical artifact admission failed'):
                        n.admit(case,app)

    def test_signature_facts_preserve_authorities_and_timestamp_without_guessing(self):
        for text,wanted,timestamp in [
            ('Identifier=com.generated.Traverse\nTeamIdentifier=GENERATED\nCodeDirectory flags=0x10000(runtime)\nAuthority=Developer ID Application: Generated\nAuthority=Generated chain\nTimestamp=22 Oct 2026\n',
             ['Developer ID Application: Generated','Generated chain'],True),
            ('Identifier=com.generated.Traverse\nTeamIdentifier=not set\nCodeDirectory flags=0x0\nSignature=adhoc\n',[],False)]:
            with mock.patch.object(p,'command',return_value=type('Result',(),dict(returncode=0,stderr=text.encode()))):
                found=p.signing(Path('/generated/Traverse.app'))
                self.assertEqual(found['authorities'],wanted)
                self.assertEqual(found['timestamped'],timestamp)
                self.assertEqual(found['runtime'],timestamp)


if __name__=='__main__':unittest.main()
