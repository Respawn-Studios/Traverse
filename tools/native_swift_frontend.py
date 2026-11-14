#!/usr/bin/env python3
"""Per-command native qualification frontend; never part of a shipped app."""
import fcntl,json,os,stat,sys
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
FIXTURES={'UIVerification.swift','QueueWorkflowVerification.swift','RecoveryWorkflowVerification.swift',
    'WorkspaceNavigationVerification.swift','OpenAndShareVerification.swift','GroupedCopyResponsivenessVerification.swift',
    'IconsInteractionVerification.swift','SFTPFolderDownloadVerification.swift','RenameWorkflowVerification.swift','WorkspaceTransferVerification.swift'}

def rewrite(arguments,primary,*,repo=REPO,control_root=None):
    result=list(arguments)
    module=next((result[i+1]for i,value in enumerate(result[:-1])if value=='-module-name'),'')
    known={str(repo/'App/MacExplorer'/name)for name in FIXTURES}
    if control_root is not None:known={str(control_root/'source/FixtureDispatcher.swift')}
    matches=[name for name in primary if name in known]
    if not matches:return result,False
    definitions={result[i+1]for i,value in enumerate(result[:-1])if value=='-D'}|{value[2:]for value in result if value.startswith('-D')and len(value)>2}
    if len(primary)!=1 or module!=('NativeFrontendQualification'if control_root is not None else'Mac_Explorer')or'DEBUG'not in definitions or'-c'not in result:
        raise RuntimeError('Exact single debug fixture compilation required')
    result=[value for value in result if value not in ['-O','-Osize','-Ounchecked','-Onone']];result.append('-Onone')
    return result,True

def main():
    raw=os.environ.get('TRAVERSE_NATIVE_BUILD_ROOT')
    if not raw:raise RuntimeError('Explicit generated native build root required')
    root=Path(raw)
    if root.resolve()!=root or root.parent!=REPO/'.build/traverse-development' or root.stat().st_uid!=os.getuid():raise RuntimeError('Owned native build root required')
    marker=json.loads((root/'reservation.json').read_bytes());inputs=json.loads((root/'inputs.json').read_bytes());action=marker.get('action')
    control=action=='native-frontend-controls'
    if marker.get('packet')!='traverse-development-v1'or(not control and(action!='debug-build'or not inputs.get('optimizedQualification')or not inputs.get('boundedOptimization'))):
        raise RuntimeError('Explicit native qualification profile required')
    profile=inputs['frontendProfile'];compiler=Path(profile['compiler']);info=compiler.stat()
    if compiler.resolve()!=compiler or not stat.S_ISREG(info.st_mode)or[info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns]!=profile['compilerIdentity']:
        raise RuntimeError('Selected native compiler identity changed')
    arguments=sys.argv[1:];primary=[]
    for index,value in enumerate(arguments[:-1]):
        if value=='-primary-file':primary.append(arguments[index+1])
        if value=='-primary-filelist':
            source=Path(arguments[index+1])
            allowed=root if control else REPO/'.build/traverse-release/tooling/derived'
            if source.resolve()!=source or not source.is_relative_to(allowed)or source.stat().st_size>32768:raise RuntimeError('Owned bounded primary list required')
            primary+=source.read_text().splitlines()
    if '-c'in arguments and not primary and '-module-name'in arguments and arguments[arguments.index('-module-name')+1]in['Mac_Explorer','NativeFrontendQualification']:
        raise RuntimeError('Whole-module fixture optimization is not qualified')
    revised,overridden=rewrite(arguments,primary,control_root=root if control else None)
    event=dict(override=overridden,primaryCount=len(primary),source=Path(primary[0]).name if len(primary)==1 else None,
        optimization='Onone'if overridden else'unchanged',pid=os.getpid())
    path=root/'evidence/frontend-invocations.jsonl';fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX);payload=json.dumps(event,separators=(',',':')).encode()+b'\n'
        if os.fstat(fd).st_size+len(payload)>256<<10:raise RuntimeError('Bounded frontend evidence log')
        if os.write(fd,payload)!=len(payload):raise RuntimeError('Incomplete frontend evidence')
    finally:os.close(fd)
    os.execv(str(compiler),[str(compiler),*revised])
if __name__=='__main__':main()
