//! Generated-fixture-only R1 scanner. Shares syscall/SDK ABI and SHA-256 glue
//! with S1; parsing, traversal, aggregation and protocol encoding are Rust.
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_int, c_void, CString};
use std::time::Instant;

const FIELDS: [&str; 4] = ["data_logical", "all_logical", "data_allocated", "all_allocated"];
type Result<T> = std::result::Result<T, &'static str>;
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Identity { dev: u64, ino: u64, nlink: u64, flags: u32, mode: u32, fsid0: i32, fsid1: i32, local: c_int, mtime_sec:i64, mtime_nsec:i64, ctime_sec:i64, ctime_nsec:i64 }
#[repr(C)]
struct PollDescriptor { fd:i32,events:i16,revents:i16 }
#[repr(C)]
#[derive(Default)]
struct Resources {current_rss:u64,peak_rss:u64,user_ns:u64,system_ns:u64}
const _: () = assert!(std::mem::size_of::<Identity>()==80 && std::mem::offset_of!(Identity,mtime_sec)==48);
unsafe extern "C" {
    fn b06_common_mask() -> u32;
    fn b06_directory_mask() -> u32;
    fn b06_file_mask() -> u32;
    fn b06_policy_get() -> c_int;
    fn b06_policy_off() -> c_int;
    fn b06_policy_restore(policy: c_int) -> c_int;
    fn b06_open_root(path: *const c_char) -> c_int;
    fn b06_open_directory(fd: c_int, path: *const c_char) -> c_int;
    fn b06_identity(fd: c_int, output: *mut Identity) -> c_int;
    fn b06_bulk(fd: c_int, buffer: *mut c_void, size: usize) -> c_int;
    fn b06_sha256(data: *const c_void, size: usize, output: *mut u8);
    fn b06_install_cancellation();
    fn b06_cancelled() -> c_int;
    fn b06_set_utility_qos() -> c_int;
    fn b06_resources(output:*mut Resources) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn fcntl(fd:c_int, command:c_int, ...) -> c_int;
    fn write(fd:c_int,bytes:*const c_void,count:usize) -> isize;
    fn poll(descriptors:*mut PollDescriptor,count:u32,timeout:c_int) -> c_int;
    fn signal(number: c_int, handler: usize) -> usize;
    fn __error() -> *mut c_int;
}
fn errno() -> i32 { unsafe { *__error() } }
struct Descriptor(i32);
impl Drop for Descriptor { fn drop(&mut self) { unsafe { close(self.0); } } }
struct Policy(i32);
impl Policy {
    fn establish() -> Result<Self> { unsafe {
        let old = b06_policy_get();
        if old < 0 { return Err("materialization_policy"); }
        if b06_policy_off() != 0 || b06_policy_get() != 1 {
            b06_policy_restore(old); return Err("materialization_policy");
        }
        Ok(Self(old))
    } }
    fn restore(self) -> bool { unsafe { b06_policy_restore(self.0) == 0 && b06_policy_get() == self.0 } }
}
#[derive(Clone, Default)]
struct Observation {
    name: Vec<u8>, masks: [u32;5], dev: Option<u64>, ino: Option<u64>, links: Option<u64>,
    flags: Option<u32>, object_type: Option<u32>, mount: Option<u32>, error: u32, values: [Option<u64>;4],
}
impl Observation {
    fn kind(&self) -> &'static str { match self.object_type { Some(1) => "regular", Some(2) => "directory", Some(5) => "symlink", None|Some(0) => "unknown", _ => "other" } }
}
struct Cursor<'a> { bytes: &'a [u8], offset: usize, end: usize }
impl Cursor<'_> {
    fn bytes<const N:usize>(&mut self) -> Result<[u8;N]> {
        let end = self.offset.checked_add(N).ok_or("truncated_field")?;
        if end > self.end || end > self.bytes.len() { return Err("truncated_field"); }
        let value = self.bytes[self.offset..end].try_into().map_err(|_| "truncated_field")?;
        self.offset = end; Ok(value)
    }
    fn u32(&mut self) -> Result<u32> { Ok(u32::from_le_bytes(self.bytes()?)) }
    fn i32(&mut self) -> Result<i32> { Ok(i32::from_le_bytes(self.bytes()?)) }
    fn u64(&mut self) -> Result<u64> { Ok(u64::from_le_bytes(self.bytes()?)) }
    fn size(&mut self) -> Result<u64> { u64::try_from(i64::from_le_bytes(self.bytes()?)).map_err(|_| "negative_size") }
}
fn parse(bytes: &[u8], count: usize, bulk: bool) -> Result<Vec<Observation>> {
    if count > 220_000 { return Err("record_count"); }
    let allowed = unsafe { [b06_common_mask(),0,b06_directory_mask(),b06_file_mask(),0] };
    let mut observations = Vec::new(); let mut start: usize = 0;
    for _ in 0..count {
        if bulk && start % 8 != 0 { return Err("record_alignment"); }
        let mut head = Cursor { bytes, offset:start, end:bytes.len() };
        let length = head.u32()? as usize;
        let end = start.checked_add(length).ok_or("record_length")?;
        if length < 24 || end > bytes.len() || (bulk && length % 8 != 0) { return Err("record_length"); }
        let mut cursor = Cursor { bytes, offset:start+4, end }; let mut o = Observation::default();
        for mask in &mut o.masks { *mask=cursor.u32()?; }
        if o.masks.iter().zip(allowed).any(|(mask, allow)| mask & !allow != 0) || o.masks[0] & 0x8000_0000 == 0 { return Err("unexpected_mask"); }
        let common=o.masks[0]; let directory=o.masks[2]; let file=o.masks[3];
        if common & 0x2000_0000 != 0 { o.error=cursor.u32()?;if o.error>i32::MAX as u32{return Err("invalid_entry_errno");} }
        let mut name_range=None;
        if common & 1 != 0 {
            let reference=cursor.offset; let displacement=cursor.i32()?; let name_length=cursor.u32()? as usize;
            let name_start=reference.checked_add_signed(displacement as isize).ok_or("name_range")?;
            let name_end=name_start.checked_add(name_length).ok_or("name_range")?;
            if name_length<2 || name_start<start+24 || name_start>end || name_end>end { return Err("name_range"); }
            name_range=Some((name_start,name_end));
        }
        if common & 2 != 0 { o.dev=Some(cursor.u32()? as u64); }
        if common & 8 != 0 { let value=cursor.u32()?;if value>10{return Err("unknown_vnode_type");}o.object_type=Some(value); }
        if common & 0x40000 != 0 { o.flags=Some(cursor.u32()?); }
        if common & 0x0200_0000 != 0 { o.ino=Some(cursor.u64()?); }
        if directory & 1 != 0 { o.links=Some(cursor.u32()? as u64); }
        if directory & 4 != 0 { o.mount=Some(cursor.u32()?); }
        if file & 1 != 0 { o.links=Some(cursor.u32()? as u64); }
        for (bit,index) in [(2,1),(4,3),(0x200,0),(0x400,2)] { if file & bit != 0 { o.values[index]=Some(cursor.size()?); } }
        if let Some((name_start,name_end))=name_range {
            if name_start<cursor.offset || bytes[name_end-1]!=0 { return Err("name_overlap_or_terminator"); }
            o.name=bytes[name_start..name_end-1].to_vec();
            if o.name.contains(&0) || o.name.contains(&47) || o.name==b"." || o.name==b".." { return Err("invalid_component"); }
        } else if o.error==0 { return Err("missing_name"); }
        observations.push(o); start=end;
    }
    Ok(observations)
}
fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8;64]=b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut result=String::with_capacity(bytes.len().div_ceil(3)*4);
    for chunk in bytes.chunks(3) {
        let a=chunk[0]; let b=*chunk.get(1).unwrap_or(&0); let c=*chunk.get(2).unwrap_or(&0);
        result.push(TABLE[(a>>2) as usize] as char); result.push(TABLE[(((a&3)<<4)|(b>>4)) as usize] as char);
        result.push(if chunk.len()>1 {TABLE[(((b&15)<<2)|(c>>6)) as usize] as char} else {'='});
        result.push(if chunk.len()>2 {TABLE[(c&63) as usize] as char} else {'='});
    }
    result
}
fn number(value: Option<u64>) -> String { value.map(|v|v.to_string()).unwrap_or_else(||"-".into()) }
fn add_total(total:&mut u64,value:u64) -> Result<()> {*total=total.checked_add(value).ok_or("overflow")?;Ok(())}
fn canonical(o:&Observation, path:&[u8]) -> Vec<u8> {
    let masks=o.masks.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let values=o.values.iter().map(|v|number(*v)).collect::<Vec<_>>().join(",");
    format!("b06-record-v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",base64(path),base64(&o.name),o.kind(),number(o.dev),number(o.ino),number(o.links),number(o.flags.map(u64::from)),masks,o.error,values).into_bytes()
}
#[derive(Default)]
struct Digest { xor:[u8;32], sum:[u8;32] }
impl Digest {
    fn add(&mut self,data:&[u8]) { let mut hash=[0u8;32]; unsafe {b06_sha256(data.as_ptr().cast(),data.len(),hash.as_mut_ptr());}
        let mut carry=0u16; for i in (0..32).rev() { self.xor[i]^=hash[i];let sum=self.sum[i] as u16+hash[i] as u16+carry;self.sum[i]=sum as u8;carry=sum>>8; }
    }
    fn hex(bytes:&[u8]) -> String { bytes.iter().map(|byte|format!("{byte:02x}")).collect() }
}
fn quote(text:&str) -> String {
    let mut result=String::from("\"");
    for c in text.chars() { match c { '"'=>result.push_str("\\\""), '\\'=>result.push_str("\\\\"), '\n'=>result.push_str("\\n"), '\r'=>result.push_str("\\r"), '\t'=>result.push_str("\\t"), '\u{0}'..='\u{1f}'=>result.push_str(&format!("\\u{:04x}",c as u32)), _=>result.push(c) } }
    result.push('"');result
}
fn json_number(value:Option<u64>) -> String { value.map(|v|quote(&v.to_string())).unwrap_or_else(||"null".into()) }
fn json_map(pairs:Vec<(&str,String)>) -> String { format!("{{{}}}",pairs.into_iter().map(|(k,v)|format!("{}:{}",quote(k),v)).collect::<Vec<_>>().join(",")) }
fn totals_json(values:&[u64;4]) -> String { json_map(FIELDS.iter().zip(values).map(|(k,v)|(*k,quote(&v.to_string()))).collect()) }
fn observation_json(o:&Observation,path:&[u8],parent:&[u8]) -> Vec<(&'static str,String)> {
    let mut pairs=vec![("relative_b64",quote(&base64(path))),("parent_b64",quote(&base64(parent))),("name_b64",quote(&base64(&o.name))),("type",quote(o.kind())),("dev",json_number(o.dev)),("ino",json_number(o.ino)),("nlink",json_number(o.links)),("flags",json_number(o.flags.map(u64::from))),("errno",o.error.to_string())];
    pairs.push(("returned",json_map(["common","volume","directory","file","fork"].into_iter().zip(o.masks).map(|(k,v)|(k,quote(&v.to_string()))).collect())));
    for (index,key) in FIELDS.iter().enumerate() {
        let value=if o.error!=0 {"{\"state\":\"error\"}".into()} else if let Some(v)=o.values[index] {format!("{{\"state\":\"returned\",\"value\":\"{v}\"}}")} else {"{\"state\":\"not_returned\"}".into()};pairs.push((key,value));
    }
    pairs
}
struct Options { root:String,session:String,dev:u64,ino:u64,cancel_after:Option<u64>,summary_only:bool,maximum_depth:usize,maximum_queue:usize }
impl Options {
    fn parse(args:&[String]) -> Result<Self> {
        let mut result=Self {root:String::new(),session:String::new(),dev:0,ino:0,cancel_after:None,summary_only:false,maximum_depth:64,maximum_queue:4096}; let mut lane=String::new();let mut index=0;
        while index<args.len() { let key=&args[index]; index+=1;
            if key=="--summary-only" {result.summary_only=true;continue;}
            let value=args.get(index).ok_or("missing_argument")?;index+=1;
            match key.as_str() {"--lane"=>lane=value.clone(),"--root"=>result.root=value.clone(),"--session"=>result.session=value.clone(),"--expected-dev"=>result.dev=value.parse().map_err(|_|"dev")?,"--expected-ino"=>result.ino=value.parse().map_err(|_|"ino")?,"--cancel-after"=>result.cancel_after=Some(value.parse().map_err(|_|"cancel")?),"--maximum-depth"=>{result.maximum_depth=value.parse().map_err(|_|"depth")?;if result.maximum_depth>64{return Err("depth");}},"--maximum-queue"=>{result.maximum_queue=value.parse().map_err(|_|"queue")?;if result.maximum_queue==0 || result.maximum_queue>4096{return Err("queue");}},_=>return Err("unknown_argument")}
        }
        if lane!="rust" || result.session.is_empty() || result.session.len()>128 || result.dev==0 || result.ino==0 {return Err("required_arguments");}
        let current=std::env::current_dir().map_err(|_|"root_admission")?;let base=format!("{}/.build/b06-analyzer/",current.to_str().ok_or("root_admission")?);
        let tail=result.root.strip_prefix(&base).ok_or("root_admission")?;let parts=tail.split('/').collect::<Vec<_>>();
        if result.root.len()>4096 || parts.len()!=3 || parts[1]!="fixtures" || parts.iter().any(|s|s.is_empty() || *s=="." || *s=="..") {return Err("root_admission");}
        Ok(result)
    }
}
#[derive(Clone)]
struct Pending {path:Vec<u8>,dev:u64,ino:u64,depth:usize}
struct ObjectObservation { values:[Option<u64>;4],links:Option<u64>,edges:u64 }
struct Scanner {
    options:Options,entries:u64,counts:HashMap<&'static str,u64>,objects:HashMap<String,ObjectObservation>,unknown_object_identity:bool,directories:HashSet<String>,totals:[u64;4],object_totals:[u64;4],missing:[u64;4],digest:Digest,errors:u64,issued:u64,calls:u64,bulk_calls:u64,peak_queue:usize,peak_fds:usize,complete:bool,reason:&'static str,output_failed:bool,root_identity:Identity,start:Instant,startup:Resources,resource_support:bool,
}
impl Scanner {
    fn new(options:Options) -> Self {let start=Instant::now();let mut startup=Resources::default();let resource_support=unsafe{b06_resources(&mut startup)}==0;Self {options,entries:0,counts:HashMap::new(),objects:HashMap::new(),unknown_object_identity:false,directories:HashSet::new(),totals:[0;4],object_totals:[0;4],missing:[0;4],digest:Digest::default(),errors:0,issued:0,calls:0,bulk_calls:0,peak_queue:0,peak_fds:0,complete:true,reason:"complete",output_failed:false,root_identity:Identity::default(),start,startup,resource_support}}
    fn emit(&mut self,kind:&str,mut pairs:Vec<(&str,String)>) {
        if self.output_failed {return;}
        if (kind=="entry" || kind=="progress") && unsafe{b06_cancelled()}!=0 {self.complete=false;self.reason="cancelled";return;}
        pairs.push(("kind",quote(kind)));pairs.push(("schema","1".into()));pairs.push(("session",quote(&self.options.session)));
        let line=json_map(pairs)+"\n";let mut offset=0;let begin=Instant::now();let bytes=line.as_bytes();let mut failed=bytes.len()>64*1024;
        while offset<bytes.len() && !failed {
            let count=unsafe{write(1,bytes.as_ptr().add(offset).cast(),bytes.len()-offset)};
            if count<0 {let error=errno();if error==4 {continue;}if error==35 {
                if begin.elapsed().as_secs()>=5 || unsafe{b06_cancelled()}!=0 {failed=true;continue;}
                let mut descriptor=PollDescriptor{fd:1,events:4,revents:0};unsafe{poll(&mut descriptor,1,20);}continue;
            }failed=true;}else{offset+=count as usize;}
        }
        if failed{self.output_failed=true;self.complete=false;self.reason="output_closed";}
    }
    fn issue(&mut self,code:&'static str,error:i32) {self.errors+=1;self.complete=false;if self.reason=="complete" {self.reason=code;}if self.issued<100 {self.issued+=1;self.emit("issue",vec![("code",quote(code)),("errno",error.to_string())]);}}
    fn identity(&mut self,fd:i32) -> Result<Identity> {let mut value=Identity::default();self.calls+=1;if unsafe {b06_identity(fd,&mut value)}!=0 {return Err("identity_failed");}Ok(value)}
    fn guarded(&self,i:&Identity) -> bool {i.local!=0 && i.dev==self.root_identity.dev && i.fsid0==self.root_identity.fsid0 && i.fsid1==self.root_identity.fsid1 && i.flags & (0x0080_0000|0x4000_0000)==0}
    fn stopped(&mut self) -> bool {if self.output_failed{return true;}if unsafe{b06_cancelled()}!=0 || self.options.cancel_after.is_some_and(|count|self.entries>=count){self.complete=false;self.reason="cancelled";return true;}false}
    fn accept(&mut self,o:&Observation,parent:&[u8]) -> Result<()> {
        if o.name.is_empty(){self.issue("metadata_error",o.error as i32);return Ok(());}
        if self.entries>=220_000{return Err("entry_limit");}
        let mut path=parent.to_vec();if !path.is_empty(){path.push(47);}path.extend_from_slice(&o.name);if path.len()>8192{return Err("path_limit");}
        self.entries+=1;*self.counts.entry(o.kind()).or_insert(0)+=1;self.digest.add(&canonical(o,&path));
        if o.error!=0 {self.issue(if o.error==11 {"materialization_denied"}else{"entry_error"},o.error as i32);}
        if o.dev.is_none() || o.ino.is_none() || o.object_type.is_none_or(|kind|kind==0) || o.flags.is_none() || o.links.is_none(){self.issue("missing_identity",0);}
        if o.kind()=="regular" {
            let mut fresh=false;let mut changed=false;
            if let Some((dev,ino))=o.dev.zip(o.ino){
                let key=format!("{dev}:{ino}");
                if let Some(previous)=self.objects.get_mut(&key){previous.edges+=1;changed=previous.values!=o.values || previous.links!=o.links || previous.links.is_some_and(|links|previous.edges>links);}else{self.objects.insert(key,ObjectObservation{values:o.values,links:o.links,edges:1});fresh=true;}
            }else{self.unknown_object_identity=true;}
            if changed{self.issue("object_changed",0);}
            for index in 0..4 {if let Some(value)=o.values[index].filter(|_|o.error==0){add_total(&mut self.totals[index],value)?;if fresh{add_total(&mut self.object_totals[index],value)?;}}else{self.missing[index]+=1;self.complete=false;if self.reason=="complete"{self.reason="missing_fields";}}}
        }
        if !self.options.summary_only{self.emit("entry",observation_json(o,&path,parent));}
        if self.entries==1{self.emit("progress",vec![("entries",quote("1")),("elapsed_ns",quote(&self.start.elapsed().as_nanos().to_string()))]);}
        Ok(())
    }
    fn open_pending(&mut self,root:i32,pending:&Pending) -> Result<Descriptor> {
        let path=CString::new(if pending.path.is_empty(){b".".to_vec()}else{pending.path.clone()}).map_err(|_|"invalid_component")?;
        let fd=unsafe {b06_open_directory(root,path.as_ptr())};if fd<0{return Err("open_directory_failed");}let descriptor=Descriptor(fd);let identity=self.identity(fd)?;
        if !self.guarded(&identity) || identity.dev!=pending.dev || identity.ino!=pending.ino{return Err("directory_changed");}Ok(descriptor)
    }
    fn receive(&mut self,o:&Observation,pending:&Pending,queue:&mut Vec<Pending>,head:usize) -> Result<()> {
        if self.stopped(){return Ok(());}self.accept(o,&pending.path)?;
        if o.kind()=="directory" && o.error==0 {
            let boundary=o.mount!=Some(0) || o.dev!=Some(self.root_identity.dev) || o.ino.is_none() || o.flags.is_none_or(|f|f&(0x0080_0000|0x4000_0000)!=0);
            if boundary{self.issue("boundary_excluded",0);return Ok(());}
            if pending.depth>=self.options.maximum_depth{self.issue("depth_limit",0);return Ok(());}
            let dev=o.dev.unwrap();let ino=o.ino.unwrap();if !self.directories.insert(format!("{dev}:{ino}")){self.issue("duplicate_directory",0);return Ok(());}
            if queue.len()-head>=self.options.maximum_queue{return Err("queue_limit");}
            let mut path=pending.path.clone();if !path.is_empty(){path.push(47);}path.extend_from_slice(&o.name);queue.push(Pending{path,dev,ino,depth:pending.depth+1});self.peak_queue=self.peak_queue.max(queue.len()-head);
        }Ok(())
    }
    fn scan(&mut self) -> Result<()> {
        if unsafe{b06_set_utility_qos()}!=0{return Err("worker_qos");}
        let policy=Policy::establish()?;let result=self.scan_guarded();if !policy.restore(){self.issue("materialization_restore",0);}result
    }
    fn scan_guarded(&mut self) -> Result<()> {
        let path=CString::new(self.options.root.as_bytes()).map_err(|_|"root_open")?;let fd=unsafe{b06_open_root(path.as_ptr())};if fd<0{return Err("root_open");}let root=Descriptor(fd);
        self.root_identity=self.identity(root.0)?;if self.root_identity.dev!=self.options.dev || self.root_identity.ino!=self.options.ino || !self.guarded(&self.root_identity){return Err("root_identity_or_boundary");}
        self.emit("header",vec![("lane",quote("rust")),("materialization_policy",quote("off")),("workers","1".into()),("worker_qos",quote("utility")),("common_mask",quote(&unsafe{b06_common_mask()}.to_string())),("directory_mask",quote(&unsafe{b06_directory_mask()}.to_string())),("file_mask",quote(&unsafe{b06_file_mask()}.to_string())),("profile",quote("core-v1")),("scope_contract",quote("descriptor-anchored"))]);
        let mut queue=vec![Pending{path:Vec::new(),dev:self.options.dev,ino:self.options.ino,depth:0}];let mut head=0;
        while head<queue.len() && !self.stopped() {
            let pending=queue[head].clone();head+=1;if head>1024{queue.drain(..head);head=0;}
            let directory=match self.open_pending(root.0,&pending){Ok(fd)=>fd,Err(_)=>{self.issue("directory_open",errno());continue;}};self.peak_fds=self.peak_fds.max(2);let before=self.identity(directory.0)?;
            let mut buffer=vec![0u8;256*1024];
            while !self.stopped() {
                self.bulk_calls+=1;self.calls+=1;let count=unsafe{b06_bulk(directory.0,buffer.as_mut_ptr().cast(),buffer.len())};
                if count<0{let error=errno();self.issue(if error==11{"materialization_denied"}else{"bulk_error"},error);break;}if count==0{break;}
                for o in parse(&buffer,count as usize,true)?{self.receive(&o,&pending,&mut queue,head)?;if self.stopped(){break;}}
            }
            let after=self.identity(directory.0)?;if before.dev!=after.dev || before.ino!=after.ino || before.mtime_sec!=after.mtime_sec || before.mtime_nsec!=after.mtime_nsec || before.ctime_sec!=after.ctime_sec || before.ctime_nsec!=after.ctime_nsec{self.issue("directory_changed",0);}
            let fresh_root=self.identity(root.0)?;if !self.guarded(&fresh_root){return Err("root_changed");}
            let check=unsafe{b06_open_root(path.as_ptr())};if check<0{return Err("root_replaced");}let check=Descriptor(check);self.peak_fds=self.peak_fds.max(3);let current=self.identity(check.0)?;
            if current.dev!=self.options.dev || current.ino!=self.options.ino{return Err("root_replaced");}
        }Ok(())
    }
    fn finish(&mut self) {
        let mut final_resources=Resources::default();let resources=self.resource_support && unsafe{b06_resources(&mut final_resources)}==0;
        let count=|key|self.counts.get(key).copied().unwrap_or(0);let mut summary=vec![("complete",self.complete.to_string()),("reason",quote(self.reason)),("entries",quote(&self.entries.to_string())),("regular_entries",quote(&count("regular").to_string())),("directory_entries",quote(&count("directory").to_string())),("symlink_entries",quote(&count("symlink").to_string())),("other_entries",quote(&(count("other")+count("unknown")).to_string())),("objects",quote(&self.objects.len().to_string())),("entry_totals",totals_json(&self.totals)),("object_totals",totals_json(&self.object_totals)),("missing_fields",totals_json(&self.missing)),("errors",quote(&self.errors.to_string())),("issues_emitted",quote(&self.issued.to_string())),("metadata_calls",quote(&self.calls.to_string())),("bulk_calls",quote(&self.bulk_calls.to_string())),("foundation_next_calls",quote("0")),("peak_queued_dirs",quote(&self.peak_queue.to_string())),("peak_owned_fds",quote(&self.peak_fds.to_string())),("elapsed_ns",quote(&self.start.elapsed().as_nanos().to_string())),("digest_xor",quote(&Digest::hex(&self.digest.xor))),("digest_sum",quote(&Digest::hex(&self.digest.sum))),("digest_count",quote(&self.entries.to_string())),("resource_metrics_state",quote(if resources{"returned"}else{"error"}))];
        summary.push(("object_accounting_state",quote(if self.unknown_object_identity{"unknown"}else if self.complete{"returned"}else{"partial"})));
        summary.push(("outside_link_objects",quote(&self.objects.values().filter(|object|object.links.is_some_and(|links|links>object.edges)).count().to_string())));
        if resources {summary.extend([("startup_current_rss",quote(&self.startup.current_rss.to_string())),("peak_rss",quote(&final_resources.peak_rss.to_string())),("incremental_peak_rss",quote(&final_resources.peak_rss.saturating_sub(self.startup.current_rss).to_string())),("post_drain_rss",quote(&final_resources.current_rss.to_string())),("user_ns",quote(&final_resources.user_ns.saturating_sub(self.startup.user_ns).to_string())),("system_ns",quote(&final_resources.system_ns.saturating_sub(self.startup.system_ns).to_string()))]);}self.emit("summary",summary);
    }
}
fn self_test() -> Result<()> {
    let mut bytes=Vec::new();for value in [48u32,0xa0000001,0,0,0,0,0,8,2]{bytes.extend(value.to_le_bytes());}bytes.extend([97,0]);bytes.resize(48,0);
    let o=parse(&bytes,1,true)?.remove(0);if o.name!=b"a" || o.values.iter().any(Option::is_some){return Err("selftest_supported_zero");}
    let mut error=bytes.clone();error[24]=13;if parse(&error,1,true)?[0].error!=13{return Err("selftest_error");}
    let mut bads=vec![bytes[..20].to_vec()];let mut bad=bytes.clone();bad[0]=47;bads.push(bad);let mut bad=bytes.clone();bad[28..32].copy_from_slice(&i32::MAX.to_le_bytes());bads.push(bad);let mut bad=bytes.clone();bad[37]=1;bads.push(bad);
    for bad in bads{if parse(&bad,1,true).is_ok(){return Err("selftest_accepted_bad");}}
    let mut total=u64::MAX;if add_total(&mut total,1)!=Err("overflow"){return Err("selftest_overflow");}
    let mut zero=Vec::new();for value in [96u32,0xa204000b,0,0,0x607,0,0,64,2,1,1,0]{zero.extend(value.to_le_bytes());}zero.extend(7u64.to_le_bytes());zero.extend(1u32.to_le_bytes());for _ in 0..4{zero.extend(0i64.to_le_bytes());}zero.extend([97,0]);zero.resize(96,0);
    if parse(&zero,1,true)?[0].values!=[Some(0);4]{return Err("selftest_returned_zero");}
    let mut raw=bytes.clone();raw[36]=255;if parse(&raw,1,true)?[0].name!=[255]{return Err("selftest_raw_name");}
    let mut negatives=Vec::new();let mut bad=zero.clone();bad[60..68].copy_from_slice(&(-1i64).to_le_bytes());negatives.push(bad);
    let mut bad=bytes.clone();bad[8]=1;negatives.push(bad);let mut bad=bytes.clone();bad[28]=0;negatives.push(bad);let mut bad=bytes.clone();bad[36]=47;negatives.push(bad);let mut bad=bytes.clone();bad[36]=46;negatives.push(bad);let mut bad=bytes.clone();bad[24..28].copy_from_slice(&u32::MAX.to_le_bytes());negatives.push(bad);let mut bad=bytes;bad[7]=0;negatives.push(bad);let mut bad=zero;bad[40..44].copy_from_slice(&999u32.to_le_bytes());negatives.push(bad);
    for bad in negatives{if parse(&bad,1,true).is_ok(){return Err("selftest_accepted_bad");}}
    println!("{{\"kind\":\"selftest\",\"schema\":1,\"passed\":17}}");Ok(())
}
fn main() {
    unsafe{signal(13,1);} // SIGPIPE ignored, output closure becomes an explicit outcome.
    unsafe{b06_install_cancellation();let flags=fcntl(1,3);if flags<0 || fcntl(1,4,flags|4)!=0{std::process::exit(74);}}
    let args=std::env::args().skip(1).collect::<Vec<_>>();if args==["--self-test"]{if self_test().is_err(){eprintln!("selftest_failed");std::process::exit(2);}return;}
    let options=match Options::parse(&args){Ok(o)=>o,Err(_)=>{eprintln!("invalid_admission_or_arguments");std::process::exit(64);}};
    let mut scanner=Scanner::new(options);let complete=std::thread::spawn(move||{if let Err(error)=scanner.scan(){scanner.issue(error,errno());}scanner.finish();scanner.complete}).join().unwrap_or(false);
    std::process::exit(if complete{0}else{2});
}
