#!/usr/bin/env python3
"""Real native-module TAR production, cold Undo, faults and isolated crashes."""
import argparse,hashlib,json,os,stat,sys,tarfile,zipfile
from pathlib import Path
sys.dont_write_bytecode=True
from tar_packet import d,reserve,audit,run,directory,REPO
from native_transfer import native_proof

def retained_tree(path):
    result={}
    for parent,dirs,files in os.walk(path,followlinks=False):
        for name in dirs+files:
            p=Path(parent)/name;s=p.lstat()
            if p.is_symlink()or s.st_uid!=os.getuid()or not(stat.S_ISDIR(s.st_mode)or stat.S_ISREG(s.st_mode)):raise RuntimeError('Generated output namespace differs')
            if stat.S_ISREG(s.st_mode):
                if s.st_nlink!=1:raise RuntimeError('Generated output alias')
                result[str(p.relative_to(path))]=hashlib.sha256(p.read_bytes()).hexdigest()
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--native-case',required=True);args=parser.parse_args();proof=native_proof(args.native_case)
    fixture=d.ROOT/'76F09997-CBB1-48B9-A79A-F87CE95CC709';source=fixture/'source/archives/ustar.tar';frozen=d.digest(source)
    root=reserve('extraction-controls');control=Path(__file__).with_name('ExtractionControls.swift');product=d.TOOLING/'derived/Build/Products/Debug'
    objects=[product/(name+'.o')for name in ['ExplorerCore','FileOperations','LocalStorage','SSHConfiguration']]
    hashes={str(p.relative_to(REPO)):d.digest(p)for p in objects}
    graph={str(p.relative_to(REPO)):d.digest(p)for p in [control,*sorted((REPO/'Packages/ExplorerKit/Sources/LocalStorage').glob('TAR*.swift')),
        REPO/'Packages/ExplorerKit/Sources/LocalStorage/ArchiveProducedFacts.swift',REPO/'Packages/ExplorerKit/Sources/LocalStorage/ZIPSourceFile.swift',
        REPO/'Packages/ExplorerKit/Sources/LocalStorage/ZIPSourceSecurity.swift',REPO/'Packages/ExplorerKit/Sources/FileOperations/ArchiveProduction.swift']}
    d.put(root/'inputs.json',dict(nativeCase=args.native_case,sourceSHA256=graph,objectSHA256=hashes,fixtureCase=fixture.name,fixtureSHA256=frozen,
        generatedOnly=True,maximumCompilerRSSBytes=512<<20,maximumRuntimeRSSBytes=128<<20,maximumCaseBytes=64<<20,plannedCrashChildren=2))
    binary=root/'source/tar-extraction-controls';report=dict(passed=False)
    try:
        compiled,_,_=run(['xcrun','swiftc','-O','-parse-as-library','-warnings-as-errors','-swift-version','6','-strict-concurrency=complete',
            '-module-cache-path',str(d.TOOLING/'swift'),'-I',str(product),str(control),*map(str,objects),'-lsqlite3','-o',str(binary)],root,'compile-tar-production',timeout=120)
        report['compiler']=compiled
        if not compiled['passed']:raise RuntimeError('Actual native-module TAR production controls did not compile')
        archives=directory(root/'source/archives');(archives/'Mutable.tar').write_bytes(source.read_bytes());(archives/'Mutable.tar').chmod(0o600)
        with zipfile.ZipFile(archives/'Generated.zip','w',compression=zipfile.ZIP_STORED)as archive:
            archive.writestr('Folder/Member.txt',b'generated zip regression');archive.writestr('Folder/Empty/',b'');archive.writestr('Other.txt',b'keep other zip')
        process,out,_=run([str(binary),str(root),str(fixture),'all'],root,'actual-tar-production',timeout=90)
        value=json.loads(out.read_bytes())if out.stat().st_size else{}
        if not process['passed']or process['peakRSSBytes']>128<<20 or not value.get('passed')or value.get('activityAfter')!=0:raise RuntimeError('Actual TAR production controls failed')
        expected={}
        with tarfile.open(source,'r:')as archive:
            for entry in archive:
                if entry.isfile():expected[entry.name]=hashlib.sha256(archive.extractfile(entry).read()).hexdigest()
        independent=[]
        for row in value['outputs']:
            wanted={p:h for p,h in expected.items()if row['case']=='Whole'or p=='Folder/Member.bin'}
            relative=Path(row['retainedPayload']);path=root/relative
            if relative.is_absolute()or'..'in relative.parts or path.resolve()!=path or not path.is_relative_to(root/'source'):raise RuntimeError('Generated retained-output reference refused')
            actual=retained_tree(path)
            if row['hashes']!=wanted or actual!=wanted:raise RuntimeError('Independent TAR bytes differ')
            independent.append(dict(case=row['case'],files=len(actual),exactPythonTarfileHashes=True))
        zip_process,zip_out,_=run([str(binary),str(root),str(fixture),'zip-regressions'],root,'existing-zip-regressions',timeout=45)
        zip_value=json.loads(zip_out.read_bytes())if zip_out.stat().st_size else{}
        if not zip_process['passed']or not zip_value.get('passed'):raise RuntimeError('Existing ZIP extraction regression')
        crashes=[]
        for mode in ['crash-synced','crash-committed']:
            child,_,_=run([str(binary),str(root),str(fixture),mode],root,mode,timeout=30)
            if child['actualExit']!=77 or child['contained']or child['forced']or child['peakRSSBytes']>128<<20:raise RuntimeError('Actual planned producer crash was not reached/reaped')
            crashes.append(dict(mode=mode,expectedExit=77,process=child))
        cold,cold_out,_=run([str(binary),str(root),str(fixture),'cold-crashes'],root,'cold-tar-crash-inspection',timeout=45)
        cold_value=json.loads(cold_out.read_bytes())if cold_out.stat().st_size else{}
        if not cold['passed']or not cold_value.get('passed'):raise RuntimeError('Cold TAR crash inspection/Undo failed')
        if graph!={p:d.digest(REPO/p)for p in graph}or hashes!={p:d.digest(REPO/p)for p in hashes}or d.digest(source)!=frozen or proof['sourceSHA256']!=d.native_sources():raise RuntimeError('Current native/fixture inputs changed')
        report.update(passed=True,process=process,controls=value,independent=independent,zipProcess=zip_process,zipControls=zip_value,
            plannedCrashes=crashes,coldProcess=cold,coldControls=cold_value,sourceUnchanged=True,usage=audit())
        if d.measure(root)['bytes']>64<<20:raise RuntimeError('TAR production case ceiling')
        print(json.dumps(dict(case=root.name,passed=True,groups=len(value['checks'])+len(zip_value['checks'])+len(cold_value['checks']),plannedCrashChildren=2)),flush=True)
    finally:d.put(root/'evidence/result.json',report)
if __name__=='__main__':main()
