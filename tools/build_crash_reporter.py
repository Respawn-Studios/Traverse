#!/usr/bin/env python3
"""Pinned, offline app-only PLCrashReporter preparation and verified embedding."""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from distribution.artifact_files import read
from distribution.helper_symbols import uuids

REPO = Path(__file__).resolve().parents[1]
VENDOR = REPO / "Vendor/PLCrashReporter"
PROVENANCE = REPO / "Vendor/PLCrashReporter.provenance.json"
PROVENANCE_SHA256 = "e8fca41f21132623d1c5cb1f75a0205807a7c92ad2cf268321f62ad00e69a4c3"
COMMIT = "0254f941c646b1ed17b243654723d0f071e990d0"
ROOT = REPO / ".build/crash-reporter-tooling"
PRODUCTS = ROOT / "derived/Build/Products/Release-macosx"
FRAMEWORK = PRODUCTS / "CrashReporter.framework"
SYMBOLS = PRODUCTS / "CrashReporter.framework.dSYM"
RECEIPT = ROOT / "current-framework.json"
FRAMEWORK_LINKS = {"CrashReporter": "Versions/Current/CrashReporter", "Headers": "Versions/Current/Headers",
                   "Modules": "Versions/Current/Modules", "Resources": "Versions/Current/Resources",
                   "Versions/Current": "A"}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def reviewed_sources() -> dict[str, str]:
    """Exact reviewed source path set; never general Vendor admission."""
    raw = read(PROVENANCE, 128 << 10)
    if sha(raw) != PROVENANCE_SHA256:
        raise RuntimeError("Unreviewed crash reporter provenance")
    value = json.loads(raw)
    if value.get("schema") != 1 or value.get("version") != "1.12.2" or value.get("commit") != COMMIT \
            or len(value.get("files", {})) != 350:
        raise RuntimeError("Unexpected crash reporter source identity")
    patch = value.get("downstreamPatch")
    if not isinstance(patch, dict) or patch.get("path") != "Source/PLCrashReporter.m" \
            or patch.get("upstreamSHA256") != value["files"][patch["path"]]["sha256"] \
            or patch.get("upstreamBytes") != value["files"][patch["path"]]["bytes"] \
            or len(patch.get("replacements", [])) != 5:
        raise RuntimeError("Unexpected crash reporter downstream patch identity")
    result = {"Vendor/PLCrashReporter.provenance.json": PROVENANCE_SHA256}
    for name, facts in value["files"].items():
        path = PurePosixPath(name)
        if path.is_absolute() or str(path) != name or ".." in path.parts or "\\" in name:
            raise RuntimeError("Invalid reviewed crash reporter source path")
        result["Vendor/PLCrashReporter/" + name] = patch["patchedSHA256"] if name == patch["path"] else facts["sha256"]
    return result


def verify_downstream_patch(data: bytes, patch: dict, upstream_facts: dict) -> None:
    if len(data) != patch["patchedBytes"] or sha(data) != patch["patchedSHA256"]:
        raise RuntimeError("Crash reporter downstream source differs from reviewed patch")
    original = data
    for change in reversed(patch["replacements"]):
        before = change["before"].encode("utf-8")
        after = change["after"].encode("utf-8")
        if not after or original.count(after) != 1:
            raise RuntimeError("Crash reporter downstream patch cannot be reversed exactly")
        original = original.replace(after, before, 1)
    if len(original) != upstream_facts["bytes"] or sha(original) != upstream_facts["sha256"]:
        raise RuntimeError("Crash reporter downstream patch does not restore pinned upstream")
    diff = "".join(difflib.unified_diff(
        original.decode("utf-8").splitlines(keepends=True), data.decode("utf-8").splitlines(keepends=True),
        fromfile="a/Source/PLCrashReporter.m", tofile="b/Source/PLCrashReporter.m"))
    if diff != patch["unifiedDiff"] or sha(diff.encode("utf-8")) != patch["unifiedDiffSHA256"]:
        raise RuntimeError("Crash reporter downstream diff differs from reviewed provenance")


def verify_sources() -> dict[str, str]:
    expected = reviewed_sources()
    value = json.loads(read(PROVENANCE, 128 << 10))
    facts = value["files"]
    patch = value["downstreamPatch"]
    actual = set()
    for path in VENDOR.rglob("*"):
        if path.is_symlink() or (not path.is_file() and not path.is_dir()):
            raise RuntimeError("Crash reporter source links/special files refused")
        if not path.is_file():
            continue
        name = path.relative_to(VENDOR).as_posix()
        if name not in facts:
            raise RuntimeError("Unreviewed crash reporter source file")
        data = read(path, 1 << 20)
        if bool(path.stat().st_mode & 0o111) != facts[name]["executable"]:
            raise RuntimeError("Crash reporter source differs from reviewed manifest: " + name)
        if name == patch["path"]:
            verify_downstream_patch(data, patch, facts[name])
        elif len(data) != facts[name]["bytes"] or sha(data) != facts[name]["sha256"]:
            raise RuntimeError("Crash reporter source differs from reviewed manifest: " + name)
        actual.add(name)
    if actual != set(facts):
        raise RuntimeError("Reviewed crash reporter source is missing")
    return expected


def directory(path: Path) -> Path:
    if not path.is_relative_to(REPO / ".build"):
        raise RuntimeError("Crash reporter output must stay in the checkout build root")
    current = REPO
    for part in path.relative_to(REPO).parts:
        current /= part
        if current.is_symlink():
            raise RuntimeError("Redirected crash reporter output")
        current.mkdir(exist_ok=True)
        if not current.is_dir():
            raise RuntimeError("Crash reporter output is not a directory")
    return path


def snapshot(root: Path, *, framework: bool = False) -> dict:
    """Compiled framework links are exact native layout, never source exceptions."""
    if root.resolve() != root or not root.is_dir():
        raise RuntimeError("Crash reporter product is missing or redirected")
    result = {}; total = 0
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            if not framework or FRAMEWORK_LINKS.get(name) != os.readlink(path):
                raise RuntimeError("Unexpected compiled crash reporter link")
            result[name] = {"link": os.readlink(path)}
        elif path.is_file():
            data = read(path, 16 << 20); total += len(data)
            result[name] = {"sha256": sha(data), "bytes": len(data)}
        elif not path.is_dir():
            raise RuntimeError("Special crash reporter product file")
        if len(result) > 128 or total > 32 << 20:
            raise RuntimeError("Crash reporter product bounds exceeded")
    if not result or (framework and not set(FRAMEWORK_LINKS) <= set(result)):
        raise RuntimeError("Incomplete crash reporter product")
    return result


def output(arguments: list[str], env: dict) -> str:
    return subprocess.check_output(arguments, cwd=REPO, env=env, stderr=subprocess.PIPE, timeout=30).decode().strip()


def tooling_environment() -> dict:
    env = os.environ.copy()
    env.update(TMPDIR=str(directory(ROOT / "tmp")) + "/", CFFIXED_USER_HOME=str(directory(ROOT / "user")),
               CLANG_MODULE_CACHE_PATH=str(directory(REPO / ".build/compiler-cache/xcode")), SWIFTPM_NETRC_DATA="")
    return env


def toolchain(env: dict) -> dict:
    sdk = Path(output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env)).resolve()
    clang = Path(output(["/usr/bin/xcrun", "--find", "clang"], env)).resolve()
    xcodebuild = Path(output(["/usr/bin/xcrun", "--find", "xcodebuild"], env)).resolve()
    # Compiler identity includes its actual executable bytes, not just a version label.
    compiler_hash = hashlib.sha256()
    with clang.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            compiler_hash.update(chunk)
    return dict(sdk=str(sdk), sdkSettingsSHA256=sha(read(sdk / "SDKSettings.json", 1 << 20)),
                clang=str(clang), compilerSHA256=compiler_hash.hexdigest(),
                compilerVersion=output([str(clang), "--version"], env),
                xcodebuild=str(xcodebuild), xcodebuildSHA256=sha(read(xcodebuild, 16 << 20)))


def build_identity(env: dict) -> dict:
    return dict(schema=2, version="1.12.2", commit=COMMIT, architectures=["arm64", "x86_64"], minimumOS="15.0",
                sourceSHA256=verify_sources(), builderSHA256=sha(read(Path(__file__), 128 << 10)), toolchain=toolchain(env))


def verify_prepared(*, identity: dict | None = None) -> dict:
    sources = verify_sources()
    value = json.loads(read(RECEIPT, 256 << 10))
    expected = value.get("inputs", {})
    if value.get("passed") is not True or expected.get("sourceSHA256") != sources \
            or expected.get("builderSHA256") != sha(read(Path(__file__), 128 << 10)) \
            or (identity is not None and expected != identity):
        raise RuntimeError("Prepared crash reporter is stale; run the preparation step")
    if value.get("framework") != snapshot(FRAMEWORK, framework=True) or value.get("symbols") != snapshot(SYMBOLS):
        raise RuntimeError("Prepared crash reporter product/symbol identity differs")
    binary_uuids = uuids(FRAMEWORK / "Versions/A/CrashReporter")
    if set(binary_uuids) != {"arm64", "x86_64"} or binary_uuids != value.get("UUIDs") \
            or binary_uuids != uuids(SYMBOLS / "Contents/Resources/DWARF/CrashReporter"):
        raise RuntimeError("Crash reporter requires matching symbols for both Mac architectures")
    return value


def prepare() -> dict:
    env = tooling_environment(); identity = build_identity(env)
    if RECEIPT.exists():
        try:
            return verify_prepared(identity=identity)
        except (RuntimeError, OSError, ValueError):
            pass
    command = [identity["toolchain"]["xcodebuild"], "-project", str(VENDOR / "CrashReporter.xcodeproj"),
               "-scheme", "CrashReporter macOS Framework", "-configuration", "Release", "-sdk", "macosx",
               "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "-derivedDataPath", str(directory(ROOT / "derived")),
               "-clonedSourcePackagesDirPath", str(directory(ROOT / "packages")),
               "-packageCachePath", str(directory(ROOT / "package-cache")),
               "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-jobs", "4",
               "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "MACOSX_DEPLOYMENT_TARGET=15.0",
               "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym", "GCC_TREAT_WARNINGS_AS_ERRORS=NO",
               "CLANG_MODULE_CACHE_PATH=" + env["CLANG_MODULE_CACHE_PATH"], "build"]
    log = ROOT / "framework-build.log"
    if log.is_symlink() or (log.exists() and log.stat().st_nlink != 1):
        raise RuntimeError("Unsafe crash reporter build log")
    with log.open("wb") as stream:
        subprocess.run(command, cwd=REPO, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=300)
    if identity != build_identity(env):
        raise RuntimeError("Crash reporter inputs changed during compilation")
    binary = FRAMEWORK / "Versions/A/CrashReporter"
    symbols = SYMBOLS / "Contents/Resources/DWARF/CrashReporter"
    binary_uuids = uuids(binary)
    if set(binary_uuids) != {"arm64", "x86_64"} or binary_uuids != uuids(symbols):
        raise RuntimeError("Crash reporter framework and dSYM UUID differ")
    value = dict(passed=True, inputs=identity, framework=snapshot(FRAMEWORK, framework=True),
                 symbols=snapshot(SYMBOLS), UUIDs=binary_uuids, log=log.relative_to(REPO).as_posix())
    fd, temporary = tempfile.mkstemp(prefix=".framework-", dir=ROOT)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True); stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
        if RECEIPT.is_symlink():
            raise RuntimeError("Redirected crash reporter receipt")
        os.replace(temporary, RECEIPT)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return verify_prepared(identity=identity)


def embed() -> None:
    value = verify_prepared()  # Never compile, download, or discover packages here.
    target = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    if target.resolve() != target or not target.is_relative_to(REPO / ".build") \
            or not target.is_dir() or target.name != "Contents" or target.parent.suffix != ".app":
        raise RuntimeError("Crash reporter embedding requires the checkout's app build bundle")
    frameworks = directory(target / "Frameworks")
    destination = frameworks / "CrashReporter.framework"
    temporary = frameworks / (".CrashReporter-" + uuid.uuid4().hex)
    try:
        shutil.copytree(FRAMEWORK, temporary, symlinks=True)
        if snapshot(temporary, framework=True) != value["framework"]:
            raise RuntimeError("Crash reporter changed during embedding")
        if destination.exists() or destination.is_symlink():
            snapshot(destination, framework=True)  # Reject redirected/unexpected old layout before disposal.
            shutil.rmtree(destination)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or os.environ.get("CODE_SIGN_IDENTITY") or "-"
        signing_env = os.environ.copy()
        signing_env.pop("CFFIXED_USER_HOME", None)
        if signing_env.get("HOME") == str(REPO / ".build/xcode-user"):
            signing_env.pop("HOME", None)
        command = ["/usr/bin/codesign", "--force", "--sign", identity]
        if os.environ.get("ENABLE_HARDENED_RUNTIME") == "YES":
            command.extend(["--options", "runtime"])
        subprocess.run([*command, str(destination)], env=signing_env, check=True, timeout=45)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(destination)],
                       env=signing_env, check=True, timeout=30)


def main() -> None:
    parser = argparse.ArgumentParser(); parser.add_argument("action", choices=("prepare", "verify", "verify-sources", "embed"))
    action = parser.parse_args().action
    if action == "prepare": prepare()
    elif action == "verify": verify_prepared(identity=build_identity(tooling_environment()))
    elif action == "verify-sources": verify_sources()
    else: embed()
    print(json.dumps(dict(passed=True, version="1.12.2", action=action)), flush=True)


if __name__ == "__main__":
    main()
