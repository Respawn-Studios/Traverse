"""Generated overnight foundation evidence; no user files or global changes.

Separate from all B06/B07/B10 allowances:512 MiB total,64 MiB/case,16,384
entries,16 MiB source,32 MiB receipts. Failed evidence is preserved.
"""
import fcntl
import json
import os
from pathlib import Path
import stat
import uuid
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1] / '.build/overnight-foundation'
MIB = 1024 * 1024


def directory(path):
    parent = Path(path.anchor)
    for part in path.parts[1:]:
        parent /= part
        if parent.is_symlink(): raise RuntimeError('Redirected generated evidence directory')
        parent.mkdir(mode=0o700,exist_ok=True)
        if not parent.is_dir(): raise RuntimeError('Unavailable generated evidence directory')
    return path


def put(path,value):
    with path.open('x') as out: json.dump(value,out,sort_keys=True,indent=2);out.write('\n')


def measure(case):
    total = count = source = receipts = 0
    pending = [case]
    device = case.lstat().st_dev
    while pending:
        path = pending.pop(); facts = path.lstat(); count += 1
        amount = max(facts.st_size,facts.st_blocks*512); total += amount
        if facts.st_uid != os.getuid() or facts.st_dev != device: raise RuntimeError('Changed generated fixture owner/device')
        if stat.S_ISDIR(facts.st_mode): pending.extend(path.iterdir())
        elif stat.S_ISLNK(facts.st_mode):
            target = Path(os.readlink(path))
            if not target.is_absolute(): target = path.parent/target
            if '..' in target.parts or not target.is_relative_to(case/'source'): raise RuntimeError('Generated refusal link escapes its case')
        elif not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1: raise RuntimeError('Unexpected generated fixture entry')
        if path != case:
            area = path.relative_to(case).parts[0]
            if area == 'source': source += amount
            elif area == 'evidence': receipts += amount
    return dict(bytes=total,entries=count,sourceBytes=source,receiptBytes=receipts)


def audit():
    directory(ROOT)
    result = dict(bytes=0,entries=0,sourceBytes=0,receiptBytes=0,reservedBytes=0,reservedEntries=0)
    for case in ROOT.iterdir():
        if case.name == '.budget.lock': continue
        if case.is_symlink() or not case.is_dir() or str(uuid.UUID(case.name)).upper()!=case.name: raise RuntimeError('Unexpected foundation case')
        limits = json.loads((case/'reservation.json').read_bytes()); found = measure(case)
        if found['bytes']>limits['bytes'] or found['entries']>limits['entries']: raise RuntimeError('Foundation case exceeded')
        for key,value in found.items(): result[key] += value
        result['reservedBytes'] += limits['bytes']; result['reservedEntries'] += limits['entries']
    if result['reservedBytes']>512*MIB or result['reservedEntries']>16384 or result['sourceBytes']>16*MIB or result['receiptBytes']>32*MIB:
        raise RuntimeError('Foundation aggregate allowance exceeded')
    return result


def reserve(action,amount=8*MIB,entries=256):
    directory(ROOT)
    fd = os.open(ROOT/'.budget.lock',os.O_RDWR|os.O_CREAT|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a+b') as lock:
        facts = os.fstat(lock.fileno())
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=1 or facts.st_uid!=os.getuid() or facts.st_mode&0o077: raise RuntimeError('Unsafe foundation reservation lock')
        fcntl.flock(lock,fcntl.LOCK_EX); before=audit()
        if not 0<amount<=64*MIB or not 0<entries<=16384 or before['reservedBytes']+amount>512*MIB or before['reservedEntries']+entries>16384:
            raise RuntimeError('No foundation evidence headroom')
        case=directory(ROOT/str(uuid.uuid4()).upper())
        put(case/'reservation.json',dict(action=action,bytes=amount,entries=entries)); return case
