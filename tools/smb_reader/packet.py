"""Owned, bounded tooling for the approved isolated B10 reader comparison."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import fcntl
import re
import uuid

REPO = Path(__file__).resolve().parents[2]
TOOLING = REPO / ".build/b10-network-tooling"
# Overnight delegated completion decision,21 October: preserve the failed75MiB
# signed copy while admitting the remaining same-size completion/trust checks.
# Build/cache space only; runtime and source fixture byte limits are unchanged.
#26October's delegated completion retains every old compiler variant and adds
#512MiB cache headroom; runtime/fixture/credential limits are independent.
TOOLING_LIMIT = 4 << 30
PACKET = REPO / ".build/b10-network-reader"
TOOLCHAIN = REPO / ".build/b06-toolchain/rust-1.99.1"
MIB = 1 << 20
PINS = {
    "smb2": ("vdavid/smb2", "b7e88bdf948e8e99923a40c9c2dcf3cba0f2d4aa"),
    "smb": ("afiffon/smb-rs", "f4524d032c8951cc288e1c8231ad68588583abda"),
}


def directory(path: Path) -> Path:
    path.relative_to(REPO / ".build")
    current = REPO
    for component in path.relative_to(REPO).parts:
        current /= component
        if not current.exists() and not current.is_symlink():
            current.mkdir(mode=0o700)
        facts = current.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid():
            raise RuntimeError("Redirected or unowned B10 tooling directory")
    return path


def native_compiler_lock(path: Path, target: str) -> bool:
    """Count an unfollowed ephemeral Clang lock, never trust its target."""
    try: relative = path.relative_to(TOOLING / "swift-module-cache")
    except ValueError: return False
    if any(part in ['.','..'] for part in relative.parts) or not re.fullmatch(r"[A-Za-z0-9_+.=-]{1,220}\.lock(?:-[a-fA-F0-9]+)?", path.name):return False
    if re.fullmatch(r"[A-Za-z0-9_.:@+-]{1,255}", target) and target not in ['.','..']:return True
    # Some Clang submissions link to their unique peer using an absolute name.
    # Count only an exact same-directory peer; never follow this target.
    peer=Path(target)
    return bool(len(target.encode())<=4096 and peer.is_absolute() and '..' not in peer.parts
        and peer.parent==path.parent and re.fullmatch(re.escape(path.name)+r'-[a-fA-F0-9]{4,32}',peer.name))


def verify_fixture_link(path: Path, facts, control: dict) -> None:
    observed=dict(device=facts.st_dev,inode=facts.st_ino,mode=facts.st_mode,links=facts.st_nlink,size=facts.st_size)
    if observed!=control['identity']:
        raise RuntimeError('Generated unsafe-link control changed')
    if control['kind']=='symlink':
        if not stat.S_ISLNK(facts.st_mode) or os.readlink(path)!=control['target']:
            raise RuntimeError('Generated symbolic-link control changed')
    elif control['kind']!='hardlink' or not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=2 or digest(path)!=control['sha256']:
        raise RuntimeError('Generated hard-link control changed')


def native_contract_link(path: Path, target: str, device: int) -> bool:
    """One SwiftPM convenience link, counted without traversing its target."""
    if path != TOOLING / 'folder-local-contracts/debug' or target != 'arm64-apple-macosx/debug':
        return False
    destination = path.parent / 'arm64-apple-macosx/debug'
    for node in [destination.parent, destination]:
        facts = node.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_dev != device:
            return False
    return True


def usage(root: Path, maximum: int, *, building: bool = False, compiler_locks: bool = False, fixture_links: dict | None = None) -> dict:
    if not root.exists():
        return dict(bytes=0, entries=0)
    total = count = lock_count = 0
    pending = [root]
    device = root.lstat().st_dev
    while pending:
        path = pending.pop()
        try:
            facts = path.lstat()
        except FileNotFoundError:
            if building and root == TOOLING:
                continue # Cargo can retire temporary object names during a build.
            raise
        count += 1
        total += max(facts.st_size, facts.st_blocks * 512)
        if facts.st_dev != device or facts.st_uid != os.getuid():
            raise RuntimeError("Changed B10 fixture/tooling ownership or device")
        if stat.S_ISDIR(facts.st_mode):
            try:
                pending.extend(path.iterdir())
            except FileNotFoundError:
                if not building or root != TOOLING:
                    raise
        elif stat.S_ISLNK(facts.st_mode) and root == TOOLING and path == TOOLING / 'folder-local-contracts/debug':
            if not native_contract_link(path, os.readlink(path), device):
                raise RuntimeError('Redirected native contract convenience link')
        elif stat.S_ISLNK(facts.st_mode) and root == TOOLING and building and compiler_locks:
            try: target = os.readlink(path)
            except FileNotFoundError: continue
            lock_count += 1
            if lock_count > 64 or not native_compiler_lock(path,target):
                raise RuntimeError("Unexpected native compiler lock: " + str(path.relative_to(TOOLING)))
        elif fixture_links and path in fixture_links:
            verify_fixture_link(path,facts,fixture_links[path])
        elif not stat.S_ISREG(facts.st_mode) or (facts.st_nlink != 1 and root != TOOLING):
            raise RuntimeError("Unexpected B10 fixture/tooling entry: " + str(path.relative_to(root)))
        if total > maximum or count > 100_000:
            raise RuntimeError("B10 fixture/tooling allowance exceeded")
    return dict(bytes=total, entries=count)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def put(path: Path, value: object) -> None:
    raw = json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
    if len(raw) > MIB:
        raise RuntimeError("B10 receipt too large")
    with path.open("xb") as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())


def environment() -> dict[str, str]:
    # No inherited Cargo tokens/configuration, SSH agents, tracing or dynamic
    # library overrides. HOME is neither repurposed nor supplied to the worker.
    directory(TOOLING)
    for leaf in ["cargo-home", "rustup-home", "tmp", "target"]:
        directory(TOOLING / leaf)
    return dict(PATH=str(TOOLCHAIN / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
                CARGO_HOME=str(TOOLING / "cargo-home"),
                RUSTUP_HOME=str(TOOLING / "rustup-home"),
                RUSTC=str(TOOLCHAIN / "bin/rustc"),
                RUSTDOC=str(TOOLCHAIN / "bin/rustdoc"),
                CARGO_TARGET_DIR=str(TOOLING / "target"),
                CARGO_BUILD_JOBS="4", CARGO_INCREMENTAL="0",
                MACOSX_DEPLOYMENT_TARGET="15.0", TMPDIR=str(TOOLING / "tmp"),
                LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")


def reservations(root: Path = PACKET) -> dict:
    """Count explicit reservations, never charge a lock as an imaginary case."""
    actual = usage(root, 512 * MIB)
    reserved_bytes = reserved_entries = 0
    for case in root.iterdir():
        if case.is_file() and case.name in ["live.lock", "signed.lock", ".budget.lock"]:
            continue
        if not case.is_dir() or str(uuid.UUID(case.name)).upper() != case.name:
            raise RuntimeError("Unexpected B10 qualification case")
        value = json.loads((case / "reservation.json").read_bytes())
        amount, entries = value.get("bytes"), value.get("entries")
        if (type(amount) is not int or type(entries) is not int or not 0 < amount <= 64 * MIB
                or not 0 < entries <= 8192):
            raise RuntimeError("Invalid B10 case reservation")
        owned = usage(case, amount)
        if owned["entries"] > entries:
            raise RuntimeError("B10 case entry reservation exceeded")
        reserved_bytes += amount; reserved_entries += entries
    if reserved_bytes > 512 * MIB or reserved_entries > 8192 or actual["bytes"] > 16 * MIB:
        raise RuntimeError("B10 aggregate reservation/receipt allowance exceeded")
    return dict(**actual, reservedBytes=reserved_bytes, reservedEntries=reserved_entries)


def reserve(action: str, *, amount: int = 16 * MIB, entries: int = 64, candidate: str = "smb2") -> Path:
    directory(PACKET)
    with (PACKET / ".budget.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = reservations()
        if (not 0 < amount <= 64 * MIB or entries <= 0
                or before["reservedBytes"] + amount > 512 * MIB
                or before["reservedEntries"] + entries > 8192
                or before["bytes"] + min(amount, 8 * MIB) > 16 * MIB):
            raise RuntimeError("No B10 explicit reservation/receipt headroom")
        case = directory(PACKET / str(uuid.uuid4()).upper())
        put(case / "reservation.json", dict(version=1, bytes=amount, entries=entries, candidate=candidate, action=action))
        return case
