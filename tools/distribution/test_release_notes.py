import copy
import json
import unittest
import release_notes as notes

class ReleaseHistoryTests(unittest.TestCase):
    def setUp(self):self.catalog=notes.read()
    def rejects(self,value):
        with self.assertRaises((ValueError,TypeError,KeyError)):notes.decode(json.dumps(value).encode())
    def test_first_public_version_preserves_prior_beta_history(self):
        notes.verify_bundled()
        newest = self.catalog['releases'][0]
        self.assertEqual((newest['version'], newest['build']), ('0.1.0', 93))
        self.assertEqual(newest['state'], 'published')
        published = notes.release_for_build(self.catalog, '0.1.4', '69')
        self.assertEqual(published['build'], 69)
        self.assertEqual(published['state'], 'published')
    def test_duplicate_or_reordered_build_refused(self):
        newest=self.catalog['releases'][0]
        for key,value in [('build',newest['build']),('build',newest['build']+1)]:
            case=copy.deepcopy(self.catalog);case['releases'][1][key]=value;self.rejects(case)
    def test_repeated_display_versions_keep_distinct_machine_builds(self):
        case=copy.deepcopy(self.catalog)
        case['releases'][1]['version']=case['releases'][0]['version']
        decoded=notes.decode(json.dumps(case).encode())
        for entry in decoded['releases'][:2]:
            self.assertIs(notes.release_for_build(decoded, entry['version'], entry['build']), entry)
        self.assertIsNone(notes.release_for_build(decoded, '0.1.0', '999999'))
        for build in [True, '092', '', -1]:
            with self.assertRaises(ValueError):notes.release_for_build(decoded, '0.1.0', build)
    def test_wrong_date_and_date_reversal_refused(self):
        for value in ['2026-02-30','2026-1-2','2026-12-01']:
            case=copy.deepcopy(self.catalog);case['releases'][1]['date']=value;self.rejects(case)
    def test_unknown_states_or_private_fields_refused(self):
        case=copy.deepcopy(self.catalog);case['releases'][0]['state']='released';self.rejects(case)
        case=copy.deepcopy(self.catalog);case['releases'][0]['credential']='secret';self.rejects(case)
    def test_unbounded_or_control_text_refused(self):
        for value in ['x'*1001,'bad\x00value','bad\nvalue']:
            case=copy.deepcopy(self.catalog);case['releases'][0]['changes']=[value];self.rejects(case)
    def test_boolean_build_is_not_a_version(self):
        case=copy.deepcopy(self.catalog);case['releases'][0]['build']=True;self.rejects(case)

if __name__=='__main__':unittest.main()
