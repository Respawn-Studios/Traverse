#!/usr/bin/env python3
"""Inventory generated storage; remove only an explicitly reviewed cleanup plan.

No personal data, installed applications, Git files or external worktrees are
eligible. Run `plan` first. Reports and unresolved reproducers are retained.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import time

REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / '.build'
REPORT = BUILD / 'maintenance/2026-10-31'
# These contain the current unintegrated investigation, not obsolete builds.
KEEP = (
    'maintenance', 'runtime', 'runtime-cache', 'xcode', 'xcode-release',
    'swift-tests', 'swift-tests-release', 'compiler-cache',
    # These are the ordinary network workers' current incremental caches, not
    # per-attempt build copies. Their packet/build entry points still use them.
    'ssh-profile-tooling/target', 'b10-network-tooling/target',
    'b10-network-tooling/swift-module-cache', 'b11-reader-tooling/target',
    # traverse.py project_arguments still uses this distribution cache. Frozen
    # archives are independent, but the next beta should reuse its compilation.
    'traverse-release/tooling/derived',
    # The pinned crash framework uses one shared incremental compiler cache.
    'crash-reporter-tooling/derived',
    # The concurrent security review owns source diffs and recovery evidence
    # here as well as compiler data. It is not a disposable module cache.
    'traverse-security-review',
    'traverse-security-actions',
    'traverse-development/A5F9410C-B3BE-454F-B5CE-68496D9D6205',
    'traverse-release/tooling/analysis-pin-repair-qualification-860B06B3-AFA6-4E51-9484-17256C00BAFE',
)
CACHES = {'clang-modules', 'swift-module-cache', 'compiler-cache',
          'ModuleCache.noindex', 'Index.noindex', 'Intermediates.noindex'}


def preserved(relative: Path) -> bool:
    name = relative.as_posix()
    return any(name == p or name.startswith(p + '/') for p in KEEP) or (
        name.startswith('traverse-release/tooling/native-journal11-'))


def save(name: str, value: dict) -> None:
    REPORT.mkdir(parents=True, exist_ok=True)
    (REPORT / name).write_text(json.dumps(value, indent=2) + '\n')


def inventory(name: str, *, whole_checkout: bool = False) -> None:
    """Descriptor-relative traversal also handles old overlong-name fixtures."""
    scan_root = REPO if whole_checkout else BUILD
    totals = {}
    errors = []
    large_low_allocation = []
    started = time.monotonic()
    def error(value):
        errors.append(str(value))
    for directory, dirs, files, fd in os.fwalk(scan_root, follow_symlinks=False, onerror=error):
        relative = Path(directory).relative_to(scan_root)
        key = relative.parts[0] if relative.parts else '.'
        row = totals.setdefault(key, dict(logicalBytes=0, allocatedBytes=0, files=0, directories=0, symlinks=0))
        row['directories'] += 1
        for entry in files + [d for d in dirs if os.path.islink(os.path.join(directory, d))]:
            try:
                value = os.stat(entry, dir_fd=fd, follow_symlinks=False)
                if stat.S_ISLNK(value.st_mode):
                    row['symlinks'] += 1
                elif stat.S_ISREG(value.st_mode):
                    row['files'] += 1
                    row['logicalBytes'] += value.st_size
                    row['allocatedBytes'] += value.st_blocks * 512
                    # Compiler caches can reserve very large address-space
                    # maps with almost no allocated blocks. Report the facts
                    # separately; neither sparse nor compressed files imply
                    # an equivalent physical-space reclaim opportunity.
                    if value.st_size >= 1 << 30 and value.st_blocks * 512 < value.st_size // 5:
                        large_low_allocation.append(dict(
                            path=(relative / entry).as_posix(), logicalBytes=value.st_size,
                            allocatedBytes=value.st_blocks * 512))
            except OSError as exc:
                error(exc)
    value = dict(repository=str(REPO), scope=scan_root.relative_to(REPO).as_posix(), seconds=time.monotonic()-started,
                 allocationNote='Per-file allocation, not exclusive physical APFS space; hard links may repeat.',
                 roots=totals, errors=errors,
                 largeLowAllocationFiles=sorted(large_low_allocation,
                     key=lambda entry: entry['logicalBytes'], reverse=True)[:32])
    save(name, value)
    print(json.dumps(dict(report=str(REPORT/name), logicalGB=sum(v['logicalBytes'] for v in totals.values())/1e9,
                          allocatedGB=sum(v['allocatedBytes'] for v in totals.values())/1e9,
                          files=sum(v['files'] for v in totals.values()), errors=len(errors)), indent=2))


def plan() -> None:
    candidates = []
    def is_directory(name, fd):
        try:
            return stat.S_ISDIR(os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode)
        except OSError:
            return False
    for directory, dirs, _, fd in os.fwalk(BUILD, follow_symlinks=False):
        parent = Path(directory)
        for name in list(dirs):
            path = parent / name
            relative = path.relative_to(BUILD)
            value = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISLNK(value.st_mode) or preserved(relative):
                dirs.remove(name)
                continue
            # Reproducible compiler outputs, not source/checkpoint directories.
            cached = name in CACHES or (name == 'target' and is_directory(name+'/debug/.fingerprint', fd))
            cached |= name == 'derived' and is_directory(name+'/Build', fd)
            # An owner marker identifies a fixture, not a passing result.
            # The package runner retires its own successful new roots. Older
            # failure/standalone fixtures require a separate reviewed list.
            if cached:
                candidates.append(dict(path=relative.as_posix(), device=value.st_dev, inode=value.st_ino,
                                       reason='reproducible compiler cache'))
                dirs.remove(name)
    save('cleanup-plan.json', dict(repository=str(REPO), ownerRequest='31 October cleanup', entries=candidates))
    print(f'{len(candidates)} proposed paths; inspect {REPORT / "cleanup-plan.json"}')


def apply(*, reviewed: bool = False) -> None:
    if not reviewed:
        raise ValueError('Inspect the exact cleanup plan, then use apply --reviewed')
    value = json.loads((REPORT/'cleanup-plan.json').read_text())
    if value['repository'] != str(REPO) or BUILD.is_symlink():
        raise ValueError('Wrong checkout')
    admitted = []
    seen = set()
    # Refuse the whole plan before the first deletion. In particular, a newly
    # protected workspace must not cause a partially applied older discovery.
    for row in value['entries']:
        relative = Path(row['path'])
        if not relative.parts or relative.is_absolute() or '..' in relative.parts or preserved(relative) or relative in seen:
            raise ValueError('Ineligible path')
        seen.add(relative)
        path = BUILD / relative
        if not path.exists():
            if path.is_symlink():
                raise ValueError('Redirected cleanup target')
            continue
        current = path.lstat()
        if path.resolve() != path or not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid() \
                or (current.st_dev, current.st_ino) != (row['device'], row['inode']):
            raise ValueError(f'Changed or redirected cleanup target: {relative}')
        admitted.append((row, path))
    completed = []
    for row, path in admitted:
        # Recheck the namespace immediately before mutation as well.
        current = path.lstat()
        if path.resolve() != path or (current.st_dev, current.st_ino) != (row['device'], row['inode']):
            raise ValueError(f'Cleanup target changed after review: {row["path"]}')
        shutil.rmtree(path)
        completed.append(row)
        save('cleanup-result.json', dict(repository=str(REPO), removed=completed))
    print(f'Removed {len(completed)} explicitly planned generated directories')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['before', 'after', 'plan', 'apply'])
    parser.add_argument('--report-root', type=Path, default=REPORT,
                        help='Owned report/plan directory under .build/maintenance; use a fresh dated run.')
    parser.add_argument('--reviewed', action='store_true', help='Apply only after inspecting the complete exact plan.')
    parser.add_argument('--whole-checkout', action='store_true',
                        help='Include source and Git metadata in before/after size observations only; never expands cleanup.')
    args = parser.parse_args()
    if args.whole_checkout and args.action not in ('before', 'after'):
        parser.error('--whole-checkout is read-only and requires before or after')
    report = args.report_root if args.report_root.is_absolute() else REPO / args.report_root
    maintenance = BUILD / 'maintenance'
    if not report.is_relative_to(maintenance) or '..' in report.parts \
            or report.resolve() != report or report.exists() and not report.is_dir():
        parser.error('--report-root must be an unredirected directory under .build/maintenance')
    REPORT = report
    if args.action in ('before', 'after'):
        inventory(args.action+'.json', whole_checkout=args.whole_checkout)
    elif args.action == 'plan':
        plan()
    else:
        apply(reviewed=args.reviewed)
