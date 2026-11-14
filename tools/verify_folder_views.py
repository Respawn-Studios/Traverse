#!/usr/bin/env python3
"""Bounded generated-only folder presentation qualification; no user catalog."""
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
BASE = ROOT/'.build/b01-folder-views'

def usage() -> dict:
    if BASE.resolve() != BASE:
        raise RuntimeError('Redirected folder-view root')
    totals = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, payload=0, evidence=0)
    for case in BASE.iterdir():
        if case.name == '.budget.lock':
            continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():
            raise RuntimeError('Unexpected folder-view case')
        reservation = json.loads((case/'reservation.json').read_bytes())
        size = entries = evidence = 0; pending = [case]
        while pending:
            path = pending.pop(); info = path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISDIR, stat.S_ISREG, stat.S_ISLNK, stat.S_ISFIFO)):
                raise RuntimeError('Unexpected folder-view fixture node')
            amount = max(info.st_size, info.st_blocks*512); size += amount; entries += 1
            if stat.S_ISDIR(info.st_mode):
                pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):
                evidence += amount
        if size > reservation['bytes'] or entries > reservation['entries'] or reservation['bytes'] > 64*MIB:
            raise RuntimeError('Folder-view case exceeded admission')
        for key, value in dict(bytes=size, entries=entries, reservedBytes=reservation['bytes'], reservedEntries=reservation['entries'], payload=reservation['payload'], evidence=evidence).items():
            totals[key] += value
    if totals['reservedBytes'] > 512*MIB or totals['reservedEntries'] > 8192 or totals['payload'] > 8*MIB or totals['evidence'] > 16*MIB:
        raise RuntimeError('Folder-view aggregate allowance exhausted')
    return totals

def admit() -> Path:
    local_directory('b01-folder-views')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); before = usage()
        if before['reservedBytes']+32*MIB > 512*MIB or before['reservedEntries']+512 > 8192 or before['payload']+128*1024 > 8*MIB:
            raise RuntimeError('Folder-view headroom exhausted')
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=32*MIB, entries=512, payload=128*1024)))
        (case/'evidence').mkdir(mode=0o700); (case/'source').mkdir(mode=0o700)
        return case

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument('--audit', action='store_true')
    parser.add_argument('--native', action='store_true'); parser.add_argument('--foreground', action='store_true')
    parser.add_argument('--drive', action='store_true'); parser.add_argument('--scale', action='store_true'); args = parser.parse_args()
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    if args.native:
        case = admit()
        for name in ('Photos', 'Work'):
            folder = case/'source'/name; folder.mkdir(mode=0o700)
            (folder/'Child').mkdir(mode=0o700)
            for index in range(4):
                (folder/f'Generated {index}.txt').write_bytes((f'generated-{name}-{index}\n'.encode())*(index+1))
        files = sorted(path for path in (case/'source').rglob('*') if path.is_file())
        before = {str(path.relative_to(case/'source')): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        (case/'evidence/source.json').write_text(json.dumps(before, sort_keys=True))
        env = environment(tooling=False)
        env.update(MAC_EXPLORER_STATE_ROOT=str(case/'app-state'), MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
                   MAC_EXPLORER_TEST_ROOT=str(case), MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
        binary = ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
        inputs = [binary, Path(__file__).resolve(), ROOT/'App/MacExplorer/Browser/FolderViewStore.swift', ROOT/'App/MacExplorer/Browser/FolderViewPreferences.swift',
                  ROOT/'App/MacExplorer/Development/Checks/FolderViewsVerification.swift', ROOT/'App/MacExplorer/Browser/BrowserViewController.swift',
                  ROOT/'App/MacExplorer/Browser/BrowserPreferences.swift', ROOT/'App/MacExplorer/Browser/BrowserTabManagement.swift',
                  ROOT/'App/MacExplorer/Browser/BrowserWorkspaceController.swift', ROOT/'Packages/ExplorerKit/Sources/ExplorerCore/FolderViewPresets.swift',
                  ROOT/'Packages/ExplorerKit/Sources/ExplorerCore/BrowserModels.swift', ROOT/'App/MacExplorer/Browser/BrowserSnapshotFile.swift']
        hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        (case/'evidence/provenance.json').write_text(json.dumps(hashes, sort_keys=True))
        print(f'Generated native folder-view case: {case.relative_to(ROOT)}', flush=True)
        with (case/'evidence/native.log').open('xb') as output:
            result = subprocess.run([str(binary), '-ApplePersistenceIgnoreState', 'YES', '--verify-ui', '--check-folder-views', '--analysis-source', str(case)]
                                    +(['--drive-folder-views'] if args.drive else [])+(['--folder-views-scale'] if args.scale else [])
                                    +([] if args.foreground or args.drive else ['--offscreen']),
                                    cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=180 if args.drive else 90)
        if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
            raise RuntimeError('Folder-view inputs changed during qualification')
        if result.returncode or not (case/'evidence/native.json').is_file():
            raise RuntimeError(f'Native folder views failed; preserve {case.relative_to(ROOT)}')
        if 'Application performed a reentrant operation' in (case/'evidence/native.log').read_text():
            raise RuntimeError(f'Native table delegate warning remains; preserve {case.relative_to(ROOT)}')
        after = {str(path.relative_to(case/'source')): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
        if before != after or any((case/'source').rglob('.DS_Store')):
            raise RuntimeError('Folder views changed source data or wrote .DS_Store')
        report = json.loads((case/'evidence/native.json').read_bytes()); report['independentSourceHashesUnchanged'] = True
        (case/'evidence/independent.json').write_text(json.dumps(report, indent=2, sort_keys=True))
        print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=report, usage=usage()), indent=2)); return 0
    parser.error('Choose --native or --audit')

if __name__ == '__main__':
    raise SystemExit(main())
