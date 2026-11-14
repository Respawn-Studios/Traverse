#!/usr/bin/env python3
"""Focused generated security controls within the existing extraction packet."""
import argparse
import json
import os
import shutil
import sys
sys.dont_write_bytecode=True
import dev
from verify_zip_extraction import admit,usage,MIB

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--configuration',choices=['debug','release'],default='debug');args=parser.parse_args()
    case=admit(size=64*MIB,entries=1024,payload=2*MIB)
    os.environ['MAC_EXPLORER_ZIP_EXTRACTION_TEST_ROOT']=str(case/'source')
    before=set((dev.BUILD/'logs').glob('test-*.log'))
    try:
        dev.test('ZIPExtractionSecurityTests|ZIPExtractionTests',args.configuration,serial=True)
        passed=True
    except Exception:
        passed=False
    logs=set((dev.BUILD/'logs').glob('test-*.log'))-before
    if len(logs)!=1:raise RuntimeError('Exact security test log missing')
    log=logs.pop();shutil.copyfile(log,case/'evidence/tests.log')
    result=dict(passed=passed,configuration=args.configuration,log=str(log.relative_to(dev.ROOT)),
        sourceFiles='generated only',quarantineRemovedFromSource=False,gatekeeperExecutionExercised=False,after=usage())
    with (case/'evidence/security-result.json').open('x') as output:json.dump(result,output,sort_keys=True,indent=2)
    print(json.dumps(dict(case=case.name,passed=passed)))
    if not passed:raise SystemExit(1)

if __name__=='__main__':main()
