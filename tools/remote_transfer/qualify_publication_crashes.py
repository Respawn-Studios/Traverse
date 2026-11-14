#!/usr/bin/env python3
"""Fresh-process received-file publication/Undo interruption and cold inspection."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
from qualification import REPO,MIB,reserve,audit,directory,put
sys.path.insert(0,str(REPO/'tools'))
import dev
def main():
    case=reserve('received-file-publication-crashes',size=16*MIB,entries=512);directory(case/'source')
    try:
        # Compile the separate child entry without exercising other FS fixtures.
        build_log=dev.test('SFTPDownloadProtocolTests',serial=True)
        binary=REPO/'.build/swift-tests/out/Products/Debug/LocalStorageTests.xctest/Contents/MacOS/LocalStorageTests'
        sources=[binary,REPO/'Packages/ExplorerKit/Tests/LocalStorageTests/ReceivedFileInterruptionProcessTests.swift',
            *sorted((REPO/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift')),
            REPO/'Packages/ExplorerKit/Sources/LocalStorage/RemoteDownloadStore.swift',REPO/'Packages/ExplorerKit/Sources/LocalStorage/DownloadedFilePublication.swift']
        hashes={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
        put(case/'inputs.json',dict(sourceSHA256=hashes,compileLog=str(build_log.relative_to(REPO)),networkConnections=0,personalFiles=0,keychainQueries=0))
        command=['/usr/bin/xcrun','swift','test','--package-path',str(REPO/'Packages/ExplorerKit'),'--configuration','debug',
            '--scratch-path',str(dev.local_directory('swift-tests')),'--cache-path',str(dev.local_directory('swift-cache')),
            '--config-path',str(dev.local_directory('swift-config')),'--security-path',str(dev.local_directory('swift-security')),
            '--swift-sdks-path',str(dev.local_directory('swift-sdks')),'--disable-keychain','--disable-netrc','--disable-dependency-cache',
            '--manifest-cache','local','--disable-automatic-resolution','--jobs','4','--skip-build','--no-parallel','--filter','ReceivedFileInterruptionProcessTests/child']
        results=[]
        for boundary in ['produced','rename','committed','reverse-before','reverse-rename']:
            env=dev.environment(tooling=True);env.update(MAC_EXPLORER_B12_PROCESS_ROOT=str(case),MAC_EXPLORER_B12_PROCESS_BOUNDARY=boundary)
            def invoke(action,crash=False):
                env['MAC_EXPLORER_B12_PROCESS_ACTION']=action;path=case/'evidence'/(boundary+'-'+action+'.log')
                with path.open('xb')as log:process=subprocess.run(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,timeout=45)
                events=[json.loads(line.split('MAC_EXPLORER_DOWNLOAD_CHILD ',1)[1])for line in path.read_text(errors='replace').splitlines()if'MAC_EXPLORER_DOWNLOAD_CHILD 'in line]
                if len(events)!=1 or (process.returncode==0)==crash or events[0].get('event')!=('crash'if crash else action):raise RuntimeError('Received-file child failed; preserve its exact log')
                return dict(event=events[0],actualLauncherExit=process.returncode)
            interrupted=invoke('reverse'if boundary.startswith('reverse-')else'forward',True)
            def snapshot():return{str(p.relative_to(case)):hashlib.sha256(p.read_bytes()).hexdigest()for p in(case/'source').rglob('*')if p.is_file()}
            before=snapshot();inspected=invoke('inspect');assert before==snapshot()
            root=case/'source'/('Process-'+boundary)
            shutil.copytree(root/'journal',case/'evidence'/(boundary+'-catalog-before-recovery'))
            recovered=invoke('recover');assert len({v['event']['pid']for v in [interrupted,inspected,recovered]})==3
            value=dict(boundary=boundary,passed=True,interrupted=interrupted,inspection=inspected,recovery=recovered)
            put(case/'evidence'/(boundary+'-result.json'),value);results.append(value);audit()
        assert hashes=={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in sources}
        put(case/'result.json',dict(passed=True,results=results,packet=audit()));print(json.dumps(dict(case=case.name,passed=True)),flush=True)
    except BaseException as error:put(case/'result.json',dict(passed=False,errorType=type(error).__name__,packet=audit()));raise
if __name__=='__main__':main()
