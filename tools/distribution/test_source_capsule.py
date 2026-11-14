"""Generated private-source copies, refusal paths and real replacement races."""
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest
from unittest import mock
import uuid
from distribution import source_capsule as capsule
from distribution import source_release
from distribution import source_kit
from distribution.traverse import sources
from native_build_inputs import source_inputs


class SourceManifestTests(unittest.TestCase):
    def test_retained_export_requires_full_offline_matching_dependency_configuration(self):
        selected, head = 'a'*40, 'b'*40
        def generated(name):
            return b'Generated notice.\n'*110_000 if name == 'Distribution/ThirdPartyNotices.txt' \
                else ('Generated '+name).encode()
        def git(*args):
            if args == ('rev-parse', 'HEAD'):
                return head.encode()+b'\n'
            if args[0] == 'status':
                return b''
            if args[0] == 'merge-base':
                self.assertEqual(args, ('merge-base', '--is-ancestor', selected, head))
                return b''
            self.assertEqual(args[0], 'show')
            return generated(args[1].split(':',1)[1])
        def read(path, maximum):
            data = generated(str(path.relative_to(source_release.ROOT)))
            if len(data) > maximum:
                raise RuntimeError('Generated dependency file exceeds read bound')
            return data
        with mock.patch.object(source_release, 'git', side_effect=git), \
                mock.patch.object(source_release, 'read', side_effect=read):
            context = source_release.export_context(selected, 'full', False)
            self.assertEqual(context['checkoutCommit'], head)
            self.assertEqual(set(context['dependencyConfigurationSHA256']), set(source_release.DEPENDENCY_CONFIGURATION))
            for selection, fetch in (('contributor-v1', False), ('full', True)):
                with self.assertRaisesRegex(RuntimeError, 'full offline'):
                    source_release.export_context(selected, selection, fetch)
            with mock.patch.object(source_release, 'read', return_value=b'Changed dependency pin.'), \
                    self.assertRaisesRegex(RuntimeError, 'configuration differs'):
                source_release.export_context(selected, 'full', False)
            def unrelated(*args):
                if args[0] == 'merge-base':
                    raise subprocess.CalledProcessError(1, ['git', *args])
                return git(*args)
            with mock.patch.object(source_release, 'git', side_effect=unrelated), \
                    self.assertRaisesRegex(RuntimeError, 'must be an ancestor'):
                source_release.export_context(selected, 'full', False)

    def test_contributor_selection_keeps_build_tests_and_tools_but_classifies_history(self):
        repo = Path(__file__).resolve().parents[2]
        policy = json.loads((repo/'Distribution/SourceSelection.json').read_text())
        tracked = source_release.committed_files('HEAD')
        selected, paths, receipt = source_release.contributor_selection(tracked, policy)
        self.assertLessEqual(set(source_inputs()), set(selected))
        for tree in ('App/', 'Packages/', 'Workers/', 'Vendor/', 'Distribution/', 'tools/'):
            self.assertEqual({name for name in tracked if name.startswith(tree)},
                             {name for name in selected if name.startswith(tree)})
        # A cleaned contributor tree can select every committed file. Internal
        # reports must not be kept merely to manufacture an omitted member.
        self.assertTrue(all(name.startswith(('docs/', 'Prototypes/')) for name in receipt['omittedGitObjects']))
        self.assertFalse(set(selected) & set(receipt['omittedGitObjects']))
        self.assertEqual(set(selected) | set(receipt['omittedGitObjects']), set(tracked))
        self.assertEqual(len(paths), len(set(paths)))
        with self.assertRaisesRegex(RuntimeError, 'new path'):
            source_release.contributor_selection({**tracked, 'NewWorker/Main.swift': '0'*40}, policy)

    def test_contributor_selection_refuses_missing_inputs_and_nonliteral_paths(self):
        repo = Path(__file__).resolve().parents[2]
        policy = json.loads((repo/'Distribution/SourceSelection.json').read_text())
        tracked = source_release.committed_files('HEAD')
        for invalid in ('../App', '/App', 'App//Source', 'App/*', 'App\\Source'):
            changed = {**policy, 'retainedTrees': [invalid]}
            with self.subTest(path=invalid), self.assertRaisesRegex(RuntimeError, 'canonical literal'):
                source_release.contributor_selection(tracked, changed)
        changed = {**policy, 'retainedFiles': [*policy['retainedFiles'], 'Missing.md']}
        with self.assertRaisesRegex(RuntimeError, 'missing'):
            source_release.contributor_selection(tracked, changed)

    def test_xcode_output_file_lists_enter_native_inventory_and_capsule_policy(self):
        repo = Path(__file__).resolve().parents[2]
        recorded = source_inputs()
        for name in ('App/Config/BundleOutputs-network.xcfilelist',
                     'App/Config/BundleOutputs-local-only.xcfilelist'):
            with self.subTest(name=name):
                self.assertEqual(recorded[name], hashlib.sha256((repo/name).read_bytes()).hexdigest())
                self.assertEqual(capsule.manifest({name: recorded[name]}), {name: recorded[name]})

    def test_only_bounded_canonical_recorded_source_paths(self):
        digest = hashlib.sha256(b'').hexdigest()
        self.assertEqual(capsule.manifest({'App/Empty.swift': digest}), {'App/Empty.swift': digest})
        for name in capsule.WORKER_INPUTS:
            self.assertEqual(capsule.manifest({name: digest}), {name: digest})
        for name in capsule.RELEASE_INPUTS:
            self.assertEqual(capsule.manifest({name: digest}), {name: digest})
        for name in capsule.EXACT_BUILD_RESOURCES:
            self.assertEqual(capsule.manifest({name: digest}), {name: digest})
        for path in ['../App/F.swift', '/App/F.swift', 'App/../F.swift', 'App//F.swift', 'App/./F.swift',
                     'App/F.swift\n', 'App\\F.swift', 'Personal/F.swift', 'App/key.pem', 'App/F.txt', 'Workers/Private.json',
                     'Distribution/PrivateSecrets.json', 'Distribution/Other.txt', 'Distribution/Other.xcprivacy',
                     'App/MacExplorer/Resources/Other.icns', 'Vendor/smb2/Other.json',
                     'Vendor/smb2/Other.patch',
                     'Vendor/smb2/Other.swift', 'MacExplorer.xcodeproj/Other.swift',
                     'MacExplorer.xcodeproj/Other.pbxproj', 'MacExplorer.xcodeproj/Package.resolved', 'App']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                capsule.manifest({path: digest})
        for value in [{}, [], {'App/F.swift': 'x'*64}, {'App/F.swift': digest.upper()},
                      {'App/'+str(i)+'.swift': digest for i in range(2049)}]:
            with self.assertRaises(ValueError):
                capsule.manifest(value)

    def test_current_archive_input_inventory_fits_the_exact_capsule_policy(self):
        wanted = sources()
        repo = Path(__file__).resolve().parents[2]
        self.assertEqual(capsule.manifest(wanted), wanted)
        self.assertTrue(capsule.EXACT_BUILD_RESOURCES - {
            'MacExplorer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'} <= set(wanted))
        self.assertLessEqual(sum((repo / name).stat().st_size for name in wanted), capsule.MAX_SOURCE_BYTES)
        for name in wanted:
            with self.subTest(name=name):
                self.assertLessEqual((repo / name).stat().st_size, capsule.file_limit(name))


class SourceKitTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]/'.build/fixtures'/('source-kit-'+str(uuid.uuid4()))
        self.root.mkdir(mode=0o700, parents=True)

    def tearDown(self):
        result = self._outcome.result
        if not any(test is self for test, _ in result.errors + result.failures):
            shutil.rmtree(self.root)

    def archive(self, values):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as archive:
            for name, body in sorted(values.items()):
                member = tarfile.TarInfo(name)
                member.size = len(body)
                archive.addfile(member, io.BytesIO(body))
        return output.getvalue()

    def fixture(self):
        commit = 'a'*40
        sdks = []
        artifacts = {'WorkerDependencies.tar.gz': self.archive({'CargoCaches/README': b'Generated only.'})}
        for index, name in enumerate(('Sparkle', 'swift-argument-parser')):
            revision = str(index + 1)*40
            filename = name+'-'+revision+'.tar.gz'
            body = self.archive({name+'-'+revision+'/LICENSE': b'Generated license fixture.'})
            artifacts[filename] = body
            sdks.append({'name': name, 'commit': revision, 'filename': filename,
                         'sha256': hashlib.sha256(body).hexdigest()})
        project = {'LICENSE': b'Generated license fixture.\n',
                   'Distribution/ThirdPartyNotices.txt': b'Generated notices.\n',
                   'Distribution/SourceDependencies.json': json.dumps({'schema': 1, 'components': sdks}).encode(),
                   'App/Main.swift': b'// Generated source.\n'}
        retained = {name: hashlib.sha1(b'blob '+str(len(body)).encode()+b'\0'+body).hexdigest()
                    for name, body in project.items()}
        artifacts['Traverse-project-source.tar.gz'] = self.archive(
            {'Traverse-'+commit[:12]+'/'+name: body for name, body in project.items()})
        artifacts['source-selection.json'] = json.dumps({'name': 'full',
            'retainedGitObjects': retained, 'omittedGitObjects': {}}).encode()
        manifest = {'schema': 1, 'prepared': True, 'published': False, 'sourceCommit': commit,
                    'sourceSelection': 'full', 'projectFiles': len(project), 'sdkSources': sdks,
                    'privacyReview': 'NOT EXERCISED', 'cleanExportBuild': 'NOT EXERCISED',
                    'binaryCorrespondence': 'NOT EXERCISED', 'files': {
                        name: {'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
                        for name, body in artifacts.items()}}
        artifacts['source-manifest.json'] = json.dumps(manifest).encode()
        for name, body in artifacts.items():
            (self.root/name).write_bytes(body)
        return artifacts, project

    def test_one_transparent_deterministic_kit_preserves_original_export_and_claims(self):
        original, project = self.fixture()
        path = source_kit.create_source_kit(self.root)
        result = source_kit.inspect_source_kit(path)
        self.assertEqual(result['format'], 'traverse-source-kit-v1')
        self.assertEqual(result['projectSourceSHA256'],
                         {name: hashlib.sha256(body).hexdigest() for name, body in project.items()})
        self.assertEqual(result['sourceManifestSHA256'], hashlib.sha256(original['source-manifest.json']).hexdigest())
        for key in ('privacyReview', 'cleanExportBuild', 'binaryCorrespondence'):
            self.assertEqual(result[key], 'NOT EXERCISED')
        for name, body in original.items():
            self.assertEqual((self.root/name).read_bytes(), body)
        other = self.root/'second'
        other.mkdir()
        for name, body in original.items():
            (other/name).write_bytes(body)
        self.assertEqual(source_kit.create_source_kit(other).read_bytes(), path.read_bytes())
        with self.assertRaises(FileExistsError):
            source_kit.create_source_kit(self.root)
        with tarfile.open(path, 'r:gz') as archive:
            self.assertEqual(len(archive.getmembers()), 9)
            self.assertFalse(any(member.name.endswith('/source-kit.json') for member in archive))

    def test_changed_git_bytes_licenses_members_and_oversized_kit_refuse(self):
        original, _ = self.fixture()
        path = source_kit.create_source_kit(self.root)
        with tarfile.open(path, 'r:gz') as archive:
            values = {member.name: archive.extractfile(member).read() for member in archive}
        root = 'Traverse-source-'+'a'*12+'/'
        for label, changed in (
                ('license', {**values, root+'LICENSE': b'Changed license.'}),
                ('extra', {**values, root+'extra.txt': b'Unexpected.'}),
                ('traversal', {**values, root+'../extra.txt': b'Unexpected.'})):
            candidate = self.root/(label+'.tar.gz')
            candidate.write_bytes(self.archive(changed))
            with self.subTest(label=label), self.assertRaises(RuntimeError):
                source_kit.inspect_source_kit(candidate)
        with mock.patch.object(source_kit, 'MAX_KIT_BYTES', 4), self.assertRaises(RuntimeError):
            source_kit.inspect_source_kit(path)
        appended = self.root/'appended.tar.gz'
        appended.write_bytes(path.read_bytes()+gzip.compress(b'Generated extra bytes after tar EOF.'))
        with self.assertRaisesRegex(RuntimeError, 'after source archive end'):
            source_kit.inspect_source_kit(appended)
        with tarfile.open(fileobj=io.BytesIO(original['Traverse-project-source.tar.gz']), mode='r:gz') as archive:
            project = {member.name: archive.extractfile(member).read() for member in archive}
        project['Traverse-'+'a'*12+'/App/Main.swift'] = b'// Changed after export.\n'
        changed = self.archive(project)
        (self.root/'Traverse-project-source.tar.gz').write_bytes(changed)
        manifest = json.loads(original['source-manifest.json'])
        manifest['files']['Traverse-project-source.tar.gz'] = {'bytes': len(changed), 'sha256': hashlib.sha256(changed).hexdigest()}
        (self.root/'source-manifest.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError, 'Git object'):
            source_kit.create_source_kit(self.root)


class SourceCapsuleTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ['TRAVERSE_CAPSULE_TEST_ROOT'])
        self.assertEqual(root.resolve(), root)
        self.assertEqual(root.name, 'source')
        self.assertTrue((root.parent/'reservation.json').is_file())
        self.root = root/str(uuid.uuid4()).upper()
        self.root.mkdir(mode=0o700)
        (self.root/'App').mkdir(mode=0o700)
        self.source = self.root/'App/Report.swift'
        self.data = b'// Generated source only.\nstruct Report {}\n'
        self.source.write_bytes(self.data)
        self.wanted = {'App/Report.swift': hashlib.sha256(self.data).hexdigest()}
        self.output = self.root/'Private.tar.gz'

    def test_xcode_output_file_list_copy_is_hash_bound(self):
        name = 'App/Config/BundleOutputs-network.xcfilelist'
        source = self.root/name
        source.parent.mkdir(mode=0o700)
        source.write_bytes(b'$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/storage-scanner-worker\n')
        wanted = {name: hashlib.sha256(source.read_bytes()).hexdigest()}
        result = capsule.create(self.root, wanted, self.output)
        self.assertTrue(capsule.inspect(self.output, wanted, result['sha256'])['passed'])
        source.write_bytes(b'$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/changed-worker\n')
        with self.assertRaises(ValueError):
            capsule.create(self.root, wanted, self.root/'Changed.tar.gz')

    def test_exact_private_copy_independent_member_check_and_no_extraction(self):
        # Relative CLI paths resolve once at the boundary; all no-follow/hash
        # checks still operate on the exact absolute owned directory.
        with mock.patch('os.getcwd', return_value=str(self.root)):
            result = capsule.create(Path('.'), self.wanted, Path('Private.tar.gz'))
            self.assertTrue(capsule.inspect(Path('Private.tar.gz'), self.wanted, result['sha256'])['passed'])
        before = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob('*'))
        checked = capsule.inspect(self.output, self.wanted, result['sha256'])
        self.assertEqual(capsule.inspect_payload(self.output.read_bytes(), self.wanted, result['sha256']), checked)
        self.assertEqual(checked['files'], 1)
        self.assertEqual(checked['extractedFiles'], 0)
        self.assertEqual(checked['sourceBytes'], len(self.data))
        with tarfile.open(self.output, 'r:gz') as archive:
            entry = archive.getmember('App/Report.swift')
            self.assertEqual((entry.uid, entry.gid, entry.mtime, entry.uname), (0, 0, 0, ''))
            self.assertEqual(archive.extractfile(entry).read(), self.data)
        self.assertEqual(before, sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob('*')))
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_deterministic_payload_and_no_overwrite(self):
        first = capsule.create(self.root, self.wanted, self.output)
        second_path = self.root/'Second.tar.gz'
        second = capsule.create(self.root, self.wanted, second_path)
        self.assertEqual(first, second)
        with self.assertRaises(FileExistsError):
            capsule.create(self.root, self.wanted, self.output)
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), first['sha256'])

    def test_changed_source_keeps_partial_evidence_and_never_reports_success(self):
        self.source.write_bytes(b'// Generated replacement.\n')
        with self.assertRaises(ValueError):
            capsule.create(self.root, self.wanted, self.output)
        self.assertTrue(self.output.is_file())

    def test_explicit_recovery_must_still_match_original_hash(self):
        preserved = self.root/'Preserved.swift'
        preserved.write_bytes(self.data)
        self.source.write_bytes(b'// Later generated validator revision.\n')
        result = capsule.create(self.root, self.wanted, self.output,
            {'App/Report.swift': (self.root, 'Preserved.swift')})
        self.assertTrue(capsule.inspect(self.output, self.wanted, result['sha256'])['passed'])
        with self.assertRaises(ValueError):
            capsule.create(self.root, self.wanted, self.root/'Unrecorded.tar.gz',
                {'App/Other.swift': (self.root, 'Preserved.swift')})

    def test_each_and_combined_source_bounds_stop_before_admission(self):
        with mock.patch.object(capsule, 'MAX_FILE_BYTES', 3), self.assertRaises(ValueError):
            capsule.create(self.root, self.wanted, self.output)
        with mock.patch.object(capsule, 'MAX_SOURCE_BYTES', 3), self.assertRaises(ValueError):
            capsule.create(self.root, self.wanted, self.root/'Total.tar.gz')
        with mock.patch.object(capsule, 'MAX_ARCHIVE_BYTES', 3), self.assertRaises(ValueError):
            capsule.create(self.root, self.wanted, self.root/'Archive.tar.gz')

    def test_only_the_exact_icon_and_notices_paths_get_the_larger_file_bound(self):
        for index, name in enumerate(sorted(capsule.LARGE_INPUTS)):
            with self.subTest(name=name), mock.patch.object(capsule, 'MAX_FILE_BYTES', 3), \
                    mock.patch.object(capsule, 'MAX_LARGE_FILE_BYTES', 6):
                source = self.root / name
                source.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source.write_bytes(b'ABCD')
                wanted = {name: hashlib.sha256(b'ABCD').hexdigest()}
                output = self.root / f'Large-{index}.tar.gz'
                created = capsule.create(self.root, wanted, output)
                self.assertTrue(capsule.inspect(output, wanted, created['sha256'])['passed'])
        with self.assertRaises(ValueError):
            capsule.manifest({'App/MacExplorer/Resources/Other.icns': hashlib.sha256(b'ABCD').hexdigest()})

    def test_symlink_special_file_and_redirected_parent_refuse(self):
        (self.root/'Link.swift').symlink_to(self.source)
        os.mkfifo(self.root/'Pipe.swift', 0o600)
        (self.root/'Redirect').symlink_to(self.root/'App', target_is_directory=True)
        for relative in ['Link.swift', 'Pipe.swift', 'App', 'Redirect/Report.swift']:
            with self.subTest(relative=relative), self.assertRaises((ValueError, OSError)):
                capsule.read_at(self.root, relative, 1024)

    def test_hardlinked_source_is_refused(self):
        os.link(self.source, self.root/'App/Linked.swift')
        with self.assertRaises(ValueError):
            capsule.read_at(self.root, 'App/Report.swift', 1024)

    def test_byte_identical_file_replacement_is_detected(self):
        replacement = self.root/'Replacement.swift'
        replacement.write_bytes(self.data)
        original = os.read
        switched = False
        def read(fd, length):
            nonlocal switched
            data = original(fd, length)
            if not switched:
                switched = True
                os.replace(replacement, self.source)
            return data
        with mock.patch.object(capsule.os, 'read', side_effect=read), self.assertRaises(ValueError):
            capsule.read_at(self.root, 'App/Report.swift', 1024)

    def test_replaced_parent_is_detected_even_when_open_file_is_unchanged(self):
        original = os.read
        switched = False
        def read(fd, length):
            nonlocal switched
            data = original(fd, length)
            if not switched:
                switched = True
                (self.root/'App').rename(self.root/'OldApp')
                (self.root/'App').mkdir(mode=0o700)
                (self.root/'App/Report.swift').write_bytes(self.data)
            return data
        with mock.patch.object(capsule.os, 'read', side_effect=read), self.assertRaises(ValueError):
            capsule.read_at(self.root, 'App/Report.swift', 1024)

    def test_unbound_capsule_is_refused_before_any_archive_parser(self):
        self.output.write_bytes(b'Generated bytes, not an archive.')
        with mock.patch.object(capsule.tarfile, 'open') as parser, self.assertRaises(ValueError):
            capsule.inspect(self.output, self.wanted, '0'*64)
        parser.assert_not_called()

    def test_missing_or_different_recorded_member_is_not_a_complete_snapshot(self):
        result = capsule.create(self.root, self.wanted, self.output)
        different = dict(self.wanted, **{'App/Other.swift': hashlib.sha256(b'').hexdigest()})
        with self.assertRaises(ValueError):
            capsule.inspect(self.output, different, result['sha256'])
        with self.assertRaises(ValueError):
            capsule.inspect(self.output, {'App/Report.swift': '0'*64}, result['sha256'])


if __name__ == '__main__':
    unittest.main()
