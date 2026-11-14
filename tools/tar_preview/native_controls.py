#!/usr/bin/env python3
"""Twenty finite source-bound native TAR preview cases; no compiler admission."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import sys
import tarfile
import time
import zipfile

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools/archive_opening'))
from packet import d, shared, MASTER, prepare
from admission_packet import OwnedMemory
from native_transfer import native_proof, unlocked
import runtime_diagnostics

ACTION = 'tar-preview-native'
MODES = ['full-dark', 'reduced-dark', 'off-light150']


def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json') if json.loads(p.read_bytes()).get('action') == ACTION]


def audit():
    prepare(); value = d.audit(); roots = cases(); source_bytes = 0
    if len(roots) > 20: raise RuntimeError('Twenty native TAR preview reservations exceeded')
    for root in roots:
        usage = d.measure(root)
        if usage['bytes'] > 64 << 20 or usage['entries'] > 512: raise RuntimeError('Native TAR preview case bound')
        inputs = root / 'inputs.json'
        if inputs.exists():
            for name in json.loads(inputs.read_bytes())['generatedInputPaths']:
                path = root / 'source' / name
                if path.parent != root / 'source' or path.is_symlink() or not path.is_file(): raise RuntimeError('Generated TAR preview input redirected')
                source_bytes += path.stat().st_size
    if source_bytes > 5 * (1 << 18): raise RuntimeError('Native tiny TAR preview input sub-bound')
    value.update(tarPreviewNativeReservations=len(roots), tarPreviewNativeInputBytes=source_bytes)
    return value


def helpers():
    return {p.name: d.digest(p) for p in sorted((d.APP / 'Contents/Helpers').iterdir()) if p.is_file() and not p.is_symlink()}


def sources():
    paths = [Path(__file__).resolve(), REPO / 'tools/archive_opening/packet.py', REPO / 'tools/archive_opening/admission_packet.py',
             REPO / 'tools/development.py', REPO / 'tools/native_build_processes.py', REPO / 'tools/runtime_diagnostics.py',
             REPO / 'tools/ssh_profiles/packet.py', REPO / 'tools/ssh_profiles/native_transfer.py', REPO / 'tools/ssh_profiles/owned_observer.py']
    return {str(p.relative_to(REPO)): d.digest(p) for p in paths}


def hex_text(data):
    result = []
    for offset in range(0, len(data), 16):
        part = data[offset:offset + 16]
        result.append(f'{offset:08X}  ' + ' '.join(f'{b:02X}' for b in part).ljust(47)
                      + '  |' + ''.join(chr(b) if 32 <= b <= 126 else '.' for b in part).ljust(16) + '|\n')
    return ''.join(result)


def generate(root):
    markup = '<b>Generated café & inert markup</b>\n'
    rows = [('Folder/', None), ('Folder/Member.txt', b'abc'), ('Note.txt', b'hello'), ('Markup.txt', markup.encode()),
            ('Binary.bin', bytes(range(32))), ('Motion.txt', ('Generated TAR preview line with inert <markup> and enough text to wrap.\n' * 60).encode())]
    def archive(values):
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode='w', format=tarfile.USTAR_FORMAT) as writer:
            for name, body in values:
                info = tarfile.TarInfo(name); info.uid = info.gid = info.mtime = 0
                if body is None: info.type = tarfile.DIRTYPE; info.mode = 0o755
                else: info.size = len(body); info.mode = 0o644
                writer.addfile(info, None if body is None else io.BytesIO(body))
        return out.getvalue()
    base = archive(rows)
    replacement = archive([(name, b'changed' if name == 'Note.txt' else body) for name, body in rows])
    for name, body in [('Review.tar', base), ('Mutable.tar', base), ('Replacement.tar', replacement)]:
        with (root / 'source' / name).open('xb') as output: output.write(body)
        (root / 'source' / name).chmod(0o600)
    with zipfile.ZipFile(root / 'source/Review.zip', 'x', compression=zipfile.ZIP_STORED) as archive:
        info = zipfile.ZipInfo('Note.txt', (2026, 1, 1, 0, 0, 0)); info.create_system = 3; info.external_attr = (stat.S_IFREG | 0o644) << 16
        archive.writestr(info, b'hello')
    (root / 'source/Review.zip').chmod(0o600)
    digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
    d.put(root / 'oracle.json', dict(helloHexSHA256=digest(hex_text(b'hello')), binaryHexSHA256=digest(hex_text(bytes(range(32)))),
                                   markupSHA256=digest(markup), independentPythonByteOracle=True))


def snapshot(path):
    found = path.lstat()
    if not stat.S_ISREG(found.st_mode) or found.st_nlink != 1 or found.st_uid != os.getuid(): raise RuntimeError('Original generated preview input changed kind/owner')
    return dict(sha256=d.digest(path), size=found.st_size, mode=stat.S_IMODE(found.st_mode), device=found.st_dev,
                inode=found.st_ino, mtimeNS=found.st_mtime_ns, ctimeNS=found.st_ctime_ns)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--native-case', required=True); parser.add_argument('--preview-mode', choices=MODES, required=True)
    args = parser.parse_args()
    unlocked(); proof = native_proof(args.native_case)
    if helpers() != proof.get('helpersSHA256'): raise RuntimeError('Current native helper graph differs from source-bound build')
    audit()
    if len(cases()) >= 20: raise RuntimeError('Twenty native TAR preview reservations consumed')
    root = d.reserve(ACTION)
    d.put(root / 'preview-admission.json', dict(master=MASTER, action=ACTION, mode=args.preview_mode, maximumRuntimeReservations=20,
          maximumCaseBytes=64 << 20, maximumEntries=512, maximumRSSBytes=256 << 20, maximumSeconds=120,
          maximumOwnWindowClips=2 if args.preview_mode == 'full-dark' else 0, compilerReservations=0))
    report = dict(passed=False)
    try:
        generate(root)
        before = {p.name: snapshot(p) for p in sorted((root / 'source').iterdir())}
        drivers = sources()
        d.put(root / 'inputs.json', dict(nativeCase=args.native_case, nativeSources=proof['sourceSHA256'], helpersSHA256=proof['helpersSHA256'],
              driverSources=drivers, generatedSource=before, generatedInputPaths=list(before), mode=args.preview_mode,
              generatedOnly=True, explicitBodies=True, explicitGeneratedSourceChange=True, networkRequests=0, keychainCalls=0))
        memory = OwnedMemory(256 << 20); last = 0.0
        def observe(pid):
            nonlocal last
            memory(pid)
            if time.monotonic() - last > .25:
                usage = d.measure(root)
                if usage['bytes'] > 64 << 20 or usage['entries'] > 512: raise RuntimeError('Native TAR preview live case bound')
                last = time.monotonic()
        try:
            process, _, stderr = shared.run([str(d.APP / 'Contents/MacOS/Mac Explorer'), '--verify-ui',
                    '--check-tar-preview-native', '--preview-mode', args.preview_mode], root, 'native-tar-preview', timeout=120,
                    native=True, observer=observe, independent_observer=True)
        finally: d.put(root / 'evidence/native-memory.json', memory.report())
        path = root / 'evidence/native-tar-preview.json'; native = json.loads(path.read_bytes()) if path.exists() else {}
        if {p.name for p in (root / 'source').iterdir()} != set(before): raise RuntimeError('Read-only preview created an unexpected source output')
        after = {name: snapshot(root / 'source' / name) for name in before}
        expected = dict(before)
        changed = native.get('sourceChanged') is True
        if changed:
            actual = after['Mutable.tar']
            if actual['sha256'] != before['Replacement.tar']['sha256'] or actual['mode'] != before['Mutable.tar']['mode']:
                raise RuntimeError('Declared generated TAR replacement differs from frozen replacement')
            expected['Mutable.tar'] = actual
        stable = after == expected and drivers == sources() and proof['sourceSHA256'] == d.native_sources() and proof['helpersSHA256'] == helpers()
        native_proof(args.native_case)
        diagnostics = runtime_diagnostics.inspect(stderr)
        expected_clips = 2 if args.preview_mode == 'full-dark' else 0
        passed = bool(process['passed'] and process['peakRSSBytes'] <= 256 << 20 and native.get('passed')
            and native.get('activityAfter') == 0 and native.get('poolRetainedAfter') == 0 and native.get('poolRetiringAfter') == 0
            and native.get('exportsAfter') == 0 and native.get('externalOpenCalls') == 0 and native.get('sourceChanged') is True
            and len(native.get('clips', [])) == expected_clips and stable and diagnostics['passed'])
        report.update(passed=passed, process=process, native=native, originalInputsUnchangedExceptDeclaredReplacement=stable,
                      generatedInputAfter=after, runtimeDiagnostics=diagnostics, usage=audit())
        print(json.dumps(dict(case=root.name, passed=passed, mode=args.preview_mode, failureStage=native.get('failureStage'), checks=len(native.get('checks', [])))), flush=True)
        if not passed: raise RuntimeError('Native TAR preview failed; retain exact evidence')
    finally:
        d.put(root / 'evidence/result.json', report)


if __name__ == '__main__': main()
