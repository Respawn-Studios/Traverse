import os
from pathlib import Path
import stat
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest import mock

import dev
from worker_setup import require_public_lock, run


class WorkerSetupTests(unittest.TestCase):
    def test_fetch_admission_refuses_nonpublic_and_ambiguous_sources(self):
        require_public_lock(b'[[package]]\nname = "generated"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n')
        for source in [b'', b'[[package]]\nsource = "git+https://example.invalid/private"\n',
                       b'[[package]]\nsource = "registry+https://example.invalid/private"\n',
                       b'[[package]]\nsource = "one"\nsource = "two"\n']:
            with self.subTest(source=source), self.assertRaises((RuntimeError, ValueError)):
                require_public_lock(source)

    def test_capture_drains_both_pipes_and_refuses_excess_output(self):
        environment = {"PATH": "/usr/bin:/bin"}
        value = run([sys.executable, "-c", "import sys;sys.stderr.write('generated diagnostic');print('ready')"], environment)
        self.assertEqual(value, b'ready\n')
        with self.assertRaisesRegex(RuntimeError, "output exceeded"):
            run([sys.executable, "-c", "import os;os.write(1,b'x'*(5<<20))"], environment)


class DevelopmentRuntimeDirectoryTests(unittest.TestCase):
    def test_only_exact_owned_runtime_leaves_are_tightened_without_following_links(self):
        with TemporaryDirectory(prefix="private-runtime-", dir=dev.local_directory("test-fixtures")) as temporary:
            root = Path(temporary)
            unrelated = root / "unrelated"
            unrelated.mkdir(mode=0o755)
            unrelated.chmod(0o755)
            with mock.patch.object(dev, "BUILD", root):
                with self.assertRaises(ValueError):
                    dev.private_runtime_directory("unrelated")
                for name in ("runtime", "runtime-cache"):
                    leaf = root / name
                    leaf.mkdir(mode=0o755)
                    leaf.chmod(0o755)
                    self.assertEqual(dev.private_runtime_directory(name), leaf)
                    self.assertEqual(stat.S_IMODE(leaf.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(unrelated.stat().st_mode), 0o755)
                (root / "runtime").rmdir()
                (root / "runtime").symlink_to(unrelated, target_is_directory=True)
                with self.assertRaises(ValueError):
                    dev.private_runtime_directory("runtime")
                self.assertEqual(stat.S_IMODE(unrelated.stat().st_mode), 0o755)
                with mock.patch.object(dev.os, "geteuid", return_value=os.geteuid() + 1):
                    with self.assertRaisesRegex(ValueError, "different owner"):
                        dev.private_runtime_directory("runtime-cache")
