#!/usr/bin/env python3
"""Generated early destination observation across real received-file publication."""
import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import reserve, put, measure, audit, directory, MIB, REPO


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--red', action='store_true')
    parser.add_argument('--with-publication', action='store_true')
    args = parser.parse_args()
    root = reserve('traverse-received-destination')
    sources = ['Packages/ExplorerKit/Sources/FileOperations/ReceivedFileProduction.swift',
        'Packages/ExplorerKit/Sources/LocalStorage/DownloadedFilePublication.swift',
        'Packages/ExplorerKit/Sources/LocalStorage/SFTPRequestedDownload.swift',
        'Packages/ExplorerKit/Tests/LocalStorageTests/DownloadedFilePublicationTests.swift',
        'Packages/ExplorerKit/Tests/LocalStorageTests/ReceivedDestinationIdentityTests.swift']
    copies = directory(root/'evidence/input-sources')
    hashes = {}
    for name in sources:
        data = (REPO/name).read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
        (copies/Path(name).name).write_bytes(data)
    put(root/'inputs.json', dict(generatedOnly=True, maximumCaseBytes=8*MIB, maximumCaseEntries=1024,
        maximumSourceBytes=2*MIB, personalFiles=0, networkRequests=0, expectedCounterexample=args.red, sourceSHA256=hashes))
    env_name = 'MAC_EXPLORER_DESTINATION_TEST_ROOT'
    os.environ[env_name] = str(root)
    if args.with_publication: os.environ['MAC_EXPLORER_B12_SOURCE'] = str(root/'source')
    failure = None; log = None
    try:
        selected = 'ReceivedDestinationIdentityTests'
        if args.red: selected += '/testReplacementBetweenEarlyCheckAndFinalPreparationIsRefused'
        elif args.with_publication: selected += '|DownloadedFilePublicationTests'
        log = dev.test(selected, args.configuration, serial=True)
        raw = log.read_text()
        if not re.search(r'Executed '+str(1 if args.red else 15 if args.with_publication else 5)+r' tests?, with 0 failures', raw) or 'skipped' in raw:
            raise RuntimeError('Destination controls did not all run')
    except BaseException as error: failure = type(error).__name__
    finally:
        os.environ.pop(env_name, None); os.environ.pop('MAC_EXPLORER_B12_SOURCE', None)
    usage = measure(root)
    passed = failure is None and usage['bytes'] <= 8*MIB and usage['entries'] <= 1024 \
        and hashes == {name: hashlib.sha256((REPO/name).read_bytes()).hexdigest() for name in sources}
    put(root/'result.json', dict(passed=passed, expectedCounterexample=args.red, errorType=failure,
        testLog=str(log.relative_to(REPO)) if log else None, caseUsage=usage, packet=audit()))
    print(json.dumps(dict(case=root.name, passed=passed, expectedCounterexample=args.red)), flush=True)
    if not passed: raise SystemExit(1)


if __name__ == '__main__': main()
