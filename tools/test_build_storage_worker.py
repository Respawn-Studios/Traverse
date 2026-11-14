#!/usr/bin/env python3
"""Mocked cache/refusal tests, not native compiler or signing qualification.

All generated files stay in one owned TemporaryDirectory per test below this
repository's .build/test-fixtures. Failed fixtures are retained for inspection.
"""
from __future__ import annotations

from contextlib import ExitStack
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
import build_storage_worker as worker


class StorageWorkerBuildCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        parent = worker.ROOT / ".build/test-fixtures"
        parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="storage-worker-cache-", dir=parent)
        self.root = Path(self.temporary.name)
        self.addCleanup(self.finish_fixture)
        self.patches = ExitStack(); self.addCleanup(self.patches.close)
        self.source = self.root / "source"; self.source.mkdir()
        self.output = self.root / "output"
        self.rustc = self.root / "mock-rustc"; self.rustc.write_bytes(b"mock compiler identity\n")
        self.clang = self.root / "mock-clang"; self.clang.write_bytes(b"mock clang identity\n")
        self.sdk = self.root / "Mock.sdk"; self.sdk.mkdir()
        (self.sdk / "SDKSettings.plist").write_bytes(b"mock sdk settings\n")
        self.sdk_query_path = self.sdk
        self.inputs = {
            "main.rs": b'const VECTORS: &str = include_str!("policy-vectors.tsv");\nfn main() {}\n',
            "policy.rs": b"pub const REVISION: &str = \"local-metadata-v1\";\n",
            "ScannerNative.c": b'#include "ScannerNative.h"\n',
            "ScannerNative.h": b"/* generated mock native input */\n",
            "policy-vectors.tsv": b"d\t0\t/Generated/Ordinary\n",
        }
        for name, data in self.inputs.items(): (self.source / name).write_bytes(data)
        for name, value in [("SOURCE", self.source), ("OUTPUT", self.output), ("RUSTC", self.rustc)]:
            self.patches.enter_context(mock.patch.object(worker, name, value))
        # Mock call records must never copy the invoking shell's environment.
        self.patches.enter_context(mock.patch.dict(worker.os.environ, {"LANG": "C", "LC_ALL": "C"}, clear=True))
        self.compiler_queries = self.patches.enter_context(
            mock.patch.object(worker.subprocess, "check_output", side_effect=self.fake_query))
        self.compiler_runs = self.patches.enter_context(
            mock.patch.object(worker.subprocess, "run", side_effect=self.fake_compile))
        self.change_source_during_compile = False

    def fake_query(self, argv, **kwargs):
        if argv == ["/usr/bin/xcrun", "--show-sdk-path"]: return str(self.sdk_query_path) + "\n"
        if argv == ["/usr/bin/xcrun", "--find", "clang"]: return str(self.clang) + "\n"
        if argv == ["/usr/bin/xcrun", "--show-sdk-version"]: return "26.0\n"
        if argv == ["/usr/bin/xcodebuild", "-version"]: return "Xcode mock\nBuild 1\n"
        if argv == [str(self.rustc), "-vV"]: return "rustc 1.99.1 (mock only)\nhost: aarch64-apple-darwin\n"
        if argv == [str(self.clang), "--version"]: return "Apple clang mock\n"
        raise AssertionError("Unexpected external query: " + repr(argv))

    def fake_compile(self, argv, **kwargs):
        self.assertTrue(kwargs.get("check"))
        if len(argv) > 2 and argv[0] == sys.executable and str(argv[2]).endswith("build_network_helpers.py"):
            return subprocess.CompletedProcess(argv, 0)
        destination = Path(argv[argv.index("-o") + 1])
        self.assertIn(destination, [self.output / "ScannerNative.o", self.output / "storage-scanner-worker"])
        if argv[0] == "/usr/bin/clang":
            destination.write_bytes(b"mock object; no compiler executed\n")
            if self.change_source_during_compile:
                with (self.source / "main.rs").open("ab") as output: output.write(b"// concurrent edit\n")
        elif argv[0] == str(self.rustc):
            # Mock output depends on every compiled fixture input. This is a
            # deterministic stub, not a model of native code generation.
            payload = b"".join((self.source / name).read_bytes() for name in sorted(self.inputs))
            destination.write_bytes(b"mock executable\n" + hashlib.sha256(payload).digest())
        else: raise AssertionError("Unexpected compiler invocation")
        return subprocess.CompletedProcess(argv, 0)

    def tearDown(self) -> None:
        paths = list(self.root.rglob("*"))
        self.assertLess(len(paths) + 1, 30, "Owned test fixture exceeded entry bound")
        logical = sum(p.lstat().st_size for p in paths if stat.S_ISREG(p.lstat().st_mode))
        self.assertLess(logical, 64 << 10, "Owned test fixture exceeded data bound")

    def finish_fixture(self) -> None:
        result = self._outcome.result
        failures = list(result.failures) + list(result.errors)
        # Python3.9 queues errors on _Outcome until after cleanups; newer
        # unittest versions may already have fed them into the result. The first
        # RED fixture was inadvertently cleaned before this compatibility guard;
        # the same dangling-link failure was reproduced and retained afterward.
        failures += [(case, error) for case, error in getattr(self._outcome, "errors", []) if error is not None]
        failed = any(case is self or getattr(case, "test_case", None) is self for case, _ in failures)
        if failed:
            # TemporaryDirectory's finalizer would otherwise erase RED evidence
            # when this TestCase or the interpreter is released.
            self.temporary._finalizer.detach()
            print("Retained failed owned fixture: " + str(self.root), file=sys.stderr)
        else: self.temporary.cleanup()

    def test_unchanged_input_hits_cache(self) -> None:
        binary = worker.build()
        self.assertEqual(self.compiler_runs.call_count, 2)
        receipt = json.loads((self.output / "build.json").read_text())
        self.assertIn("policy-vectors.tsv", receipt["input"]["sources"])
        self.compiler_runs.reset_mock()
        self.assertEqual(worker.build(), binary)
        self.assertEqual(self.compiler_runs.call_count, 0)
        self.assertEqual(worker.sha(binary), receipt["binary_sha256"])

    def test_release_rust_path_arguments_invalidate_cache(self) -> None:
        worker.build()
        ordinary = json.loads((self.output / "build.json").read_text())["input"]
        self.assertNotIn("rustSourcePath", ordinary)
        self.compiler_runs.reset_mock()
        with mock.patch.object(worker.helper_symbols, "requested", return_value=True), \
                mock.patch.object(worker.helper_symbols, "validate", return_value={}):
            worker.build()
        self.assertEqual(self.compiler_runs.call_count, 2)
        release = json.loads((self.output / "build.json").read_text())["input"]
        policy = worker.helper_symbols.rust_source_path_fingerprint(True)["rustSourcePath"]
        self.assertEqual(release["rustSourcePath"], policy)
        command = self.compiler_runs.call_args_list[-1].args[0]
        self.assertEqual(command[0], str(self.rustc))
        self.assertIn(policy["arguments"][0], command)
        self.assertNotIn("RUSTFLAGS", self.compiler_runs.call_args_list[-1].kwargs["env"])

        with mock.patch.object(worker.helper_symbols, "REPO", Path("/tmp/source with spaces")):
            flags = worker.helper_symbols.rust_source_path_arguments(True)
            cargo_env = {}
            worker.helper_symbols.apply_cargo_rust_source_path_policy(cargo_env, True)
            self.assertEqual(cargo_env, {"CARGO_ENCODED_RUSTFLAGS": "\x1f".join(flags)})
            with self.assertRaisesRegex(ValueError, "Unreviewed Rust flags"):
                worker.helper_symbols.apply_cargo_rust_source_path_policy({"RUSTFLAGS": "-C opt-level=0"}, True)

    def test_tsv_input_invalidates_cached_binary(self) -> None:
        binary = worker.build(); first = worker.sha(binary)
        prior = json.loads((self.output / "build.json").read_text())
        (self.source / "policy-vectors.tsv").write_bytes(b"d\t1\t/Generated/Excluded\n")
        self.compiler_runs.reset_mock()
        self.assertEqual(worker.build(), binary)
        self.assertEqual(self.compiler_runs.call_count, 2)
        current = json.loads((self.output / "build.json").read_text())
        self.assertNotEqual(prior["input"]["sources"]["policy-vectors.tsv"], current["input"]["sources"]["policy-vectors.tsv"])
        self.assertNotEqual(first, current["binary_sha256"])
        self.assertEqual(current["binary_sha256"], worker.sha(binary))

    def test_selected_compiler_or_sdk_change_invalidates_cache(self) -> None:
        worker.build()
        for path in [self.clang, self.sdk / "SDKSettings.plist"]:
            with self.subTest(path=path.name):
                self.compiler_runs.reset_mock()
                with path.open("ab") as output: output.write(b"changed\n")
                worker.build()
                self.assertEqual(self.compiler_runs.call_count, 2)

    def test_sdk_alias_reuses_cache_but_changed_target_invalidates_it(self) -> None:
        binary = worker.build()
        original = json.loads((self.output / "build.json").read_text())["input"]
        alias = self.root / "MacOSX.sdk"
        alias.symlink_to(self.sdk, target_is_directory=True)
        self.sdk_query_path = alias
        fingerprint, sdk, env = worker.current_input(symbols=False)
        self.assertEqual(fingerprint, original)
        self.assertEqual(sdk, str(self.sdk.resolve(strict=True)))
        self.assertEqual(env["SDKROOT"], sdk)
        self.compiler_runs.reset_mock()
        self.assertEqual(worker.build(), binary)
        self.assertEqual(self.compiler_runs.call_count, 0)

        other = self.root / "Other.sdk"; other.mkdir()
        (other / "SDKSettings.plist").write_bytes((self.sdk / "SDKSettings.plist").read_bytes())
        alias.unlink(); alias.symlink_to(other, target_is_directory=True)
        self.compiler_runs.reset_mock()
        self.assertEqual(worker.build(), binary)
        self.assertEqual(self.compiler_runs.call_count, 2)
        changed = json.loads((self.output / "build.json").read_text())["input"]
        self.assertNotEqual(changed["sdk_resolved"], original["sdk_resolved"])

    def test_local_embed_reuses_only_matching_signed_bytes_and_inputs(self) -> None:
        product = self.root / "product"
        helper = product / "Example.app/Contents/Helpers/storage-scanner-worker"
        helper.parent.mkdir(parents=True)
        signature = dict(identifier=helper.name, team="not set", adhoc=True, runtime=False)
        publications = []
        def fake_publish(_binary, destination, **kwargs):
            identity = worker.os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
            self.assertEqual(kwargs["signing_arguments"],
                ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none",
                 "--identifier", helper.name])
            publications.append(len(publications) + 1)
            destination.write_bytes(("signed " + str(publications[-1])).encode())
        original_sha = worker.sha
        def fake_sha(path):
            return "codesign-tool-sha" if str(path) == "/usr/bin/codesign" else original_sha(path)
        environment = {"TARGET_BUILD_DIR": str(product), "CONTENTS_FOLDER_PATH": "Example.app/Contents",
                       "PRODUCT_BUNDLE_IDENTIFIER": "local.macexplorer.development", "EXPANDED_CODE_SIGN_IDENTITY": "-"}
        with mock.patch.dict(worker.os.environ, environment), \
                mock.patch.object(worker, "publish", side_effect=fake_publish), \
                mock.patch.object(worker, "signed_facts", return_value=signature), \
                mock.patch.object(worker, "sha", side_effect=fake_sha), \
                mock.patch.object(worker.helper_symbols, "publish_for_xcode"):
            worker._main_locked(True)
            self.assertEqual(publications, [1])
            self.assertIsNotNone(worker.embedded_provenance(helper, current=True))
            worker._main_locked(True)
            self.assertEqual(publications, [1], "An unchanged signed product should retain exact bytes")
            value = json.loads((self.output / "build.json").read_bytes())
            self.assertEqual(value["embed"]["signing"]["arguments"],
                ["--force", "--sign", "-", "--timestamp=none", "--identifier", helper.name])
            value["embed"]["signing"]["arguments"] = value["embed"]["signing"]["arguments"][:-2]
            (self.output / "build.json").write_text(json.dumps(value))
            self.assertIsNone(worker.embedded_provenance(helper, current=True),
                "A pre-identifier signing receipt must not be reused")
            worker._main_locked(True)
            self.assertEqual(publications, [1, 2])
            helper.write_bytes(b"tampered signed helper")
            worker._main_locked(True)
            self.assertEqual(publications, [1, 2, 3], "Changed helper bytes must force signing")
            value = json.loads((self.output / "build.json").read_bytes())
            value["embed"]["signing"]["identity"] = "0" * 40
            (self.output / "build.json").write_text(json.dumps(value))
            worker._main_locked(True)
            self.assertEqual(publications, [1, 2, 3, 4], "Changed signing input must force signing")
            with mock.patch.dict(worker.os.environ, {"EXPANDED_CODE_SIGN_IDENTITY": "A" * 40}), \
                    mock.patch.object(worker, "signed_facts", return_value=dict(
                        identifier=helper.name, team="OTHERTEAM", adhoc=False, runtime=False)):
                worker._main_locked(True)
                worker._main_locked(True)
            self.assertEqual(publications, [1, 2, 3, 4, 5, 6], "A different team cannot establish a reuse receipt")

    def test_signed_helper_facts_require_role_team_flags_and_empty_rights(self) -> None:
        helper = self.root / "storage-scanner-worker"; helper.write_bytes(b"signed mock")
        display = "Identifier=storage-scanner-worker\nTeamIdentifier=CDLNJRG82U\nAuthority=Apple Development: Mock\nCodeDirectory flags=0x0(none)\n"
        rights = b""
        def codesign(argv, **_kwargs):
            if "--verify" in argv: return subprocess.CompletedProcess(argv, 0, b"", b"")
            if "--entitlements" in argv: return subprocess.CompletedProcess(argv, 0, rights, b"")
            return subprocess.CompletedProcess(argv, 0, "", display)
        with mock.patch.object(worker.subprocess, "run", side_effect=codesign):
            facts = worker.signed_facts(helper, identifier=helper.name, team="CDLNJRG82U", adhoc=False, runtime=False)
            self.assertEqual(facts["team"], "CDLNJRG82U")
            display = display.replace("Identifier=storage-scanner-worker\n",
                "Identifier=storage-scanner-worker-555549449ef2ee088c5d3593b1821d0557609539\n")
            with self.assertRaisesRegex(ValueError, "identifier"):
                worker.signed_facts(helper, identifier=helper.name)
            display = display.replace("Identifier=storage-scanner-worker-555549449ef2ee088c5d3593b1821d0557609539\n",
                "Identifier=storage-scanner-worker\n")
            with self.assertRaisesRegex(ValueError, "team changed"):
                worker.signed_facts(helper, identifier=helper.name, team="OTHER")
            with self.assertRaisesRegex(ValueError, "hardened-runtime"):
                worker.signed_facts(helper, identifier=helper.name, runtime=True)
            rights = b"<?xml version='1.0'?><plist version='1.0'><dict><key>unexpected</key><true/></dict></plist>"
            with self.assertRaisesRegex(ValueError, "entitlements"):
                worker.signed_facts(helper, identifier=helper.name)

    def test_result_selection_invalidates_cache_without_test_generators(self) -> None:
        worker.build()
        command = self.compiler_runs.call_args_list[-1].args[0]
        self.assertIn("b06_compact_values", command)
        self.assertIn("b06_reference_index", command)
        self.assertNotIn("b06_qualification", command)
        self.assertIn("b06_app_data", command)
        self.assertIn("b06_live_totals", command)
        self.assertIn("b06_checkpoint4096", command)
        self.assertIn("b06_classification_v3", command)
        self.assertIn("b06_layout_explanations", command)
        self.assertIn("b06_application_layouts", command)
        self.assertIn("b06_stored_locations", command)
        self.assertIn("b06_sorted_pages", command)
        self.assertNotIn("b06_parallel_metadata", command)
        self.assertNotIn("b06_classification_audit", command)
        self.assertNotIn("b06_stage_profile", command)
        self.assertNotIn("b06_reuse_statements", command)
        self.assertNotIn("b06_dense_names", command)
        self.compiler_runs.reset_mock()
        with mock.patch.object(worker, "RESULT_CONFIG", ()):
            worker.build()
        self.assertEqual(self.compiler_runs.call_count, 2)
        self.assertEqual(json.loads((self.output / "build.json").read_text())["input"]["result_config"], [])

    def test_source_change_during_compile_refuses_receipt(self) -> None:
        self.change_source_during_compile = True
        with self.assertRaisesRegex(ValueError, "sources changed during compilation"): worker.build()
        self.assertFalse((self.output / "build.json").exists())
        self.assertTrue((self.output / "storage-scanner-worker").exists())
        self.assertTrue((self.output / "ScannerNative.o").exists())

    def test_redirected_existing_outputs_are_refused(self) -> None:
        self.output.mkdir(); target = self.root / "owned-target"; target.write_bytes(b"preserve\n")
        for name in ["storage-scanner-worker", "ScannerNative.o", "build.json"]:
            with self.subTest(output=name):
                link = self.output / name; link.symlink_to(target)
                with self.assertRaisesRegex(ValueError, "redirected"): worker.build()
                self.assertEqual(self.compiler_runs.call_count, 0)
                self.assertEqual(target.read_bytes(), b"preserve\n")
                link.unlink()  # Only this successfully checked, owned link.

    def test_redirected_dangling_outputs_are_refused(self) -> None:
        self.output.mkdir(); target = self.root / "must-not-be-created"
        for name in ["storage-scanner-worker", "ScannerNative.o", "build.json"]:
            with self.subTest(output=name):
                link = self.output / name; link.symlink_to(target)
                with self.assertRaisesRegex(ValueError, "redirected"): worker.build()
                self.assertEqual(self.compiler_runs.call_count, 0)
                self.assertFalse(target.exists())
                link.unlink()

    def test_shared_output_is_refused(self) -> None:
        self.output.mkdir(); target = self.root / "owned-target"; target.write_bytes(b"preserve\n")
        os.link(target, self.output / "storage-scanner-worker")
        with self.assertRaisesRegex(ValueError, "redirected"): worker.build()
        self.assertEqual(self.compiler_runs.call_count, 0)
        self.assertEqual(target.read_bytes(), b"preserve\n")

    def test_parallel_builds_have_one_compiler_owner(self) -> None:
        for name in ("tmp", "cargo-home", "rustup-home"): worker.directory(self.output / name)
        counters = {"active": 0, "maximum": 0}
        guard = threading.Lock()
        def slow_compile(argv, **kwargs):
            with guard:
                counters["active"] += 1
                counters["maximum"] = max(counters["maximum"], counters["active"])
            try:
                time.sleep(0.03)
                return self.fake_compile(argv, **kwargs)
            finally:
                with guard: counters["active"] -= 1
        self.compiler_runs.side_effect = slow_compile
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker.build) for _ in range(2)]
            paths = [f.result(timeout=10) for f in futures]
        self.assertEqual(paths, [self.output / "storage-scanner-worker"] * 2)
        self.assertEqual(counters["maximum"], 1, "Concurrent compilers shared Rust intermediate paths")
        self.assertEqual(self.compiler_runs.call_count, 2, "The waiting build did not use the completed cache")

    def test_redirected_build_lock_is_refused(self) -> None:
        self.output.mkdir(); target = self.root / "untouched-lock"; target.write_bytes(b"preserve\n")
        (self.output / "build.lock").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "build lock"): worker.build()
        self.assertEqual(self.compiler_runs.call_count, 0)
        self.assertEqual(target.read_bytes(), b"preserve\n")

    def test_shared_build_lock_is_refused(self) -> None:
        self.output.mkdir(); target = self.root / "untouched-lock"; target.write_bytes(b"preserve\n"); target.chmod(0o600)
        os.link(target, self.output / "build.lock")
        with self.assertRaisesRegex(ValueError, "build lock"): worker.build()
        self.assertEqual(self.compiler_runs.call_count, 0)
        self.assertEqual(target.read_bytes(), b"preserve\n")

    def test_redirected_build_directory_is_refused(self) -> None:
        target = self.root / "owned-directory"; target.mkdir(); self.output.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "redirected"): worker.build()
        self.assertEqual(self.compiler_runs.call_count, 0); self.assertEqual(self.compiler_queries.call_count, 0)
        self.assertEqual(list(target.iterdir()), [])

    def test_dangling_embed_target_is_refused_before_copy_or_sign(self) -> None:
        binary = self.root / "storage-scanner-worker"; binary.write_bytes(b"unsigned mock helper\n")
        product = self.root / "product"
        helpers = product / "Example.app/Contents/Helpers"; helpers.mkdir(parents=True)
        target = self.root / "must-not-be-created-by-embed"
        (helpers / binary.name).symlink_to(target)
        with mock.patch.object(worker, "_build_locked", return_value=binary), \
                mock.patch.object(sys, "argv", ["build_storage_worker.py", "--embed"]), \
                mock.patch.dict(worker.os.environ, {"TARGET_BUILD_DIR": str(product),
                                                   "CONTENTS_FOLDER_PATH": "Example.app/Contents"}):
            with self.assertRaisesRegex(ValueError, "redirected"): worker.main()
        self.assertFalse(target.exists())
        self.assertEqual(self.compiler_runs.call_count, 0)
        self.assertEqual(binary.read_bytes(), b"unsigned mock helper\n")


if __name__ == "__main__": unittest.main(verbosity=2, failfast=True)
