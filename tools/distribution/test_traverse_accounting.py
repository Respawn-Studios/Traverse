"""Live compiler-cache disappearance versus retained-evidence accounting."""
import json
from pathlib import Path
import plistlib
import signal
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import stat
import unittest
from unittest import mock
import traverse_packet as packet


def setUpModule():
    (packet.REPO/'.build').mkdir(mode=0o700,exist_ok=True)


class LiveAccounting(unittest.TestCase):
    def measure(self, root, result):
        with mock.patch.object(Path, 'exists', return_value=True), \
             mock.patch.object(packet.os, 'walk', return_value=[(str(root), [], ['compiler.o.tmp'])]), \
             mock.patch.object(Path, 'lstat', side_effect=result):
            return packet.measure(root)

    def test_removed_compiler_temporary_is_no_longer_allocated(self):
        for root in packet.COMPILER_ROOTS:
            with self.subTest(root=root):
                self.assertEqual(self.measure(root, FileNotFoundError()), dict(bytes=0, allocatedBytes=0, entries=0))

    def test_missing_retained_evidence_still_stops_the_packet(self):
        with self.assertRaises(FileNotFoundError):
            self.measure(packet.ROOT/'generated-case', FileNotFoundError())

    def test_other_errors_are_not_hidden(self):
        with self.assertRaises(PermissionError):
            self.measure(packet.TOOLING, PermissionError())

    def test_present_files_keep_exact_byte_and_allocation_counts(self):
        facts = SimpleNamespace(st_blocks=2, st_size=37, st_mode=stat.S_IFREG | 0o600)
        self.assertEqual(self.measure(packet.TOOLING, [facts]), dict(bytes=37, allocatedBytes=1024, entries=1))


class SharedToolingAccounting(unittest.TestCase):
    @staticmethod
    def usage(tooling, clang, swift, crash=0):
        def entry(allocated):
            return dict(bytes=allocated, allocatedBytes=allocated, entries=1)
        return dict(tooling=entry(tooling), crashReporterTooling=entry(crash), sharedCompilerCaches=dict(
            clang=entry(clang), swift=entry(swift)),
            chargedToolingAllocatedBytes=tooling+clang+swift+crash)

    def test_actual_tooling_and_both_cache_roots_are_counted(self):
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
            repo=Path(temporary);build=repo/'.build'
            tooling=build/'traverse-release/tooling';clang=build/'compiler-cache/xcode'
            swift=build/'compiler-cache/xcode-swift'
            crash=build/'crash-reporter-tooling'
            for root in (tooling,clang,swift,crash):
                root.mkdir(parents=True)
                (root/'generated-module').write_bytes(root.name.encode())
            with mock.patch.multiple(packet,REPO=repo,TOOLING=tooling,CLANG_CACHE=clang,
                                     SWIFT_CACHE=swift,CRASH_TOOLING=crash,COMPILER_ROOTS=frozenset({tooling,clang,swift,crash})):
                observed=packet.charged_tooling()
                expected=sum(packet.measure(root)['allocatedBytes'] for root in (tooling,clang,swift,crash))
            self.assertEqual(observed['chargedToolingAllocatedBytes'],expected)
            self.assertEqual(observed['tooling'],packet.measure(tooling))
            self.assertEqual(observed['sharedCompilerCaches']['clang'],packet.measure(clang))
            self.assertEqual(observed['sharedCompilerCaches']['swift'],packet.measure(swift))
            self.assertEqual(observed['crashReporterTooling'],packet.measure(crash))

    def test_combined_charge_keeps_the_release_ceiling(self):
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary, \
             mock.patch.object(packet, 'ROOT', Path(temporary)), \
             mock.patch.object(packet, 'directory', side_effect=lambda path: path):
            at_limit=self.usage((4 << 30)-12288,4096,4096,4096)
            with mock.patch.object(packet, 'charged_tooling', return_value=at_limit):
                result=packet.audit()
            self.assertEqual(result['tooling']['allocatedBytes'], (4 << 30)-12288)
            self.assertEqual(result['sharedCompilerCaches']['clang']['allocatedBytes'], 4096)
            self.assertEqual(result['chargedToolingAllocatedBytes'], 4 << 30)
            with mock.patch.object(packet, 'charged_tooling', return_value=self.usage((4 << 30)-12288,4096,4096,4097)):
                with self.assertRaisesRegex(RuntimeError, 'Release tooling allocation budget reached'):
                    packet.audit()

    def test_development_charge_keeps_its_independent_ceiling(self):
        import development
        zero=dict(bytes=0,allocatedBytes=0,entries=0)
        with mock.patch.object(development, 'measure', return_value=zero), \
             mock.patch.object(development, 'charged_tooling', return_value=self.usage((5 << 30)-8192,4096,4096)):
            self.assertEqual(development.audit()['chargedToolingAllocatedBytes'],5 << 30)
        with mock.patch.object(development, 'measure', return_value=zero), \
             mock.patch.object(development, 'charged_tooling', return_value=self.usage((5 << 30)-8192,4096,4097)):
            with self.assertRaisesRegex(RuntimeError, 'Development or isolated tooling limit reached'):
                development.audit()

    def test_redirected_compiler_root_is_refused(self):
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
            repo=Path(temporary);build=repo/'.build';cache=build/'compiler-cache'
            cache.mkdir(parents=True)
            (cache/'target').mkdir()
            (cache/'xcode').symlink_to(cache/'target',target_is_directory=True)
            clang=cache/'xcode';swift=cache/'xcode-swift'
            tooling=build/'traverse-release/tooling'
            crash=build/'crash-reporter-tooling'
            with mock.patch.multiple(packet,REPO=repo,TOOLING=tooling,CLANG_CACHE=clang,
                                     SWIFT_CACHE=swift,CRASH_TOOLING=crash,COMPILER_ROOTS=frozenset({tooling,clang,swift,crash})):
                with self.assertRaisesRegex(RuntimeError,'Redirected compiler or tooling directory'):
                    packet.charged_tooling()

    def test_failed_build_receipt_uses_reaped_exit(self):
        from distribution import traverse
        class Child:
            pid=13579
            returncode=None
            def poll(self): return self.returncode
            def wait(self,timeout): self.returncode=-signal.SIGTERM;return self.returncode
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
            case=Path(temporary);(case/'evidence').mkdir()
            child=Child()
            with mock.patch.object(traverse, 'directory', side_effect=lambda path: path), \
                 mock.patch.object(traverse.subprocess, 'Popen', return_value=child) as launch, \
                 mock.patch.object(traverse.os, 'killpg') as stopped, \
                 mock.patch.object(traverse, 'audit', side_effect=RuntimeError('Release tooling allocation budget reached')):
                with self.assertRaisesRegex(RuntimeError,'Release tooling allocation budget reached'):
                    traverse.run(case,['generated-build'],'archive')
            stopped.assert_called_once_with(child.pid,signal.SIGTERM)
            process=json.loads(next((case/'evidence').glob('archive-*.process.json')).read_text())
            self.assertEqual(process['actualExit'],-signal.SIGTERM)
            self.assertTrue(process['processReaped'])
            self.assertFalse(process['passed'])
            self.assertEqual(process['errorType'],'RuntimeError')
            env=launch.call_args.kwargs['env']
            self.assertEqual(env['CLANG_MODULE_CACHE_PATH'],str(packet.CLANG_CACHE))
            self.assertEqual(env['SWIFTPM_MODULECACHE_OVERRIDE'],str(packet.SWIFT_CACHE))

    def test_release_project_arguments_use_charged_cache_paths(self):
        from distribution import traverse
        with mock.patch.object(traverse, 'generate'), \
             mock.patch.object(traverse, 'directory', side_effect=lambda path: path), \
             mock.patch.object(traverse.release_candidate, 'settings', return_value=[]):
            command=traverse.project_arguments(packet.REPO/'.build/generated-case','developer-id')
        self.assertIn('CLANG_MODULE_CACHE_PATH='+str(packet.CLANG_CACHE),command)
        self.assertIn('SWIFT_MODULE_CACHE_PATH='+str(packet.SWIFT_CACHE),command)


class EditorCacheAccounting(unittest.TestCase):
    def audit(self, *, allocated=4096, cache_allocated=0, case_bytes=4096, shared_allocated=4096):
        import sandbox
        from distribution import remote_editor_qa
        usage = SharedToolingAccounting.usage(allocated,cache_allocated,0)
        usage['tooling']['bytes']=40 << 30
        fixture = dict(bytes=case_bytes, allocatedBytes=case_bytes, entries=8)
        def measured(path):
            return dict(bytes=shared_allocated, allocatedBytes=shared_allocated, entries=3) \
                if path == remote_editor_qa.STAGING_PRODUCT else fixture
        with mock.patch.object(sandbox.d, 'audit', return_value=usage), \
             mock.patch.object(Path, 'is_symlink', return_value=False), \
             mock.patch.object(Path, 'exists', return_value=True), \
             mock.patch.object(sandbox, 'measure', side_effect=measured):
            return sandbox.editor_release_audit(Path('/generated/case'))

    def test_sparse_compiler_maps_keep_logical_measurement_without_false_refusal(self):
        observed = self.audit()
        self.assertEqual(observed['tooling']['bytes'], 40 << 30)
        self.assertEqual(observed['tooling']['allocatedBytes'], 4096)
        self.assertEqual(observed['sharedReleaseProducts']['allocatedBytes'], 4096)
        self.assertEqual(observed['chargedToolingAndProductsAllocatedBytes'], 8192)

    def test_allocated_cache_and_retained_source_limits_remain_independent(self):
        import sandbox
        for arguments in [dict(allocated=(4 << 30) + 1), dict(case_bytes=(4 << 20) + 1)]:
            with self.subTest(arguments=arguments), self.assertRaises(sandbox.EditorReleaseResourceLimit):
                self.audit(**arguments)

    def test_shared_products_are_charged_against_the_same_ceiling(self):
        import sandbox
        self.assertEqual(self.audit(allocated=(4 << 30)-4096)
                         ['chargedToolingAndProductsAllocatedBytes'], 4 << 30)
        with self.assertRaises(sandbox.EditorReleaseResourceLimit):
            self.audit(allocated=(4 << 30)-4096, shared_allocated=8192)

    def test_shared_compiler_cache_is_charged_with_products(self):
        import sandbox
        self.assertEqual(self.audit(allocated=(4 << 30)-8192,cache_allocated=4096)
                         ['chargedToolingAndProductsAllocatedBytes'],4 << 30)
        with self.assertRaises(sandbox.EditorReleaseResourceLimit):
            self.audit(allocated=(4 << 30)-8192,cache_allocated=4097)

    def test_retained_symbols_are_required_and_limited_to_declared_roles(self):
        import sandbox
        from distribution import helper_symbols
        product=Path('/generated/products')
        service_parent='local.macexplorer.sandbox.remote-editor.'+helper_symbols.HEALTH_QA_CASE.replace('-','').lower()
        cases=[({},None), ({'CFBundleIdentifier':'com.respawnstudios.traverse',
            'MacExplorerDistributionChannel':'developer-id',
            'MacExplorerAccessPolicy':'sandbox-selected-v1',
            helper_symbols.HEALTH_VERSION_KEY:2},helper_symbols.HEALTH_HELPER),
            ({'CFBundleIdentifier':service_parent,'MacExplorerDistributionChannel':'qualification',
              'MacExplorerSandboxQualificationCase':helper_symbols.HEALTH_QA_CASE,
              'MacExplorerStorageMode':'portable','MacExplorerAccessPolicy':'sandbox-selected-v1',
              helper_symbols.HEALTH_SERVICE_VERSION_KEY:1},helper_symbols.HEALTH_SERVICE_EXECUTABLE)]
        for info,health in cases:
            with self.subTest(health=health), \
                 mock.patch.object(sandbox,'read',return_value=plistlib.dumps(info)):
                artifacts=sandbox.editor_release_artifacts(product)
                expected={'Mac Explorer.app','Mac Explorer.app.dSYM'} | \
                    {name+'.dSYM' for name in helper_symbols.HELPERS}
                if health:expected.add(health+'.dSYM')
                self.assertEqual({path.name for path in artifacts},expected)
                self.assertTrue(all(path.parent==product for path in artifacts))

    def test_final_audit_failure_preserves_the_original_failed_build_receipt(self):
        import sandbox
        for error in [sandbox.EditorReleaseResourceLimit(dict(tooling=dict(allocatedBytes=(4 << 30) + 1))),
                      PermissionError('private location must not enter diagnostics')]:
            with self.subTest(error=type(error).__name__), \
                 mock.patch.object(sandbox, 'scope_audit', side_effect=error):
                observed = sandbox.complete_build_receipt(dict(passed=False, failure='Original build stop'),
                    case=Path('/generated/case'), editor_release=True, actual_exit=-15,
                    elapsed=1.5, failure_detail=dict(type='OriginalFailure'))
                self.assertFalse(observed['passed'])
                self.assertEqual(observed['failure'], 'Original build stop')
                self.assertEqual(observed['actualBuildExit'], -15)
                self.assertEqual(observed['resourceAuditFailure'], dict(type='OriginalFailure'))
                self.assertEqual(observed['packet'], dict(complete=False))
                self.assertEqual(observed['finalResourceAuditFailure']['type'], type(error).__name__)
                self.assertNotIn('private location', str(observed))


class CrashDependencySymbols(unittest.TestCase):
    def test_signed_review_refuses_stale_framework_before_compilation(self):
        import build_crash_reporter as crash
        from distribution import signed_local_qa as review
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary, \
             mock.patch.object(crash,'verify_prepared',side_effect=RuntimeError('prepared framework stale')), \
             mock.patch.object(review.subprocess,'Popen') as launch:
            inputs=mock.Mock();put=mock.Mock()
            with self.assertRaisesRegex(RuntimeError,'prepared framework stale'):
                review.build(Path(temporary),'generated',{},'Generated.xcconfig',inputs,mock.Mock(),put,'Generated')
            inputs.assert_not_called();put.assert_not_called();launch.assert_not_called()

    def test_framework_embed_respects_explicit_local_no_timestamp_only(self):
        import build_crash_reporter as crash
        for flags in ('--timestamp=none', '--timestamp', '', '--prefix=local --timestamp=none'):
            with self.subTest(flags=flags), TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
                root=Path(temporary)
                framework=root/'Prepared.framework';framework.mkdir()
                (framework/'Generated').write_bytes(b'generated framework fixture')
                target=root/'Generated.app/Contents';target.mkdir(parents=True)
                env=dict(TARGET_BUILD_DIR=str(target.parent),CONTENTS_FOLDER_PATH='Contents',
                    CODE_SIGNING_ALLOWED='YES',EXPANDED_CODE_SIGN_IDENTITY='A'*40,
                    ENABLE_HARDENED_RUNTIME='YES',OTHER_CODE_SIGN_FLAGS=flags)
                with mock.patch.dict(crash.os.environ,env,clear=True), \
                     mock.patch.object(crash,'FRAMEWORK',framework), \
                     mock.patch.object(crash,'verify_prepared',return_value={'framework':{'fixture':True}}), \
                     mock.patch.object(crash,'snapshot',return_value={'fixture':True}), \
                     mock.patch.object(crash.subprocess,'run') as run:
                    crash.embed()
                signing=run.call_args_list[0].args[0]
                self.assertEqual('--timestamp=none' in signing,'--timestamp=none' in flags.split())
                self.assertNotIn('--prefix=local',signing)
                self.assertIn('runtime',signing)
                self.assertEqual(run.call_args_list[1].args[0][:3],['/usr/bin/codesign','--verify','--strict'])

    def test_stale_generated_notices_stop_before_project_generation(self):
        import sys
        from distribution import traverse
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
            case=Path(temporary)
            (case/'configuration.json').write_text(json.dumps({'channel':'developer-id'}))
            for action in ('prepare','archive'):
                with self.subTest(action=action), \
                     mock.patch.object(sys,'argv',['traverse.py',action,'--case','generated']), \
                     mock.patch.object(traverse,'require_case',return_value=case), \
                     mock.patch.object(traverse.release_notes,'verify_bundled'), \
                     mock.patch('distribution.notices.verify_outputs',side_effect=RuntimeError('Generated notices need reviewed regeneration')), \
                     mock.patch.object(traverse,'project_arguments',side_effect=AssertionError('Project generation reached')) as project, \
                     mock.patch.object(traverse,'run') as run:
                    with self.assertRaisesRegex(RuntimeError,'Generated notices need reviewed regeneration'):
                        traverse.main()
                    project.assert_not_called()
                    run.assert_not_called()

    def test_archive_retention_uses_the_prepared_framework_and_matching_bundle(self):
        import build_crash_reporter as crash
        from distribution import helper_symbols as symbols
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
            archive=Path(temporary)/'Generated.xcarchive';archive.mkdir()
            with mock.patch.object(crash,'verify_prepared') as verified, \
                 mock.patch.object(symbols,'copy_bundle',return_value={'hasCompileUnits':True}) as copied:
                symbols.retain_crash_reporter_symbols(archive)
            verified.assert_called_once_with()
            copied.assert_called_once_with(crash.FRAMEWORK/'Versions/A/CrashReporter',crash.SYMBOLS,
                archive/'Products/Applications/Traverse.app/Contents/Frameworks/CrashReporter.framework/Versions/A/CrashReporter',
                archive/'dSYMs/CrashReporter.framework.dSYM')

    def test_archive_inspection_refuses_missing_or_mismatched_crash_symbols(self):
        from distribution import helper_symbols as symbols
        with TemporaryDirectory(dir=packet.REPO/'.build') as temporary:
            archive=Path(temporary)/'Generated.xcarchive'
            app=archive/'Products/Applications/Traverse.app'
            (app/'Contents/Frameworks/CrashReporter.framework').mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({}))
            for name in symbols.HELPERS:
                binary=app/'Contents/Helpers'/name;binary.parent.mkdir(exist_ok=True)
                binary.write_bytes(b'generated helper')
                dwarf=archive/'dSYMs'/(name+'.dSYM')/'Contents/Resources/DWARF'/name
                dwarf.parent.mkdir(parents=True);dwarf.write_bytes(b'generated symbols')
            def validate(binary,bundle):
                if binary.name=='CrashReporter':raise ValueError('Helper/dSYM UUID mismatch')
                return dict(UUIDs={'arm64':'00000000-0000-0000-0000-000000000001'},hasCompileUnits=True)
            with mock.patch.object(symbols,'validate',side_effect=validate):
                result=symbols.inspect_archive(archive)
            self.assertFalse(result['passed'])
            self.assertTrue(all(row['passed'] for row in result['helpers']))
            self.assertEqual([row['image'] for row in result['images']],['Traverse','CrashReporter'])
            self.assertTrue(result['images'][0]['passed'])
            self.assertFalse(result['images'][1]['passed'])


if __name__ == '__main__':
    unittest.main()
