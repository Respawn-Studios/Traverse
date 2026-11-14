#!/usr/bin/env python3
"""Real owned-catalog filesystem controls, without network or credentials."""
import argparse
import json
import os
import re
import sys
sys.dont_write_bytecode = True
from completion_packet import reserve, audit
from packet import REPO, MIB, directory, digest, put
sys.path.insert(0, str(REPO / 'tools'))
import dev


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--contracts', action='store_true')
    parser.add_argument('--setup', action='store_true')
    parser.add_argument('--identity', action='store_true')
    args = parser.parse_args()
    case = reserve('runtime-storage-' + args.configuration)
    source = directory(case / 'source')
    files = [REPO / 'Packages/ExplorerKit/Sources/LocalStorage/SMBTemporaryCatalog.swift',
             REPO / 'Packages/ExplorerKit/Tests/LocalStorageTests/SMBTemporaryCatalogTests.swift']
    if args.contracts:
        files += [REPO / 'Packages/ExplorerKit/Sources/LocalStorage' / name for name in ['SMBPreparedConnection.swift', 'SMBBrowserSession.swift', 'SMBBrowserLaunch.swift']]
        files += [REPO / 'Packages/ExplorerKit/Tests/LocalStorageTests/SMBPreparedConnectionTests.swift']
    if args.setup:
        files += [REPO / 'Packages/ExplorerKit/Sources/LocalStorage' / name for name in ['SMBConnectionCoordinator.swift', 'SMBServerRemembering.swift']]
        files += [REPO / 'Packages/ExplorerKit/Tests/LocalStorageTests/SMBConnectionCoordinatorTests.swift']
    if args.identity:
        files += [REPO / 'Packages/ExplorerKit/Sources/LocalStorage/SMBBundledHelperIdentity.swift',
            REPO / 'Packages/ExplorerKit/Tests/LocalStorageTests/SMBHelperManifestTests.swift']
    put(case / 'inputs.json', dict(sourceSHA256={str(p.relative_to(REPO)): digest(p) for p in files},
        networkConnections=0, keychainAccesses=0, personalCatalogs=0, configuration=args.configuration))
    os.environ['MAC_EXPLORER_B10_COMPLETION_SOURCE'] = str(source)
    before = set((REPO / '.build/logs').glob('test-*.log')); failure = None; log = None
    try:
        selected = 'SMBTemporaryCatalogTests|SMBPreparedConnectionTests|SMBBrowserSessionTests' if args.contracts else 'SMBTemporaryCatalogTests'
        if args.setup: selected += '|SMBConnectionCoordinatorTests'
        if args.identity: selected += '|SMBHelperManifestTests'
        dev.test(selected, configuration=args.configuration, serial=True)
        logs = set((REPO / '.build/logs').glob('test-*.log')) - before
        if len(logs) != 1: raise RuntimeError('Exact runtime-storage log missing')
        log = logs.pop(); contents = log.read_text()
        count = (15 if args.contracts else 8) + (9 if args.setup else 0) + (6 if args.identity else 0)
        if log.stat().st_size > MIB or not re.search(r'Executed ' + str(count) + r' tests, with 0 failures', contents) or 'skipped' in contents:
            raise RuntimeError('Runtime storage/contract tests did not execute all expected cases')
    except Exception as error: failure = str(error)[:400]
    finally: os.environ.pop('MAC_EXPLORER_B10_COMPLETION_SOURCE', None)
    put(case / 'result.json', dict(passed=failure is None, failure=failure, actualExit=0 if failure is None else None,
        testLog=str(log.relative_to(REPO)) if log else None))
    after = audit(); print(json.dumps(dict(case=case.name, passed=failure is None, failure=failure, after=after)), flush=True)
    if failure: raise SystemExit(1)


if __name__ == '__main__': main()
