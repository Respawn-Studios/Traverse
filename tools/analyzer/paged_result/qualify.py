#!/usr/bin/env python3
"""Isolated paged-result qualification on exact generated B06 inputs only.

No ordinary app route, personal catalog, source mutation or global tool change.
Unexpected failures retain their store and evidence; owned session handles close
only after real child exit. Source corpus and tooling limits remain separate.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import selectors
import signal
import sqlite3
import stat
import statistics
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import refinement_budget as budget
from packet import REPO,BASE,NOFOLLOW_ANY,directory_fd,put,read_owned
spec=importlib.util.spec_from_file_location("b06_dfs",HERE.parent/"full_scan/traversal.py")
dfs=importlib.util.module_from_spec(spec);spec.loader.exec_module(dfs)
TOOL_ROOT=REPO/".build/b06-consumer-profile-build"
EVIDENCE=BASE/"evidence-extension-20261018"

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

class ChildFailure(ValueError):
    def __init__(self,code,stdout,stderr,elapsed,peak):
        super().__init__("Generated child refused or failed")
        self.evidence=dict(exit=code,stdout_sha256=hashlib.sha256(stdout).hexdigest(),
            stdout_tail=bytes(stdout[-4096:]).decode(errors="replace"),stderr=bytes(stderr).decode(errors="replace"),
            actual_exit_observed=True,wall_seconds=elapsed,peak_bytes=peak)

def derive_rust():
    text=dfs.derive(64,256<<10);replace=dfs.replace_once
    text=replace(text,"mod policy;","mod policy;\nmod paged;")
    text=replace(text,"pending_rows:Vec<String>,","result_store:Option<paged::NodeWriter>,pending_rows:Vec<String>,")
    text=replace(text,"pending_rows:Vec::new(),","result_store:None,pending_rows:Vec::new(),")
    text=replace(text,'("schema","2".into())','("schema","4".into())')
    text=replace(text,'        pairs.push(("kind",quote(kind)));',
        '        if kind=="header" {if let Some(store)=self.result_store.as_ref(){if store.bind_root(self.options.dev,self.options.ino).is_err(){self.output_failed=true;self.complete=false;eprintln!("store_root_failed");return;}}}\n        if let Some(store)=self.result_store.as_ref(){pairs.push(("commit_rows",quote(&store.rows().to_string())));pairs.push(("aggregate_layout",quote(if store.direct(){"direct_v1"}else{"replay_v1"})));if kind=="summary" {for (key,value) in ["worker_sql_statements","worker_sql_commits","worker_sql_profile_ns","worker_sql_commit_ns"].iter().zip(store.statistics()){pairs.push((key,quote(&value.to_string())));}}}\n        pairs.push(("store_contract",quote("b06-paged-result-experiment-v2")));\n        pairs.push(("kind",quote(kind)));')
    text=replace(text,'let line=json_map(pairs)+"\\n";let mut offset=0;',
        'let line=json_map(pairs)+"\\n";if kind=="summary" {if let Some(store)=self.result_store.as_mut(){if store.terminal(&line).is_err(){self.complete=false;self.output_failed=true;eprintln!("store_terminal_failed");return;}}}let mut offset=0;')
    text=replace(text,'    fn row(&mut self,o:&Observation,path:&[u8],parent:&[u8]){',
        '''    fn row(&mut self,o:&Observation,path:&[u8],parent:&[u8])->Result<()>{
        if self.result_store.is_some() {
            let committed=self.result_store.as_mut().unwrap().accept(o,path,parent)?;
            if committed {self.emit("store_progress",vec![("entries",quote(&self.entries.to_string()))]);}
            return Ok(());
        }''')
    text=replace(text,'        self.row(o,&path,parent);','        self.row(o,&path,parent)?;')
    text=replace(text,'self.last_flush.elapsed().as_millis()>=100{self.flush_rows();}\n    }',
        'self.last_flush.elapsed().as_millis()>=100{self.flush_rows();}\n        Ok(())\n    }')
    text=replace(text,'    let args=std::env::args().skip(1).collect::<Vec<_>>();',
        '    let mut args=std::env::args().skip(1).collect::<Vec<_>>();if args==["--aggregate-vectors"] {println!("{}",paged::vectors());return;}')
    text=replace(text,'    let options=match Options::parse(&args)',
        '    let store_path=if args.len()==10 && args[0]=="--qualification-store" {let path=args[1].clone();args.drain(..2);Some(path)} else {None};\n    let options=match Options::parse(&args)')
    text=replace(text,'let mut scanner=Scanner::new(options);let complete=',
        'let mut scanner=Scanner::new(options);scanner.result_store=match store_path {Some(path)=>match paged::NodeWriter::open(&path){Ok(value)=>Some(value),Err(_)=>{eprintln!("store_admission_failed");std::process::exit(2);}},None=>{eprintln!("store_required");std::process::exit(2);}};let complete=')
    return text

def build(output,record,rust_patch=None):
    sdk=subprocess.check_output(["xcrun","--show-sdk-path"],text=True).strip()
    env={k:v for k,v in os.environ.items() if not k.startswith(("DYLD_","B06_","AUDIT_","RUST","CARGO","SWIFT_"))}
    env.update(TMPDIR=str(output),SDKROOT=sdk,MACOSX_DEPLOYMENT_TARGET="15.0")
    sources=REPO/"Packages/ExplorerKit/Sources/StorageAnalysis"
    cache=TOOL_ROOT/"paged-module-cache"
    if not cache.exists():cache.mkdir(mode=0o700)
    if cache.is_symlink() or cache.stat().st_mode&0o077:raise ValueError("Isolated module cache ownership changed")
    record["module_cache"]=str(cache.relative_to(REPO))
    # Exact source copies preserve inspectable derivation without exposing an
    # app API solely for an experiment. Only classify visibility is changed.
    for name in ("AnalysisModels.swift","AnalysisFileTypes.swift","StorageAnalysisAccumulator.swift","ScannerProtocol.swift","ScannerCoverage.swift"):
        (output/name).write_bytes((sources/name).read_bytes())
    text=(sources/"AnalysisAttribution.swift").read_text()
    text=dfs.replace_once(text,"    private static func classify(","    static func classify(")
    (output/"AnalysisAttribution.swift").write_text(text)
    view=(REPO/"App/MacExplorer/Features/StorageAnalysis/FileProperties.swift").read_text()
    view=view[view.index("func storageMetricText("):view.index("struct AppStorageComponent:")]
    view=dfs.replace_once(view,'    var compact = false\n',
        '    var compact = false\n    init(report:AnalysisAttributionReport,compact:Bool=false,initialGroup:Int=0){self.report=report;self.compact=compact;_group=State(initialValue:Group.allCases[min(2,max(0,initialGroup))])}\n')
    (output/"ChartView.swift").write_text("import Foundation\nimport SwiftUI\nimport Charts\n"+view)
    formatting=(REPO/"App/MacExplorer/Browser/FilePresentation.swift").read_text()
    formatting=formatting[formatting.index("enum FileSizeText"):formatting.index("enum BrowserColumn")]
    (output/"FileSize.swift").write_text("import Foundation\n"+formatting)
    rows=(REPO/"App/MacExplorer/Features/StorageAnalysis/StorageAnalysisWindow.swift").read_text()
    rows=rows[rows.index("private final class StorageAnalysisFolderItem:"):]
    for name in ("final class StorageAnalysisFolderItem","struct StorageAnalysisRowSort","struct StorageAnalysisPreparedRows"):
        rows=dfs.replace_once(rows,"private "+name,name)
    (output/"ReferenceRows.swift").write_text("import Foundation\n"+rows)
    policy=(sources/"StorageAnalysisPolicy.swift").read_text()
    if 'public static let revision = "local-metadata-v1"' not in policy:raise ValueError("Protocol policy pin changed")
    (output/"PolicyRevision.swift").write_text('enum StorageAnalysisPolicy {static let revision="local-metadata-v1"}\n')
    (output/"Schema.swift").write_text('let pagedSchema = """\n'+(HERE/"PagedStore.sql").read_text()+'\n"""\n')
    for name in ("PagedStore.swift","BoundedDirectAggregates.swift","PagedProjection.swift","PagedReport.swift","ObjectConsistencyVectors.swift","Probe.swift","StoreAuthority.c","StoreAuthority.h","PagedWriter.rs","PagedStore.sql","WorkerPump.swift","NativeView.swift","NativePipeline.swift","SyntheticFolders.swift"):
        (output/name).write_bytes((HERE/name).read_bytes())
    (output/"main.rs").write_text(derive_rust())
    (output/"paged.rs").write_bytes((HERE/"PagedWriter.rs").read_bytes())
    if rust_patch is not None:
        original=(output/"paged.rs").read_text()
        (output/"paged.rs").write_text(rust_patch(original))
        record["isolated_rust_patch"]={"input_sha256":hashlib.sha256(original.encode()).hexdigest(),"output_sha256":sha(output/"paged.rs")}
    rules=[]
    mapping={"documents":1,"textAndSource":2,"spreadsheets":3,"presentations":4,"images":5,"video":6,"audio":7,"archives":8,"diskImages":9,"virtualDisks":10,"models":11,"fonts":12}
    for suffixes,kind in re.findall(r'case ((?:"[a-z0-9]+"(?:, )?)+): return \.(\w+)',(sources/"AnalysisFileTypes.swift").read_text()):
        if kind not in mapping:raise ValueError("Unreviewed type classifier derivation")
        rules.append(" | ".join('b'+suffix for suffix in re.findall(r'"[a-z0-9]+"',suffixes))+" => "+str(mapping[kind])+",")
    if len(rules)!=12:raise ValueError("Incomplete fixed type classifier port")
    (output/"TypeRules.rs").write_text('fn file_type(name:&[u8])->usize {let Some(dot)=name.iter().rposition(|b|*b==46) else{return 0;};if dot==0{return 0;}let suffix=&name[dot+1..];if suffix.is_empty() || suffix.len()>16 || suffix.iter().any(|b|*b>=128){return 0;}let lower:Vec<u8>=suffix.iter().map(|b|b.to_ascii_lowercase()).collect();match lower.as_slice(){'+"".join(rules)+'_=>0}}\n')
    for name in ("policy.rs","policy-vectors.tsv"):(output/name).write_bytes((dfs.SOURCE/name).read_bytes())
    native=output/"ScannerNative.o";guard=output/"StoreAuthority.o"
    commands=[("native",["clang","-O3","-target","arm64-apple-macosx15.0","-isysroot",sdk,"-c",str(dfs.SOURCE/"ScannerNative.c"),"-o",str(native)]),
        ("authority",["clang","-O3","-Wall","-Wextra","-Werror","-target","arm64-apple-macosx15.0","-isysroot",sdk,"-I",str(dfs.SOURCE),"-c",str(output/"StoreAuthority.c"),"-o",str(guard)])]
    swift=output/"paged-swift";rust=output/"paged-rust"
    commands.append(("swift",["xcrun","swiftc","-O","-whole-module-optimization","-swift-version","6","-strict-concurrency=complete","-warnings-as-errors","-parse-as-library",
        "-target","arm64-apple-macosx15.0","-sdk",sdk,"-module-cache-path",str(cache),"-I",str(dfs.SOURCE),
        "-import-objc-header",str(output/"StoreAuthority.h")]+[str(output/name) for name in
        ("AnalysisModels.swift","AnalysisFileTypes.swift","StorageAnalysisAccumulator.swift","AnalysisAttribution.swift","ScannerProtocol.swift","ScannerCoverage.swift","PolicyRevision.swift","PagedStore.swift","BoundedDirectAggregates.swift","PagedProjection.swift","PagedReport.swift","ObjectConsistencyVectors.swift","WorkerPump.swift","NativeView.swift","NativePipeline.swift","SyntheticFolders.swift","ChartView.swift","FileSize.swift","ReferenceRows.swift","Schema.swift","Probe.swift")]
        +[str(native),str(guard),"-o",str(swift)]))
    commands.append(("rust",[str(dfs.RUSTC),"--edition=2024","-C","opt-level=3","-C","lto=thin","-C","codegen-units=1","-C","panic=abort",
        "--target=aarch64-apple-darwin","-C","link-arg=-isysroot","-C","link-arg="+sdk,"-C","link-arg="+str(native),"-C","link-arg="+str(guard),str(output/"main.rs"),"-o",str(rust)]))
    record["builds"]=[]
    for lane,command in commands:
        result=subprocess.run(command,cwd=REPO,env=env,capture_output=True,timeout=120)
        (output/(lane+"-build.txt")).write_bytes(result.stdout+result.stderr)
        record["builds"].append({"lane":lane,"returncode":result.returncode,"log_sha256":sha(output/(lane+"-build.txt"))})
        if result.returncode or (lane!="native" and result.stderr):raise ValueError("Qualification compilation failed: "+lane)
    record["binaries"]={"swift":sha(swift),"rust":sha(rust)};record["sdk"]=sdk
    return swift,rust

class Owner:
    """Generated test lease, not a personal-store VFS or cleanup admission."""
    def __init__(self):
        root=budget.SQLITE_STORE_ROOT
        # Create only relative to held, no-follow directory descriptors. A
        # namespace swap after admission cannot redirect mkdir into another repo.
        base=directory_fd(BASE)
        try:
            try:os.mkdir(root.name,mode=0o700,dir_fd=base)
            except FileExistsError:pass
            container=os.open(root.name,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|NOFOLLOW_ANY,dir_fd=base)
        finally:os.close(base)
        self.root=root/("session-"+uuid.uuid4().hex)
        try:
            value=os.fstat(container)
            if value.st_uid!=os.geteuid() or value.st_mode&0o777!=0o700:raise ValueError("Generated session container permissions changed")
            os.mkdir(self.root.name,mode=0o700,dir_fd=container)
            parent=os.open(self.root.name,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|NOFOLLOW_ANY,dir_fd=container)
        finally:os.close(container)
        def retain(fd):
            kept=fcntl.fcntl(fd,fcntl.F_DUPFD_CLOEXEC,10);os.close(fd);return kept
        self.parent=retain(parent);self.identity=os.fstat(self.parent)
        self.lease=retain(os.open("owner.lock",os.O_CREAT|os.O_EXCL|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=self.parent))
        fcntl.flock(self.lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
        self.database=retain(os.open("result.sqlite",os.O_CREAT|os.O_EXCL|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=self.parent))
        self.database_identity=os.fstat(self.database);self.active=set()
        self.proof=None
        fd=os.open("owner.json",os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=self.parent)
        with os.fdopen(fd,"w") as output:json.dump({"schema":1,"scope":"b06-generated-paged-result-qualification",
            "directory":[self.identity.st_dev,self.identity.st_ino],"database":[self.database_identity.st_dev,self.database_identity.st_ino]},output)
    @property
    def path(self):return self.root/"result.sqlite"
    def fresh(self):
        parent=os.stat(self.root,follow_symlinks=False);database=os.stat("result.sqlite",dir_fd=self.parent,follow_symlinks=False)
        if ((parent.st_dev,parent.st_ino)!=(self.identity.st_dev,self.identity.st_ino) or not stat.S_ISDIR(parent.st_mode)
            or parent.st_mode&0o777!=0o700 or (database.st_dev,database.st_ino)!=(self.database_identity.st_dev,self.database_identity.st_ino)
            or not stat.S_ISREG(database.st_mode) or database.st_nlink!=1 or database.st_mode&0o777!=0o600):
            raise ValueError("Generated session authority changed")
        if sum(p.lstat().st_size for p in self.root.iterdir() if p.name in budget.SQLITE_NAMES)>32<<20:
            raise ValueError("Session SQLite/sidecar cap exceeded")
    def actions(self):
        return [(os.POSIX_SPAWN_DUP2,self.parent,4),(os.POSIX_SPAWN_DUP2,self.database,5),(os.POSIX_SPAWN_DUP2,self.lease,6)]
    def close(self):
        if self.active:raise ValueError("Actual child still owns session")
        if self.proof is not None:os.close(self.proof);self.proof=None
        for fd in (self.database,self.lease,self.parent):os.close(fd)
    def preserve_verified(self,proof):
        self.fresh()
        if self.active:raise ValueError("Proof before actual exit")
        if self.proof is None:
            self.proof=os.open("verified.ndjson",os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_APPEND|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=self.parent)
            os.fsync(self.parent)
        data=(json.dumps(dict(proof,database_sha256=sha(self.path)),sort_keys=True)+"\n").encode()
        if len(data)>8192 or os.fstat(self.proof).st_size+len(data)>128<<10:raise ValueError("Bounded generated proof log")
        if os.write(self.proof,data)!=len(data):raise OSError("Short proof append")
        os.fsync(self.proof);self.fresh()

def execute(binary,args,owner,*,actions=(),timeout=60,expected=0,fresh=True,drain_probe=False):
    if fresh:owner.fresh()
    out,err=os.pipe(),os.pipe()
    pid=os.posix_spawn(str(binary),[str(binary)]+list(map(str,args)),{"LANG":"C","LC_ALL":"C"},
        file_actions=[(os.POSIX_SPAWN_DUP2,out[1],1),(os.POSIX_SPAWN_DUP2,err[1],2)]+owner.actions()+list(actions))
    owner.active.add(pid);os.close(out[1]);os.close(err[1])
    began=time.monotonic();status=None;stdout=bytearray();stderr=bytearray();peak=0
    try:
        if drain_probe:
            try:owner.close()
            except ValueError:pass
            else:raise ValueError("Session release ignored its actual child")
        with selectors.DefaultSelector() as selector:
            selector.register(out[0],selectors.EVENT_READ,"out");selector.register(err[0],selectors.EVENT_READ,"err")
            while selector.get_map() or status is None:
                if status is None:
                    got,value,usage=os.wait4(pid,os.WNOHANG)
                    if got:status=value;peak=usage.ru_maxrss
                if time.monotonic()-began>timeout:raise TimeoutError("Bounded generated-child deadline")
                for key,_ in selector.select(.01):
                    value=os.read(key.fd,65536)
                    if not value:selector.unregister(key.fd);continue
                    target=stdout if key.data=="out" else stderr;target.extend(value)
                    if len(stdout)>1<<20 or len(stderr)>16384:raise ValueError("Bounded generated-child output")
        code=os.waitstatus_to_exitcode(status)
        if code!=expected or (expected==0 and stderr):raise ChildFailure(code,stdout,stderr,time.monotonic()-began,peak)
        return {"exit":code,"stdout":bytes(stdout),"stderr":bytes(stderr),"actual_exit_observed":True,"wall_seconds":time.monotonic()-began,"peak_bytes":peak,
            "release_refused_before_exit":drain_probe}
    finally:
        if status is None:
            os.kill(pid,signal.SIGTERM)
            # Only this owned test child; a hard stop is test failure, not a
            # successful drain claim. Preserve its store and original receipt.
            end=time.monotonic()+2
            while time.monotonic()<end:
                got,value,usage=os.wait4(pid,os.WNOHANG)
                if got:status=value;break
                time.sleep(.01)
            if status is None:os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
        owner.active.discard(pid);os.close(out[0]);os.close(err[0])
        if fresh:owner.fresh()

def authority_controls(binary,owner):
    """Expected substitutions restore only after exact quiet refusal and hash
    equality. Unexpected output leaves the generated state/evidence untouched.
    This observes boundaries; it does not qualify SQLite's internal path races.
    """
    def held_hash():
        value=hashlib.sha256();offset=0
        while True:
            data=os.pread(owner.database,65536,offset)
            if not data:break
            offset+=len(data);value.update(data)
            if offset>32<<20:raise ValueError("Generated authority hash bound")
        return value.hexdigest()
    original=held_hash();checks=[]
    def refuse(label,actions=()):
        result=execute(binary,["inspect",owner.path],owner,actions=actions,expected=2,fresh=False)
        if result["stdout"] or result["stderr"]!=b"paged_probe_-10\n" or held_hash()!=original:
            raise ValueError("Native store authority refusal changed or wrote data")
        checks.append(dict(control=label,quiet_fixed_refusal=True,original_database_unchanged=True,actual_exit_observed=True))
    refuse("wrong held lease identity",[(os.POSIX_SPAWN_DUP2,owner.database,6)])
    os.fchmod(owner.database,0o644);refuse("database permissions widened");os.fchmod(owner.database,0o600);owner.fresh()
    os.link("result.sqlite","extra.link",src_dir_fd=owner.parent,dst_dir_fd=owner.parent,follow_symlinks=False)
    refuse("additional hardlink");os.unlink("extra.link",dir_fd=owner.parent);owner.fresh()
    os.rename("result.sqlite","saved.sqlite",src_dir_fd=owner.parent,dst_dir_fd=owner.parent)
    fd=os.open("result.sqlite",os.O_CREAT|os.O_EXCL|os.O_RDWR|os.O_NOFOLLOW,0o600,dir_fd=owner.parent)
    replacement=os.fstat(fd);os.close(fd);refuse("regular file identity replacement")
    current=os.stat("result.sqlite",dir_fd=owner.parent,follow_symlinks=False)
    if (current.st_dev,current.st_ino,current.st_size)!=(replacement.st_dev,replacement.st_ino,0):raise ValueError("Generated replacement changed")
    os.unlink("result.sqlite",dir_fd=owner.parent);os.rename("saved.sqlite","result.sqlite",src_dir_fd=owner.parent,dst_dir_fd=owner.parent);owner.fresh()
    os.rename("result.sqlite","saved.sqlite",src_dir_fd=owner.parent,dst_dir_fd=owner.parent)
    os.symlink("saved.sqlite",owner.root/"result.sqlite");link=os.lstat(owner.root/"result.sqlite")
    refuse("database symlink replacement")
    current=os.lstat(owner.root/"result.sqlite")
    if (current.st_dev,current.st_ino)!=(link.st_dev,link.st_ino) or os.readlink(owner.root/"result.sqlite")!="saved.sqlite":raise ValueError("Generated link changed")
    os.unlink("result.sqlite",dir_fd=owner.parent);os.rename("saved.sqlite","result.sqlite",src_dir_fd=owner.parent,dst_dir_fd=owner.parent);owner.fresh()
    os.symlink("result.sqlite",owner.root/"result.sqlite-journal");link=os.lstat(owner.root/"result.sqlite-journal")
    refuse("journal symlink replacement")
    current=os.lstat(owner.root/"result.sqlite-journal")
    if (current.st_dev,current.st_ino)!=(link.st_dev,link.st_ino):raise ValueError("Generated journal link changed")
    os.unlink("result.sqlite-journal",dir_fd=owner.parent);owner.fresh()
    container=directory_fd(budget.SQLITE_STORE_ROOT);moved="session-"+uuid.uuid4().hex
    try:
        os.rename(owner.root.name,moved,src_dir_fd=container,dst_dir_fd=container)
        os.symlink(moved,owner.root);link=os.lstat(owner.root)
        refuse("parent directory alias replacement")
        current=os.lstat(owner.root)
        if (current.st_dev,current.st_ino)!=(link.st_dev,link.st_ino) or os.readlink(owner.root)!=moved:raise ValueError("Generated directory alias changed")
        os.unlink(owner.root.name,dir_fd=container);os.rename(moved,owner.root.name,src_dir_fd=container,dst_dir_fd=container)
    finally:os.close(container)
    owner.fresh()
    if held_hash()!=original:raise ValueError("Authority controls changed original database")
    return checks

def control_oracle(owner):
    """Separate Python integer arithmetic and explicit generated membership.

    Not the Swift classifier, SQL merge callback or accumulator subtraction.
    Names here are solely this code's fixed in-memory control graph.
    """
    owner.fresh();before=sha(owner.path)
    raw=sqlite3.connect(owner.path.as_uri()+"?mode=ro",uri=True)
    paths={0:b""};expected={};totals={}
    roles={b"Work/build/zero.txt":1,b"Work/build/missing.bin":1,b"Work/build/failed.bin":1,
        b"Work/node_modules/package.json":2,b"Work/node_modules/dependency.txt":2,
        b"Work/.cache/shared.dat":3,b"Library/Caches/huggingface/model.gguf":4}
    values={b"Package.swift":7,b"Work/Cargo.toml":7,b"Work/build/zero.txt":0,
        b"Work/build/missing.bin":None,b"Work/build/failed.bin":"error",b"Work/.cache/shared.dat":7,
        b"Work/node_modules/package.json":7,b"Work/node_modules/dependency.txt":7,
        b"Library/Caches/huggingface/model.gguf":13,bytes([255,95,97,46,77,80,52]):12,
        b"hard-one.txt":9,b"hard-two.txt":9,b"overflow-one.bin":(1<<64)-1,b"overflow-two.bin":1}
    for kind,count in [(0,13),(1,9),(2,1)]:
        for key in range(count):expected[(kind,key)]=[]
    expected[(2,1)]=[];expected[(2,3)]=[]
    seen=set()
    for node,parent,name,kind,payload in raw.execute("SELECT id,parent,name,kind,payload FROM observations_v2 WHERE id>0 ORDER BY id"):
        path=paths[parent]+(b"/" if paths[parent] else b"")+name
        if kind==1:paths[node]=path
        if kind!=0:continue
        if path not in values or path in seen:raise ValueError("Independent generated graph membership")
        seen.add(path);value=values[path]
        wanted=(bytes([0])+bytes(12)) if value is None else (bytes([2])+bytes(8)+(13).to_bytes(4,"big")) if value=="error" else bytes([1])+value.to_bytes(8,"big")+bytes(4)
        if payload!=wanted*4:raise ValueError("Independent raw metric/support payload")
        suffix=name.rsplit(b".",1)[-1].lower()
        type_key=6 if suffix==b"mp4" else 11 if suffix==b"gguf" else 2 if suffix in (b"swift",b"toml",b"json",b"txt") else 0
        project=0 if path.startswith((b"Library/",b"Work/.cache/")) else 3 if path.startswith(b"Work/") else 1
        for key in [(0,type_key),(1,roles.get(path,0)),(2,project)]:expected[key].append(value)
    if seen!=values.keys():raise ValueError("Independent control graph missing file")
    observed={}
    for kind,key,payload in raw.execute("SELECT kind,key,value FROM groups"):
        group=expected.get((kind,key))
        if group is None:raise ValueError("Unexpected classification group")
        total=sum(v for v in group if type(v) is int);missing=sum(v is None for v in group);failed=sum(v=="error" for v in group)
        counts=len(group).to_bytes(8,"big")+bytes(32)
        encoded=(0 if total>=1<<64 else total).to_bytes(8,"big")+missing.to_bytes(8,"big")+failed.to_bytes(8,"big")+bytes([int(total>=1<<64)])
        if payload!=counts+encoded*4:raise ValueError("Independent group counts/UInt64/support/overflow mismatch")
        observed[(kind,key)]=True
    if observed.keys()!=expected.keys():raise ValueError("Independent group set mismatch")
    raw.close();owner.fresh()
    if sha(owner.path)!=before:raise ValueError("Read-only oracle changed generated store")
    return dict(independent_exact=True,groups=len(observed),files=len(seen),database_unchanged=True,
        reference_overflow_note="Existing subtraction can conservatively contaminate unrelated slices; direct-member oracle stays exact. No ordinary model adoption.")

def fixture(name):
    if name not in ("smoke","wide","mixed"):raise ValueError("Fixed existing corpus only")
    root=dfs.CORPUS/"fixtures"/name
    receipt=json.loads(read_owned(dfs.CORPUS/"manifests"/(name+".json"),65536))
    fd=directory_fd(root);value=os.fstat(fd)
    if receipt["root"]!=str(root) or (receipt["dev"],receipt["ino"])!=(value.st_dev,value.st_ino):os.close(fd);raise ValueError("Frozen root identity changed")
    kept=fcntl.fcntl(fd,fcntl.F_DUPFD_CLOEXEC,16);os.close(fd)
    return root,kept,value

def observed_oracle(owner,name):
    expected={item["relative_b64"]:item for item in map(json.loads,read_owned(dfs.CORPUS/"manifests"/(name+".ndjson"),128<<20).splitlines())}
    import base64
    expected={key:value for key,value in expected.items() if len(base64.b64decode(key).split(b"/"))<=64}
    owner.fresh();before=sha(owner.path);db=sqlite3.connect(owner.path.as_uri()+"?mode=ro",uri=True)
    paths={0:b""};seen=set();kinds=[0]*5
    for node,parent,raw,kind,identity,payload in db.execute("SELECT id,parent,name,kind,identity,payload FROM observations_v2 WHERE id>0 ORDER BY id"):
        if parent not in paths:raise ValueError("Independent stored parent is absent/not a folder")
        path=paths[parent]+(b"/" if paths[parent] else b"")+raw;key=base64.b64encode(path).decode()
        value=expected.get(key)
        if value is None or key in seen or value["type"]!=["regular","directory","symlink","other","unknown"][kind]:raise ValueError("Independent stored namespace mismatch")
        if identity!=int(value["dev"]).to_bytes(8,"big")+int(value["ino"]).to_bytes(8,"big"):raise ValueError("Independent stored object identity mismatch")
        if kind==0 and (payload[0]!=1 or int.from_bytes(payload[1:9],"big")!=int(value["data_logical"])):raise ValueError("Independent stored logical size mismatch")
        if kind==1:paths[node]=path
        kinds[kind]+=1;seen.add(key)
    if seen!=expected.keys():raise ValueError("Independent store omitted expected admitted fixture records")
    state=db.execute("SELECT state FROM scan_state").fetchone()[0]
    for metric in range(4):
        start=40+metric*25
        root=db.execute("SELECT value FROM rollups WHERE node=0").fetchone()[0]
        for grouping in (0,1,2):
            groups=[v[0] for v in db.execute("SELECT value FROM groups WHERE kind=?",(grouping,))]
            for offset in (0,8,16):
                total=sum(int.from_bytes(v[start+offset:start+offset+8],"big") for v in groups)
                if total!=int.from_bytes(root[start+offset:start+offset+8],"big"):raise ValueError("Independent classification partition mismatch")
    db.close();owner.fresh()
    if before!=sha(owner.path):raise ValueError("Read-only result oracle wrote data")
    return dict(independent_exact=True,entries=len(seen),state=state,kind_counts=kinds,classification_partitions=12,database_unchanged=True)

def native_smoke(swift,rust,owner,record):
    pinned=json.loads(read_owned(EVIDENCE/"traversal-fdd17e4e26ab416c9160c2d102db2fb7.json",65536))
    dfs_worker=REPO/pinned["tool_output"]/"dfs64-256k"
    if sha(dfs_worker)!=pinned["binaries"]["dfs64-256k"]:raise ValueError("Matched DFS binary changed")
    normal=REPO/".build/storage-scanner/storage-scanner-worker"
    root,fd,value=fixture("smoke")
    record["native_smoke"]=[]
    try:
        for lane,worker in [("memory",normal),("swift",dfs_worker),("rust",rust)]:
            reset=execute(swift,["reset",owner.path],owner)
            if json.loads(reset["stdout"])["passed"] is not True:raise ValueError("Explicit generated-session reset failed")
            result=execute(swift,["native",owner.path,lane,worker,root,value.st_dev,value.st_ino,"-"],owner,actions=[(os.POSIX_SPAWN_DUP2,fd,3)],timeout=60)
            sample=json.loads(result["stdout"])
            if sample["passed"] is not True or sample["complete_scope"] is not True:raise ValueError("Generated smoke pipeline did not complete")
            sample["actual_parent_exit_observed"]=True
            if lane!="memory":sample["oracle"]=observed_oracle(owner,"smoke")
            record["native_smoke"].append(sample)
            owner.preserve_verified(dict(case="native-smoke",lane=lane,entries=sample["entries"],oracle=sample.get("oracle")))
    finally:os.close(fd)

def native_cohort(swift,rust,owner,record):
    pinned=json.loads(read_owned(EVIDENCE/"traversal-fdd17e4e26ab416c9160c2d102db2fb7.json",65536))
    dfs_worker=REPO/pinned["tool_output"]/"dfs64-256k"
    if sha(dfs_worker)!=pinned["binaries"]["dfs64-256k"]:raise ValueError("Matched DFS binary changed")
    binaries={"memory":REPO/".build/storage-scanner/storage-scanner-worker","swift":dfs_worker,"rust":rust}
    record["frozen_native_plan"]={"cases":["wide","mixed"],"prime_per_lane_case":1,"paired_repeats":3,
        "order":"Rotating memory/swift/rust; reverse on alternating pairs; preparation and independent oracle outside timed parent",
        "scan_depth":64,"page":256,"cached_rows":512,"sqlite_cache_kib":1024,"transaction_rows":128,
        "first_feedback_seconds":.5,"heartbeat_p99_seconds":.05,"heartbeat_max_seconds":.15,
        "median_time_regression":.10,"paired_time_regression":.15,
        "memory_target":"At least25% lower parent peak on the separately qualified folder-heavy control; file-heavy memory descriptive",
        "limits":"24 MiB main database,32 MiB entire session,64 MiB total SQLite allowance; no new corpus",
        "interpretation":"Mixed depth64 remains incomplete; full source scope is a separate failed gate, not silently repaired"}
    record["native_primes"]=[];record["native_samples"]=[]
    for name in ("wide","mixed"):
        root,fd,value=fixture(name)
        try:
            for pair in (-1,0,1,2):
                order=["memory","swift","rust"]
                if pair>=0:order=order[pair%3:]+order[:pair%3]
                if pair%2==1:order=list(reversed(order))
                for lane in order:
                    preparation=execute(swift,["reset",owner.path],owner,timeout=60)
                    if json.loads(preparation["stdout"])["passed"] is not True:raise ValueError("Verified generated-session reset failed")
                    result=execute(swift,["native",owner.path,lane,binaries[lane],root,value.st_dev,value.st_ino,"-"],owner,
                        actions=[(os.POSIX_SPAWN_DUP2,fd,3)],timeout=60)
                    sample=json.loads(result["stdout"])
                    sample.update(case=name,pair=pair,actual_parent_exit_observed=True,preparation_seconds=preparation["wall_seconds"])
                    if lane!="memory":sample["oracle"]=observed_oracle(owner,name)
                    expected=100000 if name=="wide" else 99392
                    if sample["entries"]!=expected or sample["complete_scope"]!=(name=="wide"):
                        raise ValueError("Equivalent-depth native coverage changed")
                    if sample["peak_cached_rows"]>512:raise ValueError("Native row cache limit")
                    (record["native_primes"] if pair<0 else record["native_samples"]).append(sample)
                    owner.preserve_verified(dict(case=name,pair=pair,lane=lane,entries=sample["entries"],oracle=sample.get("oracle")))
                    if not budget.inspect()["passed"]:raise ValueError("Between-case resource admission")
                print("Native paged cohort "+name+" pair "+str(pair)+" complete",flush=True)
        finally:os.close(fd)
    record["native_summary"]={}
    for name in ("wide","mixed"):
        values={lane:[s for s in record["native_samples"] if s["case"]==name and s["lane"]==lane] for lane in binaries}
        median={lane:statistics.median(s["scan_to_prepared_display_seconds"] for s in samples) for lane,samples in values.items()}
        summary={"median_scan_to_display_seconds":median,
            "median_parent_peak_bytes":{lane:statistics.median(s["parent_peak_bytes"] for s in samples) for lane,samples in values.items()},
            "rust_vs_swift_median_ratio":median["rust"]/median["swift"],"native_gates":{}}
        for lane in ("swift","rust"):
            ratios=[next(s for s in values[lane] if s["pair"]==pair)["scan_to_prepared_display_seconds"]/
                    next(s for s in values["memory"] if s["pair"]==pair)["scan_to_prepared_display_seconds"] for pair in range(3)]
            summary["native_gates"][lane]={"median_time":median[lane]/median["memory"]<=1.10,"maximum_paired_time":max(ratios)<=1.15,
                "first_feedback":all(s["first_feedback_seconds"]<=.5 for s in values[lane]),
                "heartbeat_p99":all(s["heartbeat_p99_seconds"]<=.05 for s in values[lane]),
                "heartbeat_max":all(s["heartbeat_max_seconds"]<=.15 for s in values[lane]),"cache_rows":all(s["peak_cached_rows"]<=512 for s in values[lane]),
                "paired_time_ratios":ratios,"complete_full_fixture":name=="wide"}
        record["native_summary"][name]=summary

def folder_scale(swift,owner,record):
    record["folder_scale_plan"]={"records":32000,"source":"in-memory generated directory observations only; no new filesystem corpus",
        "page":256,"cache":512,"parent_peak_reduction_target":.25,"comparison":"Same native table/chart, existing model versus paged model; raw time retained, no source scan claim"}
    record["folder_scale"]=[]
    for lane in ("memory","paged"):
        execute(swift,["reset",owner.path],owner,timeout=60)
        result=execute(swift,["folders",owner.path,lane,"-"],owner,timeout=60)
        value=json.loads(result["stdout"])
        if value["passed"] is not True or value["records"]!=32000:raise ValueError("Native folder scale control failed")
        if lane=="memory" and value["reference_root_wrappers"]!=32001:raise ValueError("Reference root was not actually expanded")
        if lane=="paged" and (value["peak_cached_rows"]!=512 or value["peak_visible_rows"]!=256):raise ValueError("Native folder paging/eviction bound")
        value["actual_exit_observed"]=True;record["folder_scale"].append(value)
        owner.preserve_verified(dict(case="generated-folder-scale",lane=lane,records=32000,paging=value["peak_cached_rows"]))
    memory,paged=record["folder_scale"]
    record["folder_scale_gates"]={"parent_peak_ratio":paged["parent_peak_bytes"]/memory["parent_peak_bytes"],
        "parent_peak_reduction":paged["parent_peak_bytes"]<=memory["parent_peak_bytes"]*.75,"bounded_rows":True}

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--controls",action="store_true");parser.add_argument("--smoke",action="store_true");parser.add_argument("--profile",action="store_true");parser.add_argument("--folders",action="store_true")
    args=parser.parse_args()
    before=budget.inspect()
    # Warm identical-SDK module cache: this subset adds no new frameworks and
    # needs one <=32 MiB session plus32 MiB measured build headroom. Overall
    # 2 GiB tooling and64 MiB store limits are never changed by this projection.
    entries,tool_and_store,stores=(6,64<<20,32<<20) if args.folders else (12,184<<20,56<<20)
    if (not before["passed"] or before["combined"]["entries"]+entries>before["limits"]["entries"]
        or before["isolated_tooling_allocated"]+tool_and_store>2<<30
        or before["sqlite_qualification"]["remaining_bytes"]<stores
        or before["original_allowance_charge"]["logical"]+65536>1<<30):raise ValueError("Paged qualification admission refused")
    output=TOOL_ROOT/("paged-"+uuid.uuid4().hex);output.mkdir(mode=0o700)
    record={"schema":1,"complete":False,"scope":__doc__,"before":before,"tool_output":str(output.relative_to(REPO)),
        "sources":{str(p.relative_to(REPO)):sha(p) for p in sorted(HERE.iterdir()) if p.is_file()},"controls":[]}
    failure=None;owner=None
    try:
        swift,rust=build(output,record)
        for option in ("--self-test","--policy-self-test"):
            result=subprocess.run([str(rust),option],cwd=REPO,env={"LANG":"C","LC_ALL":"C"},capture_output=True,timeout=5)
            if result.returncode or result.stderr:raise ValueError("Pinned Rust parser/policy control failed")
            record["controls"].append(json.loads(result.stdout))
        owner=Owner();record["store"]=str(owner.root.relative_to(REPO))
        prepare=execute(swift,["prepare",owner.path],owner,drain_probe=True);record["controls"].append(json.loads(prepare["stdout"]))
        record["controls"].append({"release_refused_before_actual_exit":prepare["release_refused_before_exit"]})
        result=execute(swift,["controls",owner.path],owner);record["controls"].append(json.loads(result["stdout"]))
        oracle=control_oracle(owner);record["controls"].append(oracle)
        record["controls"].extend(authority_controls(swift,owner))
        if args.smoke or args.profile:
            owner.preserve_verified(dict(case="generated-control-graph",oracle=oracle))
            native_smoke(swift,rust,owner,record)
        if args.profile:native_cohort(swift,rust,owner,record)
        if args.folders:
            owner.preserve_verified(dict(case="generated-control-graph",oracle=oracle))
            folder_scale(swift,owner,record)
        owner.close();owner=None
        record["after"]=budget.inspect()
        if not record["after"]["passed"]:raise ValueError("Post-controls resource admission")
        record["complete"]=True
    except BaseException as error:
        failure=error;record["failure"]=type(error).__name__+": "+str(error)
        if isinstance(error,ChildFailure):record["child_failure"]=error.evidence
    finally:
        if owner and not owner.active:owner.close()
        path=EVIDENCE/("paged-controls-"+uuid.uuid4().hex+".json");put(path,record)
        print(json.dumps({"receipt":str(path.relative_to(REPO)),"complete":record["complete"],"failure":record.get("failure")}),flush=True)
    if failure:raise failure

if __name__=="__main__":main()
