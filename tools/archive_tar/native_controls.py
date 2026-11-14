#!/usr/bin/env python3
"""Source-bound native TAR routing, search, review, extraction and Undo."""
import argparse,hashlib,io,json,sys,tarfile
sys.dont_write_bytecode=True
from tar_packet import d,reserve,audit,run
from native_transfer import native_proof,unlocked
import runtime_diagnostics
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--native-case',required=True);parser.add_argument('--large',action='store_true');args=parser.parse_args()
    unlocked();proof=native_proof(args.native_case);root=reserve('native');path=root/'source/Review.tar'
    with tarfile.open(path,'w',format=tarfile.USTAR_FORMAT)as archive:
        for name,body in [('Folder/',None),('Folder/Empty/',None),('Folder/Member.txt',b'abc'),('Note.txt',b'note')]:
            member=tarfile.TarInfo(name);member.mode=0o755 if body is None else 0o644;member.mtime=0
            if body is None:member.type=tarfile.DIRTYPE;archive.addfile(member)
            else:member.size=len(body);archive.addfile(member,io.BytesIO(body))
    before=d.digest(path)
    d.put(root/'inputs.json',dict(nativeCase=args.native_case,nativeSources=proof['sourceSHA256'],generatedArchiveInputs=['source/Review.tar'],
        archiveSHA256=before,large=args.large,maximumNativeRSSBytes=256<<20,maximumCaseBytes=64<<20,networkRequests=0,keychainCalls=0))
    audit()
    process,_,_=run([str(d.APP/'Contents/MacOS/Mac Explorer'),'--verify-ui','--check-tar-archive',*(['--large-interface']if args.large else[])],root,'native-tar-archive',timeout=90,native=True)
    report_path=root/'evidence/native-tar-archive.json';value=json.loads(report_path.read_bytes())if report_path.is_file()else{}
    diagnostics=runtime_diagnostics.inspect(root/'evidence/native-tar-archive.stderr')
    passed=process['passed']and process['peakRSSBytes']<=256<<20 and value.get('passed')and value.get('activityAfter')==0 and len(value.get('clips',[]))==2 and diagnostics['passed']
    stable=before==d.digest(path)and proof['sourceSHA256']==d.native_sources();passed=bool(passed and stable and d.measure(root)['bytes']<=64<<20)
    d.put(root/'evidence/result.json',dict(passed=passed,process=process,native=value,sourceUnchanged=stable,runtimeDiagnostics=diagnostics,usage=audit()))
    print(json.dumps(dict(case=root.name,passed=passed,line=value.get('line'),checks=len(value.get('checks',[])))),flush=True)
    if not passed:raise RuntimeError('Native TAR integration check failed; evidence retained')
if __name__=='__main__':main()
