#!/usr/bin/env python3
"""Source-bound native layout/storage/crash controls, no personal input."""
import argparse
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ssh_profiles'))
from packet import prepare, directory, d, run, audit
from native_transfer import native_proof, unlocked


def invoke(root, native_case, mode, expected_exit=0):
    proof = native_proof(native_case)
    process, _, _ = run([str(d.APP/'Contents/MacOS/Mac Explorer'),'--verify-ui','--check-network-workspaces',
        '--workspace-mode',mode],root,'native-'+mode,timeout=45,native=True)
    path = root/'evidence'/(mode+'.json')
    report = json.loads(path.read_bytes()) if path.is_file() else None
    if process['actualExit'] != expected_exit or process['contained'] or process['failure'] is not None \
        or process['peakRSSBytes'] > 256 << 20 or expected_exit == 0 and (not report or not report['passed']):
        raise RuntimeError('Native workspace '+mode+' failed; preserved evidence')
    if proof['sourceSHA256'] != d.native_sources(): raise RuntimeError('Native workspace source fence')
    if d.measure(root)['bytes'] > 64 << 20: raise RuntimeError('Native workspace case cap')
    return dict(process=process,native=report)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--native-case',required=True);parser.add_argument('--crashes',action='store_true');args=parser.parse_args()
    prepare()
    if not args.crashes: unlocked()
    proof=native_proof(args.native_case);root=d.reserve('workspace-native')
    directory(root/'source/Local')
    d.put(root/'inputs.json',dict(nativeCase=args.native_case,sources=proof['sourceSHA256'],generatedOnly=True,
        networkRequests=0,keychainCalls=0,crashes=args.crashes))
    results=[]
    if args.crashes:
        for suffix,code in [('stage',91),('published',92)]:
            crashed=invoke(root,args.native_case,'crash-'+suffix,code)
            folder=root/'state'/('Crash-'+suffix)
            before={str(p.relative_to(folder)):d.digest(p) for p in folder.rglob('*') if p.is_file()}
            if suffix=='stage' and not any(name.startswith('.snapshot-') for name in before):raise RuntimeError('Actual staged crash did not retain its generated stage')
            cold=invoke(root,args.native_case,'cold-'+suffix)
            after={str(p.relative_to(folder)):d.digest(p) for p in folder.rglob('*') if p.is_file()}
            if before!=after:raise RuntimeError('Passive cold read changed crash source')
            results.append(dict(boundary=suffix,actualExit=code,crashOriginalPreserved=True,crash=crashed,cold=cold))
    else:results.append(invoke(root,args.native_case,'offline'))
    d.put(root/'evidence/result.json',dict(passed=True,results=results,usage=audit()))
    print(json.dumps(dict(case=root.name,passed=True,crashes=args.crashes)),flush=True)


if __name__=='__main__': main()
