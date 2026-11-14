#!/usr/bin/env python3
"""Charged, metadata-only private-server tests. No network or real Keychain."""
import argparse
import json
import os
import re
import sys
from pathlib import Path
from browser_packet import reserve, audit
from packet import REPO, TOOLING, TOOLING_LIMIT, MIB, directory, digest, put, usage
sys.path.insert(0, str(REPO/'tools'))
import dev


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--configuration', choices=['debug','release'], default='debug')
    parser.add_argument('--integrated',action='store_true')
    args=parser.parse_args()
    case=reserve('saved-server-store-'+args.configuration, amount=MIB, entries=384)
    root=directory(case/'source')
    sources=sorted((REPO/'Packages/ExplorerKit/Sources/LocalStorage').glob('SMB*Server*.swift'))
    sources += [REPO/'Packages/ExplorerKit/Sources/LocalStorage'/name for name in ['RemoteSettingsFile.swift','SMBPasswordVault.swift','SMBWorkerProtocol.swift','RemoteNetworkAuthority.swift','SMBConnectionAddress.swift']]
    sources += [REPO/'Packages/ExplorerKit/Tests/LocalStorageTests/SMBSavedServerStoreTests.swift']
    put(case/'inputs.json',dict(configuration=args.configuration,
        sourceSHA256={str(p.relative_to(REPO)):digest(p) for p in sources},
        networkConnections=0,keychainAccesses=0,personalCatalogs=0))
    os.environ['MAC_EXPLORER_B10_SERVER_STORE_ROOT']=str(root)
    failure=None;log=None;before_logs=set((REPO/'.build/logs').glob('test-*.log'))
    try:
        selected='SMBSavedServerStoreTests|SMBServerRememberingTests'
        if args.integrated:selected+='|SMBConnectionAddressTests|SMBPagedDirectoryProtocolTests|SMBGeneratedCatalogSessionTests|SMBResolverProtocolTests|SMBHostnameResolverTests|SMBWorkerProtocolTests|SMBPasswordVaultTests'
        dev.test(selected,configuration=args.configuration,serial=True)
        fresh=set((REPO/'.build/logs').glob('test-*.log'))-before_logs
        if len(fresh)!=1:raise RuntimeError('Exact saved-server test log missing')
        log=fresh.pop()
        expected=48 if args.integrated else 14
        if log.stat().st_size>MIB or not re.search(r'Executed '+str(expected)+r' tests, with 0 failures',log.read_text()) or 'skipped' in log.read_text():
            raise RuntimeError('Saved-server test count or actual fixture execution differs')
    except Exception as error:failure=str(error)[:400]
    finally:os.environ.pop('MAC_EXPLORER_B10_SERVER_STORE_ROOT',None)
    after=None
    try:after=audit()
    except Exception as error:failure=failure or 'Evidence audit: '+str(error)[:300]
    result=dict(passed=failure is None,actualExit=0 if failure is None else None,failure=failure,after=after,tooling=usage(TOOLING,TOOLING_LIMIT),testLog=str(log.relative_to(REPO)) if log else None)
    put(case/'result.json',result);print(json.dumps(dict(case=case.name,**result)),flush=True)
    if failure:raise SystemExit(1)


if __name__=='__main__':main()
