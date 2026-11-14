#!/usr/bin/env python3
"""Real upload-ledger process interruption and passive fresh-process checks."""
import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from upload_packet import REPO,reserve,directory,put,audit
sys.path.insert(0,str(REPO/'tools'))
import dev

def launch(command,env,case,label,expected_failure):
    path=case/'evidence'/(label+'.log');started=time.monotonic();contained=False
    with path.open('xb')as output:
        child=subprocess.Popen(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        while True:
            found,status,stats=os.wait4(child.pid,os.WNOHANG)
            if found:child.returncode=os.waitstatus_to_exitcode(status);break
            if time.monotonic()-started>45 or path.stat().st_size>1024*1024:
                contained=True;os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=3)
                break
            time.sleep(.03)
    put(case/'evidence'/(label+'.process.json'),dict(launcherPID=child.pid,launcherExit=child.returncode,contained=contained,elapsedSeconds=time.monotonic()-started))
    if contained or (child.returncode!=0)!=expected_failure:raise RuntimeError('Actual upload child outcome differs')
    return path
def image(root):
    return{p.name:dict(hash=hashlib.sha256(p.read_bytes()).hexdigest(),inode=p.stat().st_ino,size=p.stat().st_size,mode=p.stat().st_mode,mtime=p.stat().st_mtime_ns,ctime=p.stat().st_ctime_ns)for p in root.iterdir()}
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--integration',action='store_true');args=parser.parse_args()
    if args.integration:
        from upload_integration_packet import reserve as admission,audit as packet_audit
    else:admission,packet_audit=reserve,audit
    binary=REPO/'.build/swift-tests-release/out/Products/Release/LocalStorageTests.xctest/Contents/MacOS/LocalStorageTests'
    sources=[binary,*[REPO/'Packages/ExplorerKit'/p for p in ['Tests/LocalStorageTests/SFTPUploadCrashControlTests.swift','Sources/LocalStorage/SFTPUploadLedger.swift','Sources/LocalStorage/RemoteSettingsFile.swift']]]
    hashes={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
    command=['/usr/bin/xcrun','swift','test','--package-path',str(REPO/'Packages/ExplorerKit'),'--configuration','release',
        '--scratch-path',str(dev.local_directory('swift-tests-release')),'--cache-path',str(dev.local_directory('swift-cache')),
        '--config-path',str(dev.local_directory('swift-config')),'--security-path',str(dev.local_directory('swift-security')),
        '--swift-sdks-path',str(dev.local_directory('swift-sdks')),'--disable-keychain','--disable-netrc','--disable-dependency-cache',
        '--manifest-cache','local','--disable-automatic-resolution','--jobs','4','--skip-build','--no-parallel','--filter']
    results=[]
    for mode in ['prepared-stage','prepared-rename','publication-stage','publication-rename']:
        case=admission('upload-crash-'+mode,size=8*1024*1024,entries=256);source=directory(case/'source')
        put(case/'inputs.json',dict(sourceSHA256=hashes,mode=mode,networkConnections=0,personalFiles=0,keychainQueries=0))
        try:
            env=dev.environment();env.update(MAC_EXPLORER_B12_UPLOAD_SOURCE=str(source),MAC_EXPLORER_B12_UPLOAD_CRASH=mode)
            launch(command+['SFTPUploadCrashControlTests/testCrashBoundary'],env,case,'actual-crash',True)
            boundary=source/'crash-control/actual-crash-boundary.txt';proof=boundary.read_text()
            if proof!=mode+':'+('2'if mode.startswith('publication-')else'1')+':'+('stagingSynchronized'if mode.endswith('stage')else'renamed')+'\n':raise RuntimeError('Actual durable boundary not reached')
            history=source/'crash-control/upload-history';before=image(history)
            log=launch(command+['SFTPUploadCrashControlTests/testColdInspection'],env,case,'passive-cold-inspection',False)
            if not re.search(r'Executed 1 test, with 0 failures',log.read_text())or'skipped'in log.read_text():raise RuntimeError('Cold inspection not exercised')
            if image(history)!=before:raise RuntimeError('Passive upload inspection changed evidence')
            if hashes!={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}:raise RuntimeError('Upload crash inputs changed')
            value=dict(passed=True,mode=mode,actualBoundary=proof.strip(),passiveBytesAndMetadataUnchanged=True,ordinaryUpload=False,packet=packet_audit())
            put(case/'result.json',value);results.append(dict(case=case.name,mode=mode,passed=True));print(json.dumps(results[-1]),flush=True)
        except BaseException as error:put(case/'result.json',dict(passed=False,errorType=type(error).__name__,packet=packet_audit()));raise
    print(json.dumps(dict(passed=True,realChildInterruptions=4,results=results)),flush=True)
if __name__=='__main__':main()
