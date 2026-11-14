#!/usr/bin/env python3
"""Fourteen finite generated B13 native cases; no real service perform or compiler."""
import argparse
import io
import json
import os
from pathlib import Path
import stat
import sys
import time
import zipfile

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools/archive_opening'))
from packet import d, shared, MASTER, prepare
from admission_packet import OwnedMemory
from native_transfer import native_proof, unlocked
import runtime_diagnostics

ACTION = 'airdrop-native'

def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json') if json.loads(p.read_bytes()).get('action') == ACTION]

def audit():
    prepare(); value = d.audit(); roots = cases(); total = entries = bodies = 0
    if len(roots) > 14: raise RuntimeError('Fourteen B13 native reservations exceeded')
    for root in roots:
        usage = d.measure(root); total += usage['bytes']; entries += usage['entries']
        if usage['bytes'] > 64 << 20 or usage['entries'] > 256: raise RuntimeError('B13 native per-case bound')
        for path in (root / 'source').rglob('*'):
            if path.is_symlink(): continue
            if path.is_file(): bodies += path.stat().st_size
    if total > 64 << 20 or entries > 1536 or bodies > 16 << 10: raise RuntimeError('B13 total/source bound')
    value.update(airDropNativeReservations=len(roots), airDropPacketBytes=total, airDropPacketEntries=entries,
                 airDropGeneratedBytes=bodies, maximumNativeReservations=14)
    return value

def helpers():
    return {p.name: d.digest(p) for p in sorted((d.APP / 'Contents/Helpers').iterdir()) if p.is_file() and not p.is_symlink()}

def sources():
    paths = [Path(__file__).resolve(), REPO / 'tools/archive_opening/packet.py', REPO / 'tools/archive_opening/admission_packet.py',
             REPO / 'tools/development.py', REPO / 'tools/native_build_processes.py', REPO / 'tools/runtime_diagnostics.py',
             REPO / 'tools/ssh_profiles/packet.py', REPO / 'tools/ssh_profiles/native_transfer.py', REPO / 'tools/ssh_profiles/owned_observer.py']
    return {str(p.relative_to(REPO)): d.digest(p) for p in paths}

def generate(root):
    source = root / 'source'
    bodies = {'First.txt': b'generated first\n', 'Second.txt': b'generated second\n',
              'Mutable.txt': b'before\n', 'Replacement.txt': b'after!\n'}
    for name, body in bodies.items():
        with (source / name).open('xb') as out: out.write(body)
        (source / name).chmod(0o600)
    for number in range(65):
        with (source / ('Count%02d' % number)).open('xb'): pass
    os.symlink('First.txt', source / 'Link')
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_STORED) as archive:
        info = zipfile.ZipInfo('Empty', (2026, 1, 1, 0, 0, 0)); info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o644) << 16; archive.writestr(info, b'')
    with (source / 'Review.zip').open('xb') as out: out.write(buffer.getvalue())
    (source / 'Review.zip').chmod(0o600)

def snapshot(source):
    result = {}
    for path in sorted(source.iterdir()):
        value = path.lstat()
        if value.st_uid != os.getuid(): raise RuntimeError('B13 generated source owner changed')
        if stat.S_ISLNK(value.st_mode):
            if path.name != 'Link' or os.readlink(path) != 'First.txt': raise RuntimeError('Exact opaque generated link required')
            digest = None
        elif stat.S_ISREG(value.st_mode) and value.st_nlink == 1:
            digest = d.digest(path)
        else: raise RuntimeError('Unexpected B13 generated namespace')
        result[path.name] = dict(sha256=digest, device=value.st_dev, inode=value.st_ino, mode=stat.S_IMODE(value.st_mode),
                                 size=value.st_size, mtimeNS=value.st_mtime_ns, ctimeNS=value.st_ctime_ns)
    return result

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--native-case', required=True)
    parser.add_argument('--airdrop-mode', choices=['full', 'reduced', 'off'], required=True); args = parser.parse_args()
    unlocked(); proof = native_proof(args.native_case)
    if helpers() != proof.get('helpersSHA256'): raise RuntimeError('Source-bound helper graph changed')
    audit()
    if len(cases()) >= 14: raise RuntimeError('Fourteen B13 native reservations consumed')
    root = d.reserve(ACTION)
    d.put(root / 'airdrop-admission.json', dict(master=MASTER, action=ACTION, mode=args.airdrop_mode,
          maximumRuntimeReservations=14, maximumPacketBytes=64 << 20, maximumPacketEntries=1536,
          maximumCaseBytes=64 << 20, maximumEntries=256, maximumSourceBytes=16 << 10,
          maximumRSSBytes=256 << 20, maximumSeconds=120, compilerReservations=0, realServicePerformCalls=0))
    report = dict(passed=False)
    try:
        generate(root); before = snapshot(root / 'source'); driver = sources()
        d.put(root / 'inputs.json', dict(nativeCase=args.native_case, nativeSources=proof['sourceSHA256'], helpersSHA256=proof['helpersSHA256'],
              driverSources=driver, generatedSource=before, generatedOnly=True, mode=args.airdrop_mode,
              realServicePerformCalls=0, recipientSelections=0, networkRequests=0, keychainCalls=0))
        memory = OwnedMemory(256 << 20); last = 0.0
        def observe(pid):
            nonlocal last
            memory(pid)
            if time.monotonic() - last > .25:
                usage = d.measure(root)
                if usage['bytes'] > 64 << 20 or usage['entries'] > 256: raise RuntimeError('B13 live case bound')
                audit(); last = time.monotonic()
        try:
            process, _, stderr = shared.run([str(d.APP / 'Contents/MacOS/Mac Explorer'), '--verify-ui', '--check-airdrop-native',
                    '--airdrop-mode', args.airdrop_mode], root, 'native-airdrop', timeout=120, native=True, observer=observe, independent_observer=True)
        finally: d.put(root / 'evidence/native-memory.json', memory.report())
        path = root / 'evidence/native-airdrop.json'; native = json.loads(path.read_bytes()) if path.exists() else {}
        after = snapshot(root / 'source'); expected = dict(before)
        if native.get('sourceChanged') is True:
            actual = after.get('Mutable.txt', {})
            if actual.get('sha256') != before['Replacement.txt']['sha256'] or actual.get('mode') != before['Mutable.txt']['mode']:
                raise RuntimeError('Declared generated mutation differs from exact replacement')
            expected['Mutable.txt'] = actual
        stable = after == expected and driver == sources() and proof['sourceSHA256'] == d.native_sources() and proof['helpersSHA256'] == helpers()
        native_proof(args.native_case); diagnostics = runtime_diagnostics.inspect(stderr)
        passed = bool(process['passed'] and process['peakRSSBytes'] <= 256 << 20 and native.get('passed') and stable
            and native.get('sourceChanged') is True and native.get('activityAfter') == 0
            and native.get('hasActiveHandoffAfter') is False and native.get('hasPendingPreparationAfter') is False
            and native.get('realServicePerformCalls') == 0 and native.get('recipientSelections') == 0
            and native.get('actualSend') is False and native.get('externalOpenCalls') == 0 and diagnostics['passed'])
        report.update(passed=passed, process=process, native=native, runtimeDiagnostics=diagnostics,
                      originalInputsUnchangedExceptDeclaredMutable=stable, generatedInputAfter=after, usage=audit())
        print(json.dumps(dict(case=root.name, passed=passed, mode=args.airdrop_mode, failureStage=native.get('failureStage'), checks=len(native.get('checks', [])))), flush=True)
        if not passed: raise RuntimeError('B13 native red; preserve exact evidence')
    finally:
        report['usage'] = audit(); d.put(root / 'evidence/result.json', report)

if __name__ == '__main__': main()
