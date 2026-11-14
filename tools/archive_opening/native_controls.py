#!/usr/bin/env python3
"""Actual native archive Open regression, including an explicitly expected red."""
import argparse
import io
import json
import os
from pathlib import Path
import stat
import sys
import tarfile
import zipfile

sys.dont_write_bytecode = True
from packet import d, reserve, audit, run, MASTER
from native_transfer import native_proof, unlocked
import runtime_diagnostics

RED_STAGE = 'tar-default-open-routed-externally'


def driver_sources():
    return {name: d.digest(Path(__file__).resolve().parent / name)
            for name in ['packet.py', 'native_controls.py']}


def snapshot(root):
    result = {}
    for path in sorted(root.rglob('*')):
        facts = path.lstat()
        key = str(path.relative_to(root))
        result[key] = dict(mode=stat.S_IMODE(facts.st_mode), device=facts.st_dev, inode=facts.st_ino,
                           size=facts.st_size, mtimeNS=facts.st_mtime_ns, ctimeNS=facts.st_ctime_ns,
                           kind=stat.S_IFMT(facts.st_mode))
        if stat.S_ISREG(facts.st_mode): result[key]['sha256'] = d.digest(path)
        if stat.S_ISLNK(facts.st_mode): result[key]['target'] = os.readlink(path)
    return result


def generate(root):
    source = root / 'source'
    with tarfile.open(source / 'Review.tar', 'w', format=tarfile.USTAR_FORMAT) as archive:
        for name, body in [('Folder/', None), ('Folder/Member.txt', b'abc'), ('Note.txt', b'note')]:
            item = tarfile.TarInfo(name)
            item.mode, item.mtime = (0o755 if body is None else 0o644), 0
            if body is None:
                item.type = tarfile.DIRTYPE
                archive.addfile(item)
            else:
                item.size = len(body)
                archive.addfile(item, io.BytesIO(body))
    with zipfile.ZipFile(source / 'Review.zip', 'x', compression=zipfile.ZIP_STORED) as archive:
        for name, body in [('Folder/', b''), ('Folder/Member.txt', b'abc'), ('Note.txt', b'note')]:
            item = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = ((stat.S_IFDIR | 0o755) if name.endswith('/') else (stat.S_IFREG | 0o644)) << 16
            archive.writestr(item, body)
    (source / 'Ordinary.txt').write_bytes(b'generated ordinary Open probe\n')
    (source / 'Folder').mkdir(mode=0o700)
    (source / 'Link.tar').symlink_to('Review.tar')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-case', required=True)
    parser.add_argument('--expected-red', action='store_true')
    args = parser.parse_args()
    unlocked()
    proof = native_proof(args.native_case)
    root = reserve()
    generate(root)
    before = snapshot(root / 'source')
    drivers = driver_sources()
    d.put(root / 'inputs.json', dict(dayBuildMaster=MASTER, nativeCase=args.native_case,
          nativeSources=proof['sourceSHA256'], driverSources=drivers, generatedSource=before,
          expectedRedStage=RED_STAGE if args.expected_red else None,
          maximumNativeRSSBytes=256 << 20, maximumSeconds=90, networkRequests=0, keychainCalls=0))
    audit()
    process, _, stderr = run([str(d.APP / 'Contents/MacOS/Mac Explorer'), '--verify-ui',
                              '--check-archive-open-routing'], root, 'native-archive-open-routing')
    path = root / 'evidence/native-archive-open-routing.json'
    native = json.loads(path.read_bytes()) if path.is_file() else {}
    diagnostics = runtime_diagnostics.inspect(stderr)
    stable = (before == snapshot(root / 'source') and proof['sourceSHA256'] == d.native_sources()
              and drivers == driver_sources())
    bounded = bool(process['passed'] and process['peakRSSBytes'] <= 256 << 20 and diagnostics['passed'])
    passed = bool(bounded and stable and native.get('passed') and native.get('activityAfter') == 0
                  and native.get('ownersDrained') is True)
    expected_red_observed = bool(args.expected_red and bounded and stable and native.get('passed') is False
                                and native.get('failureStage') == RED_STAGE
                                and native.get('defaultOpenCalls') == 1
                                and native.get('activityAfter') == 0 and native.get('ownersDrained') is True)
    d.put(root / 'evidence/result.json', dict(passed=passed, expectedRedRequested=args.expected_red,
          expectedRedStage=RED_STAGE if args.expected_red else None, expectedRedObserved=expected_red_observed,
          process=process, native=native, generatedSourceUnchanged=stable,
          runtimeDiagnostics=diagnostics, usage=audit()))
    print(json.dumps(dict(case=root.name, passed=passed, expectedRedObserved=expected_red_observed,
                          failureStage=native.get('failureStage'), checks=len(native.get('checks', [])))), flush=True)
    if args.expected_red:
        if not expected_red_observed:
            raise RuntimeError('Expected native archive Open red stage was not observed; evidence retained')
    elif not passed:
        raise RuntimeError('Native archive Open regression failed; evidence retained')


if __name__ == '__main__':
    main()
