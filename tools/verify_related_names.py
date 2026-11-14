#!/usr/bin/env python3
"""Bounded generated-only B08 qualification; retained cases never recycle."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory

MIB = 1024**2
BASE = ROOT / '.build/b08-related-names'

def usage() -> dict:
    if BASE.resolve() != BASE: raise RuntimeError('Redirected qualification root')
    totals = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, metadata=0, evidence=0)
    for case in BASE.iterdir():
        if case.name == '.budget.lock': continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir(): raise RuntimeError('Unknown case')
        reservation = json.loads((case/'reservation.json').read_bytes())
        values = dict(bytes=0, entries=0, metadata=0, evidence=0)
        pending = [case]
        while pending:
            path = pending.pop(); info = path.lstat()
            if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)): raise RuntimeError('Unexpected fixture node')
            amount = max(info.st_size, info.st_blocks*512); values['bytes'] += amount; values['entries'] += 1
            if stat.S_ISDIR(info.st_mode): pending.extend(path.iterdir())
            elif path.parent == case/'metadata': values['metadata'] += amount
            elif path.suffix in ('.json', '.log', '.png'): values['evidence'] += amount
        if values['bytes'] > reservation['bytes'] or values['entries'] > reservation['entries'] or reservation['bytes'] > 128*MIB:
            raise RuntimeError('Case exceeded admission')
        for key,value in values.items(): totals[key] += value
        totals['reservedBytes'] += reservation['bytes']; totals['reservedEntries'] += reservation['entries']
    if totals['reservedBytes'] > 512*MIB or totals['reservedEntries'] > 8192 or totals['metadata'] > 16*MIB or totals['evidence'] > 16*MIB:
        raise RuntimeError('B08 allowance exhausted')
    return totals

def admit(size: int = 4*MIB, entries: int = 64) -> Path:
    local_directory('b08-related-names')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); before=usage()
        if before['reservedBytes']+size > 512*MIB or before['reservedEntries']+entries > 8192 or not 0 < size <=128*MIB:
            raise RuntimeError('Insufficient qualification headroom')
        case=BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size, entries=entries)))
        for name in ('metadata', 'evidence'): (case/name).mkdir(mode=0o700)
        return case

def main() -> int:
    parser=argparse.ArgumentParser(); parser.add_argument('--assets', action='store_true'); parser.add_argument('--audit', action='store_true')
    parser.add_argument('--controls', action='store_true')
    parser.add_argument('--quality', choices=('tuning','heldout','latency'))
    args=parser.parse_args()
    if args.audit: print(json.dumps(usage(), indent=2)); return 0
    if args.controls or args.quality:
        case=admit(); env=environment(tooling=False)
        if args.quality:
            from related_names_corpus import corpus
            data=json.dumps(corpus(),ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
            if hashlib.sha256(data).hexdigest()!='fc39eaccb9ce66418ae92ce72adbb30089ef6b8a8fb40a32a89ff76a440f029f':
                raise RuntimeError('Frozen corpus changed')
            (case/'metadata/corpus.json').write_bytes(data)
            (case/'evidence/freeze.json').write_text(json.dumps(dict(sha256=hashlib.sha256(data).hexdigest(),
                phase=args.quality, qualityGates=dict(recall=0.90,semanticRecall=0.85,mrr=0.70,precision=0.80,maximumNoMatchHits=2))))
        env.update(MAC_EXPLORER_STATE_ROOT=str(case/'state'), MAC_EXPLORER_CACHE_ROOT=str(case/'cache'), MAC_EXPLORER_TEST_ROOT=str(case))
        binary=ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        sources=[binary,ROOT/'App/MacExplorer/Features/PrivateNames/AppleRelatedNameEncoder.swift',ROOT/'App/MacExplorer/Development/Checks/RelatedNamesVerification.swift',Path(__file__).resolve(),
            *sorted((ROOT/'Packages/ExplorerKit/Sources/FileMemory').glob('RelatedName*.swift'))]
        hashes={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes,sort_keys=True))
        with (case/'evidence/native.log').open('xb') as output:
            result=subprocess.run([str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--offscreen',
                '--check-related-names','--analysis-source',str(case)] +
                (['--related-quality','--related-partition',args.quality] if args.quality else []),
                cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,timeout=90)
        if any(hashlib.sha256(path.read_bytes()).hexdigest()!=hashes[str(path.relative_to(ROOT))] for path in sources):
            raise RuntimeError('Qualification inputs changed')
        if result.returncode or not (case/'evidence/native.json').is_file(): raise RuntimeError(f'Native controls failed; preserve {case}')
        report=json.loads((case/'evidence/native.json').read_bytes())
        summary={k:v for k,v in report.items() if k!='answers'}
        print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=summary,usage=usage()),indent=2))
        if not report['passed']: raise RuntimeError('Native controls not qualified')
        return 0
    if not args.assets: parser.error('Choose --assets, --controls or --audit')
    case=admit(); tooling=local_directory('b08-tooling'); binary=tooling/'apple-assets-probe'
    env=environment()
    with (case/'evidence/build.log').open('xb') as output:
        subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-warnings-as-errors',
            '-module-cache-path',str(local_directory('compiler-cache/b08')), '-o',str(binary),str(ROOT/'tools/B08AppleAssetsProbe.swift')],
            cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True,timeout=90)
    result=subprocess.run([str(binary)],cwd=ROOT,env=environment(tooling=False),capture_output=True,timeout=20)
    (case/'evidence/process.log').write_bytes(result.stderr)
    if result.returncode: raise RuntimeError(f'Asset probe failed; preserve {case}')
    report=json.loads(result.stdout); (case/'evidence/assets.json').write_text(json.dumps(report,indent=2,sort_keys=True))
    print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=report,usage=usage()),indent=2)); return 0

if __name__ == '__main__': raise SystemExit(main())
