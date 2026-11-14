#!/usr/bin/env python3
"""Preserve baseline and prepare public-only isolated Cargo registry."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
sys.dont_write_bytecode = True
from packet import REPO, TOOLING, TOOLCHAIN, prepare, directory, audit, d, run

PROJECT = REPO / 'tools/sftp_reader/qualification'


def package_versions(data):
    values = {}
    for block in data.decode().split('[[package]]')[1:]:
        name = re.search(r'^name = "([^"]+)"$', block, re.M)
        version = re.search(r'^version = "([^"]+)"$', block, re.M)
        checksum = re.search(r'^checksum = "([a-f0-9]{64})"$', block, re.M)
        if not name or not version:
            raise RuntimeError('Invalid owned Cargo lock package')
        values[name.group(1) + '@' + version.group(1)] = checksum.group(1) if checksum else None
    return values


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'resolve', 'fetch'])
    args = parser.parse_args()
    prepare()
    root = d.reserve('ssh-dependency-' + args.action)
    for name in ['Cargo.toml', 'Cargo.lock']:
        (root / 'source' / name).write_bytes((PROJECT / name).read_bytes())
    before = package_versions((PROJECT / 'Cargo.lock').read_bytes())
    d.put(root / 'inputs.json', {'action': args.action, 'manifestSHA256': d.digest(PROJECT / 'Cargo.toml'),
                               'lockSHA256': d.digest(PROJECT / 'Cargo.lock'), 'publicRegistryOnly': True,
                               'newToolingLimitBytes': 2 << 30, 'personalCredentials': False})
    if args.action == 'prepare':
        source = REPO / '.build/b11-reader-tooling/cargo-home/registry'
        target = directory(TOOLING / 'cargo-home/registry')
        copied = {}
        total = 0
        for area in ['cache', 'index']:
            for parent, dirs, files in os.walk(source / area, followlinks=False):
                dirs[:] = [name for name in dirs if name != '.git']
                for name in files:
                    path = Path(parent) / name
                    facts = path.lstat()
                    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_size > 32 << 20:
                        raise RuntimeError('Unexpected public registry input')
                    relative = path.relative_to(source)
                    destination = target / relative
                    directory(destination.parent)
                    total += facts.st_size
                    if total > 64 << 20 or len(copied) >= 2048:
                        raise RuntimeError('Registry seed bound')
                    if destination.exists():
                        if destination.is_symlink() or d.digest(destination) != d.digest(path):
                            raise RuntimeError('Different existing isolated registry seed')
                    else:
                        with destination.open('xb') as output:
                            os.fchmod(output.fileno(), 0o600)
                            output.write(path.read_bytes())
                    if d.digest(destination) != d.digest(path):
                        raise RuntimeError('Registry copy mismatch')
                    copied[str(relative)] = d.digest(destination)
        d.put(root / 'evidence/registry-seed.json', {'files': copied, 'bytes': total, 'previousRegistryUnmodified': True})
    elif args.action == 'resolve':
        # crypto-bigint's fixed release itself requires ctutils >= 0.4.5.
        # Freeze that compatible fixed pair rather than force the advisory's
        # older minimum into an unsatisfiable dependency graph.
        for package, version in [('crypto-bigint', '0.7.6'), ('ctutils', '0.4.5')]:
            result, _, _ = run([str(TOOLCHAIN / 'bin/cargo'), 'update', '--manifest-path', str(PROJECT / 'Cargo.toml'),
                                '-p', package, '--precise', version], root, 'update-' + package,
                               timeout=120, cwd=PROJECT, rust=True)
            if not result['passed']:
                raise RuntimeError('Contained dependency resolution failed; preserve lock and evidence')
    else:
        result, _, _ = run([str(TOOLCHAIN / 'bin/cargo'), 'fetch', '--manifest-path', str(PROJECT / 'Cargo.toml'),
                            '--locked', '--target', 'aarch64-apple-darwin'], root, 'fetch-public-locked',
                           timeout=120, cwd=PROJECT, rust=True)
        if not result['passed']:
            raise RuntimeError('Public dependency fetch failed')
    after = package_versions((PROJECT / 'Cargo.lock').read_bytes())
    existing_unchanged = all(after[k] == v for k, v in before.items() if k in after)
    if not existing_unchanged:
        raise RuntimeError('Public registry checksum changed for an existing version')
    d.put(root / 'evidence/graph.json', {'action': args.action, 'before': before, 'after': after,
        'added': sorted(set(after) - set(before)), 'removed': sorted(set(before) - set(after)),
        'checksumsOfExistingVersionsUnchanged': existing_unchanged,
        'lockSHA256': d.digest(PROJECT / 'Cargo.lock'), 'usage': audit()})
    print(json.dumps({'case': root.name, 'action': args.action, 'packages': len(after), 'added': sorted(set(after)-set(before)), 'removed': sorted(set(before)-set(after))}))


if __name__ == '__main__':
    main()
