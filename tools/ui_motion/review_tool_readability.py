#!/usr/bin/env python3
"""Read fixed pixels from owned generated movies; never capture a screen."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,TOOLING,MIB,require_case,directory,put,audit,measure
from qualify_foundation import wait_generated


def main():
    parser=argparse.ArgumentParser();parser.add_argument('case');parser.add_argument('--baseline',action='store_true');args=parser.parse_args()
    root=require_case(args.case)
    if json.loads((root/'reservation.json').read_bytes()).get('action')!='traverse-properties-storage':raise RuntimeError('Expected generated Properties case')
    if json.loads((root/'evidence/qualification.json').read_bytes()).get('passed')is not True:raise RuntimeError('Passed native Properties source required')
    output=directory(root/'evidence'/('readability-'+str(uuid.uuid4()).upper()))
    names=[f'properties-storage-{m}.{s}'for m in ['full','reduced','off']for s in ['mov','json']]
    hashes={n:hashlib.sha256((root/'evidence'/n).read_bytes()).hexdigest()for n in names}
    source=REPO/'tools/ui_motion/review_tool_readability.swift';source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    put(output/'scope.json',dict(rect=[20,330,160,40],offsetsMilliseconds=list(range(15,301,15)),minimumInkFraction=.5,brightnessThreshold=.65,
        sourceSHA256=source_hash,movieSHA256=hashes,baseline=args.baseline,noNewCapture=True,generatedOnly=True))
    log=output/'decoder.log'
    with log.open('xb')as stream:
        child=subprocess.Popen(['xcrun','swift','-module-cache-path',str(directory(TOOLING/'motion-module-cache')),str(source),root.name,output.name],
            cwd=REPO,env=dev.environment(tooling=False),stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        stats,failure,contained,forced=wait_generated(child,log,output,deadline=40)
    result=json.loads((output/'result.json').read_bytes())if(output/'result.json').is_file()else None
    measured=result is not None and result.get('passed')is True
    completed=child.returncode==0 and not contained and result is not None and stats.ru_maxrss<=MIB*1024 \
        and source_hash==hashlib.sha256(source.read_bytes()).hexdigest()and hashes=={n:hashlib.sha256((root/'evidence'/n).read_bytes()).hexdigest()for n in names} \
        and measure(root/'evidence')['bytes']<=8*MIB
    passed=completed and (not measured if args.baseline else measured)
    put(output/'qualification.json',dict(passed=passed,measuredPass=measured,baseline=args.baseline,actualExit=child.returncode,contained=contained,forced=forced,
        peakRSSBytes=stats.ru_maxrss,failure=failure,result=result,packet=audit()))
    compact=[dict(mode=r['mode'],passed=r['passed'],minimumFraction=r['minimumFraction'],settledInk=r['settledInk'])for r in result['modes']]if result else None
    print(json.dumps(dict(case=root.name,review=output.name,passed=passed,measuredPass=measured,baseline=args.baseline,modes=compact)),flush=True)
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
