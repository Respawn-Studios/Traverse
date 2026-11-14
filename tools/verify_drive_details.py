#!/usr/bin/env python3
"""Generated drive-details review; no device mutation or external application."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import plistlib
from pathlib import Path
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
from dev import ROOT, environment, local_directory

MIB = 1024**2
BASE = ROOT/'.build/b04-drive-details'

def review_copy() -> Path:
    tooling = local_directory('b04-drive-details-tooling')
    marker = tooling/'review.json'
    source = ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app'
    source_binary = source/'Contents/MacOS/Mac Explorer'
    digest = hashlib.sha256(source_binary.read_bytes()).hexdigest()
    if marker.exists():
        record = json.loads(marker.read_bytes()); app = Path(record['app'])
        uuid.UUID(app.parent.name)
        if app.parent.parent != tooling or app.name != 'Mac Explorer Drive Details Review.app' or record['source'] != digest:
            raise RuntimeError('Preserved review copy differs; do not overwrite it')
        if hashlib.sha256((app/'Contents/MacOS/Mac Explorer').read_bytes()).hexdigest() != record['binary']:
            raise RuntimeError('Preserved review executable changed')
    else:
        if any(tooling.iterdir()):
            raise RuntimeError('Incomplete review copy stays preserved; no implicit retry')
        owned = tooling/str(uuid.uuid4()).upper(); owned.mkdir(mode=0o700)
        app = owned/'Mac Explorer Drive Details Review.app'
        subprocess.run(['/usr/bin/ditto', str(source), str(app)], check=True, capture_output=True)
        info = app/'Contents/Info.plist'; value = plistlib.loads(info.read_bytes())
        value['CFBundleIdentifier'] = 'local.macexplorer.drivedetails.review.'+owned.name.lower()
        value['CFBundleName'] = value['CFBundleDisplayName'] = 'Mac Explorer Drive Details Review'
        value['MacExplorerDevelopmentStateRoot'] = str(owned/'state')
        info.write_bytes(plistlib.dumps(value, sort_keys=False))
        subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(app)], check=True, capture_output=True)
        marker.write_text(json.dumps(dict(app=str(app),source=digest,binary=hashlib.sha256((app/'Contents/MacOS/Mac Explorer').read_bytes()).hexdigest()),sort_keys=True))
    size = entries = 0; pending = [tooling]
    while pending:
        path = pending.pop(); info = path.lstat(); entries += 1; size += max(info.st_size, info.st_blocks*512)
        if stat.S_ISDIR(info.st_mode): pending.extend(path.iterdir())
    if size > 128*MIB or entries > 1024:
        raise RuntimeError('Review tooling exceeded its single-copy allowance')
    print(f'Isolated review app: {app}', flush=True)
    return app/'Contents/MacOS/Mac Explorer'

def usage() -> dict:
    if BASE.resolve() != BASE:
        raise RuntimeError('Redirected drive-details packet')
    totals = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, evidence=0, payload=0)
    for case in BASE.iterdir():
        if case.name == '.budget.lock':
            continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():
            raise RuntimeError('Unexpected drive-details case')
        reservation = json.loads((case/'reservation.json').read_bytes())
        size = entries = evidence = payload = 0; pending = [case]
        while pending:
            path = pending.pop(); info = path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISDIR, stat.S_ISREG, stat.S_ISLNK)):
                raise RuntimeError('Unexpected drive-details fixture node')
            amount = max(info.st_size, info.st_blocks*512); size += amount; entries += 1
            if stat.S_ISDIR(info.st_mode):
                pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):
                evidence += amount
            elif stat.S_ISREG(info.st_mode):
                payload += amount
        if size > reservation['bytes'] or entries > reservation['entries']:
            raise RuntimeError('Drive-details case exceeded admission')
        for key, value in dict(bytes=size, entries=entries, reservedBytes=reservation['bytes'], reservedEntries=reservation['entries'], evidence=evidence, payload=payload).items():
            totals[key] += value
    if totals['reservedBytes'] > 256*MIB or totals['reservedEntries'] > 4096 or totals['evidence'] > 16*MIB or totals['payload'] > 2*MIB:
        raise RuntimeError('Drive-details allowance exhausted')
    return totals

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument('--audit', action='store_true'); parser.add_argument('--drive', action='store_true')
    parser.add_argument('--review-copy', action='store_true'); args = parser.parse_args()
    local_directory('b04-drive-details')
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); before = usage()
        if before['reservedBytes']+16*MIB > 256*MIB or before['reservedEntries']+128 > 4096:
            raise RuntimeError('No drive-details headroom')
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=16*MIB, entries=128)))
        (case/'evidence').mkdir(mode=0o700)
    binary = review_copy() if args.review_copy else ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
    inputs = [binary, Path(__file__).resolve(), ROOT/'App/MacExplorer/Features/Drives/DriveDetails.swift',
        ROOT/'App/MacExplorer/Development/Checks/DriveDetailsVerification.swift', ROOT/'App/MacExplorer/Features/Drives/DriveControls.swift',
        ROOT/'App/MacExplorer/Shared/Presentation/ToolWindowPresentation.swift', ROOT/'App/MacExplorer/App.swift',
        ROOT/'Packages/ExplorerKit/Sources/LocalStorage/VolumeInspection.swift',
        ROOT/'Packages/ExplorerKit/Sources/LocalStorage/VolumeLifecycle.swift']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (case/'evidence/provenance.json').write_text(json.dumps(hashes, sort_keys=True))
    env = environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(case/'app-state'), MAC_EXPLORER_CACHE_ROOT=str(case/'cache'), MAC_EXPLORER_TEST_ROOT=str(case))
    print(f'Generated drive-details case: {case.relative_to(ROOT)}', flush=True)
    with (case/'evidence/native.log').open('xb') as output:
        result = subprocess.run([str(binary), '-ApplePersistenceIgnoreState', 'YES', '--verify-ui', '--check-drive-details',
            '--analysis-source', str(case)] + (['--drive-details-input'] if args.drive else ['--offscreen']), cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=660 if args.drive else 45)
    if any(hashlib.sha256(p.read_bytes()).hexdigest() != hashes[str(p.relative_to(ROOT))] for p in inputs):
        raise RuntimeError('Drive-details inputs changed during qualification')
    if result.returncode or not (case/'evidence/native.json').is_file():
        raise RuntimeError(f'Drive-details check failed; preserve {case.relative_to(ROOT)}')
    if args.review_copy:
        review_copy()
    print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=json.loads((case/'evidence/native.json').read_bytes()), usage=usage()), indent=2))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
