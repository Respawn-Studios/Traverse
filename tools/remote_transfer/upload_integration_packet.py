"""Separate bounded streamed/native upload increment, preserving prior evidence."""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid
sys.dont_write_bytecode=True
from upload_packet import REPO,TOOLCHAIN,TOOLING,directory,put,audit as foundation_audit,measure as source_measure
ROOT=REPO/'.build/b12-upload-integration'
MIB=1<<20
def measure(path):return source_measure(path,envelope=ROOT)
def audit():
    foundation=foundation_audit();directory(ROOT)
    total=dict(bytes=0,entries=0,reservedBytes=0,reservedEntries=0,sourceBytes=0,evidenceBytes=0)
    for case in ROOT.iterdir():
        if case.name=='.budget.lock':continue
        if case.is_symlink()or not case.is_dir()or str(uuid.UUID(case.name)).upper()!=case.name:raise RuntimeError('Unknown upload integration case')
        limit=json.loads((case/'reservation.json').read_bytes())
        if limit.get('packet')!='b12-upload-integration-v1':raise RuntimeError('Unknown upload integration authority')
        found=measure(case)
        if found['bytes']>limit['bytes']or found['entries']>limit['entries']:raise RuntimeError('Upload integration case ceiling')
        for key in ['bytes','entries']:total[key]+=found[key]
        total['reservedBytes']+=limit['bytes'];total['reservedEntries']+=limit['entries']
        for area,key in [('source','sourceBytes'),('evidence','evidenceBytes')]:
            if(case/area).exists():total[key]+=measure(case/area)['bytes']
    if total['reservedBytes']>512*MIB or total['reservedEntries']>16384 or total['sourceBytes']>32*MIB or total['evidenceBytes']>32*MIB:raise RuntimeError('Upload integration envelope')
    return dict(**total,foundation=foundation,sharedTooling=foundation['sharedTooling'])
def locked():
    directory(ROOT);fd=os.open(ROOT/'.budget.lock',os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,0o600);held=os.fdopen(fd,'a+b')
    value=os.fstat(fd)
    if not stat.S_ISREG(value.st_mode)or value.st_nlink!=1 or value.st_uid!=os.getuid()or value.st_mode&0o077:held.close();raise RuntimeError('Upload integration lock')
    fcntl.flock(fd,fcntl.LOCK_EX);fresh=(ROOT/'.budget.lock').lstat()
    if(value.st_dev,value.st_ino)!=(fresh.st_dev,fresh.st_ino):held.close();raise RuntimeError('Upload integration lock changed')
    return held
def reserve(action,size=8*MIB,entries=256):
    with locked():
        value=audit()
        if not 0<size<=128*MIB or not 0<entries<=16384 or value['reservedBytes']+size>512*MIB or value['reservedEntries']+entries>16384:raise RuntimeError('Upload integration admission')
        case=directory(ROOT/str(uuid.uuid4()).upper());put(case/'reservation.json',dict(packet='b12-upload-integration-v1',action=action,bytes=size,entries=entries));directory(case/'evidence');return case
def admit_connection(case,scenario):
    from upload_packet import ROOT as FOUNDATION
    with locked():
        audit()
        if case.parent!=ROOT or case.is_symlink()or case.resolve()!=case or not re.fullmatch(r'[a-z0-9-]{1,64}',scenario):raise RuntimeError('Unknown upload connection scope')
        old=list(FOUNDATION.glob('*/evidence/connection-*-admitted.json'));new=list(ROOT.glob('*/evidence/connection-*-admitted.json'))
        for path in old+new:
            value=json.loads(path.read_bytes())
            if value.get('scope')!='generated-loopback-only'or value.get('connectionAttempts')!=1:raise RuntimeError('Unknown cumulative upload connection')
        if len(old)>16 or len(new)>=16 or len(old)+len(new)>=32:raise RuntimeError('Cumulative upload network ceiling')
        receipt=case/'evidence'/('connection-'+scenario+'-admitted.json')
        put(receipt,dict(scope='generated-loopback-only',connectionAttempts=1,ordinal=len(old)+len(new)+1,integrationOrdinal=len(new)+1,personalEndpoints=0,keychainQueries=0))
        with receipt.open('rb')as file:os.fsync(file.fileno())
        fd=os.open(receipt.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
