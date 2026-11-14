#!/usr/bin/env python3
"""Three generated native Trash process interruptions and independent inspection."""
import hashlib,json,os,stat,subprocess,sys,uuid
from pathlib import Path
sys.dont_write_bytecode=True
from dev import ROOT,environment

def resources():
    counts=dict(fixture_entries=0,source_bytes=0,history_bytes=0,tooling_bytes=0)
    for pattern,tooling in (('.build/test-fixtures/guarded-crash-*',False),('.build/guarded-trash-process-*',True)):
        for root in ROOT.glob(pattern):
            for directory,children,files in os.walk(root,followlinks=False):
                for path in [Path(directory),*(Path(directory)/n for n in files)]:
                    info=path.lstat()
                    if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                        raise ValueError('unexpected generated process fixture object')
                    if tooling:counts['tooling_bytes']+=info.st_size if stat.S_ISREG(info.st_mode) else 0
                    else:
                        counts['fixture_entries']+=1
                        key='history_bytes' if 'journal' in path.relative_to(root).parts else 'source_bytes'
                        counts[key]+=info.st_size if stat.S_ISREG(info.st_mode) else 0
                if any((Path(directory)/n).is_symlink() for n in children):
                    raise ValueError('generated process fixture symlink')
    limits=dict(fixture_entries=96,source_bytes=64<<10,history_bytes=2<<20,tooling_bytes=512<<20)
    if any(counts[k]>limits[k] for k in limits):raise ValueError('generated process qualification allowance')
    return dict(counts=counts,limits=limits)

def main():
    before_resources=resources()
    root=ROOT/'.build'/('guarded-trash-process-'+uuid.uuid4().hex);root.mkdir(mode=0o700)
    sources=sorted((ROOT/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift'))
    binary=root/'worker'; worker=ROOT/'tools/GuardedTrashProcessWorker.swift'
    sources.append(worker)
    frozen={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    report=dict(schema=1,passed=False,scope=__doc__,sources=frozen,cases=[],resources_before=before_resources,limits=['process interruption, not power loss','generated native Trash only','unrecorded native targets preserved, never adopted'])
    try:
        command=['xcrun','swiftc','-O','-swift-version','6','-warnings-as-errors','-parse-as-library','-j','2','-num-threads','2',
                 '-module-cache-path',str(root/'modules'),'-o',str(binary),*map(str,sources)]
        with (root/'build.log').open('xb') as log:subprocess.run(command,cwd=ROOT,env=environment(),stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
        if any(hashlib.sha256(p.read_bytes()).hexdigest()!=frozen[str(p.relative_to(ROOT))] for p in sources):raise ValueError('qualification sources changed')
        report['binary_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
        for boundary in ('intent','native','validated'):
            resources()
            fixture=ROOT/'.build/test-fixtures'/('guarded-crash-'+str(uuid.uuid4()))
            case=dict(boundary=boundary,fixture=str(fixture.relative_to(ROOT)));report['cases'].append(case)
            def call(phase,expected=0):
                child=subprocess.run([str(binary),phase,str(fixture),boundary],capture_output=True,text=True,env=environment(),timeout=30)
                case[phase]=dict(exit=child.returncode,stdout=child.stdout[-8192:],stderr=child.stderr[-8192:])
                if child.returncode!=expected:raise ValueError('generated '+boundary+'/'+phase+' did not reach its expected boundary')
                return json.loads(child.stdout) if child.stdout else None
            call('run',86)
            before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (fixture/'journal').iterdir() if p.is_file()}
            observation=call('inspect');case['inspection']=observation
            after={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (fixture/'journal').iterdir() if p.is_file()}
            if before!=after or observation['unfinished']!='1' or observation['sourcePresent']!=str(boundary=='intent').lower():raise ValueError('cold passive inspection/state mismatch')
            if observation['canUndo']!='false' or observation['canRecover']!=str(boundary=='validated').lower():raise ValueError('cold recovery availability mismatch')
            if boundary=='validated':
                restored=call('recover')
                if restored['pid']==observation['pid'] or restored['recordID']!=observation['recordID'] or restored['disposition']!='succeeded' or restored['sourcePresent']!='true':raise ValueError('independent explicit recovery did not restore the same record')
                if (fixture/'Selected.txt').read_bytes()!=b'Generated process interruption data':raise ValueError('generated restored bytes mismatch')
            elif boundary=='native':
                returned=Path((fixture/'native-returned.txt').read_text())
                if (fixture/'Selected.txt').exists() or not returned.is_file():raise ValueError('unknown native target not retained')
                case['unrecorded_target_preserved']=True
            else:
                if (fixture/'Selected.txt').read_bytes()!=b'Generated process interruption data':raise ValueError('untouched original bytes mismatch')
                case['unresolved_native_intent_preserved']=True
            case['passed']=True
        report['resources_after']=resources()
        report['passed']=True
    except Exception as error:report['failure']=type(error).__name__+':'+str(error)[:1500]
    (root/'receipt.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(passed=report['passed'],receipt=str((root/'receipt.json').relative_to(ROOT)),failure=report.get('failure'),cases=[dict(boundary=v['boundary'],passed=v.get('passed')) for v in report['cases']]),indent=2))
    return 0 if report['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
