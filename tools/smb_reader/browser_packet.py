"""Separate owner-approved B10 native-browsing qualification allowance.

256 MiB total, 64 MiB/case, 8,384 filesystem entries; source and receipts each
at most16 MiB within that total. Existing reader evidence/tooling are separate
and remain untouched. All paths stay inside this repository's ignored .build.
"""
import fcntl
import json
import os
import stat
import uuid

from packet import MIB, REPO, directory, put, usage, digest

ROOT = REPO/".build/b10-browser-qualification"
# Owner-approved consolidated completion headroom, 21 October 2026.
# Per-case limits and all byte ceilings stay unchanged.
MAX_ENTRIES = 8384


def fixture_link_controls():
    """Count exact generated rejection controls without following symbolic links.

    Accepted only for the saved-server packet, at most 16 records/case. A hard
    link pair must be entirely inside its case; no unaccounted external alias.
    """
    allowed={}
    for case in ROOT.iterdir():
        if case.name=='.budget.lock':continue
        facts=case.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid!=os.getuid() or str(uuid.UUID(case.name)).upper()!=case.name:
            raise RuntimeError('Unexpected generated control namespace')
        marker=case/'fixture-links.json'
        if not marker.exists() and not marker.is_symlink():continue
        fd=os.open(marker,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_uid!=os.getuid() or not 0<info.st_size<=16384:
                raise RuntimeError('Unsafe generated control receipt')
            value=json.loads(os.read(fd,16385))
        finally:os.close(fd)
        reservation=json.loads((case/'reservation.json').read_bytes())
        controls=value.get('entries')
        if value.get('version')!=1 or value.get('guardChecksPassed') is not True or not reservation.get('action','').startswith('saved-server-store-') \
            or not isinstance(controls,list) or not 0<len(controls)<=16:
            raise RuntimeError('Unexpected generated unsafe-link receipt')
        families={}
        for item in controls:
            relative=item.get('path','');parts=relative.split('/')
            if len(parts) not in [3,4] or parts[0]!='source' or str(uuid.UUID(parts[1])).upper()!=parts[1] \
                or any(p in ['','.','..'] for p in parts):raise RuntimeError('Invalid generated control path')
            path=case/relative
            for parent in path.parents:
                if parent==case:break
                if not stat.S_ISDIR(parent.lstat().st_mode):raise RuntimeError('Redirected generated control parent')
            if path in allowed:raise RuntimeError('Duplicate generated control')
            identity=item.get('identity',{})
            if set(identity)!=set(['device','inode','mode','links','size']) or any(type(v) is not int for v in identity.values()) \
                or not 0<=identity['size']<=256*1024:raise RuntimeError('Invalid control identity')
            if item.get('kind')=='symlink':
                target=case/'source'/parts[1]/'retained.json'
                target_info=target.lstat()
                if item.get('target')!=str(target) or not stat.S_ISREG(target_info.st_mode) or target_info.st_nlink!=1 or not 0<=target_info.st_size<=256*1024 \
                    or target_info.st_uid!=os.getuid() or digest(target)!=item.get('targetSHA256'):
                    raise RuntimeError('Unexpected generated symbolic-link destination')
            elif item.get('kind')=='hardlink':
                families.setdefault((identity['device'],identity['inode']),[]).append(path)
            else:raise RuntimeError('Unknown generated control kind')
            allowed[path]=item
        if any(len(paths)!=2 for paths in families.values()):raise RuntimeError('Unaccounted generated hard-link alias')
    return allowed


def audit():
    directory(ROOT)
    controls=fixture_link_controls()
    current=usage(ROOT,256*MIB,fixture_links=controls)
    reserved=entries=source_bytes=receipt_bytes=0
    for case in ROOT.iterdir():
        if case.name==".budget.lock" and case.is_file(): continue
        if not case.is_dir() or str(uuid.UUID(case.name)).upper()!=case.name:
            raise RuntimeError("Unexpected native SMB qualification entry")
        value=json.loads((case/"reservation.json").read_bytes())
        amount,count=value.get("bytes"),value.get("entries")
        if type(amount) is not int or type(count) is not int or not 0<amount<=64*MIB or not 0<count<=8192:
            raise RuntimeError("Invalid native SMB qualification reservation")
        supplement=case/'reservation-supplement.json'
        if supplement.exists():
            added=json.loads(supplement.read_bytes())
            extra=added.get('bytes')
            if added.get('version')!=1 or added.get('reservationSHA256')!=digest(case/'reservation.json') \
                or type(extra) is not int or extra<=0 or amount+extra>64*MIB:
                raise RuntimeError('Invalid native SMB reservation supplement')
            amount+=extra
        owned=usage(case,amount,fixture_links=controls)
        if owned["entries"]>count: raise RuntimeError("Native SMB case entry allowance exceeded")
        for path in case.rglob("*"):
            if not path.is_file(): continue
            relative=path.relative_to(case)
            size=max(path.stat().st_size,path.stat().st_blocks*512)
            if relative.parts[0]=="stores":
                if path.name=="owner.lock":
                    if path.stat().st_size!=0: raise RuntimeError("Unexpected catalog lease contents")
                elif path.suffix not in [".sqlite", ".db"] and not path.name.endswith(("-journal","-wal","-shm")):
                    raise RuntimeError("Unexpected generated catalog artifact")
            elif relative.parts[0]=="source": source_bytes+=size
            else: receipt_bytes+=size
        seal=case/'budget-seal.json'
        if seal.exists():
            frozen=json.loads(seal.read_bytes())
            retained=frozen.get('retainedBytes')
            result=json.loads((case/'result.json').read_bytes())
            if frozen.get('version')!=1 or result.get('passed') is not True or result.get('actualExit')!=0 \
                or result.get('reviewLeftOpen',False) is not False or type(retained) is not int \
                or not owned['bytes']<=retained<=amount or frozen.get('reservationSHA256')!=digest(case/'reservation.json'):
                raise RuntimeError('Invalid completed-case budget seal')
            paths={str(p.relative_to(case)):p for p in case.rglob('*') if p.is_file() and p!=seal}
            if set(paths)!=set(frozen.get('files',{})):raise RuntimeError('Sealed successful evidence changed')
            for name,p in paths.items():
                if digest(p)!=frozen['files'][name]:raise RuntimeError('Sealed successful evidence changed')
            amount=retained
        reserved+=amount; entries+=count
    if reserved>256*MIB or entries>MAX_ENTRIES or source_bytes>16*MIB or receipt_bytes>16*MIB:
        raise RuntimeError("Native SMB aggregate reservation/source/receipt allowance exceeded")
    return dict(**current,reservedBytes=reserved,reservedEntries=entries,sourceBytes=source_bytes,receiptBytes=receipt_bytes)


def reserve(action,amount=2*MIB,entries=64):
    directory(ROOT)
    with (ROOT/".budget.lock").open("a+b") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        before=audit()
        if not 0<amount<=64*MIB or not 0<entries<=8192 or before["reservedBytes"]+amount>256*MIB \
            or before["reservedEntries"]+entries>MAX_ENTRIES:
            raise RuntimeError("Native SMB packet allowance exhausted")
        case=directory(ROOT/str(uuid.uuid4()).upper())
        put(case/"reservation.json",dict(version=1,bytes=amount,entries=entries,action=action))
        return case
