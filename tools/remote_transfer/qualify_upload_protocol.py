#!/usr/bin/env python3
"""Pure native versioned upload/legacy protocol checks; no connection or body."""
import argparse
import hashlib
import json
import re
import sys
from upload_integration_packet import REPO,reserve,directory,put,audit
sys.path.insert(0,str(REPO/'tools'))
import dev

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--configuration',choices=['debug','release'],default='debug')
    args=parser.parse_args()
    case=reserve('native-upload-protocol-'+args.configuration)
    source=directory(case/'source')
    names=['Sources/LocalStorage/SFTPWorkerProtocol.swift','Sources/LocalStorage/SFTPDownloadSelection.swift',
        'Sources/LocalStorage/SFTPUploadSelection.swift','Tests/LocalStorageTests/SFTPUploadProtocolTests.swift',
        'Tests/LocalStorageTests/SFTPDownloadProtocolTests.swift','Tests/LocalStorageTests/SFTPWorkerProtocolTests.swift',
        'Tests/LocalStorageTests/SFTPStoredProtocolTests.swift']
    inputs=[REPO/'Packages/ExplorerKit'/name for name in names]
    hashes={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in inputs}
    for index,path in enumerate(inputs):(source/(str(index)+'-'+path.name)).write_bytes(path.read_bytes())
    put(case/'inputs.json',dict(sourceSHA256=hashes,networkConnections=0,nativeFileSources=0,ordinaryUpload=False))
    failure=None
    log=None
    try:
        log=dev.test('SFTPUploadProtocolTests|SFTPDownloadProtocolTests|SFTPWorkerProtocolTests|SFTPStoredProtocolTests',args.configuration,serial=True)
        if not re.search(r'Executed 40 tests, with 0 failures',log.read_text())or'skipped'in log.read_text():
            raise RuntimeError('Native upload/legacy protocol controls not all exercised')
        if hashes!={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in inputs}:
            raise RuntimeError('Native upload protocol inputs changed')
    except BaseException as error:
        failure=type(error).__name__
    if log:(case/'evidence/native-tests.log').write_bytes(log.read_bytes())
    put(case/'result.json',dict(passed=failure is None,errorType=failure,testLog=str(log.relative_to(REPO))if log else None,packet=audit()))
    print(json.dumps(dict(case=case.name,passed=failure is None)),flush=True)
    if failure:raise SystemExit(1)

if __name__=='__main__':main()
