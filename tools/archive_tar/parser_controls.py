#!/usr/bin/env python3
"""Compile exact parser snapshots; compare generated independent TAR metadata."""
import argparse,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
from tar_packet import d,reserve,audit,run,REPO
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--fixture-case',required=True,nargs='+');args=parser.parse_args()
    import uuid
    fixtures=[]
    for value in args.fixture_case:
        if str(uuid.UUID(value)).upper()!=value:raise RuntimeError('Exact generated fixture UUID required')
        fixture=d.ROOT/value;proof=json.loads((fixture/'evidence/result.json').read_bytes())
        if not proof.get('passed')or json.loads((fixture/'reservation.json').read_bytes()).get('action')!='plain-tar-fixtures':raise RuntimeError('Frozen generated fixtures required')
        fixtures.append(fixture)
    root=reserve('parser-controls');paths=[Path(__file__).with_name(name)for name in ['TARMetadata.swift','TARCatalog.swift','ParserControls.swift']]+[REPO/'Packages/ExplorerKit/Sources/ExplorerCore/FilenameMatching.swift']
    graph={str(p.relative_to(REPO)):d.digest(p)for p in paths};files=[]
    for path in paths:
        # ParserControls keeps its real source path for its fixed repo authority.
        copy=root/'source'/path.name;copy.write_bytes(path.read_bytes());files.append(path)
    fixture_hashes={fixture.name:d.digest(fixture/'inputs.json')for fixture in fixtures}
    d.put(root/'inputs.json',dict(fixtureCases=args.fixture_case,fixtureManifestSHA256=fixture_hashes,sources=graph,swiftLanguage=6,driverSHA256=d.digest(Path(__file__)),
        pureParserOnly=True,maximumCaseBytes=128<<20,maximumCompilerRSSBytes=512<<20,maximumQueryRSSBytes=128<<20))
    binary=root/'source/tar-parser-controls'
    compiled,_,_=run(['xcrun','swiftc','-O','-parse-as-library','-warnings-as-errors','-swift-version','6','-strict-concurrency=complete','-D','TAR_PARSER_STANDALONE',
        '-module-cache-path',str(d.TOOLING/'swift'),*map(str,files),'-o',str(binary)],root,'compile-tar-parser',timeout=120)
    report=dict(passed=False,compiled=compiled)
    try:
        if not compiled['passed']:raise RuntimeError('Plain TAR parser compile failed')
        controls=[]
        for index,fixture in enumerate(fixtures):
            process,out,_=run([str(binary),str(fixture)],root,'tar-parser-controls-'+str(index+1),timeout=45)
            native=json.loads(out.read_bytes())if out.stat().st_size else{}
            passed=bool(process['passed']and process['peakRSSBytes']<=128<<20 and native.get('passed')and native.get('memberBodyReadBytes')==0 and native.get('fileWrites')==0)
            controls.append(dict(fixtureCase=fixture.name,passed=passed,process=process,controls=native))
        passed=all(row['passed']for row in controls)and graph=={str(p.relative_to(REPO)):d.digest(p)for p in paths}and fixture_hashes=={fixture.name:d.digest(fixture/'inputs.json')for fixture in fixtures}
        report.update(passed=passed,controls=controls,sources=graph,fixtureUnchanged=True,usage=audit())
        if not passed:raise RuntimeError('Plain TAR metadata controls failed')
        print(json.dumps(dict(case=root.name,passed=True,checks=sum(row['controls']['checks']for row in controls),memberBodyReadBytes=0)),flush=True)
    finally:d.put(root/'evidence/result.json',report)
if __name__=='__main__':main()
