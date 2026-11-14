"""Separate generated native/paging envelope; retain the original B11 packet."""
import fcntl
import json
import os
import uuid
from packet import REPO, MIB, directory, put, measure, audit as reader_audit

ROOT=REPO/'.build/b11-native-qualification'

def audit():
    original=reader_audit();directory(ROOT)
    total=dict(bytes=0,entries=0,reservedBytes=0,reservedEntries=0,sourceBytes=0,evidenceBytes=0)
    for case in ROOT.iterdir():
        if case.name=='.budget.lock':continue
        if case.is_symlink()or not case.is_dir()or str(uuid.UUID(case.name)).upper()!=case.name:raise RuntimeError('Unknown B11 native case')
        limit=json.loads((case/'reservation.json').read_bytes())
        if limit.get('packet')!='b11-native-v1':raise RuntimeError('Wrong native packet')
        fixture_root=case/'source' if limit.get('action')=='sftp-notices-and-cli' else None
        found=measure(case,fixture_root=fixture_root)
        if found['bytes']>limit['bytes']or found['entries']>limit['entries']:raise RuntimeError('Native case exceeds reservation')
        for key in ['bytes','entries']:total[key]+=found[key]
        total['reservedBytes']+=limit['bytes'];total['reservedEntries']+=limit['entries']
        for area,key in [('source','sourceBytes'),('evidence','evidenceBytes')]:
            if(case/area).exists():total[key]+=measure(case/area,fixture_root=fixture_root)['bytes']
    if total['reservedBytes']>3072*MIB or total['reservedEntries']>20480 or total['sourceBytes']>16*MIB or total['evidenceBytes']>32*MIB:
        raise RuntimeError('Native packet ceiling exceeded')
    return dict(**total,original=original)

def reserve(action,size=16*MIB,entries=128):
    directory(ROOT)
    fd=os.open(ROOT/'.budget.lock',os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a+b')as lock:
        import stat
        facts=os.fstat(lock.fileno())
        if not stat.S_ISREG(facts.st_mode)or facts.st_nlink!=1 or facts.st_uid!=os.getuid()or facts.st_mode&0o077:raise RuntimeError('Unsafe native budget lock')
        fcntl.flock(lock,fcntl.LOCK_EX);before=audit()
        if not 0<size<=128*MIB or not 0<entries<=20480 or before['reservedBytes']+size>3072*MIB or before['reservedEntries']+entries>20480:
            raise RuntimeError('Native packet headroom exhausted')
        case=directory(ROOT/str(uuid.uuid4()).upper())
        put(case/'reservation.json',dict(packet='b11-native-v1',action=action,bytes=size,entries=entries))
        directory(case/'evidence');return case
