#!/usr/bin/env python3
"""Export reviewed source and narrowly selected offline dependency inputs.

This prepares local source artifacts, not a release, binary-reproducibility claim
or repository publication. It never copies whole Cargo homes or runs SDK scripts.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from dev import local_directory
from distribution.artifact_files import read
from distribution.notices import lock_checksums, verify_outputs
from distribution.source_kit import create_source_kit, verify_project
from worker_setup import (GRAPHS, TOOLCHAIN, load_packet, require_public_lock,
                          require_public_manifests, refuse_private_configuration, require_toolchain, run)

GIT_ENV = {"PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
DEPENDENCY_CONFIGURATION = (
    "tools/rust-toolchain.json", "Distribution/SourceDependencies.json", "Distribution/Sparkle.lock.json",
    "tools/smb_reader/smb2-browser/Cargo.toml", "tools/smb_reader/smb2-browser/Cargo.lock",
    "tools/sftp_reader/qualification/Cargo.toml", "tools/sftp_reader/qualification/Cargo.lock",
    "Vendor/smb2/Cargo.toml",
    "Distribution/ThirdPartyManifest.json", "Distribution/ThirdPartyNotices.txt",
    "tools/worker_setup.py", "tools/smb_reader/packet.py", "tools/ssh_profiles/packet.py",
    "tools/distribution/notices.py",
)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", *arguments], cwd=ROOT, timeout=60,
                                   env=GIT_ENV)


def export_context(commit: str, selection: str, fetch: bool) -> dict:
    """Historical full exports may reuse only identical, already-fetched pins.

    Project blobs always come from the selected Git commit. Dependency payloads
    come from the current verified public cache, so their configuration must be
    identical rather than silently mixing two revisions in a source release.
    """
    head = git("rev-parse", "HEAD").decode().strip()
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise RuntimeError("Export from a reviewed clean worktree")
    if commit != head and (selection != "full" or fetch):
        raise RuntimeError("Retained commits require a full offline source export")
    if commit != head:
        try:
            git("merge-base", "--is-ancestor", commit, head)
        except subprocess.CalledProcessError as error:
            raise RuntimeError("Retained source commit must be an ancestor of the current checkout") from error
    inputs = {}
    for name in DEPENDENCY_CONFIGURATION:
        expected = git("show", commit + ":" + name)
        maximum = 4 << 20 if name == "Distribution/ThirdPartyNotices.txt" else 1 << 20
        if read(ROOT / name, maximum) != expected:
            raise RuntimeError("Source dependency configuration differs from the selected commit: " + name)
        inputs[name] = sha(expected)
    return {"checkoutCommit": head, "dependencyConfigurationSHA256": inputs,
            "exporterSHA256": sha(read(Path(__file__), 1 << 20))}


def committed_files(commit: str) -> dict[str, str]:
    files = {}
    total = 0
    for record in git("ls-tree", "-rlz", commit).split(b"\0"):
        if not record: continue
        facts, raw_name = record.split(b"\t", 1)
        mode, kind, object_id, size = facts.split()
        name = raw_name.decode("utf-8")
        path = PurePosixPath(name)
        if mode not in (b"100644", b"100755") or kind != b"blob" or path.is_absolute() or ".." in path.parts:
            raise RuntimeError("Source export needs a review of nonregular Git entries")
        total += int(size)
        if int(size) > 16 << 20 or total > 128 << 20 or len(files) >= 8192:
            raise RuntimeError("Committed source exceeds the reviewed export size")
        files[name] = object_id.decode("ascii")
    for required in ("LICENSE", "README.md", "CONTRIBUTING.md", "Vendor/smb2/Cargo.toml"):
        if required not in files: raise RuntimeError("Required source file missing: " + required)
    return files


def contributor_selection(files: dict[str, str], policy: dict) -> tuple[dict[str, str], list[str], dict]:
    """Select whole source/tool trees, with an auditable boundary for history.

    Unknown top-level additions require a policy review instead of silently
    disappearing from the next source bundle. No retained blob is rewritten.
    """
    if policy.get("schema") != 1 or policy.get("name") != "contributor-v1":
        raise RuntimeError("Unknown contributor source selection")
    groups = []
    for key in ("retainedTrees", "retainedFiles", "omittedTrees"):
        values = policy.get(key)
        if not isinstance(values, list) or not values or len(values) != len(set(values)):
            raise RuntimeError("Invalid source selection paths")
        for name in values:
            if not isinstance(name, str) or not name or str(PurePosixPath(name)) != name \
                    or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts \
                    or any(c in name for c in "\\\n\r\0*?[]"):
                raise RuntimeError("Source selection needs canonical literal paths")
        groups.append(values)
    trees, exact, excluded = groups
    for name in exact:
        if name not in files: raise RuntimeError("Selected source guide missing: " + name)
    for tree in trees:
        if not any(name.startswith(tree + "/") for name in files):
            raise RuntimeError("Selected source tree missing: " + tree)
    selected, omitted = {}, {}
    for name, object_id in files.items():
        if name in exact or any(name.startswith(tree + "/") for tree in trees):
            selected[name] = object_id
        elif any(name.startswith(tree + "/") for tree in excluded):
            omitted[name] = object_id
        else:
            raise RuntimeError("Review the source selection for new path: " + name)
    from native_build_inputs import source_inputs
    if set(source_inputs()) - set(selected):
        raise RuntimeError("Contributor source selection omits a native build input")
    receipt = {"name": policy["name"], "purpose": policy["purpose"],
               "omissionReason": policy["omissionReason"],
               "retainedGitObjects": selected, "omittedGitObjects": omitted}
    return selected, trees + exact, receipt


def index_path(name: str) -> str:
    name = name.lower()
    if not re.fullmatch(r"[a-z0-9_-]+", name): raise RuntimeError("Unexpected crate name")
    if len(name) < 3: return str(len(name)) + "/" + name
    if len(name) == 3: return "3/" + name[0] + "/" + name
    return name[:2] + "/" + name[2:4] + "/" + name


def dependency_inputs(homes: dict[str, Path]) -> tuple[dict[str, bytes], dict]:
    values = {}
    graphs = {}
    for role, (packet_path, manifest_path) in GRAPHS.items():
        lock = read((ROOT / manifest_path).with_name("Cargo.lock"))
        require_public_lock(lock)
        locked = lock_checksums(lock)
        registry = homes[role] / "registry"
        count = 0
        for (name, version), checksum in sorted(locked.items()):
            if checksum is None: continue
            metadata = list((registry / "index").glob("*/.cache/" + index_path(name)))
            if len(metadata) != 1: raise RuntimeError("Locked package index metadata is missing or ambiguous")
            index = metadata[0].relative_to(registry / "index").parts[0]
            if not re.fullmatch(r"index\.crates\.io-[a-f0-9]{16}", index):
                raise RuntimeError("Unreviewed registry index")
            prefix = "CargoCaches/" + role + "/registry/"
            base = registry / "index" / index
            config = read(base / "config.json", 8192)
            if json.loads(config) != {"dl": "https://static.crates.io/crates", "api": "https://crates.io"}:
                raise RuntimeError("Unreviewed registry endpoints")
            values[prefix + "index/" + index + "/config.json"] = config
            relative = ".cache/" + index_path(name)
            values[prefix + "index/" + index + "/" + relative] = read(metadata[0], 4 << 20)
            candidates = list((registry / "cache").glob("*/" + name + "-" + version + ".crate"))
            if not candidates: continue  # The explicit target/feature build below owns completeness.
            if len(candidates) != 1: raise RuntimeError("Ambiguous locked crate cache")
            archive = candidates[0]
            if archive.parent.name != index:
                raise RuntimeError("Unreviewed registry cache")
            data = read(archive, 16 << 20)
            if sha(data) != checksum: raise RuntimeError("Crate archive differs from its production lock")
            values[prefix + "cache/" + index + "/" + archive.name] = data
            count += 1
        if not count: raise RuntimeError("Production cache is empty; run worker_setup.py --fetch")
        graphs[role] = {"archives": count,
                        "indexRecords": len({name for (name, _), checksum in locked.items() if checksum is not None}),
                        "lockSHA256": sha(lock)}
    if len(values) > 1024 or sum(map(len, values.values())) > 64 << 20:
        raise RuntimeError("Dependency source payload exceeds its reviewed size")
    return values, graphs


def public_registry(fetch: bool) -> tuple[dict[str, bytes], dict, str]:
    require_public_manifests()
    lock_data = {role: read((ROOT / manifest).with_name("Cargo.lock"))
                 for role, (_, manifest) in GRAPHS.items()}
    for data in lock_data.values(): require_public_lock(data)
    locks = {role: sha(data) for role, data in lock_data.items()}
    cargo = TOOLCHAIN / "bin/cargo"
    _, cargo_version = require_toolchain()
    identity = {"locks": locks, "cargoSHA256": sha(read(cargo, 64 << 20)),
                "cargoVersion": cargo_version, "target": "aarch64-apple-darwin", "selectionVersion": 2}
    key = sha(json.dumps(identity, sort_keys=True).encode())
    parent = local_directory("source-registry")
    case = parent / key
    if case.exists():
        receipt = json.loads(read(case / "public-fetch.json", 262_144))
        values, graphs = dependency_inputs({role: case / role for role in GRAPHS})
        if receipt.get("identity") != identity or receipt.get("origin") != "fresh-public-cargo-fetch" \
            or receipt.get("files") != {name: sha(data) for name, data in values.items()}:
            raise RuntimeError("Public source cache changed after its recorded fetch")
        return values, graphs, key
    if not fetch:
        raise RuntimeError("A fresh public registry source cache is required; use --fetch-sources once")
    stage = parent / ("pending-" + str(uuid.uuid4()))
    stage.mkdir(mode=0o700)
    for role, (packet_path, manifest) in GRAPHS.items():
        packet = load_packet(role, packet_path)
        env = packet.environment() if role == "smb" else packet.rust_environment(packet.directory(packet.TOOLING / "source-export"))
        home = stage / role
        home.mkdir(mode=0o700)
        for leaf in ("tmp", "target", "rustup"): (home / leaf).mkdir(mode=0o700)
        env.update(CARGO_HOME=str(home), CARGO_TARGET_DIR=str(home / "target"),
                   RUSTUP_HOME=str(home / "rustup"), TMPDIR=str(home / "tmp"))
        refuse_private_configuration(env)
        run([str(cargo), "fetch", "--manifest-path", str(ROOT / manifest),
             "--locked", "--target", identity["target"]], env, fetch=True)
        run([str(cargo), "metadata", "--manifest-path", str(ROOT / manifest), "--locked", "--offline",
             "--format-version", "1", "--filter-platform", identity["target"]], env)
    values, graphs = dependency_inputs({role: stage / role for role in GRAPHS})
    if locks != {role: sha(read((ROOT / manifest).with_name("Cargo.lock")))
                 for role, (_, manifest) in GRAPHS.items()}:
        raise RuntimeError("Production lock changed during public source fetch")
    receipt = {"schema": 1, "origin": "fresh-public-cargo-fetch", "identity": identity,
               "exporterSHA256": sha(read(Path(__file__), 1 << 20)),
               "preparedFromCommit": git("rev-parse", "HEAD").decode().strip(),
               "files": {name: sha(data) for name, data in values.items()}}
    (stage / "public-fetch.json").write_text(json.dumps(receipt, indent=2) + "\n")
    # Metadata expands crates for its check. Only the checksum-bound archives
    # and index are reusable export inputs; keep no duplicate source/target tree.
    for role in GRAPHS:
        expanded = stage / role / "registry/src"
        if expanded.is_dir(): shutil.rmtree(expanded)
    os.rename(stage, case)
    return values, graphs, key


def write_dependencies(path: Path, values: dict[str, bytes]) -> None:
    with path.open("xb") as output, gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as stream:
            for name, data in sorted(values.items()):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                stream.addfile(member, io.BytesIO(data))
    with tarfile.open(path, "r:gz") as stream:
        found = set()
        for member in stream:
            if not member.isfile() or member.name not in values or member.name in found:
                raise RuntimeError("Unexpected dependency payload member")
            if stream.extractfile(member).read() != values[member.name]:
                raise RuntimeError("Dependency payload differs")
            found.add(member.name)
        if found != set(values): raise RuntimeError("Dependency payload incomplete")


def sdk_sources(fetch: bool) -> list[tuple[dict, bytes]]:
    spec = json.loads(read(ROOT / "Distribution/SourceDependencies.json", 16_384))
    owners = {"Sparkle": "sparkle-project", "swift-argument-parser": "apple"}
    if spec.get("schema") != 1 or len(spec.get("components", [])) != 2 or {item.get("name") for item in spec["components"]} != set(owners):
        raise RuntimeError("SDK source inventory needs review")
    result = []
    sparkle_lock = json.loads(read(ROOT / "Distribution/Sparkle.lock.json", 8192))
    argument_pin = None
    cache = local_directory("source-dependencies")
    for item in spec["components"]:
        if not re.fullmatch(r"[a-f0-9]{40}", item["commit"]) or item["filename"] != item["name"] + "-" + item["commit"] + ".tar.gz" \
            or item["url"] != "https://codeload.github.com/" + owners[item["name"]] + "/" + item["name"] + "/tar.gz/" + item["commit"]:
            raise RuntimeError("SDK source path/origin needs review")
        path = cache / item["filename"]
        if not path.exists():
            if not fetch: raise RuntimeError("Missing pinned SDK source; use --fetch-sources once")
            with urllib.request.urlopen(item["url"], timeout=30) as response:
                data = response.read((32 << 20) + 1)
            if len(data) > 32 << 20 or sha(data) != item["sha256"]:
                raise RuntimeError("SDK source archive checksum differs")
            with path.open("xb") as output: output.write(data)
        data = read(path, 32 << 20)
        if sha(data) != item["sha256"]: raise RuntimeError("Pinned SDK source changed")
        prefix = item["name"] + "-" + item["commit"]
        legal = None
        binary_manifest = None
        total = 0
        count = 0
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as stream:
            for member in stream:
                parts = PurePosixPath(member.name).parts
                total += member.size
                count += 1
                if count > 4096 or total > 128 << 20 or not parts or parts[0] != prefix or ".." in parts or not (member.isfile() or member.isdir()):
                    raise RuntimeError("SDK source needs an archive-entry review")
                if member.name == prefix + "/" + item["licenseFile"]:
                    legal = stream.extractfile(member).read(65_537)
                if item["name"] == "Sparkle" and member.name == prefix + "/Package.swift":
                    binary_manifest = stream.extractfile(member).read(131_073)
                if item["name"] == "Sparkle" and member.name == prefix + "/Sparkle.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved":
                    resolved = json.loads(stream.extractfile(member).read(131_073))
                    pins = [pin for pin in resolved["pins"] if pin.get("identity") == "swift-argument-parser"]
                    if len(pins) != 1 or pins[0].get("location") != "https://github.com/apple/swift-argument-parser.git":
                        raise RuntimeError("Sparkle CLI source dependency changed")
                    argument_pin = pins[0]["state"]
        if legal is None or sha(legal) != item["licenseSHA256"]:
            raise RuntimeError("SDK source license differs")
        if item["name"] == "Sparkle" and (item["version"] != sparkle_lock["version"]
            or item["licenseSHA256"] != sparkle_lock["licenseSHA256"] or binary_manifest is None
            or sparkle_lock["sha256"].encode() not in binary_manifest):
            raise RuntimeError("Sparkle source does not match the selected binary SDK lock")
        result.append((item, data))
    argument = next(item for item, _ in result if item["name"] == "swift-argument-parser")
    if argument_pin != {"revision": argument["commit"], "version": argument["version"]}:
        raise RuntimeError("ArgumentParser source differs from Sparkle's pinned CLI dependency")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default="HEAD")
    parser.add_argument("--selection", choices=("full", "contributor-v1"), default="full",
                        help="Keep the full tracked snapshot, or omit only explicitly classified history/prototypes for local contributor review.")
    parser.add_argument("--fetch-sources", action="store_true", help="Acquire missing pinned SDK sources and fresh public locked registry inputs.")
    parser.add_argument("--bundle", action="store_true", help="Also wrap the verified export in one transparent source kit.")
    args = parser.parse_args()
    if args.commit != "HEAD" and not re.fullmatch(r"[a-f0-9]{40}", args.commit):
        raise RuntimeError("Select HEAD or its exact full commit ID")
    commit = git("rev-parse", "--verify", args.commit + "^{commit}").decode().strip()
    context = export_context(commit, args.selection, args.fetch_sources)
    expected = committed_files(commit)
    archive_paths = []
    selection = {"name": "full", "retainedGitObjects": expected, "omittedGitObjects": {}}
    if args.selection == "contributor-v1":
        policy_bytes = git("show", commit + ":Distribution/SourceSelection.json")
        expected, archive_paths, selection = contributor_selection(expected, json.loads(policy_bytes))
        selection["policySHA256"] = sha(policy_bytes)
    verify_outputs()
    sources = sdk_sources(args.fetch_sources)
    values, graphs, registry_key = public_registry(args.fetch_sources)
    case = local_directory("source-release") / (commit if args.selection == "full" else commit + "-" + args.selection)
    if case.exists(): raise RuntimeError("This source export already exists; inspect it rather than overwrite")
    case.mkdir(mode=0o700)
    prefix = "Traverse-" + commit[:12]
    project = case / "Traverse-project-source.tar.gz"
    subprocess.run(["git", "--literal-pathspecs", "-c", "tar.tar.gz.command=/usr/bin/gzip -n", "archive", "--format=tar.gz", "--prefix=" + prefix + "/",
                    "--output=" + str(project), commit, "--", *archive_paths], cwd=ROOT, env=GIT_ENV, check=True, timeout=60)
    verify_project(project, prefix, expected)
    (case / "source-selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    write_dependencies(case / "WorkerDependencies.tar.gz", values)
    for item, data in sources:
        with (case / item["filename"]).open("xb") as output: output.write(data)
    if context != export_context(commit, args.selection, False):
        raise RuntimeError("Worktree changed during source preparation; retain this case for review")
    record = {"schema": 1, "prepared": True, "published": False, "sourceCommit": commit,
              "sourceSelection": args.selection, "privacyReview": "NOT EXERCISED",
              "target": "aarch64-apple-darwin", "cargoVersion": "1.99.1", "projectFiles": len(expected),
              "dependencyGraphs": graphs, "sdkSources": [item for item, _ in sources],
              "publicRegistryReceipt": registry_key,
              "cleanExportBuild": "NOT EXERCISED", "binaryCorrespondence": "NOT EXERCISED",
              "sourceExporter": context,
              "files": {path.name: {"bytes": path.stat().st_size, "sha256": sha(read(path, 128 << 20))}
                        for path in sorted(case.iterdir()) if path.is_file()}}
    (case / "source-manifest.json").write_text(json.dumps(record, indent=2) + "\n")
    kit = create_source_kit(case) if args.bundle else None
    print(json.dumps({"prepared": True, "case": str(case), "sourceCommit": commit,
                      "projectFiles": len(expected), "graphs": graphs, "published": False,
                      "sourceKit": str(kit) if kit else None}))


if __name__ == "__main__":
    main()
