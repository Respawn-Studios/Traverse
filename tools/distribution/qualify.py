#!/usr/bin/env python3
"""One retained generated distribution-contract packet, not release validation."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode=True
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools'))
import dev
from foundation_packet import reserve,audit,directory,put,MIB

def main():
    case=reserve('distribution-contracts',amount=4*MIB,entries=256)
    directory(case/'source');directory(case/'evidence')
    env=dev.environment();env['MAC_EXPLORER_NOTICE_TEST_ROOT']=str(case/'source')
    with (case/'evidence/python.log').open('xb') as log:
        result=subprocess.run([sys.executable,'-B',str(REPO/'tools/distribution/test_notices.py')],cwd=REPO,env=env,
            stdout=log,stderr=subprocess.STDOUT,timeout=30)
    failure=None;before=set((dev.BUILD/'logs').glob('test-*.log'))
    if result.returncode:failure='Notice filesystem/parser controls failed'
    else:
        try:dev.test('SMBHelperManifestTests',serial=True)
        except Exception:failure='Runtime helper-channel contracts failed'
    logs=set((dev.BUILD/'logs').glob('test-*.log'))-before
    if len(logs)==1:
        log=logs.pop();shutil.copyfile(log,case/'evidence/swift.log')
        if not re.search(r'Executed 6 tests, with 0 failures',log.read_text()):failure='Expected six runtime identity tests did not execute'
    elif failure is None:failure='Exact runtime-channel test log missing'
    put(case/'result.json',dict(passed=failure is None,failure=failure,pythonActualExit=result.returncode,
        networkConnections=0,keychainQueries=0,actualProvisionedArtifact=False,after=audit()))
    print(json.dumps(dict(case=case.name,passed=failure is None,failure=failure)))
    if failure is not None:raise SystemExit(1)

if __name__=='__main__':main()
