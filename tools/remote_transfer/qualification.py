"""Generated-only B12 transfer qualification; B11 tooling cap is shared."""
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import uuid
sys.dont_write_bytecode=True
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/sftp_reader'))
from packet import MIB,TOOLCHAIN,environment,directory,put,measure,audit as tooling_audit
ROOT=REPO/'.build/b12-download-qualification'
# Consolidated 23 October local-destination lifetime packet under the extended
# owner authority. Preserve every old admission, payload and failed case.
# Byte/source/tooling caps remain unchanged. See B12_PANE_DESTINATION_ACCESS.
RESERVED_ENTRY_LIMIT=34304
NETWORK_CONNECTION_LIMIT=45
def measured(root,case,limit):
    source=case/'source'
    scoped=limit.get('action')in['download-browser-debug','download-browser-release']
    if scoped and source.exists():
        links=[p for p in source.iterdir()if p.is_symlink()]
        if len(links)>1:raise RuntimeError('Unexpected B12 refusal links')
        for path in links:
            if not path.name.startswith('pump-')or str(uuid.UUID(path.name[5:]))!=path.name[5:].lower()or os.readlink(path)!=str(source):raise RuntimeError('B12 refusal link scope')
    return measure(root,fixture_root=source if scoped else None)
def audit():
    tooling=tooling_audit();directory(ROOT)
    total=dict(bytes=0,entries=0,reservedBytes=0,reservedEntries=0,sourceBytes=0,evidenceBytes=0)
    for case in ROOT.iterdir():
        if case.name=='.budget.lock':continue
        if case.is_symlink() or not case.is_dir() or str(uuid.UUID(case.name)).upper()!=case.name:raise RuntimeError('Unknown B12 case')
        limit=json.loads((case/'reservation.json').read_bytes())
        if limit.get('packet')!='b12-download-v1':raise RuntimeError('Wrong B12 packet')
        found=measured(case,case,limit)
        if found['bytes']>limit['bytes'] or found['entries']>limit['entries']:raise RuntimeError('B12 case bound')
        for key in ['bytes','entries']:total[key]+=found[key]
        total['reservedBytes']+=limit['bytes'];total['reservedEntries']+=limit['entries']
        for area,key in [('source','sourceBytes'),('evidence','evidenceBytes')]:
            if(case/area).exists():total[key]+=measured(case/area,case,limit)['bytes']
    if total['reservedBytes']>640*MIB or total['reservedEntries']>RESERVED_ENTRY_LIMIT or total['sourceBytes']>32*MIB or total['evidenceBytes']>16*MIB:raise RuntimeError('B12 packet ceiling')
    return dict(**total,sharedTooling=tooling['tooling'])
def reserve(action,size=8*MIB,entries=128):
    directory(ROOT);descriptor=os.open(ROOT/'.budget.lock',os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    with os.fdopen(descriptor,'a+b')as lock:
        facts=os.fstat(lock.fileno())
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=1 or facts.st_uid!=os.getuid() or facts.st_mode&0o077:raise RuntimeError('B12 budget lock')
        fcntl.flock(lock,fcntl.LOCK_EX);current=(ROOT/'.budget.lock').lstat()
        if(facts.st_dev,facts.st_ino)!=(current.st_dev,current.st_ino):raise RuntimeError('B12 lock changed')
        before=audit()
        if not 0<size<=64*MIB or not 0<entries<=32768 or before['reservedBytes']+size>640*MIB or before['reservedEntries']+entries>RESERVED_ENTRY_LIMIT:raise RuntimeError('B12 admission headroom')
        case=directory(ROOT/str(uuid.uuid4()).upper());put(case/'reservation.json',dict(packet='b12-download-v1',action=action,bytes=size,entries=entries));directory(case/'evidence');return case
def admit_generated_connection(case,scenario):
    with(ROOT/'.budget.lock').open('a+b')as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);audit()
        if case.parent!=ROOT or case.is_symlink():raise RuntimeError('Unknown B12 network case')
        previous=list(ROOT.glob('*/evidence/connection-*-admitted.json'))
        for path in previous:
            prior=json.loads(path.read_bytes())
            if prior.get('scope')!='generated-loopback-only' or prior.get('connectionAttempts')!=1:raise RuntimeError('Unknown B12 network ledger')
        if len(previous)>=NETWORK_CONNECTION_LIMIT:raise RuntimeError('B12 encrypted connection ceiling')
        receipt=case/'evidence'/('connection-'+scenario+'-admitted.json')
        put(receipt,dict(scope='generated-loopback-only',connectionAttempts=1,ordinal=len(previous)+1,personalEndpoints=0,keychainQueries=0))
        with receipt.open('rb')as file:os.fsync(file.fileno())
        descriptor=os.open(receipt.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(descriptor)
        finally:os.close(descriptor)
