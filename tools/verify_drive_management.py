#!/usr/bin/env python3
"""Read-only native topology and generated overview lifecycle/layout checks."""
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
BASE = ROOT/'.build/b04-drive-management'

def usage():
    if BASE.resolve() != BASE:
        raise RuntimeError('Redirected overview packet')
    total = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, evidence=0)
    for case in BASE.iterdir():
        if case.name == '.budget.lock': continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir(): raise RuntimeError('Unexpected overview case')
        reservation = json.loads((case/'reservation.json').read_bytes())
        size = entries = evidence = 0
        pending = [case]; device = case.stat().st_dev
        while pending:
            path = pending.pop(); facts = path.lstat()
            if facts.st_dev != device or not (stat.S_ISDIR(facts.st_mode) or stat.S_ISREG(facts.st_mode)):
                raise RuntimeError('Unexpected overview entry')
            amount = max(facts.st_size, facts.st_blocks*512); size += amount; entries += 1
            if stat.S_ISDIR(facts.st_mode): pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'): evidence += amount
        if size > reservation['bytes'] or entries > reservation['entries']:
            raise RuntimeError('Overview case exceeded admission')
        for key, value in dict(bytes=size, entries=entries, reservedBytes=reservation['bytes'],
                               reservedEntries=reservation['entries'], evidence=evidence).items(): total[key] += value
    if total['reservedBytes'] > 64*MIB or total['reservedEntries'] > 1024 or total['evidence'] > 16*MIB:
        raise RuntimeError('Overview allowance exhausted')
    return total

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--audit', action='store_true')
    parser.add_argument('--review', action='store_true')
    parser.add_argument('--volumes-handoff', action='store_true'); args = parser.parse_args()
    local_directory('b04-drive-management')
    if args.audit: print(json.dumps(usage(), indent=2)); return
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX); before = usage()
        if before['reservedBytes']+8*MIB > 64*MIB or before['reservedEntries']+128 > 1024:
            raise RuntimeError('No overview headroom')
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=8*MIB, entries=128)))
        (case/'evidence').mkdir(mode=0o700)
    binary = ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
    inputs = [binary, Path(__file__).resolve()]
    inputs += [ROOT/'App/MacExplorer'/name for name in [
        'Features/Drives/DriveManagement.swift', 'Features/Drives/DriveWorkspaceView.swift',
        'Features/Drives/DriveWorkspacePage.swift', 'Features/Drives/DriveDetails.swift',
        'Features/Drives/DriveBenchmark.swift', 'Features/Drives/DriveControls.swift',
        'Features/Drives/DriveDiskUtilityHandoff.swift',
        'Development/Checks/DriveManagementVerification.swift', 'Development/Checks/UIVerification.swift',
        'Shared/Presentation/ToolWindowPresentation.swift', 'Shared/Presentation/ToolPageNavigation.swift',
        'Application/ApplicationOperationCoordinator.swift', 'Application/ApplicationVolumeCoordinator.swift',
        'App.swift', 'Browser/Menus.swift']]
    inputs += [ROOT/'Packages/ExplorerKit/Sources/LocalStorage'/name for name in ['DriveTopology.swift', 'VolumeLifecycle.swift', 'VolumeInspection.swift']]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (case/'evidence/provenance.json').write_text(json.dumps(hashes, sort_keys=True))
    env = environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(case/'app-state'), MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
               MAC_EXPLORER_TEST_ROOT=str(case))
    print('Generated overview case: '+str(case.relative_to(ROOT)), flush=True)
    command = [str(binary), '-ApplePersistenceIgnoreState', 'YES', '--verify-ui', '--check-drive-management',
               '--analysis-source', str(case)]
    if args.volumes_handoff: command.append('--drive-management-volumes')
    command += ['--drive-management-input'] if args.review else ['--offscreen']
    with (case/'evidence/native.log').open('xb') as output:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
        try: result = child.wait(timeout=930 if args.review else 60)
        except subprocess.TimeoutExpired:
            try:
                (case/'evidence/outcome-uncertain.json').write_text(json.dumps(dict(pid=child.pid, drained=False)))
                print('Overview exit uncertain; retaining actual child. Do not retry.',flush=True)
            finally: child.wait()
            raise RuntimeError('Overview exited after watchdog; preserve the failed case')
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(ROOT))] for p in inputs):
        raise RuntimeError('Overview inputs changed during verification')
    receipt = case/'evidence/native.json'
    if result or not receipt.is_file() or not json.loads(receipt.read_bytes()).get('passed'):
        raise RuntimeError('Overview failed; preserve '+str(case.relative_to(ROOT)))
    print(json.dumps(dict(root=str(case.relative_to(ROOT)),report=json.loads(receipt.read_bytes()),usage=usage()),indent=2))

if __name__ == '__main__': main()
