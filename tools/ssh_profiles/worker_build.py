#!/usr/bin/env python3
"""Frozen source/graph proof for the new bounded auth worker and fixtures."""
import argparse
import json
import sys
sys.dont_write_bytecode = True
from packet import prepare, d, run, audit, REPO, TOOLING, TOOLCHAIN


def sources():
    project = REPO / 'tools/sftp_reader/qualification'
    paths = list((project / 'src').rglob('*.rs')) + [project / n for n in ['Cargo.toml', 'Cargo.lock', 'build.rs']]
    paths += [REPO / 'tools/sftp_reader/catalog/catalog.rs', REPO / 'tools/smb_reader/catalog/StoreAuthority.c']
    return {str(p.relative_to(REPO)): d.digest(p) for p in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--release', action='store_true'); parser.add_argument('--folders', action='store_true'); parser.add_argument('--routed', action='store_true'); parser.add_argument('--routed-folder', action='store_true'); parser.add_argument('--fixture-completion',action='store_true');args = parser.parse_args()
    if args.fixture_completion and not args.routed_folder:raise RuntimeError('Only the J fixture completion is admitted')
    if args.routed and not args.folders:raise RuntimeError('Routed Download qualification requires the complete folder contract')
    if args.routed_folder:
        if not(args.release and args.folders and args.routed):raise RuntimeError('J requires optimized complete routed/folder controls')
        from routed_folder_packet import reserve,audit as packet_audit
        root=reserve('worker-controls',fixture_completion=args.fixture_completion)
    else:
        prepare(); root = d.reserve('ssh-auth-worker-release' if args.release else 'ssh-auth-worker-debug');packet_audit=audit
    hashes = sources()
    for index, (path, _) in enumerate(hashes.items()): (root / 'source' / (str(index) + '-' + path.split('/')[-1])).write_bytes((REPO / path).read_bytes())
    d.put(root / 'inputs.json', {'sources': hashes, 'release': args.release, 'personalCredentials': False, 'networkAttempts': 0,'routedFolder':args.routed_folder,'testDriverLaunches':1})
    features = 'upload-qualification,download-qualification' + (',folder-download-qualification' if args.folders else '')
    flags = ['--manifest-path', str(REPO / 'tools/sftp_reader/qualification/Cargo.toml'), '--locked', '--offline', '--features', features]
    if args.release: flags += ['--release']
    extra=['--bin','jump_bridge_fixture']if args.routed else []
    tests, _, _ = run([str(TOOLCHAIN / 'bin/cargo'), 'test', *flags, '--lib', '--bin', 'key_fixture',*extra], root, 'offline-contracts', rust=True)
    if args.routed_folder and tests['peakRSSBytes']>512<<20:tests['passed']=False
    if not tests['passed']:
        d.put(root/'evidence/result.json',dict(passed=False,stage='offline-contracts',process=tests,networkRequests=0,usage=packet_audit()))
        raise RuntimeError('Auth offline contracts failed')
    built, _, _ = run([str(TOOLCHAIN / 'bin/cargo'), 'build', *flags, '--bin', 'catalog_worker', '--bin', 'key_fixture', '--bin', 'key_probe', '--bin', 'jump_fixture', '--bin', 'fixture_only',*extra], root, 'worker-build', rust=True)
    if args.routed_folder and built['peakRSSBytes']>512<<20:built['passed']=False
    unchanged = sources() == hashes
    mode = 'release' if args.release else 'debug'
    proof = {'passed': built['passed'] and unchanged, 'sourceUnchanged': unchanged, 'release': args.release, 'sources': hashes,
        'binaries': {n: d.digest(TOOLING / 'target' / mode / n) for n in ['catalog_worker', 'key_fixture', 'key_probe', 'jump_fixture', 'fixture_only']+(['jump_bridge_fixture']if args.routed else [])} if built['passed'] else {},
        'features': features, 'usage': packet_audit()}
    d.put(root / 'evidence/result.json', proof); print(json.dumps({'case': root.name, 'passed': proof['passed']}))
    if not proof['passed']: raise SystemExit(1)


if __name__ == '__main__': main()
