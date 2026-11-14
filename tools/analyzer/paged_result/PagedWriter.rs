//! Isolated writer placement. The scanner/guards are pinned from the DFS lane.
//! Existing fd4/fd5/fd6 authority belongs to the parent generated test session.
use super::{Observation,Result as ScanResult};
use std::ffi::{c_char,c_int,c_void,CString};
#[link(name="sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(path:*const c_char,db:*mut *mut c_void,flags:c_int,vfs:*const c_char)->c_int;
    fn sqlite3_close(db:*mut c_void)->c_int;
    fn sqlite3_exec(db:*mut c_void,sql:*const c_char,cb:*const c_void,arg:*mut c_void,err:*mut *mut c_char)->c_int;
    fn sqlite3_prepare_v2(db:*mut c_void,sql:*const c_char,size:c_int,stmt:*mut *mut c_void,tail:*mut *const c_char)->c_int;
    fn sqlite3_step(stmt:*mut c_void)->c_int;
    fn sqlite3_reset(stmt:*mut c_void)->c_int;
    fn sqlite3_clear_bindings(stmt:*mut c_void)->c_int;
    fn sqlite3_finalize(stmt:*mut c_void)->c_int;
    fn sqlite3_bind_int64(stmt:*mut c_void,index:c_int,value:i64)->c_int;
    fn sqlite3_bind_blob(stmt:*mut c_void,index:c_int,bytes:*const c_void,count:c_int,destructor:isize)->c_int;
    fn sqlite3_bind_null(stmt:*mut c_void,index:c_int)->c_int;
    fn sqlite3_busy_timeout(db:*mut c_void,milliseconds:c_int)->c_int;
    fn sqlite3_column_int64(stmt:*mut c_void,index:c_int)->i64;
    fn b06_store_check(path:*const c_char,parent:c_int,database:c_int,lease:c_int)->c_int;
    fn b06_sql_profile(database:*mut c_void)->c_int;
    fn b06_sql_stats(result:*mut SQLStats);
}
#[repr(C)]
#[derive(Default)]
struct SQLStats {statements:u64,commits:u64,profile_ns:u64,commit_ns:u64}
type Result<T>=std::result::Result<T,i32>;
fn check(code:i32)->Result<()> {if code==0 {Ok(())} else {Err(code)}}
struct Statement(*mut c_void);
impl Drop for Statement {fn drop(&mut self){unsafe{sqlite3_finalize(self.0);}}}
impl Statement {
    fn new(db:*mut c_void,sql:&str)->Result<Self> {
        let sql=CString::new(sql).map_err(|_|-1)?;let mut raw=std::ptr::null_mut();
        check(unsafe{sqlite3_prepare_v2(db,sql.as_ptr(),-1,&mut raw,std::ptr::null_mut())})?;Ok(Self(raw))
    }
    fn integer(&self,index:i32,value:i64)->Result<()> {check(unsafe{sqlite3_bind_int64(self.0,index,value)})}
    fn blob(&self,index:i32,value:Option<&[u8]>)->Result<()> {
        match value {Some(value)=>check(unsafe{sqlite3_bind_blob(self.0,index,value.as_ptr().cast(),value.len() as i32,-1)}),
            None=>check(unsafe{sqlite3_bind_null(self.0,index)})}
    }
    fn done(&self)->Result<()> {
        let code=unsafe{sqlite3_step(self.0)};if code!=101{return Err(code);}
        check(unsafe{sqlite3_reset(self.0)})?;check(unsafe{sqlite3_clear_bindings(self.0)})
    }
}
pub struct NodeWriter {
    db:*mut c_void,path:CString,insert:Option<Statement>,ancestors:Vec<(Vec<u8>,i64)>,
    pub count:i64,open:bool,rows:i64,aggregates:Option<DirectAggregates>,
}
// Only moved once into the scanner's owned worker, never concurrently shared.
unsafe impl Send for NodeWriter {}
impl Drop for NodeWriter {
    fn drop(&mut self) {
        if self.open {let _=self.exec("ROLLBACK");}
        self.insert.take();self.aggregates.take();unsafe{sqlite3_close(self.db);}
    }
}
impl NodeWriter {
    pub fn open(path:&str)->Result<Self> {
        let expected=std::env::current_dir().map_err(|_|-2)?.join(".build/b06-analyzer/paged-result-stores-20261018");
        if !std::path::Path::new(path).starts_with(expected) || path.contains("/../") || path.contains("/./") {return Err(-3);}
        let path=CString::new(path).map_err(|_|-4)?;
        if unsafe{b06_store_check(path.as_ptr(),4,5,6)}!=0{return Err(-5);}
        let mut db=std::ptr::null_mut();
        let code=unsafe{sqlite3_open_v2(path.as_ptr(),&mut db,2|0x01000000|0x00040000,std::ptr::null())};
        let mut value=Self{db,path,insert:None,ancestors:vec![(Vec::new(),0)],count:0,open:false,rows:128,aggregates:None};check(code)?;
        value.fresh()?;check(unsafe{sqlite3_busy_timeout(db,50)})?;check(unsafe{b06_sql_profile(db)})?;
        // Parent prepares the exact generated schema before either writer lane.
        value.exec("PRAGMA foreign_keys=ON;PRAGMA synchronous=FULL;PRAGMA cache_size=-1024;PRAGMA temp_store=MEMORY;PRAGMA max_page_count=6144")?;
        let statement=Statement::new(db,"SELECT count(*) FROM observations_v2")?;
        if unsafe{sqlite3_step(statement.0)}!=100 || unsafe{sqlite3_column_int64(statement.0,0)}!=1{return Err(-6);}
        let profile=Statement::new(db,"SELECT revision,aggregates,transaction_rows FROM profile WHERE id=1")?;
        if unsafe{sqlite3_step(profile.0)}!=100 || unsafe{sqlite3_column_int64(profile.0,0)}!=2{return Err(-13);}
        let aggregate=unsafe{sqlite3_column_int64(profile.0,1)};
        value.rows=unsafe{sqlite3_column_int64(profile.0,2)};
        if !(aggregate==0 || aggregate==1) || !(value.rows==128 || value.rows==1024){return Err(-14);}
        if aggregate==1 {value.aggregates=Some(DirectAggregates::new(db)?);}
        value.insert=Some(Statement::new(db,"INSERT INTO observations_v2 VALUES(?,?,?,?,?,?,?,?)")?);
        Ok(value)
    }
    fn fresh(&self)->Result<()> {if unsafe{b06_store_check(self.path.as_ptr(),4,5,6)}==0 {Ok(())} else {Err(-7)}}
    fn exec(&self,sql:&str)->Result<()> {
        let sql=CString::new(sql).map_err(|_|-8)?;
        check(unsafe{sqlite3_exec(self.db,sql.as_ptr(),std::ptr::null(),std::ptr::null_mut(),std::ptr::null_mut())})
    }
    pub fn accept(&mut self,o:&Observation,path:&[u8],parent:&[u8])->ScanResult<bool> {
        self.accept_checked(o,path,parent).map_err(|_|"store_write")
    }
    fn accept_checked(&mut self,o:&Observation,path:&[u8],parent:&[u8])->Result<bool> {
        if self.count>=220000 || path.is_empty() || path.len()>8192 || o.name.is_empty() || o.name.len()>255
            || o.name.contains(&0) || o.name.contains(&47) || o.name==b"." || o.name==b".." {return Err(-9);}
        let depth=path.split(|b|*b==47).count();if depth>64 {return Err(-10);}
        while self.ancestors.len()>1 && self.ancestors.last().unwrap().0!=parent {self.ancestors.pop();}
        if self.ancestors.last().unwrap().0!=parent {return Err(-11);}
        if let Some(direct)=self.aggregates.as_mut(){direct.leave(self.ancestors.last().unwrap().1)?;}
        if !self.open {self.fresh()?;self.exec("BEGIN IMMEDIATE")?;self.open=true;}
        let stmt=self.insert.as_ref().ok_or(-12)?;
        let kind=match o.kind(){"regular"=>0,"directory"=>1,"symlink"=>2,"other"=>3,_=>4};
        stmt.integer(1,self.count+1)?;stmt.integer(2,self.ancestors.last().unwrap().1)?;
        stmt.blob(3,Some(&o.name))?;stmt.integer(4,kind)?;
        let identity=if o.error==0 {o.dev.zip(o.ino).map(|(dev,ino)|[dev.to_be_bytes(),ino.to_be_bytes()].concat())} else {None};
        let links=if o.error==0 {o.links.map(u64::to_be_bytes)} else {None};
        let flags=if o.error==0 {o.flags.map(u32::to_be_bytes)} else {None};
        stmt.blob(5,identity.as_deref())?;stmt.blob(6,links.as_ref().map(|v|v.as_slice()))?;stmt.blob(7,flags.as_ref().map(|v|v.as_slice()))?;
        let bytes=payload(o);stmt.blob(8,Some(&bytes))?;stmt.done()?;self.count+=1;
        if let Some(direct)=self.aggregates.as_mut(){direct.accept(self.count,self.ancestors.last().unwrap().1,&o.name,kind as usize,&bytes,kind==1 && depth<64)?;}
        if kind==1 && depth<64 {self.ancestors.push((path.to_vec(),self.count));}
        if self.count%self.rows==0 {self.commit()?;return Ok(true);}Ok(false)
    }
    pub fn commit(&mut self)->Result<()> {
        if self.open {if let Some(direct)=self.aggregates.as_mut(){direct.flush()?;}self.fresh()?;self.exec("COMMIT")?;self.open=false;self.fresh()?;}Ok(())
    }
    pub fn rows(&self)->i64 {self.rows}
    pub fn direct(&self)->bool {self.aggregates.is_some()}
    pub fn statistics(&self)->[u64;4] {
        let mut value=SQLStats::default();unsafe{b06_sql_stats(&mut value);}
        [value.statements,value.commits,value.profile_ns,value.commit_ns]
    }
    pub fn bind_root(&self,device:u64,inode:u64)->Result<()> {
        self.fresh()?;
        let statement=Statement::new(self.db,"UPDATE observations_v2 SET identity=? WHERE id=0")?;
        let bytes=[device.to_be_bytes(),inode.to_be_bytes()].concat();statement.blob(1,Some(&bytes))?;statement.done()?;self.fresh()
    }
    pub fn terminal(&mut self,line:&str)->Result<()> {
        self.commit()?;self.fresh()?;
        let stmt=Statement::new(self.db,"UPDATE scan_state SET terminal=? WHERE id=1 AND state=0")?;
        stmt.blob(1,Some(line.trim_end().as_bytes()))?;stmt.done()?;self.fresh()
    }
}

#[derive(Clone)]
struct Frame {id:i64,total:[u8;140],files:[u8;140],dirty:bool}
struct DirectAggregates {
    frames:Vec<Frame>,types:[[u8;140];13],dirty_types:[bool;13],
    total:Statement,files:Statement,kind:Statement,marker:Statement,
}
fn number(bytes:&[u8],offset:usize)->u64 {u64::from_be_bytes(bytes[offset..offset+8].try_into().unwrap())}
fn put(bytes:&mut [u8],offset:usize,value:u64){bytes[offset..offset+8].copy_from_slice(&value.to_be_bytes());}
fn merge(target:&mut [u8;140],source:&[u8;140])->Result<()> {
    for offset in (0..40).step_by(8) {
        let value=number(target,offset).checked_add(number(source,offset)).filter(|v|*v<=220000).ok_or(-20)?;
        put(target,offset,value);
    }
    for metric in 0..4 {
        let offset=40+metric*25;
        let (sum,overflow)=number(target,offset).overflowing_add(number(source,offset));
        let overflow=overflow || target[offset+24]!=0 || source[offset+24]!=0;
        put(target,offset,if overflow{0}else{sum});target[offset+24]=u8::from(overflow);
        for support in [8,16] {
            let value=number(target,offset+support).checked_add(number(source,offset+support)).filter(|v|*v<=220000).ok_or(-21)?;
            put(target,offset+support,value);
        }
    }
    Ok(())
}
fn observation(kind:usize,payload:&[u8;52])->Result<[u8;140]> {
    if kind>=5{return Err(-22);}
    let mut value=[0u8;140];put(&mut value,kind*8,1);
    for metric in 0..4 {
        let source=metric*13;let target=40+metric*25;
        let bytes=number(payload,source+1);
        let error=u32::from_be_bytes(payload[source+9..source+13].try_into().unwrap());
        let state=payload[source];
        if state>2 || error>i32::MAX as u32 || (state!=1 && bytes!=0) || (state!=2 && error!=0){return Err(-23);}
        if kind==0 {match state {0=>put(&mut value,target+8,1),1=>put(&mut value,target,bytes),_=>put(&mut value,target+16,1)}}
    }
    Ok(value)
}
fn marker(name:&[u8],kind:usize)->Option<i64> {
    if kind==1{return if name==b".git"{Some(0)}else{None};}
    if kind!=0{return None;}
    match name {b"Package.swift"=>Some(1),b"Cargo.toml"=>Some(2),b"pubspec.yaml"=>Some(3),b"pyproject.toml"=>Some(4),b"package.json"=>Some(5),b"go.mod"=>Some(6),_=>None}
}
include!("TypeRules.rs");
pub fn vectors()->String {
    let mut returned=[0u8;52];let missing=[0u8;52];let mut failed=[0u8;52];
    for m in 0..4 {returned[m*13]=1;returned[m*13+1..m*13+9].copy_from_slice(&u64::MAX.to_be_bytes());failed[m*13]=2;failed[m*13+9..m*13+13].copy_from_slice(&13u32.to_be_bytes());}
    let mut total=observation(0,&returned).unwrap();
    let mut one=returned;for m in 0..4 {one[m*13+1..m*13+9].copy_from_slice(&1u64.to_be_bytes());}
    merge(&mut total,&observation(0,&one).unwrap()).unwrap();
    merge(&mut total,&observation(0,&missing).unwrap()).unwrap();merge(&mut total,&observation(0,&failed).unwrap()).unwrap();
    let types=[b"a.PDF".as_slice(),b"x.TXT",b"x.xlsx",b"x.key",b"x.png",b"x.MP4",b"x.flac",b"x.zip",b"x.dmg",b"x.qcow2",b"x.gguf",b"x.ttf",b".txt",b"a.",b"a.unknown",b"\xff_x.MP4"];
    let encoded:String=total.iter().map(|b|format!("{b:02x}")).collect();
    format!("{{\"value\":\"{}\",\"types\":{:?},\"malformed_refused\":{}}}",encoded,types.map(file_type),{let mut p=missing;p[0]=3;observation(0,&p).is_err()})
}
impl DirectAggregates {
    fn new(db:*mut c_void)->Result<Self> {
        Ok(Self{frames:vec![Frame{id:0,total:[0;140],files:[0;140],dirty:false}],types:[[0;140];13],dirty_types:[false;13],
            total:Statement::new(db,"INSERT INTO direct_totals VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=excluded.value")?,
            files:Statement::new(db,"INSERT INTO direct_files VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=excluded.value")?,
            kind:Statement::new(db,"INSERT INTO type_totals VALUES(?,?) ON CONFLICT(type) DO UPDATE SET value=excluded.value")?,
            marker:Statement::new(db,"INSERT INTO markers VALUES(?,?) ON CONFLICT(node) DO UPDATE SET marker=min(markers.marker,excluded.marker)")?})
    }
    fn store(stmt:&Statement,key:i64,value:&[u8;140])->Result<()> {stmt.integer(1,key)?;stmt.blob(2,Some(value))?;stmt.done()}
    fn persist(&mut self,index:usize)->Result<()> {
        let frame=&mut self.frames[index];if !frame.dirty{return Ok(());}
        Self::store(&self.total,frame.id,&frame.total)?;
        if number(&frame.files,0)>0 {Self::store(&self.files,frame.id,&frame.files)?;}
        frame.dirty=false;Ok(())
    }
    fn leave(&mut self,parent:i64)->Result<()> {
        while self.frames.len()>1 && self.frames.last().unwrap().id!=parent {self.persist(self.frames.len()-1)?;self.frames.pop();}
        if self.frames.last().unwrap().id!=parent{return Err(-24);}Ok(())
    }
    fn accept(&mut self,id:i64,parent:i64,name:&[u8],kind:usize,payload:&[u8;52],descend:bool)->Result<()> {
        let value=observation(kind,payload)?;let frame=self.frames.last_mut().ok_or(-25)?;
        if frame.id!=parent{return Err(-26);}
        merge(&mut frame.total,&value)?;frame.dirty=true;
        if kind==0 {merge(&mut frame.files,&value)?;let key=file_type(name);merge(&mut self.types[key],&value)?;self.dirty_types[key]=true;}
        if let Some(key)=marker(name,kind){self.marker.integer(1,parent)?;self.marker.integer(2,key)?;self.marker.done()?;}
        if descend {if self.frames.len()>=65{return Err(-27);}self.frames.push(Frame{id,total:[0;140],files:[0;140],dirty:false});}Ok(())
    }
    fn flush(&mut self)->Result<()> {
        for index in 0..self.frames.len(){self.persist(index)?;}
        for key in 0..13 {if self.dirty_types[key]{Self::store(&self.kind,key as i64,&self.types[key])?;self.dirty_types[key]=false;}}Ok(())
    }
}
fn payload(o:&Observation)->[u8;52] {
    let mut data=[0u8;52];
    for metric in 0..4 {
        let start=metric*13;
        if o.error!=0 {data[start]=2;data[start+9..start+13].copy_from_slice(&o.error.to_be_bytes());}
        else if let Some(value)=o.values[metric] {data[start]=1;data[start+1..start+9].copy_from_slice(&value.to_be_bytes());}
    }
    data
}
