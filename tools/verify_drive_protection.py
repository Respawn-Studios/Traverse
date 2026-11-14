#!/usr/bin/env python3
"""Generated-only app protection; never submits a real native drive action."""
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
BASE = ROOT/'.build/b04-protected-drives'

def usage() -> dict:
    if BASE.resolve() != BASE:
        raise RuntimeError('Redirected protection root')
    totals = dict(bytes=0, entries=1, reservedBytes=0, reservedEntries=1, evidence=0)
    for case in BASE.iterdir():
        if case.name == '.budget.lock':
            continue
        uuid.UUID(case.name)
        if case.is_symlink() or not case.is_dir():
            raise RuntimeError('Unexpected protection case')
        reservation = json.loads((case/'reservation.json').read_bytes())
        size = entries = evidence = 0
        pending = [case]
        while pending:
            path = pending.pop(); info = path.lstat()
            if not any(check(info.st_mode) for check in (stat.S_ISDIR, stat.S_ISREG, stat.S_ISLNK, stat.S_ISFIFO)):
                raise RuntimeError('Unexpected protection fixture node')
            amount = max(info.st_size, info.st_blocks*512)
            size += amount; entries += 1
            if stat.S_ISDIR(info.st_mode):
                pending.extend(path.iterdir())
            elif path.is_relative_to(case/'evidence'):
                evidence += amount
        if size > reservation['bytes'] or entries > reservation['entries'] or reservation['bytes'] > 64*MIB:
            raise RuntimeError('Protection case exceeded admission')
        for key, value in dict(bytes=size, entries=entries, reservedBytes=reservation['bytes'], reservedEntries=reservation['entries'], evidence=evidence).items():
            totals[key] += value
    if totals['reservedBytes'] > 512*MIB or totals['reservedEntries'] > 8192 or totals['evidence'] > 16*MIB:
        raise RuntimeError('Protection aggregate allowance exhausted')
    return totals

def admit(size: int = 32*MIB, entries: int = 512) -> Path:
    local_directory('b04-protected-drives')
    with (BASE/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = usage()
        if before['reservedBytes']+size > 512*MIB or before['reservedEntries']+entries > 8192:
            raise RuntimeError('Protection headroom exhausted')
        case = BASE/str(uuid.uuid4()).upper(); case.mkdir(mode=0o700)
        (case/'reservation.json').write_text(json.dumps(dict(bytes=size, entries=entries)))
        (case/'evidence').mkdir(mode=0o700)
        return case

def native(case: Path, extra: list[str], foreground: bool = False, phase: str = 'native') -> subprocess.CompletedProcess:
    env = environment(tooling=False)
    env.update(MAC_EXPLORER_STATE_ROOT=str(case/'app-state'), MAC_EXPLORER_CACHE_ROOT=str(case/'cache'),
               MAC_EXPLORER_TEST_ROOT=str(case), MAC_EXPLORER_VERIFICATION_CAPTURE_BUDGET=str(2*MIB))
    binary = ROOT/'.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'
    inputs = [binary, Path(__file__).resolve(), ROOT/'App/MacExplorer/Application/ApplicationVolumeCoordinator.swift',
              ROOT/'App/MacExplorer/App.swift', ROOT/'App/MacExplorer/Browser/BrowserLifecycle.swift',
              ROOT/'App/MacExplorer/Application/ApplicationOperationCoordinator.swift',
              ROOT/'App/MacExplorer/Features/Drives/DriveProtectionStore.swift', ROOT/'App/MacExplorer/Development/Checks/DriveProtectionVerification.swift',
              ROOT/'App/MacExplorer/Features/Drives/DriveControls.swift', ROOT/'App/MacExplorer/Browser/BrowserSnapshotFile.swift',
              ROOT/'Packages/ExplorerKit/Sources/LocalStorage/VolumeLifecycle.swift',
              ROOT/'Packages/ExplorerKit/Sources/LocalStorage/VolumeRemovalProtection.swift']
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    (case/f'evidence/{phase}-provenance.json').write_text(json.dumps(hashes, sort_keys=True))
    with (case/f'evidence/{phase}.log').open('xb') as output:
        result = subprocess.run([str(binary), '-ApplePersistenceIgnoreState', 'YES', '--verify-ui', '--check-drive-protection',
                                 '--analysis-source', str(case)]+extra+([] if foreground else ['--offscreen']),
                                cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
    if any(hashlib.sha256(path.read_bytes()).hexdigest() != hashes[str(path.relative_to(ROOT))] for path in inputs):
        raise RuntimeError('Protection inputs changed during qualification')
    return result

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--audit', action='store_true'); parser.add_argument('--native', action='store_true')
    parser.add_argument('--processes', action='store_true'); parser.add_argument('--foreground', action='store_true')
    parser.add_argument('--drive', action='store_true')
    args = parser.parse_args()
    if args.audit:
        print(json.dumps(usage(), indent=2)); return 0
    if args.native:
        case = admit(); print(f'Generated protection case: {case.relative_to(ROOT)}', flush=True)
        result = native(case, ['--drive-protection-controls'] if args.drive else [], args.foreground or args.drive)
        if result.returncode or not (case/'evidence/native.json').is_file():
            raise RuntimeError(f'Native protection failed; preserve {case.relative_to(ROOT)}')
        print(json.dumps(dict(root=str(case.relative_to(ROOT)), report=json.loads((case/'evidence/native.json').read_bytes()), usage=usage()), indent=2))
        return 0
    if args.processes:
        reports = []
        for boundary in ('staged', 'validated', 'published', 'synchronized'):
            case = admit(size=8*MIB, entries=128); state = case/'state'; state.mkdir(mode=0o700)
            target = str(uuid.uuid4()).upper()
            original = dict(version=1, revision=str(uuid.uuid4()).upper(), rules=[dict(id=target, name='Generated drive', level='keepMounted')])
            path = state/'drive-protection-v1.json'
            with path.open('x') as output:
                os.chmod(path, 0o600); json.dump(original, output, sort_keys=True); output.flush(); os.fsync(output.fileno())
            before = path.read_bytes()
            result = native(case, ['--crash-protection-boundary', boundary])
            if result.returncode != 86:
                raise RuntimeError(f'Crash child missed {boundary}; preserve {case}')
            actual = json.loads(path.read_bytes())
            unpublished = boundary in ('staged', 'validated')
            expected = 'keepMounted' if unpublished else 'preventEject'
            if actual['rules'] != [dict(id=target, name='Generated drive', level=expected)]:
                raise RuntimeError('Interrupted protection is not a complete expected document')
            if unpublished and path.read_bytes() != before:
                raise RuntimeError('Unpublished protection changed original bytes')
            saved = path.read_bytes()
            reopened = native(case, ['--reopen-protection'], phase='reopen')
            observed = json.loads((case/'evidence/reopen.json').read_bytes())
            if reopened.returncode or observed['rules'] != [dict(id=target, level=expected)] or path.read_bytes() != saved:
                raise RuntimeError('Passive native reopen changed or misread interrupted protection')
            report = dict(root=str(case.relative_to(ROOT)), boundary=boundary, exitCode=result.returncode, savedLevel=expected,
                          completeDocument=True, originalUntouched=unpublished, passiveNativeReopenUnchanged=True)
            (case/'evidence/crash.json').write_text(json.dumps(report, indent=2)); reports.append(report)
        case = admit(size=8*MIB, entries=128); state = case/'state'; state.mkdir(mode=0o700)
        original = dict(version=1, revision=str(uuid.uuid4()).upper(), rules=[dict(id=str(uuid.uuid4()).upper(), name='Generated drive', level='keepMounted')])
        path = state/'drive-protection-v1.json'; path.write_text(json.dumps(original, sort_keys=True)); path.chmod(0o600)
        lockPath = state/'drive-protection-v1.json.writer-lock'
        with lockPath.open('x+b') as lock:
            lockPath.chmod(0o600); fcntl.flock(lock, fcntl.LOCK_EX)
            before = path.read_bytes()
            result = native(case, ['--reopen-protection', '--expect-protection-busy'], phase='held-process-lock')
            observed = json.loads((case/'evidence/reopen.json').read_bytes())
            if result.returncode or not observed.get('refusedBusy') or path.read_bytes() != before:
                raise RuntimeError('Native reader bypassed another process writer lock')
            fcntl.flock(lock, fcntl.LOCK_UN)
        # Preserve both receipts without overwriting the first native result.
        (case/'evidence/reopen.json').rename(case/'evidence/held-lock.json')
        result = native(case, ['--reopen-protection'], phase='released-process-lock')
        observed = json.loads((case/'evidence/reopen.json').read_bytes())
        if result.returncode or not observed.get('passed') or path.read_bytes() != before:
            raise RuntimeError('Passive native reader did not resume unchanged after lock release')
        reports.append(dict(root=str(case.relative_to(ROOT)), boundary='other-process-lock', refusedWhileHeld=True, unchangedAfterRelease=True))
        print(json.dumps(dict(passed=True, processes=reports, usage=usage()), indent=2)); return 0
    parser.error('Choose --native, --processes or --audit')

if __name__ == '__main__':
    raise SystemExit(main())
