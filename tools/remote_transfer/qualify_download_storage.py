#!/usr/bin/env python3
"""Charged generated-only native quarantine and later staging controls."""
import argparse
import hashlib
import json
import os
import re
import sys
from qualification import REPO,reserve,audit,directory,put
sys.path.insert(0,str(REPO/'tools'))
import dev
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--configuration',choices=['debug','release'],default='debug');parser.add_argument('--staging',action='store_true');parser.add_argument('--publication',action='store_true');args=parser.parse_args()
    if args.publication:args.staging=True
    case=reserve(('download-staging-' if args.staging else 'download-quarantine-')+args.configuration,entries=1024 if args.staging else 256);source=directory(case/'source')
    paths=[REPO/'Packages/ExplorerKit'/p for p in ['Sources/LocalStorage/DownloadedFileQuarantine.swift','Tests/LocalStorageTests/DownloadedFileQuarantineTests.swift']]
    if args.staging:paths += [REPO/'Packages/ExplorerKit'/p for p in ['Sources/LocalStorage/RemoteDownloadStore.swift','Tests/LocalStorageTests/RemoteDownloadStoreTests.swift']]
    if args.publication:paths += [REPO/'Packages/ExplorerKit'/p for p in ['Sources/FileOperations/ArchiveFileProduction.swift','Sources/FileOperations/ReceivedFileProduction.swift','Sources/LocalStorage/DownloadedFilePublication.swift','Tests/LocalStorageTests/DownloadedFilePublicationTests.swift']]
    for index,path in enumerate(paths):(source/(str(index)+'-'+path.name)).write_bytes(path.read_bytes())
    put(case/'inputs.json',dict(sourceSHA256={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in paths},personalFiles=0,networkConnections=0,keychainQueries=0))
    failure=None;log=None
    os.environ['MAC_EXPLORER_B12_SOURCE']=str(source)
    try:
        selected='DownloadedFileQuarantineTests|RemoteDownloadStoreTests' if args.staging else 'DownloadedFileQuarantineTests'
        if args.publication:selected+='|DownloadedFilePublicationTests'
        log=dev.test(selected,args.configuration,serial=True)
        contents=log.read_text()
        if not re.search(r'Executed '+str(30 if args.publication else 20 if args.staging else 8)+r' tests, with 0 failures',contents) or 'skipped'in contents:raise RuntimeError('Not all download-storage controls ran')
    except BaseException as error:failure=type(error).__name__
    finally:os.environ.pop('MAC_EXPLORER_B12_SOURCE',None)
    put(case/'result.json',dict(passed=failure is None,errorType=failure,testLog=str(log.relative_to(REPO))if log else None,packet=audit()))
    print(json.dumps(dict(case=case.name,passed=failure is None)),flush=True)
    if failure:raise SystemExit(1)
if __name__=='__main__':main()
