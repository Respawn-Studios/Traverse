#!/usr/bin/env python3
"""Actual pinned source/session controls; no owner archive or native app launch."""
import json,os,sys
from pathlib import Path
sys.dont_write_bytecode=True
from tar_packet import d,reserve,audit,run,directory,REPO
def main():
    fixture=d.ROOT/'76F09997-CBB1-48B9-A79A-F87CE95CC709'
    assert json.loads((fixture/'evidence/result.json').read_bytes())['passed']
    root=reserve('reader-controls')
    own=Path(__file__).parent
    files=[own/name for name in ['TARMetadata.swift','TARCatalog.swift','TARSourceCatalog.swift','TARArchiveReader.swift','TARArchiveSession.swift','ReaderControls.swift']]
    source=REPO/'Packages/ExplorerKit/Sources/LocalStorage/ZIPSourceFile.swift'
    errors=REPO/'Packages/ExplorerKit/Sources/LocalStorage/ZIPArchiveModels.swift'
    files += [source]
    # This is the exact production error enum, not a substitute source/parser.
    # The rest of ZIPArchiveModels contains the unrelated ZIP session graph.
    text=errors.read_text();start=text.index('public enum ZIPArchiveFailure:');end=text.index('\n}',start)+2
    enum_source=root/'source/ZIPArchiveFailure.swift';enum_source.write_text('import Foundation\n'+text[start:end]+'\n');files.append(enum_source)
    product=d.TOOLING/'derived/Build/Products/Debug';obj=product/'ExplorerCore.o'
    graph={str(path.relative_to(REPO)):d.digest(path)for path in files+[errors]};object_hash=d.digest(obj)
    d.put(root/'inputs.json',dict(fixtureCase=fixture.name,sources=graph,explorerCoreObjectSHA256=object_hash,
        generatedOnly=True,maximumCompilerRSSBytes=512<<20,maximumQueryRSSBytes=128<<20,maximumCaseBytes=64<<20))
    binary=root/'source/tar-reader-controls';report=dict(passed=False)
    try:
        compiled,_,_=run(['xcrun','swiftc','-O','-parse-as-library','-warnings-as-errors','-swift-version','6','-strict-concurrency=complete',
            '-module-cache-path',str(d.TOOLING/'swift'),'-I',str(product),*map(str,files),str(obj),'-o',str(binary)],root,'compile-tar-reader',timeout=120)
        report['compiler']=compiled
        if not compiled['passed']:raise RuntimeError('Actual TAR reader/session compile failed')
        archives=directory(root/'source/archives')
        (archives/'Mutable.tar').write_bytes((fixture/'source/archives/ustar.tar').read_bytes());(archives/'Mutable.tar').chmod(0o600)
        (archives/'Compressed.tar.gz').write_bytes(b'\x1f\x8b'+b'\0'*8)
        (root/'source/Linked.tar').symlink_to(archives/'Mutable.tar')
        process,out,_=run([str(binary),str(root),str(fixture)],root,'tar-reader-controls',timeout=60)
        value=json.loads(out.read_bytes())if out.stat().st_size else{}
        passed=process['passed']and process['peakRSSBytes']<=128<<20 and value.get('passed')and value.get('memberBodyReadBytes')==0 and value.get('activityCountAfter')==0
        if graph!={str(path.relative_to(REPO)):d.digest(path)for path in files+[errors]}or object_hash!=d.digest(obj):raise RuntimeError('Reader inputs changed')
        report.update(passed=bool(passed),process=process,controls=value,sources=graph,sourceUnchanged=True,usage=audit())
        if not passed:raise RuntimeError('Actual TAR reader/session controls failed')
        print(json.dumps(dict(case=root.name,passed=True,checks=len(value['checks']),memberBodyReadBytes=0)),flush=True)
    finally:d.put(root/'evidence/result.json',report)
if __name__=='__main__':main()
