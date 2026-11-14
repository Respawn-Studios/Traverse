"""Separate generated sandbox qualification; never adopts or cleans old cases."""
import fcntl
import json
import os
from pathlib import Path
import stat
import uuid

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / '.build/distribution-qualification'
TOOLING = REPO / '.build/distribution-tooling'
MIB = 1024 * 1024


def directory(path):
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink(): raise RuntimeError('Redirected sandbox packet directory')
        current.mkdir(mode=0o700, exist_ok=True)
        if not current.is_dir(): raise RuntimeError('Unavailable sandbox packet directory')
    return path


def put(path, value):
    with path.open('x') as stream: json.dump(value, stream, sort_keys=True, indent=2); stream.write('\n')


def measure(root, transient=False):
    size = count = allocated = 0
    pending = [root]
    while pending:
        path = pending.pop()
        try: facts = path.lstat()
        except FileNotFoundError:
            if transient: continue
            raise
        count += 1; allocated += facts.st_blocks * 512
        size += max(facts.st_size, facts.st_blocks * 512)
        if stat.S_ISDIR(facts.st_mode): pending.extend(path.iterdir())
    return dict(bytes=size, allocatedBytes=allocated, entries=count)


def audit():
    directory(ROOT); reserved = entries = 0; actual = 0
    for case in ROOT.iterdir():
        if case.name == '.budget.lock': continue
        if case.is_symlink() or not case.is_dir() or str(uuid.UUID(case.name)).upper() != case.name:
            raise RuntimeError('Unknown sandbox qualification entry')
        limits = json.loads((case / 'reservation.json').read_bytes()); found = measure(case)
        if found['bytes'] > limits['bytes'] or found['entries'] > limits['entries']:
            raise RuntimeError('Sandbox qualification case exceeded its allowance')
        if (case/'source').exists() and measure(case/'source')['bytes'] > 4*MIB:
            raise RuntimeError('Sandbox source-data ceiling exceeded')
        if (case/'evidence').exists() and measure(case/'evidence')['bytes'] > 16*MIB:
            raise RuntimeError('Sandbox evidence ceiling exceeded')
        reserved += limits['bytes']; entries += limits['entries']; actual += found['bytes']
    # Xcode's SDK stat cache can have tens of GiB of sparse address space with
    # only MiB actually allocated. Source/case caps above still count logical
    # bytes; compiler tooling reports both and caps observed disk allocation.
    tooling = measure(TOOLING, transient=True) if TOOLING.exists() else dict(bytes=0,allocatedBytes=0,entries=0)
    if reserved > 1280*MIB or entries > 5120 or tooling['allocatedBytes'] > 2*1024*MIB:
        raise RuntimeError('Sandbox qualification aggregate/tooling ceiling exceeded')
    return dict(reservedBytes=reserved, reservedEntries=entries, actualBytes=actual, tooling=tooling)


def reserve():
    directory(ROOT)
    descriptor = os.open(ROOT/'.budget.lock', os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor,'a+b') as lock:
        facts = os.fstat(lock.fileno())
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or facts.st_uid != os.getuid() or facts.st_mode & 0o077:
            raise RuntimeError('Unsafe sandbox budget lock')
        fcntl.flock(lock, fcntl.LOCK_EX); before = audit()
        if before['reservedBytes'] + 256*MIB > 1280*MIB or before['reservedEntries']+1024>5120:
            raise RuntimeError('Sandbox cases exhausted')
        case = directory(ROOT/str(uuid.uuid4()).upper())
        put(case/'reservation.json', dict(packet='sandbox-foundation-v1', bytes=256*MIB, entries=1024))
        return case
