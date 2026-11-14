#!/usr/bin/env python3
"""Focused search semantics with retained, exactly marked generated fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,reserve,put,audit,measure,MIB


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--configuration',choices=['debug','release'],default='debug');args=parser.parse_args()
    root=reserve('traverse-search-focused')
    sources=list((REPO/'Packages/ExplorerKit/Sources/Search').glob('*.swift'))+list((REPO/'Packages/ExplorerKit/Tests/SearchTests').glob('*.swift'))
    hashes={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
    put(root/'inputs.json',dict(sourceSHA256=hashes,maximumCaseBytes=8*MIB,maximumCaseEntries=1024,maximumSourceBytes=MIB,
        generatedOnly=True,personalFiles=0,sourceFixturesRetained=True,configuration=args.configuration))
    previous=os.environ.get('MAC_EXPLORER_SEARCH_FIXTURE_ROOT');os.environ['MAC_EXPLORER_SEARCH_FIXTURE_ROOT']=str(root/'source')
    failure=None;log=None
    try:
        log=dev.test('SearchTests',args.configuration,serial=True)
        text=log.read_text()
        reports=re.findall(r'Test run with (\d+) tests? in [^\n]* passed',text)
        if sum(map(int,reports))!=24 or 'skipped' in text:raise RuntimeError('All focused search controls must run')
    except BaseException as error:failure=type(error).__name__
    finally:
        if previous is None:os.environ.pop('MAC_EXPLORER_SEARCH_FIXTURE_ROOT',None)
        else:os.environ['MAC_EXPLORER_SEARCH_FIXTURE_ROOT']=previous
    usage=measure(root);source=measure(root/'source')
    passed=failure is None and usage['bytes']<=8*MIB and usage['entries']<=1024 and source['bytes']<=MIB \
        and hashes=={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
    put(root/'result.json',dict(passed=passed,error=failure,caseUsage=usage,sourceUsage=source,testLog=str(log.relative_to(REPO))if log else None,packet=audit()))
    print(json.dumps(dict(case=root.name,passed=passed,error=failure)),flush=True)
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
