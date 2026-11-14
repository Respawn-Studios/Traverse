#!/usr/bin/env python3
"""Freeze the already qualified SMB library, with licenses and exact provenance.

Creation is an explicit source-maintenance action, never a build hook or fetch.
Verification needs only the tracked snapshot, not the ignored experiment cache.
"""
import argparse
import difflib
import json
from pathlib import Path
import shutil
import stat
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from smb_reader.packet import REPO, TOOLING, PINS, digest

TARGET = REPO / 'Vendor/smb2'
EXCLUDED = {'CLAUDE.md', 'AGENTS.md', 'Cargo.lock'}
LOCAL_METADATA = {'.DS_Store'}


def source_inventory(target):
    result = {}
    for path in target.rglob('*'):
        if path.is_symlink(): raise RuntimeError('Redirected vendored source')
        facts = path.lstat()
        if stat.S_ISDIR(facts.st_mode): continue
        if not stat.S_ISREG(facts.st_mode): raise RuntimeError('Unexpected vendored entry kind')
        # Finder metadata is not compiled, embedded or a source dependency.
        # Preserve it locally without reading/rewriting it or weakening hashes
        # for any reviewed source. All other additional files still refuse.
        if path.name not in {'PROVENANCE.json', 'DOWNSTREAM.patch'} | LOCAL_METADATA:
            result[str(path.relative_to(target))] = digest(path)
    return result


def verify():
    record = json.loads((TARGET / 'PROVENANCE.json').read_bytes())
    if record['upstreamCommit'] != PINS['smb2'][1] or record['upstreamRepository'] != 'https://github.com/vdavid/smb2':
        raise RuntimeError('Unexpected pinned SMB provenance')
    expected = record['files']
    actual = source_inventory(TARGET)
    if actual != expected or digest(TARGET / 'DOWNSTREAM.patch') != record['downstreamPatchSHA256']:
        raise RuntimeError('Tracked SMB source differs from its reviewed provenance')
    if any(p.is_symlink() for p in TARGET.rglob('*')):
        raise RuntimeError('Redirected vendored source')
    return record


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--create', action='store_true'); args = parser.parse_args()
    if not args.create:
        value = verify(); print(json.dumps(dict(verified=True, files=len(value['files']), commit=value['upstreamCommit']))); return
    if TARGET.exists(): raise RuntimeError('Vendored snapshot already exists; no overwrite')
    acquired = TOOLING / ('smb2-' + PINS['smb2'][1])
    qualified, upstream = acquired / 'qualified-auth/crates/smb2', acquired / 'source/crates/smb2'
    delta = json.loads((acquired / 'auth-delta.json').read_bytes())
    for item in delta['changes']:
        if digest(acquired / 'qualified-auth' / item['path']) != item['qualifiedSHA256']:
            raise RuntimeError('Qualified library changed after its security/lifetime tests')
    paths = sorted(p for p in qualified.rglob('*') if p.is_file() and p.name not in EXCLUDED)
    if len(paths) > 512 or sum(p.stat().st_size for p in paths) > 8 << 20:
        raise RuntimeError('Unexpected source extent')
    for p in paths:
        if not stat.S_ISREG(p.lstat().st_mode) or p.is_symlink(): raise RuntimeError('Unsafe source snapshot')
    TARGET.mkdir(parents=True)
    changes = []
    for source in paths:
        relative = source.relative_to(qualified); target = TARGET / relative
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(source, target)
        original = upstream / relative
        before = original.read_bytes() if original.exists() else b''
        after = source.read_bytes()
        if relative == Path('Cargo.toml'):
            text = after.decode()
            fields = {'edition': '"2021"', 'rust-version': '"1.85"', 'license': '"MIT OR Apache-2.0"',
                      'repository': '"https://github.com/vdavid/smb2"'}
            for key, value in fields.items():
                prior = key + '.workspace = true'
                if text.count(prior) != 1: raise RuntimeError('Upstream workspace shape changed')
                text = text.replace(prior, key + ' = ' + value)
            after = (text + '\n# Standalone pinned source snapshot; no ignored workspace required.\n[workspace]\n').encode()
            target.write_bytes(after)
        if before != after:
            changes.extend(difflib.unified_diff(before.decode().splitlines(keepends=True), after.decode().splitlines(keepends=True),
                fromfile='upstream/' + str(relative), tofile='qualified/' + str(relative)))
    patch = TARGET / 'DOWNSTREAM.patch'; patch.write_text(''.join(changes))
    value = dict(format=1, upstreamRepository='https://github.com/vdavid/smb2', upstreamCommit=PINS['smb2'][1],
        upstreamVersion='0.33.0', license='MIT OR Apache-2.0',
        qualificationDeltaSHA256=digest(acquired / 'auth-delta.json'), downstreamPatchSHA256=digest(patch),
        purpose='Pinned qualified metadata-only SMB reader; app policy and integration are maintained separately',
        omitted='Agent instructions and dependency lock; the browser wrapper owns its exact Cargo.lock',
        files={str(p.relative_to(TARGET)): digest(p) for p in TARGET.rglob('*') if p.is_file() and p != patch})
    (TARGET / 'PROVENANCE.json').write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
    verify(); print(json.dumps(dict(created=True, files=len(value['files']), bytes=sum(p.stat().st_size for p in TARGET.rglob('*') if p.is_file()))))


if __name__ == '__main__': main()
