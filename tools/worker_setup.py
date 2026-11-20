#!/usr/bin/env python3
"""Prepare the pinned Rust components and locked production Cargo caches.

Default inspection is offline. Installation and dependency fetch are explicit
and use only checkout-local storage.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from dev import local_directory
from build_architecture import ARCHITECTURES, host, named

TOOLCHAIN = ROOT / ".build/b06-toolchain/rust-1.99.1"
GRAPHS = {
    "smb": ("tools/smb_reader/packet.py", "tools/smb_reader/smb2-browser/Cargo.toml"),
    "sftp": ("tools/ssh_profiles/packet.py", "tools/sftp_reader/qualification/Cargo.toml"),
}


def load_packet(role: str, path: str):
    spec = importlib.util.spec_from_file_location("traverse_setup_" + role, ROOT / path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Production worker environment is unavailable")
    packet = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packet)
    if packet.TOOLCHAIN != TOOLCHAIN:
        raise RuntimeError("Production worker toolchain differs from setup")
    return packet


def run(command: list[str], environment: dict[str, str], *, fetch: bool = False) -> bytes:
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": 4 << 20, "stderr": 1 << 20}
    deadline = time.monotonic() + (300 if fetch else 60)
    process = subprocess.Popen(command, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise RuntimeError("Worker setup command timed out")
                for key, _ in selector.select(timeout=0.25):
                    chunk = os.read(key.fd, 65_536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if len(buffers[key.data]) + len(chunk) > limits[key.data]:
                        raise RuntimeError("Worker setup output exceeded its expected size")
                    buffers[key.data].extend(chunk)
        status = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        if status:
            message = buffers["stderr"].decode("utf-8", errors="replace")[-2400:]
            raise RuntimeError(message or "Worker dependency check failed")
        return bytes(buffers["stdout"])
    finally:
        if process.poll() is None:
            # Only this helper's newly created process group is stopped.
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
        process.stdout.close()
        process.stderr.close()


def require_public_lock(data: bytes) -> None:
    packages = data.decode("utf-8").split("[[package]]")[1:]
    if not packages: raise RuntimeError("Missing production lock packages")
    for section in packages:
        sources = re.findall(r"^source\s*=\s*(.*)$", section, re.MULTILINE)
        if len(sources) > 1 or sources and json.loads(sources[0]) != "registry+https://github.com/rust-lang/crates.io-index":
            raise RuntimeError("Worker setup requires the reviewed crates.io-only lockfiles")


def refuse_private_configuration(environment: dict[str, str]) -> None:
    home = Path(environment["CARGO_HOME"])
    paths = [home / name for name in ("credentials", "credentials.toml", "config", "config.toml")]
    paths += [parent / ".cargo" / name for parent in (ROOT, *ROOT.parents) for name in ("config", "config.toml")]
    if any(path.exists() or path.is_symlink() for path in paths):
        raise RuntimeError("Worker setup found Cargo credential/configuration files; review them separately before fetching")


def require_public_manifests() -> None:
    for manifest in [item[1] for item in GRAPHS.values()] + ["Vendor/smb2/Cargo.toml"]:
        if re.search(r"\b(?:git|registry)\s*=", (ROOT / manifest).read_text()):
            raise RuntimeError("A production manifest selects a new source; review it before fetching")


def require_toolchain(prefix: Path = TOOLCHAIN) -> tuple[str, str]:
    compiler, cargo = prefix / "bin/rustc", prefix / "bin/cargo"
    if not compiler.is_file() or not cargo.is_file():
        raise RuntimeError("Install the pinned local Rust toolchain first; see docs/engineering/DEVELOPMENT_SETUP.md")
    env = {"PATH": str(prefix / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
    rust_version = run([str(compiler), "--version"], env).decode().strip()
    cargo_version = run([str(cargo), "--version"], env).decode().strip()
    if not rust_version.startswith("rustc 1.99.1 ") or not cargo_version.startswith("cargo 1.99.1 "):
        raise RuntimeError("Expected Rust/Cargo1.99.1; the existing toolchain was not changed")
    return rust_version, cargo_version


def install_toolchain(target: str) -> None:
    pin = json.loads((ROOT / "tools/rust-toolchain.json").read_text())
    prefix = Path(pin["prefix"])
    if prefix != TOOLCHAIN.relative_to(ROOT) or prefix.name != f'rust-{pin["version"]}':
        raise RuntimeError("Rust installation prefix differs from the build tools")
    local_directory(prefix.parent.relative_to(".build").as_posix())
    if TOOLCHAIN.is_symlink():
        raise RuntimeError("The Rust installation prefix is redirected")
    host_target = host().rust_target
    target_path = Path("lib/rustlib") / target
    install_host = not TOOLCHAIN.exists()
    if not install_host:
        require_toolchain()
        if (TOOLCHAIN / target_path / "lib").is_dir():
            return
        if target == host_target:
            raise RuntimeError("The existing Rust installation is missing its host standard library")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", pin["date"]):
        raise RuntimeError("Unexpected Rust distribution date")

    roles = ("rustc", "rust-std", "cargo")
    host_components = pin["components"][host_target]
    if [item["filename"] for item in host_components] != [f'{role}-{pin["version"]}-{host_target}.tar.xz' for role in roles]:
        raise RuntimeError("Unexpected Rust distribution component list")
    components = list(host_components) if install_host else []
    if target != host_target:
        name = f'rust-std-{pin["version"]}-{target}.tar.xz'
        target_components = [item for item in pin["components"][target] if item["filename"] == name]
        if len(target_components) != 1:
            raise RuntimeError("Unexpected Rust target standard library")
        components.extend(target_components)

    with tempfile.TemporaryDirectory(prefix="rust-components-", dir=local_directory("setup")) as temporary:
        work = Path(temporary)
        staged = work / "prefix"
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TMPDIR": temporary}
        for item in components:
            name = item["filename"]
            archive = work / name
            print("Preparing " + name, flush=True)
            url = f'https://static.rust-lang.org/dist/{pin["date"]}/{name}'
            subprocess.run(["/usr/bin/curl", "-q", "--fail", "--silent", "--show-error", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--max-filesize", str(256 << 20),
                "--output", str(archive), url], env=env, check=True, timeout=180)
            digest = hashlib.sha256()
            with archive.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1 << 20), b""):
                    digest.update(chunk)
            if digest.hexdigest() != item["sha256"]:
                raise RuntimeError(f"Checksum mismatch for {name}")
            subprocess.run(["/usr/bin/tar", "-xJf", str(archive), "-C", temporary], env=env, check=True, timeout=120)
            installer = work / name.removesuffix(".tar.xz") / "install.sh"
            subprocess.run(["/bin/bash", str(installer), f"--prefix={staged}", "--disable-ldconfig"],
                cwd=work, env=env, check=True, timeout=120)
        staged_target = staged / target_path
        if not (staged_target / "lib").is_dir():
            raise RuntimeError("The verified Rust installation is missing the requested standard library")
        if install_host:
            require_toolchain(staged)
            if not (staged / "lib/rustlib" / host_target / "lib").is_dir():
                raise RuntimeError("The verified Rust installation is missing its host standard library")
        if TOOLCHAIN.is_symlink():
            raise RuntimeError("The Rust installation prefix is redirected")
        if install_host and not TOOLCHAIN.exists():
            try:
                staged.rename(TOOLCHAIN)
            except OSError:
                if not TOOLCHAIN.is_dir() or TOOLCHAIN.is_symlink():
                    raise
        require_toolchain()
        installed_target = TOOLCHAIN / target_path
        if not (installed_target / "lib").is_dir():
            # Publish only the staged target library when extending a toolchain.
            try:
                staged_target.rename(installed_target)
            except OSError:
                if not (installed_target / "lib").is_dir():
                    raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-toolchain", action="store_true",
                        help="Download and verify the pinned host tools and the selected architecture's standard library.")
    parser.add_argument("--fetch", action="store_true",
                        help="Fetch only the two locked production graphs from public registries.")
    parser.add_argument("--arch", choices=tuple(ARCHITECTURES), default=host().name,
                        help="Prepare dependencies for this native or cross-built Mac architecture.")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise RuntimeError("The bundled workers require the pinned macOS toolchain")
    target = named(args.arch).rust_target
    if args.install_toolchain:
        install_toolchain(target)
    cargo = TOOLCHAIN / "bin/cargo"
    version, cargo_version = require_toolchain()
    if not (TOOLCHAIN / "lib/rustlib" / target / "lib").is_dir():
        raise RuntimeError("Install the pinned Rust standard library for " + target + " first")
    locks = {role: (ROOT / manifest).with_name("Cargo.lock").read_bytes()
             for role, (_, manifest) in GRAPHS.items()}
    for data in locks.values(): require_public_lock(data)
    require_public_manifests()
    report = {"format": "traverse-worker-setup-v1", "compiler": version, "cargo": cargo_version,
              "target": target, "networkRequested": args.fetch, "graphs": {}}
    for role, (packet_path, manifest) in GRAPHS.items():
        packet = load_packet(role, packet_path)
        env = packet.environment() if role == "smb" else packet.rust_environment(packet.directory(packet.TOOLING / "setup"))
        refuse_private_configuration(env)
        if args.fetch:
            print("Fetching locked " + role.upper() + " dependencies…", flush=True)
            # The bundled notices cover the locked graphs on both Mac CPUs.
            notice_targets = [arg for arch in ARCHITECTURES.values() for arg in ("--target", arch.rust_target)]
            run([str(cargo), "fetch", "--manifest-path", str(ROOT / manifest),
                 "--locked", *notice_targets], env, fetch=True)
        metadata = json.loads(run([str(cargo), "metadata", "--manifest-path", str(ROOT / manifest),
                                   "--locked", "--offline", "--format-version", "1",
                                   "--filter-platform", target], env))
        if (ROOT / manifest).with_name("Cargo.lock").read_bytes() != locks[role]:
            raise RuntimeError("A production lockfile changed; review it before building")
        report["graphs"][role] = {"packages": len(metadata["packages"]),
                                   "lockSHA256": hashlib.sha256(locks[role]).hexdigest()}
    # Reuse the normal build's exact source/license validation rather than
    # introducing a second dependency or acknowledgement interpretation.
    from distribution.notices import verify_outputs
    verify_outputs()
    if any((ROOT / manifest).with_name("Cargo.lock").read_bytes() != locks[role]
           for role, (_, manifest) in GRAPHS.items()):
        raise RuntimeError("A production lockfile changed during setup")
    report["noticesMatch"] = True
    report["locksUnchanged"] = True
    output = local_directory("setup") / "worker-dependencies.json"
    descriptor, name = tempfile.mkstemp(prefix=".worker-setup-", dir=output.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("Worker setup: " + str(error), file=sys.stderr)
        print("See docs/engineering/DEVELOPMENT_SETUP.md. Existing tools and lockfiles are preserved.", file=sys.stderr)
        raise SystemExit(1)
