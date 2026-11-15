"""Architecture admission and cross-build cache/product boundaries."""
from pathlib import Path
import unittest
from unittest.mock import patch

from build_architecture import named, selected, direct_app_architecture


class ArchitectureTests(unittest.TestCase):
    def test_cross_build_uses_intel_standard_library_and_product(self):
        with patch("build_architecture.platform.machine", return_value="arm64"):
            intel = selected({"TRAVERSE_BUILD_ARCH": "x86_64", "ARCHS": "x86_64"})
            self.assertEqual(intel.cargo_arguments(), ["--target", "x86_64-apple-darwin"])
            self.assertEqual(intel.cargo_product(Path("cache"), "worker"),
                             Path("cache/x86_64-apple-darwin/release/worker"))

    def test_native_intel_build_uses_native_cargo_output(self):
        with patch("build_architecture.platform.machine", return_value="x86_64"):
            self.assertEqual(selected({}).cargo_product(Path("cache"), "worker"),
                             Path("cache/release/worker"))

    def test_architecture_caches_do_not_replace_each_other(self):
        self.assertEqual(named("arm64").cache_directory(Path("cache")), Path("cache"))
        self.assertEqual(named("x86_64").cache_directory(Path("cache")), Path("cache/x86_64"))

    def test_direct_feed_lane_keeps_old_arm_clients_separate_from_intel(self):
        self.assertEqual(direct_app_architecture({}).name, "arm64")
        self.assertEqual(named("arm64").direct_update_lane, "direct-updates")
        self.assertEqual(named("x86_64").direct_update_lane, "direct-updates-intel")
        for invalid in ("universal", "../direct-updates", None, 1):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                direct_app_architecture({"TraverseDirectArchitecture": invalid})

    def test_mixed_app_and_helper_or_universal_selection_is_refused(self):
        for env in ({"TRAVERSE_BUILD_ARCH": "x86_64", "ARCHS": "arm64"},
                    {"ARCHS": "arm64 x86_64"}, {"TRAVERSE_BUILD_ARCH": "../arm64"},
                    {"TRAVERSE_BUILD_ARCH": ""}, {"ARCHS": "i386"}):
            with self.subTest(env=env), self.assertRaises(ValueError):
                selected(env)


if __name__ == "__main__":
    unittest.main()
