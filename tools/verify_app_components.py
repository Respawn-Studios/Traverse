#!/usr/bin/env python3
"""Generated metadata-only app-component accounting; no personal scan."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory

MIB = 1024**2
BASE = ROOT/'.build/b06-app-components'

def usage() -> dict:
    if BASE.resolve() != BASE:
        raise RuntimeError('Redirected component packet')
    totals = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, evidence=0, payload=0)
    for case in BASE.iterdir():
        if case.name == '.budget.lock':
            continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():
            raise RuntimeError('Unexpected component case')
        reservation = json.loads((case/'reservation.json').read_bytes())
        size = entries = evidence = payload = 0; pending = [case]
        while pending:
            path = pending.pop(); info = path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISDIR, stat.S_ISREG, stat.S_ISLNK)):
                raise RuntimeError('Unexpected component fixture node')
            amount = max(info.st_size, info.st_blocks*512); size += amount; entries += 1
            if stat.S_ISDIR(info.st_mode):
                pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):
                evidence += amount
            elif stat.S_ISREG(info.st_mode):
                payload += amount
        if size > reservation['bytes'] or entries > reservation['entries']:
            raise RuntimeError('Component case exceeded admission')
        for key, value in dict(bytes=size, entries=entries, reservedBytes=reservation['bytes'], reservedEntries=reservation['entries'], evidence=evidence, payload=payload).items():
            totals[key] += value
    if totals['reservedBytes'] > 64*MIB or totals['reservedEntries'] > 1024 or totals['evidence'] > 4*MIB or totals['payload'] > 2*MIB:
        raise RuntimeError('Component allowance exhausted')
    return totals

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument('--audit', action='store_true'); args = parser.parse_args()
    local_directory('b06-app-components')
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); before = usage()
        if before['reservedBytes']+8*MIB > 64*MIB or before['reservedEntries']+128 > 1024:
            raise RuntimeError('No component headroom')
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=8*MIB, entries=128)))
        (case/'evidence').mkdir(mode=0o700)
    binary = ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
    inputs = [binary, Path(__file__).resolve(), ROOT/'App/MacExplorer/Features/StorageAnalysis/FileProperties.swift', ROOT/'App/MacExplorer/Development/Checks/AppComponentAccountingVerification.swift']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (case/'evidence/provenance.json').write_text(json.dumps(hashes, sort_keys=True))
    env = environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(case/'app-state'), MAC_EXPLORER_CACHE_ROOT=str(case/'cache'), MAC_EXPLORER_TEST_ROOT=str(case))
    print(f'Generated app-component case: {case.relative_to(ROOT)}', flush=True)
    with (case/'evidence/native.log').open('xb') as output:
        result = subprocess.run([str(binary), '-ApplePersistenceIgnoreState', 'YES', '--verify-ui', '--check-app-components',
            '--analysis-source', str(case), '--offscreen'], cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=45)
    if any(hashlib.sha256(p.read_bytes()).hexdigest() != hashes[str(p.relative_to(ROOT))] for p in inputs):
        raise RuntimeError('Component inputs changed during qualification')
    if result.returncode or not (case/'evidence/native.json').is_file():
        raise RuntimeError(f'Component check failed; preserve {case.relative_to(ROOT)}')
    print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=json.loads((case/'evidence/native.json').read_bytes()), usage=usage()), indent=2))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
