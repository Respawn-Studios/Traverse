#!/usr/bin/env python3
"""Deterministic notices from the pinned offline graph; no source downloads."""
from __future__ import annotations
import argparse
import hashlib
from html.parser import HTMLParser
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode=True
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools'))
from distribution.artifact_files import read
from smb_reader.packet import TOOLCHAIN,TOOLING,environment
from smb_reader.vendor_verified_source import verify

TARGETS=('aarch64-apple-darwin','x86_64-apple-darwin')
LOCK=REPO/'tools/smb_reader/smb2-browser/Cargo.lock'
OUTPUT=REPO/'Distribution'
ALLOWED={'MIT','MIT OR Apache-2.0','Apache-2.0 OR MIT','Unlicense OR MIT',
         'BSD-3-Clause OR MIT OR Apache-2.0','(MIT OR Apache-2.0) AND Unicode-3.0',
         'BSD-3-Clause','MIT/Apache-2.0','Apache-2.0 AND ISC','Apache-2.0','ISC'}
HEADER='Third-Party Software Notices\n\nSoftware components and their license terms\n'
NESTED_NOTICE_PATHS={
    ('ring','0.17.14'):(
        'src/polyfill/once_cell/LICENSE-APACHE',
        'src/polyfill/once_cell/LICENSE-MIT',
        'third_party/fiat/LICENSE',
    ),
}

def sha(data):return hashlib.sha256(data).hexdigest()

def lock_checksums(data):
    """Read only Cargo's generated scalar fields; refuse ambiguous identities.

    This is not a general TOML parser and never rewrites the lock. Cargo itself
    validates the complete locked/offline graph immediately afterwards.
    """
    result={}
    for section in data.decode('utf-8').split('[[package]]')[1:]:
        fields={}
        for line in section.splitlines():
            if re.match(r'^(name|version|checksum)\s*=',line):
                match=re.fullmatch(r'(name|version|checksum) = ("[^"\\]*")',line)
                if match is None or match[1] in fields:raise RuntimeError('Unsupported generated lock identity')
                fields[match[1]]=json.loads(match[2])
        key=(fields.get('name'),fields.get('version'))
        if None in key or key in result:raise RuntimeError('Ambiguous generated lock identity')
        checksum=fields.get('checksum')
        if checksum is not None and not re.fullmatch('[a-f0-9]{64}',checksum):raise RuntimeError('Invalid locked package checksum')
        result[key]=checksum
    if not result:raise RuntimeError('Missing generated lock packages')
    return result

class PlainLegalText(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.parts=[];self.hidden=0
    def handle_starttag(self,tag,attrs):
        if tag in ['script','style']:self.hidden+=1
        elif tag in ['p','pre','li','h1','h2','h3','h4','br','hr','div']:self.parts.append('\n')
    def handle_endtag(self,tag):
        if tag in ['script','style']:self.hidden=max(0,self.hidden-1)
        elif tag in ['p','pre','li','h1','h2','h3','h4','div']:self.parts.append('\n')
    def handle_data(self,data):
        if not self.hidden:self.parts.append(data)

def notice_paths(directory,package):
    """Keep reviewed nested legal inputs bound to an exact published version."""
    key=(package['name'],package['version'])
    if package['name']=='ring' and key not in NESTED_NOTICE_PATHS:
        raise RuntimeError('New ring version needs nested notice review')
    paths=[Path(path.name) for path in directory.iterdir()
           if path.is_file() and path.name.upper().startswith(('LICENSE','COPYING','NOTICE','COPYRIGHT'))]
    for name in NESTED_NOTICE_PATHS.get(key,()):
        relative=Path(name)
        if not (directory/relative).is_file():raise RuntimeError('Required nested notice missing: '+name)
        paths.append(relative)
    if len(paths)!=len(set(paths)):raise RuntimeError('Duplicate dependency notice path')
    return sorted(paths)

def registry_notices(directory,package,locked,tooling=TOOLING):
    # New Cargo caches need not contain a .cargo-checksum.json. Bind the
    # published compressed archive to Cargo.lock, then compare only its plain
    # manifest/notice members. Nothing is extracted or executed.
    name=package['name']+'-'+package['version']
    registry=tooling/'cargo-home/registry'
    index=directory.parent.name
    archive=read(registry/'cache'/index/(name+'.crate'),16<<20)
    expected=locked.get((package['name'],package['version']))
    if expected is None or sha(archive)!=expected:raise RuntimeError('Published archive checksum differs from lock')
    wanted={p.as_posix() for p in notice_paths(directory,package)}
    wanted.add('Cargo.toml');found={};total=0;count=0
    if (directory/'.cargo_vcs_info.json').is_file():wanted.add('.cargo_vcs_info.json')
    with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz') as stream:
        for item in stream:
            count+=1;total+=max(0,item.size)
            if count>8192 or total>64<<20:raise RuntimeError('Published dependency archive bounds')
            prefix=name+'/'
            relative=item.name[len(prefix):] if item.name.startswith(prefix) else None
            if relative not in wanted:continue
            if relative in found or not item.isfile() or item.sparse or not 0<item.size<=65536:
                raise RuntimeError('Unsafe or ambiguous published notice')
            source=stream.extractfile(item)
            if source is None:raise RuntimeError('Published notice unavailable')
            data=source.read(65537)
            if len(data)!=item.size or data!=read(directory/relative,65536):raise RuntimeError('Local dependency notice/manifest differs from published archive')
            found[relative]=sha(data)
    if set(found)!=wanted:raise RuntimeError('Published dependency notices missing')
    return found

def supplemental_notices(directory,package,locked,checks):
    root=OUTPUT/'LicenseSupplements';index=json.loads(read(root/'index.json',65536))
    rows=[value for value in index['entries'] if (value['name'],value['version'])==(package['name'],package['version'])]
    if index.get('version')!=1 or len(rows)!=1:raise RuntimeError('Missing exact license supplement')
    record=rows[0];vcs=read(directory/'.cargo_vcs_info.json',4096)
    if record['archiveSHA256']!=locked.get((package['name'],package['version'])) or checks.get('.cargo_vcs_info.json')!=sha(vcs) or json.loads(vcs)!=record['publishedVCS']:
        raise RuntimeError('Supplement source provenance differs from published archive')
    sources=[];texts={};relative=package['name']+'-'+package['version']
    for row in record['notices']:
        name=row['name']
        if Path(name).name!=name or name in ['.','..'] or not name or len(name)>128:raise RuntimeError('Unsafe supplement basename')
        data=read(root/relative/name,65536)
        if sha(data)!=row['sha256'] or b'\0' in data:raise RuntimeError('Supplement notice changed')
        texts[row['sha256']]=data.decode('utf-8');sources.append(dict(name=name,sha256=row['sha256'],provenance=row))
    return sources,texts,record['publishedVCS']

def graph_components(lock_path,tooling,env,role,target=TARGETS[0]):
    lock=read(lock_path);locked=lock_checksums(lock)
    raw=subprocess.check_output([str(TOOLCHAIN/'bin/cargo'),'metadata','--manifest-path',str(lock_path.with_name('Cargo.toml')),
        '--locked','--offline','--format-version','1','--filter-platform',target],cwd=REPO,env=env,stderr=subprocess.PIPE,timeout=30)
    if len(raw)>4<<20:raise RuntimeError('Dependency metadata bound')
    metadata=json.loads(raw);nodes={n['id']:n for n in metadata['resolve']['nodes']}
    root=metadata['resolve']['root'];pending=[root];reachable=set()
    while pending:
        key=pending.pop()
        if key not in reachable:reachable.add(key);pending.extend(nodes[key]['dependencies'])
    components=[];texts={}
    for package in sorted(metadata['packages'],key=lambda p:(p['name'],p['version'])):
        if package['id'] not in reachable or package['id']==root:continue
        if package['license'] not in ALLOWED:raise RuntimeError('A new dependency license needs review: '+package['name'])
        directory=Path(package['manifest_path']).parent
        registry=directory.is_relative_to(tooling/'cargo-home/registry/src')
        if registry:
            checks=registry_notices(directory,package,locked,tooling)
        elif role!='smb' or directory!=REPO/'Vendor/smb2':raise RuntimeError('Unadmitted path dependency')
        sources=[]
        for relative in notice_paths(directory,package):
            data=read(directory/relative,65536)
            if b'\x00' in data:raise RuntimeError('Nontext license input')
            digest=sha(data)
            name=relative.as_posix()
            if registry and checks.get(name)!=digest:raise RuntimeError('License input differs from verified package')
            text=data.decode('utf-8')
            texts[digest]=text
            sources.append(dict(name=name,sha256=digest))
        supplement=None
        if not sources and registry:
            sources,extra,supplement=supplemental_notices(directory,package,locked,checks);texts.update(extra)
        if not sources or 'Unicode-3.0' in package['license'] and not any(p['name']=='LICENSE-UNICODE' for p in sources):
            raise RuntimeError('Required notices missing: '+package['name'])
        component=dict(name=package['name'],version=package['version'],declaredLicense=package['license'],notices=sources,graphs=[role])
        if supplement is not None:component['publishedVCSForSupplement']=supplement
        components.append(component)
    if read(lock_path)!=lock:raise RuntimeError('Dependency lock changed during component preparation')
    return components,texts,dict(role=role,target=target,path=str(lock_path.relative_to(REPO)),sha256=sha(lock))

def merge_components(graphs):
    found={};texts={};locks=[]
    for components,notices,lock in graphs:
        locks.append(lock)
        for digest,text in notices.items():
            if digest in texts and texts[digest]!=text:raise RuntimeError('Contradictory notice digest')
            texts[digest]=text
        for component in components:
            key=(component['name'],component['version']);previous=found.get(key)
            if previous is not None:
                if previous['declaredLicense']!=component['declaredLicense'] or previous['notices']!=component['notices']:raise RuntimeError('Contradictory shared component')
                previous['graphs']=sorted(set(previous['graphs']+component['graphs']))
            else:found[key]={**component,'graphs':list(component['graphs'])}
    return [found[key] for key in sorted(found)],texts,locks

def crash_reporter_component():
    from build_crash_reporter import verify_sources, COMMIT, PROVENANCE_SHA256
    verify_sources()
    sources=[];texts={}
    # The upstream root retains its historical Apache notice; the vendored
    # protobuf-c has BSD-2 terms. Preserve both, plus the full Apache license.
    for name in ('Vendor/PLCrashReporter/LICENSE', 'Vendor/PLCrashReporter/ThirdPartyNotices.txt',
                 'Vendor/smb2/LICENSE-APACHE'):
        data=read(REPO/name,65536);digest=sha(data)
        texts[digest]=data.decode('utf-8');sources.append(dict(name=name,sha256=digest))
    return dict(name='PLCrashReporter',version='1.12.2',declaredLicense='MIT AND Apache-2.0 AND BSD-2-Clause',
                notices=sources,graphs=['app'],upstreamCommit=COMMIT,sourceManifestSHA256=PROVENANCE_SHA256),texts

def build():
    verify()
    spec=importlib.util.spec_from_file_location('macexplorer_sftp_notice_packet',REPO/'tools/ssh_profiles/packet.py')
    if spec is None or spec.loader is None:raise RuntimeError('Isolated SFTP notice environment')
    packet=importlib.util.module_from_spec(spec);spec.loader.exec_module(packet)
    components,texts,locks=merge_components([
        graph_components(lock_path,tooling,env,role,target)
        for lock_path,tooling,env,role in (
            (LOCK,TOOLING,environment(),'smb'),
            (REPO/'tools/sftp_reader/qualification/Cargo.lock',packet.TOOLING,
             packet.rust_environment(packet.directory(packet.TOOLING/'notices')),'sftp'))
        for target in TARGETS])
    crash_component,crash_texts=crash_reporter_component()
    components.append(crash_component);components.sort(key=lambda item:(item['name'],item['version']))
    texts.update(crash_texts)
    lock=read(LOCK)
    standard=read(TOOLCHAIN/'share/doc/rust/COPYRIGHT-library.html')
    parser=PlainLegalText();parser.feed(standard.decode('utf-8'));parser.close()
    standardText=''.join(parser.parts).strip()+'\n'
    numbers={digest:index+1 for index,digest in enumerate(sorted(texts))}
    body=HEADER+'\nComponents\n'
    for component in components:
        body+='\n'+component['name']+' '+component['version']+' — '+component['declaredLicense']+'\n'
        for notice in component['notices']:notice['noticeNumber']=numbers[notice['sha256']]
        body+='License notices '+', '.join(str(p['noticeNumber']) for p in component['notices'])+'\n'
    for digest,text in sorted(texts.items()):
        shared=[c['name']+' '+c['version'] for c in components if any(n['sha256']==digest for n in c['notices'])]
        body+='\n\nNotice '+str(numbers[digest])+'\n'+'-'*72+'\nApplies to: '+', '.join(shared)+'\n\n'+text.rstrip()+'\n'
    body+='\n\nRust standard-library copyright and third-party notices\n'+'-'*72+'\n'+standardText
    body+='\nThe system SQLite, zlib and Apple frameworks are dynamically supplied by macOS, not bundled copies.\n'
    # The displayed bundle is canonical text; hashes of original published
    # notice bytes remain in the component provenance alongside this output hash.
    document=body.replace('\r\n','\n').replace('\r','\n').encode('utf-8')
    if len(document)>4<<20:raise RuntimeError('Bundled notice bound exceeded')
    manifest=dict(version=1,targets=list(TARGETS),lockSHA256=sha(lock),dependencyGraphs=locks,
        rustToolchainManifestSHA256=sha(read(REPO/'tools/rust-toolchain.json',65536)),
        rustLibraryCopyrightSHA256=sha(standard),components=components,noticeSHA256=sha(document),
        includesBuildDependencies=True,localAbsolutePathsIncluded=False,generatedNetworkRequests=0)
    if read(LOCK)!=lock or any(sha(read(REPO/item['path']))!=item['sha256'] for item in locks):raise RuntimeError('Dependency lock changed during notice preparation')
    return document,(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode()

def write_atomic(path,data):
    if path.exists() and (path.is_symlink() or path.stat().st_nlink!=1):raise RuntimeError('Unsafe notice output')
    fd,temporary=tempfile.mkstemp(prefix='.notice-',dir=OUTPUT)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.chmod(temporary,0o644);os.replace(temporary,path)
    finally:
        if Path(temporary).exists():Path(temporary).unlink()

def verify_outputs():
    expected=build()
    for name,data in zip(['ThirdPartyNotices.txt','ThirdPartyManifest.json'],expected):
        if read(OUTPUT/name,4<<20)!=data:raise RuntimeError('Generated notices need reviewed regeneration')
    return expected

def main():
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--write',action='store_true');group.add_argument('--check',action='store_true');args=parser.parse_args()
    if args.write:
        values=build()
        for name,data in zip(['ThirdPartyNotices.txt','ThirdPartyManifest.json'],values):write_atomic(OUTPUT/name,data)
    else:values=verify_outputs()
    manifest=json.loads(values[1]);print(json.dumps(dict(passed=True,components=len(manifest['components']),noticeBytes=len(values[0]),
        targets=list(TARGETS),networkRequests=0)))

if __name__=='__main__':main()
