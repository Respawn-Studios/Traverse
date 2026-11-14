#!/usr/bin/env python3
"""Explicit, bounded, local IPS frame symbolication; never collect crash reports."""
from __future__ import annotations
import argparse,hashlib,json,math,os,re,stat,subprocess,sys,uuid
from pathlib import Path
from typing import NamedTuple

REPO=Path(__file__).resolve().parents[2]
sys.dont_write_bytecode=True
sys.path.insert(0,str(REPO/'tools'))
from distribution import helper_symbols as symbols

MAX_REPORT=2<<20
MAX_U64=(1<<64)-1
ARCHITECTURES=frozenset(['arm64','arm64e','x86_64'])
ZERO_UUID='00000000-0000-0000-0000-000000000000'
ARCH_TOKEN=re.compile(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,31}')

class Refusal(ValueError):
    """Only closed error codes are allowed in this exception."""

class Frame(NamedTuple):
    thread:int
    index:int
    image:int
    offset:int

def integer(value,code,maximum=MAX_U64):
    if type(value)is not int or value<0 or value>maximum:raise Refusal(code)
    return value

def pairs(items):
    result={}
    for key,value in items:
        if key in result:raise Refusal('duplicate-json-key')
        result[key]=value
    return result

def no_constant(_):raise Refusal('nonfinite-json-number')

def json_integer(text):
    if len(text)>21:raise Refusal('json-integer-bound')
    value=int(text)
    if abs(value)>MAX_U64:raise Refusal('json-integer-bound')
    return value

def json_float(text):
    if len(text)>128:raise Refusal('json-float-bound')
    value=float(text)
    if not math.isfinite(value):raise Refusal('nonfinite-json-number')
    return value

def open_regular(path,maximum):
    # All inputs are explicit staged support artifacts, never paths from IPS.
    if not path.is_absolute()or not path.is_relative_to(REPO/'.build')or path.resolve()!=path:
        raise Refusal('unsafe-local-input')
    parent=os.open(REPO/'.build',os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW);fd=None
    try:
        for part in path.relative_to(REPO/'.build').parts[:-1]:
            following=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=parent)
            os.close(parent);parent=following
        fd=os.open(path.name,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=parent)
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode)or before.st_uid!=os.getuid()or before.st_nlink!=1 or before.st_size>maximum:
            raise Refusal('input-kind-owner-or-bound')
        result=fd,before;fd=None;return result
    finally:
        if fd is not None:os.close(fd)
        os.close(parent)

def read_regular(path,maximum,retain):
    fd,before=open_regular(path,maximum)
    try:
        chunks=[];total=0;digest=hashlib.sha256()
        while True:
            chunk=os.read(fd,min(1<<20,maximum-total+1))
            if not chunk:break
            total+=len(chunk)
            if total>maximum:raise Refusal('input-bound')
            digest.update(chunk)
            if retain:chunks.append(chunk)
        after=os.fstat(fd);named=path.lstat()
        identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_mode,s.st_uid)
        if total!=before.st_size or identity(before)!=identity(after)or identity(before)!=identity(named)or path.resolve()!=path:
            raise Refusal('input-changed')
        return b''.join(chunks)if retain else digest.digest()
    finally:os.close(fd)

def local_regular(path,maximum):return read_regular(path,maximum,True)

def digest_regular(path,maximum):return read_regular(path,maximum,False)

def read_ips(path):
    data=local_regular(path,MAX_REPORT)
    try:
        text=data.decode('utf-8');decoder=json.JSONDecoder(object_pairs_hook=pairs,parse_constant=no_constant,parse_int=json_integer,parse_float=json_float)
        first,end=decoder.raw_decode(text.lstrip());rest=text.lstrip()[end:].lstrip()
        body,end=decoder.raw_decode(rest)
        if rest[end:].strip():raise Refusal('trailing-json-data')
    except Refusal:raise
    except (ValueError,UnicodeError,RecursionError):raise Refusal('invalid-ips-json')from None
    if type(first)is not dict or first.get('bug_type')!='309'or type(body)is not dict:
        raise Refusal('not-a-crash-report')
    images=body.get('usedImages');threads=body.get('threads')
    if type(images)is not list or not 1<=len(images)<=512 or type(threads)is not list or not 1<=len(threads)<=512:
        raise Refusal('image-or-thread-bound')
    checked=[];placeholder_seen=False
    for image in images:
        if type(image)is not dict:raise Refusal('invalid-image')
        base=integer(image.get('base'),'invalid-image-base');size=integer(image.get('size'),'invalid-image-size')
        if not size:
            # Apple can include this exact unreferenced sentinel in usedImages.
            # Keep its index so frame references cannot silently shift.
            if placeholder_seen or image!={'base':0,'size':0,'source':'A','uuid':ZERO_UUID}:
                raise Refusal('invalid-image-placeholder')
            placeholder_seen=True
            checked.append(dict(base=0,size=0,uuid=ZERO_UUID,arch=None,placeholder=True))
            continue
        if base>MAX_U64-size:raise Refusal('image-range-overflow')
        raw=image.get('uuid');arch=image.get('arch')
        if type(raw)is not str or len(raw)>36:raise Refusal('invalid-image-uuid')
        try:identifier=str(uuid.UUID(raw)).upper()
        except ValueError:raise Refusal('invalid-image-uuid')from None
        # System-image architecture labels are bounded metadata. Only a
        # supported exact binary/dSYM architecture may become the atos target.
        if type(arch)is not str or not ARCH_TOKEN.fullmatch(arch):raise Refusal('unsupported-image-architecture')
        checked.append(dict(base=base,size=size,uuid=identifier,arch=arch))
    frames=[]
    for ti,thread in enumerate(threads):
        if type(thread)is not dict or type(thread.get('frames'))is not list:raise Refusal('invalid-thread')
        if 'triggered'in thread and type(thread['triggered'])is not bool:raise Refusal('invalid-triggered-flag')
        for fi,frame in enumerate(thread['frames']):
            if type(frame)is not dict:raise Refusal('invalid-frame')
            index=integer(frame.get('imageIndex'),'invalid-frame-image',len(checked)-1)
            offset=integer(frame.get('imageOffset'),'invalid-frame-offset')
            if checked[index].get('placeholder'):raise Refusal('placeholder-image-referenced')
            if offset>=checked[index]['size']:raise Refusal('frame-outside-image')
            frames.append(Frame(ti,fi,index,offset))
            if len(frames)>16384:raise Refusal('frame-bound')
    if not frames:raise Refusal('empty-frame-set')
    return checked,frames,hashlib.sha256(data).digest()

def render_symbol(text):
    # atos consumes trusted matching developer symbols, not report string fields.
    if not text or len(text)>4096 or re.fullmatch(r'0x[0-9a-fA-F]+',text):raise Refusal('unresolved-frame')
    source=re.fullmatch(r'(.+?) \(in [^\n]+\) \(([^\n]+):([0-9]{1,20})\)',text)
    function_only=None if source else re.fullmatch(r'(.+?) \(in [^\n]+\) \+ ([0-9]{1,20})',text)
    if not source and not function_only:raise Refusal('missing-source-line')
    name=(source or function_only)[1]
    leaf=Path(source[2]).name if source else None
    line=int(source[3]) if source else None
    if (line is not None and line>MAX_U64)or(function_only and int(function_only[2])>MAX_U64):
        raise Refusal('unsupported-symbol-output')
    if re.fullmatch(r'0x[0-9a-fA-F]+',name):raise Refusal('unresolved-frame')
    if (source and (not leaf or len(leaf)>255 or '\\'in leaf)) \
            or not name or any(ord(c)<32 for c in name+(leaf or ''))or '/'in name:
        raise Refusal('unsupported-symbol-output')
    return dict(function=name,source=leaf,line=line if line else None)

def symbolicate(report,binary,dsym,address_policy='reported'):
    if address_policy not in ['reported','lldb-return-addresses']:raise Refusal('unsupported-address-policy')
    images,frames,report_digest=read_ips(report)
    try:proof=symbols.validate(binary,dsym)
    except (ValueError,OSError,subprocess.SubprocessError):raise Refusal('invalid-symbol-binding')from None
    matches=[i for i,image in enumerate(images)if image['arch'] in ARCHITECTURES
             and proof['UUIDs'].get(image['arch'])==image['uuid']]
    if len(matches)!=1:raise Refusal('missing-or-ambiguous-image-binding')
    target=matches[0];image=images[target];selected=[f for f in frames if f.image==target]
    if not 1<=len(selected)<=512:raise Refusal('matching-frame-bound')
    dwarf=symbols.symbol_file(dsym)
    binding=(digest_regular(binary,192<<20),digest_regular(dwarf,symbols.MAX_SYMBOL_BYTES))
    command=['/usr/bin/xcrun','atos','-arch',image['arch'],'-o',str(dwarf),'-l',hex(image['base'])]
    adjustments=[1 if address_policy=='lldb-return-addresses'and f.index>0 else 0 for f in selected]
    if any(frame.offset<adjustment for frame,adjustment in zip(selected,adjustments)):raise Refusal('return-address-at-image-base')
    command.extend(hex(image['base']+f.offset-adjustment)for f,adjustment in zip(selected,adjustments))
    try:output=subprocess.run(command,check=True,capture_output=True,text=True,timeout=20).stdout
    except (OSError,subprocess.SubprocessError,UnicodeError):raise Refusal('symbol-tool-failed')from None
    if len(output)>1<<20:raise Refusal('symbol-output-bound')
    lines=output.splitlines()
    if len(lines)!=len(selected):raise Refusal('symbol-frame-count')
    rows=[]
    for frame,text,adjustment in zip(selected,lines,adjustments):
        row=render_symbol(text);row.update(thread=frame.thread,frame=frame.index,imageOffset=frame.offset,symbolicationAdjustmentBytes=adjustment);rows.append(row)
    if report_digest!=digest_regular(report,MAX_REPORT)or binding!=(digest_regular(binary,192<<20),digest_regular(dwarf,symbols.MAX_SYMBOL_BYTES)):
        raise Refusal('symbolication-input-changed')
    source_complete=all(row['line']is not None for row in rows)
    return dict(format='traverse-symbolicated-frames-v1',uuid=image['uuid'],architecture=image['arch'],addressPolicy=address_policy,
                resolvedFrames=rows,otherImageFrames=len(frames)-len(rows),sourceReportUnchanged=True,
                privateReportMetadataIncluded=False,sourceLinesComplete=source_complete,
                completeReportSymbolication=len(frames)==len(rows)and source_complete)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--report',required=True,type=Path)
    parser.add_argument('--binary',required=True,type=Path);parser.add_argument('--dsym',required=True,type=Path)
    parser.add_argument('--address-policy',choices=['reported','lldb-return-addresses'],default='reported')
    args=parser.parse_args()
    try:print(json.dumps(symbolicate(args.report,args.binary,args.dsym,args.address_policy),indent=2))
    except (Refusal,OSError)as error:
        code=str(error)if isinstance(error,Refusal)else'local-input-error'
        print(json.dumps(dict(passed=False,code=code)));return 1
    return 0

if __name__=='__main__':sys.exit(main())
