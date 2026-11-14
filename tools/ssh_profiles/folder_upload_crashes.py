#!/usr/bin/env python3
"""Twelve actual H process exits, independent passive cold readers, no network."""
import json,sys
sys.dont_write_bytecode=True
from packet import prepare,directory,d,run,audit,REPO,TOOLING

PHASES=['prepared','publication','root','progress','final','upgrade']
MODES={phase+'-'+boundary:81+index*2+offset for index,phase in enumerate(PHASES)for offset,boundary in enumerate(['stage','rename'])}
def image(root):return {str(p.relative_to(root)):[d.digest(p),p.stat().st_size,p.stat().st_ino,p.stat().st_mtime_ns,p.stat().st_ctime_ns]for p in root.rglob('*')if p.is_file()}
def main():
    prepare();root=d.reserve('folder-upload-crashes');original=REPO/'Packages/ExplorerKit';package=directory(root/'source/package')
    inputs=[p for module in['ExplorerCore','FileOperations','LocalStorage','SSHConfiguration']for p in(original/'Sources'/module).rglob('*.swift')]
    inputs += [original/'Tests/LocalStorageTests'/name for name in ['SFTPFolderUploadTests.swift','SFTPFolderUploadFixtures.swift','SFTPFolderUploadCrashTests.swift']];hashes={}
    for source in inputs:
        target=package/source.relative_to(original);directory(target.parent);target.write_bytes(source.read_bytes());hashes[str(source.relative_to(REPO))]=d.digest(source)
    (package/'Package.swift').write_text('// swift-tools-version:6.0\nimport PackageDescription\nlet package=Package(name:"TraverseFolderUploadCrashContracts",platforms:[.macOS(.v15)],targets:[.target(name:"ExplorerCore"),.target(name:"FileOperations"),.target(name:"SSHConfiguration"),.target(name:"LocalStorage",dependencies:["ExplorerCore","FileOperations","SSHConfiguration"]),.testTarget(name:"LocalStorageTests",dependencies:["LocalStorage","FileOperations"])])\n')
    directory(root/'source/UploadFixtures');scratch=directory(TOOLING/'native-contracts')
    d.put(root/'inputs.json',dict(sources=hashes,boundaries=MODES,networkRequests=0,keychainCalls=0,personalRoots=0))
    flags=['--configuration','debug','--build-system','native','--disable-index-store','--package-path',str(package),'--scratch-path',str(scratch),
        '--cache-path',str(root/'cache/swift'),'--config-path',str(root/'cache/config'),'--security-path',str(root/'cache/security'),'--swift-sdks-path',str(root/'cache/sdks'),
        '--disable-keychain','--disable-netrc','--disable-dependency-cache','--manifest-cache','local','--disable-automatic-resolution','--jobs','4',
        '-Xswiftc','-warnings-as-errors','-Xswiftc','-module-cache-path','-Xswiftc',str(TOOLING/'swift')]
    built,_,_=run(['xcrun','swift','build','--build-tests',*flags],root,'build-crash-children',timeout=300)
    if not built['passed']:raise RuntimeError('H crash child build failed')
    bundle=scratch/'arm64-apple-macosx/debug/TraverseFolderUploadCrashContractsPackageTests.xctest';binary=bundle/'Contents/MacOS/TraverseFolderUploadCrashContractsPackageTests'
    binary_hash=d.digest(binary);results=[]
    for mode,expected in MODES.items():
        def invoke(name):return run(['/usr/bin/env','TRAVERSE_FOLDER_UPLOAD_CRASH='+mode,'xcrun','xctest','-XCTest','LocalStorageTests.SFTPFolderUploadCrashTests/'+name,str(bundle)],root,mode+'-'+name,timeout=30)
        interrupted,_,_=invoke('testActualCrashBoundary');folder=root/'source/UploadFixtures'/('h-crash-'+mode)
        if interrupted['actualExit']!=expected or interrupted['contained']or not(folder/'actual-crash-boundary.txt').is_file():raise RuntimeError('Actual H crash boundary not reached')
        before=image(folder);cold,_,_=invoke('testPassiveColdInspection')
        if not cold['passed']or before!=image(folder):raise RuntimeError('Cold H inspection failed or wrote retained state')
        results.append(dict(mode=mode,actualExit=expected,interrupted=interrupted,cold=cold,passiveBytesAndIdentityUnchanged=True))
    unchanged=hashes=={p:d.digest(REPO/p)for p in hashes}and binary_hash==d.digest(binary)
    d.put(root/'evidence/result.json',dict(passed=unchanged,boundaries=results,sourceUnchanged=unchanged,networkRequests=0,usage=audit()))
    print(json.dumps(dict(case=root.name,passed=unchanged,actualCrashBoundaries=len(results))),flush=True)
    if not unchanged:raise SystemExit(1)
if __name__=='__main__':main()
