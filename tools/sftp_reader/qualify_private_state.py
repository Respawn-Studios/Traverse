#!/usr/bin/env python3
"""Charged SFTP metadata/fake-Keychain and affected SMB regression controls."""
import argparse
import hashlib
import json
import os
import re
import sys
sys.dont_write_bytecode = True
from packet import REPO, MIB, directory, put
from native_packet import reserve, audit
sys.path.insert(0, str(REPO/'tools'))
import dev

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    case = reserve('private-state-'+args.configuration, size=16*MIB, entries=512)
    root = directory(case/'source')
    local = REPO/'Packages/ExplorerKit/Sources/LocalStorage'
    sources = sorted(local.glob('SFTP*swift')) + [local/name for name in ['RemoteSettingsFile.swift', 'SMBServerFile.swift', 'SMBSavedServerModels.swift', 'SMBSavedServerStore.swift', 'SMBPasswordVault.swift']]
    sources += [REPO/'Packages/ExplorerKit/Tests/LocalStorageTests'/name for name in ['SFTPPrivateStateTests.swift', 'SMBSavedServerStoreTests.swift', 'SMBPasswordVaultTests.swift']]
    put(case/'inputs.json', dict(configuration=args.configuration, sourceSHA256={str(p.relative_to(REPO)): digest(p) for p in sources},
        networkConnections=0, keychainAccesses=0, personalCatalogs=0, backend='Injected exact generated claims'))
    selected = 'SFTPPrivateStateTests|SMBPasswordVaultTests|SMBConnectionAddressTests|SMBServerRememberingTests'
    selected += '|SMBSavedServerStoreTests.test(Passive|ServerAnd|PasswordOnly|CredentialCannot|ForgetHides|ServerForget|SecondOwner|StagingFailure|LateCancellation)'
    os.environ['MAC_EXPLORER_B11_PRIVATE_STATE_ROOT'] = str(root)
    os.environ['MAC_EXPLORER_B10_SERVER_STORE_ROOT'] = str(root)
    before = set((REPO/'.build/logs').glob('test-*.log'))
    error = None; log = None; count = None
    try:
        dev.test(selected, configuration=args.configuration, serial=True)
        fresh = set((REPO/'.build/logs').glob('test-*.log'))-before
        if len(fresh) != 1: raise RuntimeError('Exact private-state log missing')
        log = fresh.pop(); text = log.read_text()
        found = re.findall(r'Executed (\d+) tests, with 0 failures', text)
        count = max(map(int, found), default=0)
        if count != 36 or 'skipped' in text or log.stat().st_size > MIB: raise RuntimeError('Private-state execution/count bound')
        if {str(p.relative_to(REPO)): digest(p) for p in sources} != json.loads((case/'inputs.json').read_bytes())['sourceSHA256']:
            raise RuntimeError('Private-state inputs changed')
    except BaseException as caught: error = type(caught).__name__
    finally:
        for name in ['MAC_EXPLORER_B11_PRIVATE_STATE_ROOT', 'MAC_EXPLORER_B10_SERVER_STORE_ROOT']: os.environ.pop(name, None)
    result = dict(passed=error is None, errorType=error, tests=count, testLog=str(log.relative_to(REPO)) if log else None, packet=audit())
    put(case/'result.json', result)
    print(json.dumps(dict(case=case.name, **result)), flush=True)
    if error: raise SystemExit(1)


if __name__ == '__main__': main()
