"""Isolated fresh-upload controls; no ordinary activation or personal endpoint."""
import fcntl
import json
import os
import re
from pathlib import Path
import stat
import sys
import uuid
sys.dont_write_bytecode=True
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/sftp_reader'))
from packet import MIB,TOOLCHAIN,TOOLING,environment,directory,put,audit as shared_audit
ROOT=REPO/'.build/b12-upload-qualification'
def measure(root,envelope=ROOT):
    result=dict(bytes=0,allocatedBytes=0,entries=0);pending=[root]
    while pending:
        path=pending.pop();value=path.lstat()
        if value.st_uid!=os.getuid():raise RuntimeError('Changed upload evidence owner')
        result['bytes']+=max(value.st_size,value.st_blocks*512);result['allocatedBytes']+=value.st_blocks*512;result['entries']+=1
        if stat.S_ISDIR(value.st_mode):pending.extend(path.iterdir())
        elif stat.S_ISLNK(value.st_mode):
            # One retained generated refusal control only, never followed.
            parts=path.relative_to(envelope).parts
            if len(parts)!=4 or parts[1]!='source'or parts[3]!='generated-source-link' \
                or str(uuid.UUID(parts[2])).upper()!=parts[2] or os.readlink(path)!='Generated.bin' \
                or not stat.S_ISREG((path.parent/'Generated.bin').lstat().st_mode):raise RuntimeError('Unknown upload fixture link')
        elif not stat.S_ISREG(value.st_mode)or value.st_nlink!=1:raise RuntimeError('Unexpected upload evidence entry')
    return result
def audit():
    tooling=shared_audit();directory(ROOT)
    total=dict(bytes=0,entries=0,reservedBytes=0,reservedEntries=0,sourceBytes=0,evidenceBytes=0)
    for case in ROOT.iterdir():
        if case.name=='.budget.lock':continue
        if case.is_symlink()or not case.is_dir()or str(uuid.UUID(case.name)).upper()!=case.name:raise RuntimeError('Unknown upload case')
        marker=json.loads((case/'reservation.json').read_bytes())
        if marker.get('packet')!='b12-upload-v1':raise RuntimeError('Unknown upload packet')
        found=measure(case)
        if found['bytes']>marker['bytes']or found['entries']>marker['entries']:raise RuntimeError('Upload case ceiling')
        for key in ['bytes','entries']:total[key]+=found[key]
        total['reservedBytes']+=marker['bytes'];total['reservedEntries']+=marker['entries']
        for area,key in [('source','sourceBytes'),('evidence','evidenceBytes')]:
            if(case/area).exists():total[key]+=measure(case/area)['bytes']
    if total['reservedBytes']>256*MIB or total['reservedEntries']>8192 or total['sourceBytes']>16*MIB or total['evidenceBytes']>16*MIB:raise RuntimeError('Upload packet ceiling')
    return dict(**total,sharedTooling=tooling['tooling'])
def locked():
    directory(ROOT);descriptor=os.open(ROOT/'.budget.lock',os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    lock=os.fdopen(descriptor,'a+b');facts=os.fstat(descriptor)
    if not stat.S_ISREG(facts.st_mode)or facts.st_nlink!=1 or facts.st_uid!=os.getuid()or facts.st_mode&0o077:lock.close();raise RuntimeError('Upload lock authority')
    fcntl.flock(descriptor,fcntl.LOCK_EX);current=(ROOT/'.budget.lock').lstat()
    if(facts.st_dev,facts.st_ino)!=(current.st_dev,current.st_ino):lock.close();raise RuntimeError('Upload lock changed')
    return lock
def reserve(action,size=8*MIB,entries=256):
    with locked():
        value=audit()
        if not 0<size<=64*MIB or not 0<entries<=8192 or value['reservedBytes']+size>256*MIB or value['reservedEntries']+entries>8192:raise RuntimeError('Upload admission ceiling')
        case=directory(ROOT/str(uuid.uuid4()).upper());put(case/'reservation.json',dict(packet='b12-upload-v1',action=action,bytes=size,entries=entries));directory(case/'evidence');return case
def admit_connection(case,scenario):
    with locked():
        audit()
        if case.parent!=ROOT or case.is_symlink()or case.resolve()!=case or str(uuid.UUID(case.name)).upper()!=case.name \
            or json.loads((case/'reservation.json').read_bytes()).get('packet')!='b12-upload-v1' or not re.fullmatch(r'[a-z0-9-]{1,64}',scenario):raise RuntimeError('Unknown upload network scope')
        prior=list(ROOT.glob('*/evidence/connection-*-admitted.json'))
        for path in prior:
            claim=json.loads(path.read_bytes())
            if claim.get('scope')!='generated-loopback-only'or claim.get('connectionAttempts')!=1:raise RuntimeError('Unknown upload connection ledger')
        if len(prior)>=16:raise RuntimeError('Generated upload connection ceiling')
        receipt=case/'evidence'/('connection-'+scenario+'-admitted.json')
        put(receipt,dict(scope='generated-loopback-only',ordinal=len(prior)+1,connectionAttempts=1,personalEndpoints=0,keychainQueries=0))
        with receipt.open('rb')as file:os.fsync(file.fileno())
        descriptor=os.open(receipt.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(descriptor)
        finally:os.close(descriptor)
