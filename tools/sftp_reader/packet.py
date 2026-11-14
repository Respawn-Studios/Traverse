"""Separate generated-only B11 qualification and repo-local tooling budgets."""
import fcntl
import json
import os
from pathlib import Path
import stat
import re
import uuid
import sys
sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / '.build/b11-reader-qualification'
TOOLING = REPO / '.build/b11-reader-tooling'
TOOLCHAIN = REPO / '.build/b06-toolchain/rust-1.99.1'
MIB = 1 << 20


def directory(path):
    path.relative_to(REPO / '.build')
    current = REPO
    for part in path.relative_to(REPO).parts:
        if part in ['', '.', '..']: raise RuntimeError('Invalid B11 generated path')
        current /= part
        current.mkdir(mode=0o700, exist_ok=True)
        value = current.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid():
            raise RuntimeError('Redirected/unowned B11 directory')
    return path


def put(path, value):
    with path.open('x') as out:
        json.dump(value, out, sort_keys=True, indent=2)
        out.write('\n')


def measure(root, transient=False, tooling=False, fixture_root=None):
    values = dict(bytes=0, allocatedBytes=0, entries=0)
    compiler_locks=0
    pending = [root]
    while pending:
        path = pending.pop()
        try: value = path.lstat()
        except FileNotFoundError:
            if transient: continue
            raise
        if value.st_uid != os.getuid(): raise RuntimeError('Changed B11 owner')
        values['bytes'] += max(value.st_size, value.st_blocks*512)
        values['allocatedBytes'] += value.st_blocks*512
        values['entries'] += 1
        if stat.S_ISDIR(value.st_mode): pending.extend(path.iterdir())
        elif stat.S_ISLNK(value.st_mode) and tooling:
            # Clang uses unfollowed symlinks for ephemeral module locks. Accept
            # only bounded lock names/targets in this exact private cache.
            path.relative_to(TOOLING/'swift-module-cache')
            target=os.readlink(path);compiler_locks+=1
            name_ok=re.fullmatch(r'[A-Za-z0-9_+.=-]{1,220}\.lock(?:-[a-fA-F0-9]+)?',path.name)
            short_ok=re.fullmatch(r'[A-Za-z0-9_.:@+-]{1,255}',target)and target not in ['.','..']
            peer=Path(target)
            peer_ok=len(target.encode())<=4096 and peer.is_absolute()and'..'not in peer.parts \
                and peer.parent==path.parent and re.fullmatch(re.escape(path.name)+r'-[a-fA-F0-9]{4,32}',peer.name)
            if compiler_locks>64 or not name_ok or not(short_ok or peer_ok):raise RuntimeError('Unexpected native compiler lock')
        elif stat.S_ISLNK(value.st_mode) and fixture_root is not None:
            # Only the explicit notice-security packet creates these links.
            # Count their metadata, never traverse them or admit outside data.
            path.relative_to(fixture_root)
            target=os.readlink(path)
            if len(target.encode())>4096 or not path.resolve(strict=True).is_relative_to(fixture_root):raise RuntimeError('Notice fixture link escapes owned source')
        elif not stat.S_ISREG(value.st_mode) or (not tooling and value.st_nlink != 1):
            raise RuntimeError('Unexpected B11 generated entry')
    return values


def audit():
    directory(ROOT); directory(TOOLING)
    total = dict(bytes=0, entries=0, reservedBytes=0, reservedEntries=0, sourceBytes=0, evidenceBytes=0)
    for case in ROOT.iterdir():
        if case.name == '.budget.lock': continue
        if case.is_symlink() or not case.is_dir() or str(uuid.UUID(case.name)).upper() != case.name:
            raise RuntimeError('Unknown B11 qualification case')
        limits = json.loads((case/'reservation.json').read_bytes())
        if limits.get('packet') != 'b11-reader-v1': raise RuntimeError('Wrong B11 packet')
        found = measure(case)
        if found['bytes'] > limits['bytes'] or found['entries'] > limits['entries']:
            raise RuntimeError('B11 case exceeded its reservation')
        total['bytes'] += found['bytes']; total['entries'] += found['entries']
        total['reservedBytes'] += limits['bytes']; total['reservedEntries'] += limits['entries']
        for area, key in [('source','sourceBytes'), ('evidence','evidenceBytes')]:
            if (case/area).exists(): total[key] += measure(case/area)['bytes']
    tooling = measure(TOOLING, transient=True, tooling=True)
    if total['reservedBytes'] > 512*MIB or total['reservedEntries'] > 8192 or total['sourceBytes'] > 32*MIB \
            or total['evidenceBytes'] > 24*MIB or tooling['allocatedBytes'] > 2048*MIB:
        raise RuntimeError('B11 aggregate/tooling ceiling exceeded')
    if (TOOLING/'downloads').exists() and measure(TOOLING/'downloads')['bytes'] > 128*MIB:
        raise RuntimeError('B11 retained source archives exceeded')
    return dict(**total, tooling=tooling)


def reserve(action, size=16*MIB, entries=256):
    directory(ROOT)
    fd = os.open(ROOT/'.budget.lock', os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a+b') as lock:
        value = os.fstat(lock.fileno())
        if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_uid != os.getuid() or value.st_mode & 0o077:
            raise RuntimeError('Unsafe B11 reservation lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = audit()
        if not 0 < size <= 64*MIB or not 0 < entries <= 8192 or before['reservedBytes']+size > 512*MIB \
                or before['reservedEntries']+entries > 8192: raise RuntimeError('B11 reservation headroom exhausted')
        case = directory(ROOT/str(uuid.uuid4()).upper())
        put(case/'reservation.json',dict(packet='b11-reader-v1', action=action, bytes=size, entries=entries))
        directory(case/'evidence'); return case


def environment(native=False):
    for area in ['cargo-home','rustup-home','target','tmp']: directory(TOOLING/area)
    value=dict(PATH=str(TOOLCHAIN/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin', CARGO_HOME=str(TOOLING/'cargo-home'),
        RUSTUP_HOME=str(TOOLING/'rustup-home'), RUSTC=str(TOOLCHAIN/'bin/rustc'), RUSTDOC=str(TOOLCHAIN/'bin/rustdoc'),
        CARGO_TARGET_DIR=str(TOOLING/'target'), CARGO_INCREMENTAL='0', CARGO_BUILD_JOBS='4',
        MACOSX_DEPLOYMENT_TARGET='15.0', TMPDIR=str(TOOLING/'tmp'), LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
    if native:
        cache=directory(TOOLING/'swift-module-cache');home=directory(TOOLING/'native-user')
        value.update(CLANG_MODULE_CACHE_PATH=str(cache),SWIFTPM_MODULECACHE_OVERRIDE=str(cache),CFFIXED_USER_HOME=str(home))
    return value
