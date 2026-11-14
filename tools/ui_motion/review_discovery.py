#!/usr/bin/env python3
"""Decode only admitted native clips, with repo-local SDK caches."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO, TOOLING, MIB, audit, directory, put, require_case
from qualify_foundation import wait_generated


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('case')
    suite = parser.add_mutually_exclusive_group()
    suite.add_argument('--profiles', action='store_true')
    suite.add_argument('--queue', action='store_true')
    suite.add_argument('--search', action='store_true')
    suite.add_argument('--largest', action='store_true')
    suite.add_argument('--archive-pane', action='store_true')
    suite.add_argument('--archive-search', action='store_true')
    suite.add_argument('--private-labels', action='store_true')
    suite.add_argument('--archive-drag', action='store_true')
    suite.add_argument('--archive-order', action='store_true')
    suite.add_argument('--browser-tasks', action='store_true')
    suite.add_argument('--header-hover', action='store_true')
    suite.add_argument('--properties-storage', action='store_true')
    suite.add_argument('--folder-opener', action='store_true')
    suite.add_argument('--archive-bytes', action='store_true')
    args = parser.parse_args()
    root = require_case(args.case)
    action = 'traverse-profile-workspaces-ui' if args.profiles else 'traverse-queue-priority' if args.queue else 'traverse-search-progress' if args.search else 'traverse-largest-files-ui' if args.largest else 'traverse-archive-pane-destination' if args.archive_pane else 'traverse-archive-search' if args.archive_search else 'traverse-private-labels' if args.private_labels else 'traverse-archive-member-drag' if args.archive_drag else 'traverse-archive-sorting' if args.archive_order else 'traverse-browser-tasks' if args.browser_tasks else 'traverse-header-hover' if args.header_hover else 'traverse-properties-storage' if args.properties_storage else 'traverse-folder-opener' if args.folder_opener else 'traverse-archive-bytes-ui' if args.archive_bytes else 'traverse-command-finder'
    if json.loads((root/'reservation.json').read_bytes()).get('action') != action:
        raise RuntimeError('Recording packet does not match this decoder')
    before = audit()
    if before['tooling']['allocatedBytes'] + 96*MIB > 4 << 30:
        raise RuntimeError('Media compiler needs 96 MiB headroom; no child started')
    cache = directory(TOOLING/'motion-module-cache')
    command = ['/usr/bin/xcrun','swift','-module-cache-path',str(cache),
        str(REPO/'tools/ui_motion/review_command_finder.swift')]
    if args.profiles:
        command.append('--profiles')
    elif args.queue:
        command.append('--queue')
    elif args.search:
        command.append('--search')
    elif args.largest:
        command.append('--largest')
    elif args.archive_pane:
        command.append('--archive-pane')
    elif args.archive_search:
        command.append('--archive-search')
    elif args.private_labels:
        command.append('--private-labels')
    elif args.archive_drag:
        command.append('--archive-drag')
    elif args.archive_order:
        command.append('--archive-order')
    elif args.browser_tasks:
        command.append('--browser-tasks')
    elif args.header_hover:
        command.append('--header-hover')
    elif args.properties_storage:
        command.append('--properties-storage')
    elif args.folder_opener:
        command.append('--folder-opener')
    elif args.archive_bytes:
        command.append('--archive-bytes')
    command.append(args.case)
    log = root/'evidence/frame-decoder.log'
    with log.open('xb') as output:
        child = subprocess.Popen(command,cwd=REPO,env=dev.environment(tooling=False),stdin=subprocess.DEVNULL,
            stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        stats,failure,contained,forced = wait_generated(child,log,root/'evidence',deadline=40)
    passed = child.returncode == 0 and not contained and stats.ru_maxrss <= 1 << 30
    put(root/'evidence/frame-decoder.json',dict(passed=passed,actualExit=child.returncode,
        failure=failure,contained=contained,forced=forced,peakRSSBytes=stats.ru_maxrss,packet=audit()))
    print(json.dumps(dict(case=args.case,passed=passed)))
    if not passed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
