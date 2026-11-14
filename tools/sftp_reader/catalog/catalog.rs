//! SFTP-only temporary metadata. UTF-8 identity and unknown fields stay exact.
//! All SQLite work belongs to one owner, never the native/UI executor.
use std::{ffi::{c_char,c_int,c_void,CString},sync::{Arc,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};

#[link(name="sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(p:*const c_char,db:*mut *mut c_void,flags:c_int,vfs:*const c_char)->c_int;
    fn sqlite3_close(db:*mut c_void)->c_int;
    fn sqlite3_exec(db:*mut c_void,sql:*const c_char,cb:*const c_void,arg:*mut c_void,error:*mut *mut c_char)->c_int;
    fn sqlite3_prepare_v2(db:*mut c_void,sql:*const c_char,n:c_int,s:*mut *mut c_void,tail:*mut *const c_char)->c_int;
    fn sqlite3_step(s:*mut c_void)->c_int;
    fn sqlite3_finalize(s:*mut c_void)->c_int;
    fn sqlite3_reset(s:*mut c_void)->c_int;
    fn sqlite3_clear_bindings(s:*mut c_void)->c_int;
    fn sqlite3_bind_int64(s:*mut c_void,n:c_int,v:i64)->c_int;
    fn sqlite3_bind_null(s:*mut c_void,n:c_int)->c_int;
    fn sqlite3_bind_blob(s:*mut c_void,n:c_int,v:*const c_void,count:c_int,drop:isize)->c_int;
    fn sqlite3_column_int64(s:*mut c_void,n:c_int)->i64;
    fn sqlite3_column_type(s:*mut c_void,n:c_int)->c_int;
    fn sqlite3_column_blob(s:*mut c_void,n:c_int)->*const u8;
    fn sqlite3_column_bytes(s:*mut c_void,n:c_int)->c_int;
    fn sqlite3_last_insert_rowid(db:*mut c_void)->i64;
    fn sqlite3_changes(db:*mut c_void)->c_int;
    fn sqlite3_get_autocommit(db:*mut c_void)->c_int;
    fn sqlite3_limit(db:*mut c_void,id:c_int,value:c_int)->c_int;
    fn sqlite3_busy_timeout(db:*mut c_void,ms:c_int)->c_int;
    fn sqlite3_progress_handler(db:*mut c_void,n:c_int,f:Option<unsafe extern "C" fn(*mut c_void)->c_int>,ctx:*mut c_void);
    // Same exact private descriptor/lease authority as SMB; no remote names or
    // paths are passed to this local boundary check.
    fn mex_smb_store_check(p:*const c_char,parent:c_int,database:c_int,lease:c_int,cap:u64,empty:c_int)->c_int;
}
pub const VERSION:i64=2;
pub const PAGE:usize=256;
pub const CHECKPOINT:usize=1024;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub enum Error{Invalid,Authority,SQLite(i32),Stale,Stopped,Incomplete,Duplicate}
pub type Result<T>=std::result::Result<T,Error>;
fn ok(n:i32)->Result<()>{if n==0{Ok(())}else{Err(Error::SQLite(n))}}
struct Statement(*mut c_void);
impl Drop for Statement{fn drop(&mut self){unsafe{sqlite3_finalize(self.0);}}}
impl Statement{
    fn new(db:*mut c_void,sql:&str)->Result<Self>{
        let sql=CString::new(sql).map_err(|_|Error::Invalid)?;let mut p=std::ptr::null_mut();
        let code=unsafe{sqlite3_prepare_v2(db,sql.as_ptr(),-1,&mut p,std::ptr::null_mut())};
        if code!=0{if !p.is_null(){unsafe{sqlite3_finalize(p);}}return Err(Error::SQLite(code))}Ok(Self(p))
    }
    fn int(&self,n:i32,v:i64)->Result<()>{ok(unsafe{sqlite3_bind_int64(self.0,n,v)})}
    fn optional_int(&self,n:i32,v:Option<u32>)->Result<()>{match v{Some(v)=>self.int(n,v as i64),None=>ok(unsafe{sqlite3_bind_null(self.0,n)})}}
    fn blob(&self,n:i32,v:&[u8])->Result<()>{ok(unsafe{sqlite3_bind_blob(self.0,n,v.as_ptr().cast(),v.len()as i32,-1)})}
    fn step(&self)->Result<bool>{match unsafe{sqlite3_step(self.0)}{100=>Ok(true),101=>Ok(false),n=>Err(Error::SQLite(n))}}
    fn done(&self)->Result<()>{if self.step()?{Err(Error::Invalid)}else{Ok(())}}
    fn reset(&self)->Result<()>{ok(unsafe{sqlite3_reset(self.0)})?;ok(unsafe{sqlite3_clear_bindings(self.0)})}
    fn number(&self,n:i32)->i64{unsafe{sqlite3_column_int64(self.0,n)}}
    fn optional_number(&self,n:i32)->Result<Option<u32>>{
        if unsafe{sqlite3_column_type(self.0,n)}==5{return Ok(None)}
        u32::try_from(self.number(n)).map(Some).map_err(|_|Error::Invalid)
    }
    fn bytes(&self,n:i32,cap:usize)->Result<Vec<u8>>{
        let size=unsafe{sqlite3_column_bytes(self.0,n)};if size<0||size as usize>cap{return Err(Error::Invalid)}
        if size==0{return Ok(Vec::new())}let p=unsafe{sqlite3_column_blob(self.0,n)};
        if p.is_null(){return Err(Error::Invalid)}Ok(unsafe{std::slice::from_raw_parts(p,size as usize)}.to_vec())
    }
}
#[derive(Debug,Clone,PartialEq,Eq)]pub struct Entry{pub name:String,pub size:Option<u64>,pub modified:Option<u32>,pub mode:Option<u32>}
#[derive(Debug,Clone,PartialEq,Eq)]pub struct Row{pub observation:i64,pub entry:Entry}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub enum State{Loading=0,Complete=1,Partial=2,Stopped=3}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub struct Snapshot{pub read:i64,pub revision:i64,pub count:i64,pub folders:i64,pub state:State}
/// A query over one committed directory revision. The user's text is kept only
/// in this owner and is deliberately omitted from Debug/log output.
#[derive(Clone)]pub struct Find{pub snapshot:Snapshot,pub count:i64,pub folders:i64,key:Vec<u8>}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub enum Sort{Name,Size,Modified}
impl Sort{fn order(self,descending:bool)->&'static str{match(self,descending){
    (Self::Name,false)=>"sort,name",(Self::Name,true)=>"sort DESC,name DESC",
    (Self::Size,false)=>"size,sort,name",(Self::Size,true)=>"size DESC,sort DESC,name DESC",
    (Self::Modified,false)=>"modified,sort,name",(Self::Modified,true)=>"modified DESC,sort DESC,name DESC",
}}}
fn valid_name(name:&str)->Result<()>{
    if name.is_empty()||name.len()>8192||name=="."||name==".."||name.contains(['\0','/']){Err(Error::Invalid)}else{Ok(())}
}
fn natural_key(name:&str)->Result<Vec<u8>>{
    valid_name(name)?;let lower=name.to_lowercase();let bytes=lower.as_bytes();let mut key=Vec::new();let mut i=0;
    while i<bytes.len(){
        if bytes[i].is_ascii_digit(){let start=i;while i<bytes.len()&&bytes[i].is_ascii_digit(){i+=1}
            let mut significant=start;while significant+1<i&&bytes[significant]==b'0'{significant+=1}
            key.push(1);key.extend(((i-significant)as u16).to_be_bytes());key.extend(&bytes[significant..i]);key.push(0);
        }else{key.push(bytes[i]);i+=1}if key.len()>32768{return Err(Error::Invalid)}
    }Ok(key)
}
fn search_key(value:&str,cap:usize)->Result<Vec<u8>>{
    let key=value.to_lowercase().into_bytes();
    if key.is_empty()||key.len()>cap{Err(Error::Invalid)}else{Ok(key)}
}
struct Progress{stop:Arc<AtomicBool>,deadline:Instant,
    #[cfg(sftp_catalog_qualification)]pause:Option<Arc<AtomicBool>>}
unsafe extern "C" fn progress(p:*mut c_void)->c_int{
    let p=unsafe{&*(p.cast::<Progress>())};
    #[cfg(sftp_catalog_qualification)]if let Some(entered)=p.pause.as_ref(){
        entered.store(true,Ordering::Release);while !p.stop.load(Ordering::Acquire)&&Instant::now()<p.deadline{std::thread::yield_now()}
    }
    i32::from(p.stop.load(Ordering::Acquire)||Instant::now()>p.deadline)
}
pub struct Catalog{
    db:*mut c_void,path:CString,parent:i32,file:i32,lease:i32,cap:u64,progress:Box<Progress>,
    transaction:bool,active:Option<i64>,pending:i64,pending_folders:i64,insert:Option<Statement>,
}
impl Drop for Catalog{fn drop(&mut self){
    if self.db.is_null(){return}unsafe{sqlite3_progress_handler(self.db,0,None,std::ptr::null_mut());}
    if self.transaction{let _=self.exec("ROLLBACK");}self.insert.take();unsafe{sqlite3_close(self.db);}
}}
impl Catalog{
    pub fn create(path:&str,parent:i32,file:i32,lease:i32,cap:u64,stop:Arc<AtomicBool>,fault_vfs:Option<&str>)->Result<Self>{
        if fault_vfs.is_some()&&!cfg!(sftp_catalog_qualification){return Err(Error::Invalid)}
        let path=CString::new(path).map_err(|_|Error::Invalid)?;
        if unsafe{mex_smb_store_check(path.as_ptr(),parent,file,lease,cap,1)}!=0{return Err(Error::Authority)}
        let vfs=fault_vfs.map(CString::new).transpose().map_err(|_|Error::Invalid)?;let mut db=std::ptr::null_mut();
        let code=unsafe{sqlite3_open_v2(path.as_ptr(),&mut db,2|0x01000000|0x00040000,vfs.as_ref().map_or(std::ptr::null(),|p|p.as_ptr()))};
        if code!=0{if !db.is_null(){unsafe{sqlite3_close(db);}}return Err(Error::SQLite(code))}
        let mut c=Self{db,path,parent,file,lease,cap,progress:Box::new(Progress{stop,deadline:Instant::now()+Duration::from_secs(2),
            #[cfg(sftp_catalog_qualification)]pause:None}),transaction:false,active:None,pending:0,pending_folders:0,insert:None};
        c.fresh()?;ok(unsafe{sqlite3_busy_timeout(db,100)})?;
        for(id,limit)in[(0,65536),(1,16384),(2,32),(3,32),(4,1),(7,0),(9,16)]{unsafe{sqlite3_limit(db,id,limit);}}
        let pages=(cap.saturating_sub(262144)*45/100/4096).max(64);
        c.exec(&format!("PRAGMA page_size=4096;PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;PRAGMA fullfsync=ON;\
            PRAGMA foreign_keys=ON;PRAGMA cache_size=-1024;PRAGMA mmap_size=0;PRAGMA temp_store=MEMORY;\
            PRAGMA trusted_schema=OFF;PRAGMA max_page_count={pages};PRAGMA application_id=1296386131;PRAGMA user_version={VERSION};\
            CREATE TABLE session(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,state INTEGER NOT NULL CHECK(state IN(0,1))) STRICT;\
            INSERT INTO session VALUES(1,{VERSION},0);\
            CREATE TABLE reads(id INTEGER PRIMARY KEY,generation BLOB NOT NULL UNIQUE CHECK(length(generation)=16),\
              path BLOB NOT NULL CHECK(length(path)>0 AND length(path)<=8192),revision INTEGER NOT NULL CHECK(revision>=0),\
              count INTEGER NOT NULL CHECK(count>=0),folders INTEGER NOT NULL CHECK(folders>=0 AND folders<=count),\
              state INTEGER NOT NULL CHECK(state IN(0,1,2,3))) STRICT;\
            CREATE TABLE items(id INTEGER PRIMARY KEY,read INTEGER NOT NULL REFERENCES reads(id),\
              name BLOB NOT NULL CHECK(length(name)>0 AND length(name)<=8192),sort BLOB NOT NULL CHECK(length(sort)<=32768),\
              search BLOB NOT NULL CHECK(length(search)>0 AND length(search)<=32768),\
              folder INTEGER NOT NULL CHECK(folder IN(0,1)),size BLOB CHECK(size IS NULL OR length(size)=8),\
              modified INTEGER CHECK(modified IS NULL OR modified BETWEEN 0 AND 4294967295),\
              mode INTEGER CHECK(mode IS NULL OR mode BETWEEN 0 AND 4294967295),UNIQUE(read,name)) STRICT;\
            CREATE INDEX names ON items(read,folder DESC,sort,name);CREATE INDEX sizes ON items(read,folder DESC,size,sort,name);\
            CREATE INDEX dates ON items(read,folder DESC,modified,sort,name);"))?;
        c.fresh()?;unsafe{sqlite3_progress_handler(db,1000,Some(progress),(&mut*c.progress as*mut Progress).cast());}
        c.insert=Some(Statement::new(db,"INSERT INTO items(read,name,sort,search,folder,size,modified,mode) VALUES(?,?,?,?,?,?,?,?)")?);Ok(c)
    }
    fn fresh(&self)->Result<()>{if unsafe{mex_smb_store_check(self.path.as_ptr(),self.parent,self.file,self.lease,self.cap,0)}!=0{Err(Error::Authority)}else{Ok(())}}
    fn begin_work(&mut self)->Result<()>{self.fresh()?;if self.progress.stop.load(Ordering::Acquire){return Err(Error::Stopped)}
        self.progress.deadline=Instant::now()+Duration::from_secs(2);Ok(())}
    fn exec(&self,sql:&str)->Result<()>{let s=CString::new(sql).map_err(|_|Error::Invalid)?;
        ok(unsafe{sqlite3_exec(self.db,s.as_ptr(),std::ptr::null(),std::ptr::null_mut(),std::ptr::null_mut())})}
    pub fn start(&mut self,generation:[u8;16],path:&str)->Result<Snapshot>{
        self.begin_work()?;if self.active.is_some()||generation==[0;16]||path.is_empty()||path.len()>8192||path.contains('\0'){return Err(Error::Invalid)}
        let s=Statement::new(self.db,"INSERT INTO reads VALUES(NULL,?,?,0,0,0,0)")?;
        s.blob(1,&generation)?;s.blob(2,path.as_bytes())?;s.done()?;let read=unsafe{sqlite3_last_insert_rowid(self.db)};
        self.fresh()?;self.active=Some(read);self.snapshot(read)
    }
    pub fn append(&mut self,entry:&Entry)->Result<bool>{
        if self.progress.stop.load(Ordering::Acquire){return Err(Error::Stopped)}let read=self.active.ok_or(Error::Invalid)?;
        let key=natural_key(&entry.name)?;let search=search_key(&entry.name,32768)?;
        if !self.transaction{self.begin_work()?;self.exec("BEGIN IMMEDIATE")?;self.transaction=true}
        let s=self.insert.as_ref().ok_or(Error::Invalid)?;s.int(1,read)?;s.blob(2,entry.name.as_bytes())?;s.blob(3,&key)?;s.blob(4,&search)?;
        let folder=entry.mode.is_some_and(|n|n&0xf000==0x4000);s.int(5,i64::from(folder))?;
        if let Some(size)=entry.size{s.blob(6,&size.to_be_bytes())?}else{ok(unsafe{sqlite3_bind_null(s.0,6)})?}
        s.optional_int(7,entry.modified)?;s.optional_int(8,entry.mode)?;
        let done=s.done();let reset=s.reset();if let Err(error)=done{
            if matches!(error,Error::SQLite(n)if n&255==19){return Err(Error::Duplicate)}return Err(error)
        }reset?;self.pending=self.pending.checked_add(1).ok_or(Error::Invalid)?;self.pending_folders+=i64::from(folder);
        if self.pending as usize>=CHECKPOINT{self.checkpoint()?;return Ok(true)}Ok(false)
    }
    pub fn checkpoint(&mut self)->Result<()>{
        self.begin_work()?;if !self.transaction{return Ok(())}
        let s=Statement::new(self.db,"UPDATE reads SET revision=revision+1,count=count+?,folders=folders+? WHERE id=? AND state=0")?;
        s.int(1,self.pending)?;s.int(2,self.pending_folders)?;s.int(3,self.active.ok_or(Error::Invalid)?)?;s.done()?;
        if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Invalid)}
        self.fresh()?;self.exec("COMMIT")?;self.transaction=false;self.pending=0;self.pending_folders=0;self.fresh()
    }
    pub fn finish(&mut self,state:State)->Result<Snapshot>{
        if state==State::Loading{return Err(Error::Invalid)}self.checkpoint()?;self.begin_work()?;let read=self.active.ok_or(Error::Invalid)?;
        let s=Statement::new(self.db,"UPDATE reads SET revision=revision+1,state=? WHERE id=? AND state=0")?;
        s.int(1,state as i64)?;s.int(2,read)?;s.done()?;if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Invalid)}
        self.fresh()?;self.active=None;self.snapshot(read)
    }
    pub fn snapshot(&mut self,read:i64)->Result<Snapshot>{
        self.begin_work()?;if self.transaction{return Err(Error::Incomplete)}
        let s=Statement::new(self.db,"SELECT revision,count,folders,state FROM reads WHERE id=?")?;s.int(1,read)?;
        if !s.step()?{return Err(Error::Invalid)}let revision=s.number(0);let count=s.number(1);let folders=s.number(2);
        let state=match s.number(3){0=>State::Loading,1=>State::Complete,2=>State::Partial,3=>State::Stopped,_=>return Err(Error::Invalid)};
        if s.step()?||revision<0||count<0||folders<0||folders>count{return Err(Error::Invalid)}self.fresh()?;Ok(Snapshot{read,revision,count,folders,state})
    }
    pub fn page(&mut self,snapshot:Snapshot,offset:i64,limit:usize,sort:Sort,descending:bool)->Result<Vec<Row>>{
        if offset<0||limit==0||limit>PAGE{return Err(Error::Invalid)}if self.snapshot(snapshot.read)?!=snapshot{return Err(Error::Stale)}
        let mut rows=Vec::with_capacity(limit);
        for folder in [1,0]{
            let base=if folder==1{0}else{snapshot.folders};let count=if folder==1{snapshot.folders}else{snapshot.count-snapshot.folders};
            let start=(offset-base).max(0);if start>=count||rows.len()==limit{continue}
            let sql=format!("SELECT id,name,size,modified,mode FROM items WHERE read=? AND folder=? ORDER BY {} LIMIT ? OFFSET ?",sort.order(descending));
            let s=Statement::new(self.db,&sql)?;s.int(1,snapshot.read)?;s.int(2,folder)?;s.int(3,(limit-rows.len())as i64)?;s.int(4,start)?;
            while s.step()?{if rows.len()>=limit{return Err(Error::Invalid)}rows.push(Self::row(&s)?);}
        }self.fresh()?;Ok(rows)
    }
    fn row(s:&Statement)->Result<Row>{
        let observation=s.number(0);if observation<=0{return Err(Error::Invalid)}
        let name=String::from_utf8(s.bytes(1,8192)?).map_err(|_|Error::Invalid)?;valid_name(&name)?;
        let size=if unsafe{sqlite3_column_type(s.0,2)}==5{None}else{
            Some(u64::from_be_bytes(s.bytes(2,8)?.try_into().map_err(|_|Error::Invalid)?))};
        Ok(Row{observation,entry:Entry{name,size,modified:s.optional_number(3)?,mode:s.optional_number(4)?}})
    }
    /// Count a literal Unicode-lowercase substring over a sealed committed
    /// prefix. The query is bound BLOB data, never SQL syntax or stored text.
    pub fn find(&mut self,snapshot:Snapshot,query:&str)->Result<Find>{
        if query.is_empty()||query.len()>2048||query.contains('\0'){return Err(Error::Invalid)}
        let key=search_key(query,8192)?;
        if self.snapshot(snapshot.read).map_err(|e|if e==Error::Invalid{Error::Stale}else{e})?!=snapshot{return Err(Error::Stale)}
        self.begin_work()?;let mut counts=[0i64;2];
        for (i,folder) in [1,0].into_iter().enumerate(){
            let s=Statement::new(self.db,"SELECT COUNT(*) FROM items WHERE read=? AND folder=? AND instr(search,?)>0")?;
            s.int(1,snapshot.read)?;s.int(2,folder)?;s.blob(3,&key)?;
            if !s.step()?{return Err(Error::Invalid)}counts[i]=s.number(0);
            if s.step()?||counts[i]<0{return Err(Error::Invalid)}
        }
        let count=counts[0].checked_add(counts[1]).ok_or(Error::Invalid)?;
        if counts[0]>snapshot.folders||count>snapshot.count{return Err(Error::Invalid)}
        self.fresh()?;Ok(Find{snapshot,count,folders:counts[0],key})
    }
    pub fn find_page(&mut self,find:&Find,offset:i64,limit:usize,sort:Sort,descending:bool)->Result<Vec<Row>>{
        if offset<0||limit==0||limit>PAGE{return Err(Error::Invalid)}
        let snapshot=find.snapshot;
        if self.snapshot(snapshot.read).map_err(|e|if e==Error::Invalid{Error::Stale}else{e})?!=snapshot{return Err(Error::Stale)}
        self.begin_work()?;let mut rows=Vec::with_capacity(limit);
        for folder in [1,0]{
            let base=if folder==1{0}else{find.folders};let count=if folder==1{find.folders}else{find.count-find.folders};
            let start=(offset-base).max(0);if start>=count||rows.len()==limit{continue}
            let sql=format!("SELECT id,name,size,modified,mode FROM items WHERE read=? AND folder=? AND instr(search,?)>0 ORDER BY {} LIMIT ? OFFSET ?",sort.order(descending));
            let s=Statement::new(self.db,&sql)?;s.int(1,snapshot.read)?;s.int(2,folder)?;s.blob(3,&find.key)?;
            s.int(4,(limit-rows.len())as i64)?;s.int(5,start)?;
            while s.step()?{if rows.len()>=limit{return Err(Error::Invalid)}rows.push(Self::row(&s)?);}
        }
        if rows.len() as i64!=((find.count-offset).max(0)).min(limit as i64){return Err(Error::Stale)}
        self.fresh()?;Ok(rows)
    }
    pub fn retire(&mut self,read:i64)->Result<()>{
        self.begin_work()?;if self.transaction||self.active.is_some()||self.snapshot(read)?.state==State::Loading{return Err(Error::Incomplete)}
        self.exec("BEGIN IMMEDIATE")?;self.transaction=true;
        let items=Statement::new(self.db,"DELETE FROM items WHERE read=?")?;items.int(1,read)?;items.done()?;
        let reads=Statement::new(self.db,"DELETE FROM reads WHERE id=?")?;reads.int(1,read)?;reads.done()?;
        if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Invalid)}self.fresh()?;self.exec("COMMIT")?;self.transaction=false;self.fresh()
    }
    /// Resolve exactly one committed selected row inside the active sealed
    /// directory. Remote names are bound SQL data, never local paths or SQL.
    #[cfg(feature="download-qualification")]
    pub fn selected_file(&mut self,snapshot:Snapshot,observation:i64)->Result<(String,Entry)>{
        if observation<=0||snapshot.state!=State::Complete||self.snapshot(snapshot.read)?!=snapshot{return Err(Error::Stale)}
        let s=Statement::new(self.db,"SELECT reads.path,items.name,items.size,items.modified,items.mode FROM items JOIN reads ON reads.id=items.read WHERE items.read=? AND items.id=?")?;
        s.int(1,snapshot.read)?;s.int(2,observation)?;if !s.step()?{return Err(Error::Stale)}
        let path=String::from_utf8(s.bytes(0,8192)?).map_err(|_|Error::Invalid)?;
        let name=String::from_utf8(s.bytes(1,8192)?).map_err(|_|Error::Invalid)?;valid_name(&name)?;
        let size=if unsafe{sqlite3_column_type(s.0,2)}==5{None}else{Some(u64::from_be_bytes(s.bytes(2,8)?.try_into().map_err(|_|Error::Invalid)?))};
        let entry=Entry{name,size,modified:s.optional_number(3)?,mode:s.optional_number(4)?};
        if s.step()?{return Err(Error::Invalid)}self.fresh()?;
        let full=format!("{}/{}",path.trim_end_matches('/'),entry.name);
        Ok((full,entry))
    }
    pub fn close(mut self)->Result<()>{
        self.begin_work()?;if self.transaction||self.active.is_some(){return Err(Error::Incomplete)}
        self.exec("UPDATE session SET state=1 WHERE id=1 AND state=0")?;self.fresh()?;self.close_sqlite()
    }
    fn close_sqlite(&mut self)->Result<()>{
        unsafe{sqlite3_progress_handler(self.db,0,None,std::ptr::null_mut());}
        if unsafe{sqlite3_get_autocommit(self.db)}==0{self.exec("ROLLBACK")?}self.transaction=false;self.insert.take();
        ok(unsafe{sqlite3_close(self.db)})?;self.db=std::ptr::null_mut();Ok(())
    }
    pub fn drain(mut self)->Result<()>{self.close_sqlite()}
    #[cfg(sftp_catalog_qualification)]pub fn small_cache(&mut self)->Result<()>{self.exec("PRAGMA cache_size=8")}
    #[cfg(sftp_catalog_qualification)]pub fn pause_query(&mut self,entered:Arc<AtomicBool>){self.progress.pause=Some(entered);}
    #[cfg(sftp_catalog_qualification)]pub fn resume_query(&mut self){self.progress.pause=None;}
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn exact_posix_names_allow_backslash_controls_and_distinct_unicode(){
        for n in ["Café","Cafe\u{301}","a\\b","new\nline","\u{202e}name"]{assert!(valid_name(n).is_ok())}
        for n in ["",".","..","a/b","a\0b"]{assert!(valid_name(n).is_err())}assert!(valid_name(&"a".repeat(8193)).is_err());
        assert_ne!("Café".as_bytes(),"Cafe\u{301}".as_bytes());
    }
    #[test]fn natural_sort_is_bounded_without_normalizing_identity(){
        assert!(natural_key("file 2").unwrap()<natural_key("file 10").unwrap());
        assert_eq!(natural_key("FILE 0002").unwrap(),natural_key("file 2").unwrap());
        assert!(natural_key(&"a1".repeat(4096)).unwrap().len()<=32768);
    }
}
