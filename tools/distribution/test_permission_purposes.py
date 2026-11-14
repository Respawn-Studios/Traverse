"""Pure metadata controls: no prompts, files, network or credential changes."""
from pathlib import Path
import plistlib
import unittest
import preflight


class PermissionPurposes(unittest.TestCase):
    def test_each_enabled_scope_requires_a_real_explanation(self):
        valid = {key: 'An explicit generated feature purpose.' for key in preflight.PERMISSION_PURPOSES}
        self.assertTrue(all(row['passed'] for row in preflight.permission_purpose_checks(valid)))
        for key in preflight.PERMISSION_PURPOSES:
            for missing in [None, '', '  ', False, 1, 'x' * 513]:
                with self.subTest(key=key, value=type(missing).__name__):
                    changed = {**valid, key: missing}
                    self.assertFalse(all(row['passed'] for row in preflight.permission_purpose_checks(changed)))

    def test_both_app_compositions_keep_the_same_scope_explanations(self):
        root = Path(__file__).resolve().parents[2]
        for name in ['Distribution/TraverseInfo.plist', 'App/MacExplorer/Info.plist']:
            info = plistlib.loads((root / name).read_bytes())
            self.assertTrue(all(row['passed'] for row in preflight.permission_purpose_checks(info)), name)

    def test_parent_and_helpers_keep_the_existing_access_boundary(self):
        root = Path(__file__).resolve().parents[2]
        parent = plistlib.loads((root/'Distribution/AppStoreParent.entitlements').read_bytes())
        helper = plistlib.loads((root/'Distribution/HelperInherit.entitlements').read_bytes())
        self.assertEqual(set(parent), preflight.PARENT_RIGHTS)
        self.assertTrue(all(row['passed'] for row in preflight.entitlement_checks(parent, {'generated': helper})))


if __name__ == '__main__':
    unittest.main()
