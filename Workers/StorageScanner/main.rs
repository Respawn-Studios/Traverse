//! FD-only, metadata-only isolated storage worker. Derived from the frozen R1
//! scanner; parser and masks remain preserved. Object consistency also checks
//! flags and impossible link counts before claiming complete accounting. Stream admission
//! counts every relative path component, including a final non-directory name.
//! Descriptor anchoring is not process confinement or filesystem permission.
mod policy;
#[cfg_attr(b06_reference_index,allow(dead_code))]
mod catalog;
mod result;
mod traversal;
#[cfg(all(b06_deep128,not(b06_classification_v3)))]
compile_error!("Deeper explicit traversal requires the v3 result baseline");
#[cfg(all(b06_parallel_metadata,not(all(b06_classification_v3,b06_layout_explanations))))]
compile_error!("Metadata prefetch requires the qualified v3/layout result baseline");
mod startup;
#[cfg(all(b06_sorted_pages,not(b06_classification_v3)))]
compile_error!("Sorted pages require the qualified v3 metadata catalog");
#[cfg(b06_layout_explanations)]
mod layout_hints;
#[cfg(all(b06_stored_locations,not(b06_classification_v3)))]
compile_error!("Stored-location queries require the qualified v3 result contract");
#[cfg(all(b06_application_layouts,not(all(b06_classification_v3,b06_layout_explanations))))]
compile_error!("Application-layout queries require the qualified v3/layout metadata contract");
#[cfg(all(b06_layout_explanations,not(b06_classification_v3)))]
compile_error!("Layout explanation qualification requires the v3 stored metadata contract");
#[cfg(all(b06_app_data,b06_dense_names))]
compile_error!("Policy qualification and dense-name qualification are separate experiments");
#[cfg(all(b06_checkpoint4096,not(all(b06_app_data,b06_live_totals))))]
compile_error!("Larger temporary checkpoints require the explicit progress/policy experiment");
#[cfg(all(b06_classification_v3,not(all(b06_app_data,b06_live_totals,b06_checkpoint4096))))]
compile_error!("Classification v3 requires its explicit policy/progress qualification contract");
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
    fn b06_root_path(fd:c_int, output:*mut c_char, capacity:usize) -> c_int;
    fn b06_open_directory(fd: c_int, path: *const c_char) -> c_int;
    fn b06_identity(fd: c_int, output: *mut Identity) -> c_int;
    fn b06_physical_identity(fd: c_int, output: *mut Identity) -> c_int;
    fn b06_bulk(fd: c_int, buffer: *mut c_void, size: usize) -> c_int;
    fn b06_bulk_physical(fd: c_int, buffer: *mut c_void, size: usize) -> c_int;
    fn read(fd:c_int,bytes:*mut c_void,count:usize)->isize;
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
struct RootDescriptor(i32,bool);
impl Drop for RootDescriptor {fn drop(&mut self){if self.1 {unsafe{close(self.0);}}}}
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
fn parse_record(bytes:&[u8],start:usize,bulk:bool)->Result<(Observation,usize)> {
    let allowed = unsafe { [b06_common_mask(),0,b06_directory_mask(),b06_file_mask(),0] };
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
    Ok((o,end-start))
}
fn parse(bytes:&[u8],count:usize,bulk:bool)->Result<Vec<Observation>> {
    if count>220_000{return Err("record_count");}
    let mut observations=Vec::with_capacity(count);let mut start=0usize;
    for _ in 0..count {
        let (observation,length)=parse_record(bytes,start,bulk)?;
        observations.push(observation);start=start.checked_add(length).ok_or("record_length")?;
    }Ok(observations)
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
// Full-result hashing reuses one bounded buffer. Exact canonical bytes and
// SHA-256 accounting remain unchanged; this removes per-field allocations.
fn canonical_into(o:&Observation,path:&[u8],buffer:&mut String) {
    use std::fmt::Write;
    fn encoded(bytes:&[u8],output:&mut String) {
        const TABLE:&[u8;64]=b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for chunk in bytes.chunks(3) {
            let a=chunk[0];let b=*chunk.get(1).unwrap_or(&0);let c=*chunk.get(2).unwrap_or(&0);
            output.push(TABLE[(a>>2) as usize] as char);output.push(TABLE[(((a&3)<<4)|(b>>4)) as usize] as char);
            output.push(if chunk.len()>1{TABLE[(((b&15)<<2)|(c>>6)) as usize] as char}else{'='});
            output.push(if chunk.len()>2{TABLE[(c&63) as usize] as char}else{'='});
        }
    }
    fn number(value:Option<u64>,output:&mut String) {if let Some(value)=value{write!(output,"{value}").unwrap();}else{output.push('-');}}
    buffer.clear();buffer.push_str("b06-record-v1\n");encoded(path,buffer);buffer.push('\n');encoded(&o.name,buffer);
    write!(buffer,"\n{}\n",o.kind()).unwrap();
    for value in [o.dev,o.ino,o.links,o.flags.map(u64::from)]{number(value,buffer);buffer.push('\n');}
    for (i,value) in o.masks.into_iter().enumerate(){if i>0{buffer.push(',');}write!(buffer,"{value}").unwrap();}
    write!(buffer,"\n{}\n",o.error).unwrap();
    for (i,value) in o.values.into_iter().enumerate(){if i>0{buffer.push(',');}number(value,buffer);}
    buffer.push('\n');
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
struct Options { root_fd:i32, session:String, dev:u64, ino:u64, maximum_depth:usize, maximum_queue:usize, metadata_policy:policy::Profile }
impl Options {
    fn parse(args:&[String]) -> Result<Self> {
        if args.len()!=8 {return Err("required_arguments");}
        let mut root_fd=None;let mut session=None;let mut dev=None;let mut ino=None;
        for pair in args.chunks_exact(2) {
            let value=&pair[1];
            match pair[0].as_str() {
                "--root-fd" if root_fd.is_none() && value=="3" =>root_fd=Some(3),
                "--session" if session.is_none()=>{
                    if value.len()!=36 || !value.bytes().enumerate().all(|(i,c)|if [8,13,18,23].contains(&i){c==b'-'}else{c.is_ascii_hexdigit()}){return Err("session");}
                    session=Some(value.clone());
                },
                "--expected-dev" if dev.is_none()=>dev=Some(Self::unsigned(value)?),
                "--expected-ino" if ino.is_none()=>ino=Some(Self::unsigned(value)?),
                _=>return Err("unknown_or_duplicate_argument"),
            }
        }
        let result=Self{root_fd:root_fd.ok_or("root_fd")?,session:session.ok_or("session")?,dev:dev.ok_or("dev")?,ino:ino.ok_or("ino")?,maximum_depth:64,maximum_queue:4096,metadata_policy:policy::Profile::Standard};
        if result.dev==0 || result.ino==0{return Err("identity");}Ok(result)
    }
    fn unsigned(value:&str)->Result<u64>{
        if value.is_empty() || (value.len()>1 && value.starts_with('0')) || !value.bytes().all(|c|c.is_ascii_digit()){return Err("unsigned");}
        value.parse().map_err(|_|"unsigned")
    }
}
#[cfg(b06_live_totals)]
mod profiling;
#[derive(Clone)]
struct Pending {path:Vec<u8>,dev:u64,ino:u64,depth:usize}
struct ObjectObservation { values:[Option<u64>;4],links:Option<u64>,flags:Option<u32>,edges:u64 }
struct Scanner {
    startup_sources:Option<String>,data_physical:Option<Identity>,
    options:Options,result:Option<result::Writer>,refresh:Option<result::RefreshBaseline>,refresh_fallback:Option<&'static str>,enumerated_directories:u64,entries:u64,counts:HashMap<&'static str,u64>,objects:HashMap<String,ObjectObservation>,unknown_object_identity:bool,directories:HashSet<String>,totals:[u64;4],object_totals:[u64;4],missing:[u64;4],digest:Digest,errors:u64,issued:u64,calls:u64,bulk_calls:u64,peak_queue:usize,peak_fds:usize,complete:bool,reason:&'static str,output_failed:bool,root_identity:Identity,start:Instant,startup:Resources,resource_support:bool,root_namespace:Vec<u8>,canonical_buffer:String,sequence:u64,terminal:bool,pending_rows:Vec<String>,pending_bytes:usize,last_flush:Instant,
}
impl Scanner {
    fn new(options:Options) -> Self {let start=Instant::now();let mut startup=Resources::default();let resource_support=unsafe{b06_resources(&mut startup)}==0;Self {options,result:None,refresh:None,refresh_fallback:None,enumerated_directories:0,startup_sources:None,data_physical:None,entries:0,counts:HashMap::new(),objects:HashMap::new(),unknown_object_identity:false,directories:HashSet::new(),totals:[0;4],object_totals:[0;4],missing:[0;4],digest:Digest::default(),errors:0,issued:0,calls:0,bulk_calls:0,peak_queue:0,peak_fds:0,complete:true,reason:"complete",output_failed:false,root_identity:Identity::default(),start,startup,resource_support,root_namespace:Vec::new(),canonical_buffer:String::with_capacity(16*1024),sequence:0,terminal:false,pending_rows:Vec::new(),pending_bytes:0,last_flush:Instant::now()}}
    fn emit(&mut self,kind:&str,mut pairs:Vec<(&str,String)>) {
        if cfg!(test) || self.output_failed || self.terminal {return;}
        pairs.push(("kind",quote(kind)));pairs.push(("schema",if self.startup_sources.is_some(){if cfg!(b06_classification_v4){"18".into()}else if cfg!(b06_adaptive_checkpoint){"16".into()}else if cfg!(b06_deep128){"14".into()}else if cfg!(b06_classification_v3){"12".into()}else if cfg!(b06_app_data){"10".into()}else if cfg!(b06_dense_names){"8".into()}else{"6".into()}}else if self.result.is_some(){if cfg!(b06_classification_v4){"17".into()}else if cfg!(b06_adaptive_checkpoint){"15".into()}else if cfg!(b06_deep128){"13".into()}else if cfg!(b06_classification_v3){"11".into()}else if cfg!(b06_app_data){"9".into()}else if cfg!(b06_dense_names){"7".into()}else{"5".into()}}else{"2".into()}));pairs.push(("session",quote(&self.options.session)));pairs.push(("seq",quote(&self.sequence.to_string())));
        self.sequence+=1;if kind=="summary"{self.terminal=true;}
        let line=json_map(pairs)+"\n";let mut offset=0;let begin=Instant::now();let bytes=line.as_bytes();let mut failed=bytes.len()>64*1024;
        while offset<bytes.len() && !failed {
            let count=unsafe{write(1,bytes.as_ptr().add(offset).cast(),bytes.len()-offset)};
            if count<0 {let error=errno();if error==4{continue;}if error==35{
                if begin.elapsed().as_secs()>=5 || unsafe{b06_cancelled()}!=0{failed=true;continue;}
                let mut descriptor=PollDescriptor{fd:1,events:4,revents:0};unsafe{poll(&mut descriptor,1,20);}continue;
            }failed=true;}else if count==0{failed=true;}else{offset+=count as usize;}
        }
        if failed{self.output_failed=true;self.complete=false;self.reason="output_closed";}
    }
    fn flush_rows(&mut self){
        if self.result.is_some(){return;}
        if self.pending_rows.is_empty(){return;}
        let rows=format!("[{}]",self.pending_rows.join(","));self.pending_rows.clear();self.pending_bytes=0;self.last_flush=Instant::now();
        self.emit("batch",vec![("rows",rows)]);
    }
    fn row(&mut self,o:&Observation,path:&[u8],parent:&[u8])->Result<()> {
        if let Some(store)=self.result.as_mut(){return store.accept(o,path,parent);}
        let row=json_map(observation_json(o,path,parent));
        if !self.pending_rows.is_empty() && (self.pending_rows.len()>=128 || self.pending_bytes+row.len()+1024>48*1024){self.flush_rows();}
        self.pending_bytes+=row.len()+1;self.pending_rows.push(row);
        if self.pending_rows.len()>=128 || self.pending_bytes+1024>=48*1024 || self.last_flush.elapsed().as_millis()>=100{self.flush_rows();}Ok(())
    }
    fn issue(&mut self,code:&'static str,error:i32) {
        #[cfg(b06_live_totals)] profiling::notice(self.result.as_ref().map(|s|s.startup_source()).unwrap_or(0),code,error);
        self.flush_rows();self.errors+=1;self.complete=false;if self.reason=="complete" {self.reason=code;}if self.issued<100 && self.sequence>0 {self.issued+=1;self.emit("issue",vec![("code",quote(code)),("errno",error.to_string())]);}}
    // Coverage gaps can precede the error which actually terminates traversal.
    // Keep their counts/notices, but never hide the terminal cause behind the
    // first skipped boundary (or the bounded100-notice publication window).
    fn failure(&mut self,code:&'static str,error:i32) {self.reason=code;self.issue(code,error);}
    fn identity(&mut self,fd:i32) -> Result<Identity> {
        #[cfg(b06_live_totals)] let _timer=profiling::measure(profiling::Stage::Identity);
        let mut value=Identity::default();self.calls+=1;if unsafe {if self.startup_sources.is_some(){b06_physical_identity(fd,&mut value)}else{b06_identity(fd,&mut value)}}!=0 {return Err("identity_failed");}Ok(value)}
    fn guarded(&self,i:&Identity) -> bool {i.local!=0 && i.dev==self.root_identity.dev && i.fsid0==self.root_identity.fsid0 && i.fsid1==self.root_identity.fsid1 && i.flags & (0x0080_0000|0x4000_0000)==0}
    fn stopped(&mut self) -> bool {if self.output_failed{return true;}if unsafe{b06_cancelled()}!=0{self.complete=false;self.reason="cancelled";return true;}false}
    fn accept(&mut self,o:&Observation,parent:&[u8]) -> Result<()> {
        #[cfg(b06_live_totals)] let _timer=profiling::measure(profiling::Stage::Admission);
        if o.name.is_empty(){self.issue("metadata_error",o.error as i32);return Ok(());}
        if self.result.is_none() && self.entries>=220_000{return Err("entry_limit");}
        if let Some(store)=self.result.as_mut(){
            let publish=store.begin_observation()?;let committed=store.committed();
            if publish {
                self.emit("progress",vec![("committed",quote(&committed.to_string()))]);
                #[cfg(b06_live_totals)] {
                    let elapsed=self.start.elapsed().as_nanos().min(u64::MAX as u128) as u64;
                    if profiling::prefix_due(elapsed) {
                        let mut fields=self.result.as_ref().ok_or("store_prefix")?.committed_totals();
                        fields.extend([("prefix_revision",if cfg!(b06_classification_v4){"5".into()}else if cfg!(b06_adaptive_checkpoint){"4".into()}else if cfg!(b06_classification_v3){"3".into()}else if cfg!(b06_checkpoint4096){"2".into()}else{"1".into()}),("elapsed_ns",quote(&elapsed.to_string())),("policy_revision",quote(self.options.metadata_policy.revision()))]);
                        self.emit("committed_totals",fields);
                    }
                }
            }
        }
        let mut path=parent.to_vec();if !path.is_empty(){path.push(47);}path.extend_from_slice(&o.name);if path.len()>8192{return Err("path_limit");}
        self.entries=self.entries.checked_add(1).ok_or("overflow")?;*self.counts.entry(o.kind()).or_insert(0)+=1;if self.result.is_some() {
            #[cfg(b06_stage_profile)] let _timer=profiling::measure(profiling::Stage::Digest);
            canonical_into(o,&path,&mut self.canonical_buffer);
            self.digest.add(self.canonical_buffer.as_bytes());
        }else{self.digest.add(&canonical(o,&path));}
        if o.error!=0 {self.issue(if o.error==11 {"materialization_denied"}else{"entry_error"},o.error as i32);}
        if o.dev.is_none() || o.ino.is_none() || o.object_type.is_none_or(|kind|kind==0) || o.flags.is_none() || o.links.is_none(){self.issue("missing_identity",0);}
        if o.kind()=="regular" {
            if self.refresh.is_some() && o.links!=Some(1) {return Err("refresh_shared_objects");}
            #[cfg(b06_stage_profile)] let _timer=profiling::measure(profiling::Stage::ObjectAccounting);
            let mut fresh=false;let mut changed=o.links==Some(0);
            if let Some((dev,ino))=o.dev.zip(o.ino){
                if let Some(store)=self.result.as_ref() {
                    let admission=store.object([dev,ino],catalog::ObjectFacts{values:o.values,links:o.links,flags:o.flags},o.error)?;
                    fresh=admission.fresh;changed|=admission.changed;
                }else{
                    let key=format!("{dev}:{ino}");
                    if let Some(previous)=self.objects.get_mut(&key){previous.edges+=1;changed|=previous.values!=o.values || previous.links!=o.links || previous.flags!=o.flags || previous.links.is_some_and(|links|previous.edges>links);}else{self.objects.insert(key,ObjectObservation{values:o.values,links:o.links,flags:o.flags,edges:1});fresh=true;}
                }
            }else{self.unknown_object_identity=true;}
            if changed{self.issue("object_changed",0);}
            for index in 0..4 {if let Some(value)=o.values[index].filter(|_|o.error==0){add_total(&mut self.totals[index],value)?;if fresh{add_total(&mut self.object_totals[index],value)?;}}else{self.missing[index]+=1;self.complete=false;if self.reason=="complete"{self.reason="missing_fields";}}}
        }
        {
            #[cfg(b06_stage_profile)] let _timer=profiling::measure(profiling::Stage::StoredRow);
            self.row(o,&path,parent)?;
        }
        Ok(())
    }
    fn open_pending(&mut self,root:i32,pending:&Pending) -> Result<Descriptor> {
        self.open_pending_observed(root,pending).map(|(directory,_)|directory)
    }
    fn open_pending_observed(&mut self,root:i32,pending:&Pending) -> Result<(Descriptor,Identity)> {
        #[cfg(b06_live_totals)] let _timer=profiling::measure(profiling::Stage::Open);
        let path=CString::new(if pending.path.is_empty(){b".".to_vec()}else{pending.path.clone()}).map_err(|_|"invalid_component")?;
        let fd=unsafe {b06_open_directory(root,path.as_ptr())};if fd<0{return Err("open_directory_failed");}let descriptor=Descriptor(fd);let identity=self.identity(fd)?;
        if !self.guarded(&identity) || identity.dev!=pending.dev || identity.ino!=pending.ino{return Err("directory_changed");}Ok((descriptor,identity))
    }
    fn receive(&mut self,o:&Observation,pending:&Pending,queue:&mut Vec<Pending>,head:usize) -> Result<()> {
        if self.stopped(){return Ok(());}
        // The consumer's depth limit counts the final filename too. Never emit
        // component 65 and then ask Swift to reject an otherwise valid stream.
        if pending.depth>=self.options.maximum_depth{self.issue("depth_limit",0);return Ok(());}
        self.accept(o,&pending.path)?;
        let mut absolute=self.root_namespace.clone();if !absolute.ends_with(b"/"){absolute.push(47);}
        if !pending.path.is_empty(){absolute.extend_from_slice(&pending.path);absolute.push(47);}absolute.extend_from_slice(&o.name);
        if policy::excludes_for(&absolute,o.kind()=="directory",self.options.metadata_policy){self.issue("policy_excluded",0);return Ok(());}
        if o.kind()=="directory" && o.error==0 {
            let boundary=o.mount!=Some(0) || o.dev!=Some(self.root_identity.dev) || o.ino.is_none() || o.flags.is_none_or(|f|f&(0x0080_0000|0x4000_0000)!=0);
            if boundary{self.issue("boundary_excluded",0);return Ok(());}
            // Keep the boundary directory's own metadata, but do not open its
            // children: their relative names would exceed the same limit.
            if pending.depth+1>=self.options.maximum_depth{self.issue("depth_limit",0);return Ok(());}
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
        let root=RootDescriptor(self.options.root_fd,self.startup_sources.is_none());
        let mut namespace_identity=Identity::default();
        if unsafe{b06_identity(root.0,&mut namespace_identity)}!=0 || namespace_identity.dev!=self.options.dev || namespace_identity.ino!=self.options.ino {return Err("root_identity_or_boundary");}
        self.root_identity=self.identity(root.0)?;
        if self.root_identity.mode & 0o170000 != 0o040000 || !self.guarded(&self.root_identity){return Err("root_identity_or_boundary");}
        let mut namespace=vec![0u8;1024];if unsafe{b06_root_path(root.0,namespace.as_mut_ptr().cast(),namespace.len())}!=0{return Err("root_namespace");}
        let path=CString::new(namespace.into_iter().take_while(|b|*b!=0).collect::<Vec<_>>()).map_err(|_|"root_namespace")?;
        self.check_namespace(&path)?;
        self.root_namespace=path.as_bytes().to_vec();
        if self.sequence==0 {
        let mut header=vec![("lane",quote("rust")),("policy_revision",quote(self.options.metadata_policy.revision())),("expected_dev",quote(&self.options.dev.to_string())),("expected_ino",quote(&self.options.ino.to_string())),("materialization_policy",quote("off")),("workers","1".into()),("worker_qos",quote("utility")),("common_mask",quote(&unsafe{b06_common_mask()}.to_string())),("directory_mask",quote(&unsafe{b06_directory_mask()}.to_string())),("file_mask",quote(&unsafe{b06_file_mask()}.to_string())),("profile",quote(if self.result.is_some(){if self.startup_sources.is_some(){result::STARTUP_REVISION}else{result::REVISION}}else{"core-v1"})),("scope_contract",quote("descriptor-anchored"))];
            #[cfg(b06_parallel_metadata)] if self.result.is_some(){header.push(("metadata_readers","2".into()));}
            #[cfg(b06_application_layouts)] if self.result.is_some(){header.push(("application_layout_revision","1".into()));}
            #[cfg(b06_stored_locations)] if self.result.is_some(){header.push(("stored_location_revision","1".into()));}
            #[cfg(b06_sorted_pages)] if self.result.is_some(){header.push(("sorted_page_revision","1".into()));}
            #[cfg(all(b06_sorted_pages,b06_largest_files))] if self.result.is_some(){header.push(("largest_files_revision","1".into()));}
            #[cfg(b06_chart_overview)] if self.result.is_some(){header.push(("chart_overview_revision","1".into()));}
            #[cfg(b06_purpose_journey)] if self.result.is_some(){header.push(("purpose_journey_revision","1".into()));}
            header.push(("incremental_refresh",self.refresh.is_some().to_string()));
            if let Some(reason)=self.refresh_fallback {header.push(("refresh_fallback",quote(reason)));}
            if let Some(sources)=&self.startup_sources {header.push(("sources",sources.clone()));}
            #[cfg(b06_live_totals)] if self.result.is_some(){
                header.push(("progress_revision",quote(if cfg!(b06_classification_v4){"committed-totals-data-v4"}else if cfg!(b06_adaptive_checkpoint){"committed-totals-adaptive-v1"}else if cfg!(b06_classification_v3){"committed-totals-classification-v3"}else if cfg!(b06_checkpoint4096){"committed-totals-4096-v1"}else{"committed-totals-v1"})));
                #[cfg(b06_checkpoint4096)] header.push(("checkpoint_rows",result::CHECKPOINT_ROWS.to_string()));
                #[cfg(b06_adaptive_checkpoint)] header.push(("checkpoint_revision","1".into()));
            }
            if cfg!(b06_classification_v3) && self.result.is_some(){header.push(("classification_revision",result::CLASSIFICATION_REVISION.to_string()));}
            #[cfg(b06_deep128)] if self.result.is_some(){header.push(("traversal_revision",quote("bounded-depth-v1")));header.push(("maximum_depth",result::MAX_DEPTH.to_string()));}
            self.emit("header",header);
        }
        if policy::excludes_for(path.as_bytes(),true,self.options.metadata_policy){self.issue("policy_excluded",0);return Ok(());}
        if let Some(store)=self.result.as_mut(){store.bind_root(self.root_identity.dev,self.root_identity.ino)?;return self.dfs_walk(root.0,&path);}
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
            self.check_namespace(&path)?;
            if self.last_flush.elapsed().as_millis()>=100{self.flush_rows();}
        }Ok(())
    }
    fn check_namespace(&mut self,path:&CString)->Result<()>{
        #[cfg(b06_live_totals)] let _timer=profiling::measure(profiling::Stage::Namespace);
        let check=unsafe{b06_open_root(path.as_ptr())};if check<0{return Err("root_replaced");}
        let check=Descriptor(check);self.peak_fds=self.peak_fds.max(3);let current=self.identity(check.0)?;
        if current.dev!=self.root_identity.dev || current.ino!=self.root_identity.ino || !self.guarded(&current){return Err("root_replaced");}Ok(())
    }
    fn finish(&mut self) {
        if self.sequence==0{return;}
        self.flush_rows();
        if self.startup_sources.is_some(){self.emit("phase",vec![("stage",quote("sealing"))]);}
        if let Some(store)=self.result.as_mut(){
            if let Err(error)=store.seal(self.reason=="cancelled",self.complete,&self.root_namespace){
                self.complete=false;self.reason=error;
            }
            if store.ready && self.complete && !store.complete {
                self.complete=false;self.reason=if unsafe{b06_cancelled()}!=0{"cancelled"}else{"classification_incomplete"};
            }
        }
        if self.startup_sources.is_some(){self.emit("phase",vec![("stage",quote("counting"))]);}
        let stored_counts=self.result.as_ref().map(|store|store.counts()).transpose();
        if stored_counts.is_err(){self.complete=false;self.reason="store_index";}
        let (objects,outside)=stored_counts.ok().flatten().unwrap_or_else(||(self.objects.len() as u64,
            self.objects.values().filter(|object|object.links.is_some_and(|links|links>object.edges)).count() as u64));
        let mut final_resources=Resources::default();let resources=self.resource_support && unsafe{b06_resources(&mut final_resources)}==0;
        let count=|key|self.counts.get(key).copied().unwrap_or(0);let mut summary=vec![("complete",self.complete.to_string()),("reason",quote(self.reason)),("entries",quote(&self.entries.to_string())),("regular_entries",quote(&count("regular").to_string())),("directory_entries",quote(&count("directory").to_string())),("symlink_entries",quote(&count("symlink").to_string())),("other_entries",quote(&(count("other")+count("unknown")).to_string())),("objects",quote(&objects.to_string())),("entry_totals",totals_json(&self.totals)),("object_totals",totals_json(&self.object_totals)),("missing_fields",totals_json(&self.missing)),("errors",quote(&self.errors.to_string())),("issues_emitted",quote(&self.issued.to_string())),("metadata_calls",quote(&self.calls.to_string())),("bulk_calls",quote(&self.bulk_calls.to_string())),("foundation_next_calls",quote("0")),("peak_queued_dirs",quote(&self.peak_queue.to_string())),("peak_owned_fds",quote(&self.peak_fds.to_string())),("elapsed_ns",quote(&self.start.elapsed().as_nanos().to_string())),("digest_xor",quote(&Digest::hex(&self.digest.xor))),("digest_sum",quote(&Digest::hex(&self.digest.sum))),("digest_count",quote(&self.entries.to_string())),("resource_metrics_state",quote(if resources{"returned"}else{"error"}))];
        summary.push(("refresh_reused_entries",quote(&self.refresh.as_ref().map_or(0,|v|v.reused).to_string())));
        summary.push(("refresh_reused_directories",quote(&self.refresh.as_ref().map_or(0,|v|v.reused_directories).to_string())));
        summary.push(("refresh_enumerated_directories",quote(&self.enumerated_directories.to_string())));
        summary.push(("object_accounting_state",quote(if self.unknown_object_identity{"unknown"}else if self.complete{"returned"}else{"partial"})));
        summary.push(("outside_link_objects",quote(&outside.to_string())));
        if let Some(store)=self.result.as_ref(){summary.push(("committed_entries",quote(&store.committed().to_string())));summary.push(("store_ready",store.ready.to_string()));}
        if resources {summary.extend([("startup_current_rss",quote(&self.startup.current_rss.to_string())),("peak_rss",quote(&final_resources.peak_rss.to_string())),("incremental_peak_rss",quote(&final_resources.peak_rss.saturating_sub(self.startup.current_rss).to_string())),("post_drain_rss",quote(&final_resources.current_rss.to_string())),("user_ns",quote(&final_resources.user_ns.saturating_sub(self.startup.user_ns).to_string())),("system_ns",quote(&final_resources.system_ns.saturating_sub(self.startup.system_ns).to_string()))]);}
        #[cfg(b06_live_totals)] summary.push(("stage_profile",profiling::summary()));
        #[cfg(b06_stage_profile)] summary.push(("admission_profile",profiling::admission_summary()));
        #[cfg(b06_sqlite_profile)] if let Some(store)=self.result.as_mut(){summary.push(("sqlite_profile",store.sqlite_profile()));}
        self.emit("summary",summary);
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
    std::panic::set_hook(Box::new(|_|eprintln!("worker_panic")));
    unsafe{signal(13,1);} // SIGPIPE ignored, output closure becomes an explicit outcome.
    unsafe{b06_install_cancellation();let flags=fcntl(1,3);if flags<0 || fcntl(1,4,flags|4)!=0{std::process::exit(74);}}
    let args=std::env::args().skip(1).collect::<Vec<_>>();if args==["--policy-self-test"]{match policy::self_test(){Ok(passed)=>{println!("{{\"kind\":\"policy_selftest\",\"schema\":2,\"passed\":{passed}}}");return;},Err(_)=>{eprintln!("policy_selftest_failed");std::process::exit(2);}}}
    #[cfg(all(b06_scoped_bindings,b06_binding_probe))]
    if args.len()==2 && args[0]=="--binding-component" {
        match result::binding_component(&args[1]) {Ok(value)=>{println!("{value}");return;},Err(code)=>{eprintln!("{code}");std::process::exit(2);}}
    }
    #[cfg(b06_qualification)]
    if args.first().map(String::as_str)==Some("--generated-result") {
        std::process::exit(if result::generated_stream(&args).is_ok(){0}else{2});
    }
    #[cfg(all(b06_qualification,b06_purpose_journey))]
    if args.first().map(String::as_str)==Some("--generated-purpose-v1") {
        match result::generated_purpose(&args){Ok(())=>return,Err(code)=>{eprintln!("purpose_fixture_{code}");std::process::exit(2);}}
    }
    #[cfg(all(b06_qualification,b06_classification_v3))]
    if args.first().map(String::as_str)==Some("--generated-classification-v3") {
        match result::generated_classification(&args){Ok(())=>return,Err(code)=>{eprintln!("classification_fixture_{code}");std::process::exit(2);}}
    }
    if args==["--self-test"]{if self_test().is_err(){eprintln!("selftest_failed");std::process::exit(2);}return;}
    if args.first().map(String::as_str)==Some("--startup-result") {
        std::process::exit(if std::thread::spawn(move||startup::run(&args)).join().unwrap_or(false){0}else{2});
    }
    if args.first().map(String::as_str)==Some("--read-result") {
        let code=match result::query_arguments(&args){Ok(())=>0,Err(_)=>{eprintln!("result_query_refused");2}};std::process::exit(code);
    }
    let refresh_requested=args.first().map(String::as_str)==Some("--refresh-result");
    let (store,args,metadata_policy)=if refresh_requested || args.first().map(String::as_str)==Some("--full-result") {
        let (metadata_policy,args)=match policy::Profile::arguments(&args){Ok(v)=>v,Err(_)=>std::process::exit(64)};
        if args.len()!=12 || args[2]!="--result-quota" {std::process::exit(64);}
        let quota=match Options::unsigned(&args[3]) {Ok(v) if (1<<20..=result::MAX_STORE_BYTES).contains(&v)=>v,_=>std::process::exit(64)};
        (Some((args[1].clone(),quota)),args[4..].to_vec(),metadata_policy)
    }else{(None,args,policy::Profile::Standard)};
    let mut options=match Options::parse(&args){Ok(o)=>o,Err(_)=>{eprintln!("invalid_admission_or_arguments");std::process::exit(64);}};
    options.metadata_policy=metadata_policy;
    if store.is_some(){options.maximum_depth=result::MAX_DEPTH;}
    // SQLite Rc/statement ownership is constructed on its final utility worker.
    // No unsafe Send implementation or cross-thread connection is needed.
    let complete=std::thread::spawn(move||{
        if unsafe{b06_set_utility_qos()}!=0{return false;}
        let mut scanner=Scanner::new(options);
        if let Some((path,quota))=store {
            match result::Writer::open(&path,quota,&scanner.options.session,metadata_policy) {
                Ok(store)=>scanner.result=Some(store),Err(_)=>{eprintln!("result_store_refused");return false;}
            }
        }
        if refresh_requested {
            if metadata_policy!=policy::Profile::Standard {scanner.refresh_fallback=Some("unsupported_scope");}
            else {match result::RefreshBaseline::open(scanner.options.dev,scanner.options.ino) {
                Ok(value)=>scanner.refresh=Some(value), Err(reason)=>scanner.refresh_fallback=Some(reason),
            }}
        }
        if let Err(error)=scanner.scan(){if let Some(store)=scanner.result.as_mut(){store.taint();}scanner.failure(error,errno());}
        scanner.finish();scanner.complete
    }).join().unwrap_or(false);
    std::process::exit(if complete{0}else{2});
}

#[cfg(test)]
mod scope_tests {
    use super::*;

    fn scanner() -> Scanner {
        let mut value=Scanner::new(Options{root_fd:-1,session:"00000000-0000-0000-0000-000000000000".into(),dev:1,ino:1,maximum_depth:64,maximum_queue:4096,metadata_policy:policy::Profile::Standard});
        value.root_identity=Identity{dev:1,local:1,..Identity::default()};
        value
    }
    #[test] fn terminal_failure_survives_earlier_coverage_gaps_and_notice_cap() {
        let mut value=scanner();
        value.sequence=1;
        for _ in 0..150 {value.issue("boundary_excluded",0);}
        value.failure("store_quota",27);
        assert_eq!(value.reason,"store_quota");assert_eq!(value.errors,151);
        assert_eq!(value.issued,100);assert!(!value.complete);
    }
    #[test] fn reused_bulk_buffer_never_reads_name_or_fields_from_dirty_tail() {
        // Only one packed record is returned. The remainder is deliberately
        // nonzero, as it may contain observations from a preceding directory.
        let mut bytes=Vec::new();
        for value in [48u32,0xa0000001,0,0,0,0,0,8,2] {bytes.extend(value.to_le_bytes());}
        bytes.extend([b'a',0]);bytes.resize(48,0);bytes.resize(256*1024,0xff);
        let (observed,length)=parse_record(&bytes,0,true).unwrap();
        assert_eq!(length,48);assert_eq!(observed.name,b"a");
        assert_eq!(observed.values,[None;4]);assert_eq!(observed.dev,None);
        // A reference into the old directory's tail is invalid even when its
        // bytes would form a valid NUL-terminated name in the backing buffer.
        bytes[28..32].copy_from_slice(&24i32.to_le_bytes());
        bytes[52..54].copy_from_slice(&[b'z',0]);
        assert_eq!(parse_record(&bytes,0,true).err(),Some("name_range"));
    }
    fn parent(depth:usize)->Pending {
        Pending{path:vec![b"d".as_slice();depth].join(&b'/'),dev:1,ino:1,depth}
    }
    fn observation(kind:u32)->Observation {
        Observation{name:b"item".to_vec(),masks:[0;5],dev:Some(1),ino:Some(2),links:Some(1),
            flags:Some(0),object_type:Some(kind),mount:Some(0),error:0,values:[Some(0);4]}
    }
    #[test]
    fn rejects_every_kind_beyond_stream_component_limit_before_emission() {
        for kind in [1,2,5,99,0] {
            let mut value=scanner();let mut queue=Vec::new();
            value.receive(&observation(kind),&parent(64),&mut queue,0).unwrap();
            assert_eq!(value.entries,0,"component 65 was emitted for kind {kind}");
            assert!(value.pending_rows.is_empty());assert!(queue.is_empty());
            assert!(!value.complete);assert_eq!(value.reason,"depth_limit");
        }
    }
    #[test]
    fn keeps_boundary_directory_but_does_not_open_its_unobserved_children() {
        let mut value=scanner();let mut queue=Vec::new();
        value.receive(&observation(2),&parent(63),&mut queue,0).unwrap();
        assert_eq!(value.entries,1);assert!(queue.is_empty());
        assert!(!value.complete);assert_eq!(value.reason,"depth_limit");
    }
    #[test]
    fn accepts_file_at_component_limit_and_directory_before_boundary() {
        let mut file=scanner();let mut queue=Vec::new();
        file.receive(&observation(1),&parent(63),&mut queue,0).unwrap();
        assert_eq!(file.entries,1);assert!(file.complete);assert!(queue.is_empty());
        let mut directory=scanner();
        directory.receive(&observation(2),&parent(62),&mut queue,0).unwrap();
        assert_eq!(directory.entries,1);assert!(directory.complete);
        assert_eq!(queue.len(),1);assert_eq!(queue[0].depth,63);
    }
    #[test]
    fn changed_hardlink_flags_make_accounting_partial() {
        let mut value=scanner();let mut first=observation(1);first.links=Some(2);
        value.accept(&first,b"").unwrap();
        first.name=b"second".to_vec();first.flags=Some(1);
        value.accept(&first,b"").unwrap();
        assert!(!value.complete);assert_eq!(value.reason,"object_changed");
        assert_eq!(value.objects.len(),1);assert_eq!(value.entries,2);
    }
    #[test]
    fn reusable_digest_buffer_matches_original_canonical_bytes() {
        let mut buffer=String::with_capacity(16*1024);
        for i in 0..512u64 {
            let mut o=observation(if i%3==0{2}else{1});
            o.name=vec![if i%2==0{255}else{97};(i as usize%255)+1];
            o.dev=Some(u64::MAX-i);o.ino=if i%2==0{None}else{Some(i)};
            o.links=Some(i);o.flags=Some(i as u32);o.error=(i%14) as u32;
            o.values=[Some(0),None,Some(u64::MAX),Some(i)];o.masks=[i as u32,u32::MAX,0,0,0];
            let mut path=b"parent/".to_vec();path.extend_from_slice(&o.name);
            canonical_into(&o,&path,&mut buffer);
            assert_eq!(buffer.as_bytes(),canonical(&o,&path));
            assert!(buffer.len()<=16*1024);
        }
    }
    #[test]
    fn zero_link_count_never_claims_complete_object_accounting() {
        let mut value=scanner();let mut first=observation(1);first.links=Some(0);
        value.accept(&first,b"").unwrap();
        assert!(!value.complete);assert_eq!(value.reason,"object_changed");
    }
    #[test]
    fn stable_hardlinks_and_outside_names_preserve_known_object_totals() {
        let mut value=scanner();let mut first=observation(1);first.links=Some(3);first.values=[Some(7);4];
        value.accept(&first,b"").unwrap();first.name=b"second".to_vec();
        value.accept(&first,b"").unwrap();
        assert!(value.complete);assert_eq!(value.objects.len(),1);
        assert_eq!(value.object_totals,[7;4]);assert_eq!(value.totals,[14;4]);
        assert_eq!(value.objects.values().filter(|object|object.links.is_some_and(|links|links>object.edges)).count(),1);
    }
}
