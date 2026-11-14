#!/usr/bin/env python3
"""Ordinary native Help, actual generated Copy and diagnostic privacy/lifetime."""
import argparse,hashlib,json,subprocess,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from qualify_foundation import wait_generated
from distribution.traverse_packet import REPO,reserve,directory,put,audit,MIB

parser=argparse.ArgumentParser();parser.add_argument('--record-motion',action='store_true');args=parser.parse_args()
case=reserve('traverse-native-help-diagnostics')
directory(case/'source/Source');directory(case/'source/Destination');directory(case/'source/Destination2');directory(case/'state')
(case/'source/Source/Generated-private-name.txt').write_bytes(b'Generated diagnostic Copy control, not personal data.\n')
binary=dev.APP/'Contents/MacOS/Mac Explorer';digest=hashlib.sha256(binary.read_bytes()).hexdigest()
put(case/'inputs.json',dict(binarySHA256=digest,generatedOnly=True,realOSGrants=0,networkRequests=0,
    maximumSeconds=60,maximumCaseBytes=64*MIB,maximumCaseEntries=2048))
env=dev.environment(tooling=False)
env.update(MAC_EXPLORER_TEST_ROOT=str(case),MAC_EXPLORER_STATE_ROOT=str(case/'state'),MAC_EXPLORER_CACHE_ROOT=str(case/'cache'))
began=time.monotonic();log=case/'evidence/native.log'
with log.open('xb') as output:
 child=subprocess.Popen([str(binary),'--verify-ui','--check-help-diagnostics']+(['--record-help-motion']if args.record_motion else []),cwd=REPO,env=env,
     stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
 stats,failure,contained,forced=wait_generated(child,log,case/'evidence',deadline=60)
native=json.loads((case/'result.json').read_bytes())if(case/'result.json').is_file()else None
passed=child.returncode==0 and not contained and native is not None and native.get('passed')is True \
    and stats.ru_maxrss<=256*MIB and digest==hashlib.sha256(binary.read_bytes()).hexdigest()
put(case/'evidence/qualification.json',dict(passed=passed,native=native,actualExit=child.returncode,
    contained=contained,forced=forced,peakRSSBytes=stats.ru_maxrss,seconds=time.monotonic()-began,failure=failure,packet=audit()))
print(json.dumps(dict(case=case.name,passed=passed,native=native)),flush=True)
if not passed:raise SystemExit(1)
