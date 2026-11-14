"""Generated read-only ZIP preview packet, separate from older archive caps."""
import fcntl
import json
import os
from pathlib import Path
import stat
import uuid

REPO=Path(__file__).resolve().parents[1]
ROOT=REPO/'.build/b09-text-preview'
MIB=1024*1024


def directory(path):
    current=Path(path.anchor)
    for part in path.parts[1:]:
        current/=part
        if current.is_symlink():raise RuntimeError('Redirected ZIP preview packet directory')
        current.mkdir(mode=0o700,exist_ok=True)
        if not current.is_dir():raise RuntimeError('ZIP preview packet directory unavailable')
    return path


def put(path,value):
    with path.open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2);stream.write('\n')


def measure(root):
    amount=count=0;pending=[root]
    while pending:
        path=pending.pop();info=path.lstat();count+=1
        if info.st_uid!=os.getuid():raise RuntimeError('Foreign ZIP preview fixture owner')
        if stat.S_ISDIR(info.st_mode):pending.extend(path.iterdir())
        elif not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:raise RuntimeError('Unexpected ZIP preview fixture type')
        amount+=max(info.st_size,info.st_blocks*512)
    return dict(bytes=amount,entries=count)


def audit():
    directory(ROOT);reserved=count=source=receipts=actual=0
    for case in ROOT.iterdir():
        if case.name=='.budget.lock':continue
        if case.is_symlink() or not case.is_dir() or str(uuid.UUID(case.name)).upper()!=case.name:raise RuntimeError('Unknown ZIP preview case')
        limits=json.loads((case/'reservation.json').read_bytes());size=measure(case)
        if size['bytes']>limits['bytes'] or size['entries']>limits['entries']:raise RuntimeError('ZIP preview case exceeded')
        reserved+=limits['bytes'];count+=limits['entries'];actual+=size['bytes']
        for name,kind in [('source','source'),('evidence','evidence')]:
            if (case/name).exists():
                if kind=='source':source+=measure(case/name)['bytes']
                else:receipts+=measure(case/name)['bytes']
    if reserved>512*MIB or count>8192 or source>64*MIB or receipts>16*MIB:raise RuntimeError('ZIP preview packet allowance exceeded')
    return dict(reservedBytes=reserved,reservedEntries=count,sourceBytes=source,receiptBytes=receipts,actualBytes=actual)


def reserve(action,amount=64*MIB,entries=1024):
    directory(ROOT)
    fd=os.open(ROOT/'.budget.lock',os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a+b') as lock:
        facts=os.fstat(lock.fileno())
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=1 or facts.st_uid!=os.getuid() or facts.st_mode&0o077:raise RuntimeError('Unsafe ZIP preview budget lock')
        fcntl.flock(lock,fcntl.LOCK_EX);before=audit()
        if not 0<amount<=64*MIB or before['reservedBytes']+amount>512*MIB or before['reservedEntries']+entries>8192:raise RuntimeError('ZIP preview reservations exhausted')
        case=directory(ROOT/str(uuid.uuid4()).upper())
        put(case/'reservation.json',dict(packet='b09-text-preview-v1',action=action,bytes=amount,entries=entries))
        directory(case/'source');directory(case/'evidence');return case
