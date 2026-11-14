//! One-owner SMB filename/metadata catalog. No remote I/O, credentials or bodies.
//! The future worker and the generated qualifier include this exact module.
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
    fn sqlite3_bind_blob(s:*mut c_void,n:c_int,v:*const c_void,count:c_int,drop:isize)->c_int;
    fn sqlite3_column_int64(s:*mut c_void,n:c_int)->i64;
    fn sqlite3_column_blob(s:*mut c_void,n:c_int)->*const u8;
    fn sqlite3_column_bytes(s:*mut c_void,n:c_int)->c_int;
    fn sqlite3_last_insert_rowid(db:*mut c_void)->i64;
    fn sqlite3_changes(db:*mut c_void)->c_int;
    fn sqlite3_get_autocommit(db:*mut c_void)->c_int;
    fn sqlite3_limit(db:*mut c_void,id:c_int,value:c_int)->c_int;
    fn sqlite3_busy_timeout(db:*mut c_void,ms:c_int)->c_int;
    fn sqlite3_progress_handler(db:*mut c_void,n:c_int,f:Option<unsafe extern "C" fn(*mut c_void)->c_int>,ctx:*mut c_void);
    fn mex_smb_store_check(p:*const c_char,parent:c_int,database:c_int,lease:c_int,cap:u64,empty:c_int)->c_int;
}
pub const VERSION:i64=3;
pub const PAGE:usize=256;
pub const CHECKPOINT:usize=1024;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Error {Invalid,Authority,SQLite(i32),Stale,Stopped,Incomplete,Duplicate}
pub type Result<T>=std::result::Result<T,Error>;
fn ok(n:i32)->Result<()> {if n==0{Ok(())}else{Err(Error::SQLite(n))}}
struct Statement(*mut c_void);
impl Drop for Statement{fn drop(&mut self){unsafe{sqlite3_finalize(self.0);}}}
impl Statement {
    fn new(db:*mut c_void,sql:&str)->Result<Self> {
        let sql=CString::new(sql).map_err(|_|Error::Invalid)?;let mut p=std::ptr::null_mut();
        let code=unsafe{sqlite3_prepare_v2(db,sql.as_ptr(),-1,&mut p,std::ptr::null_mut())};
        if code!=0 {if !p.is_null(){unsafe{sqlite3_finalize(p);}}return Err(Error::SQLite(code));}
        Ok(Self(p))
    }
    fn int(&self,n:i32,v:i64)->Result<()> {ok(unsafe{sqlite3_bind_int64(self.0,n,v)})}
    fn blob(&self,n:i32,v:&[u8])->Result<()> {ok(unsafe{sqlite3_bind_blob(self.0,n,v.as_ptr().cast(),v.len() as i32,-1)})}
    fn step(&self)->Result<bool> {match unsafe{sqlite3_step(self.0)}{100=>Ok(true),101=>Ok(false),n=>Err(Error::SQLite(n))}}
    fn done(&self)->Result<()> {if self.step()?{Err(Error::Invalid)}else{Ok(())}}
    fn reset(&self)->Result<()> {ok(unsafe{sqlite3_reset(self.0)})?;ok(unsafe{sqlite3_clear_bindings(self.0)})}
    fn number(&self,n:i32)->i64 {unsafe{sqlite3_column_int64(self.0,n)}}
    fn bytes(&self,n:i32,cap:usize)->Result<Vec<u8>> {
        let size=unsafe{sqlite3_column_bytes(self.0,n)};
        if size<0 || size as usize>cap{return Err(Error::Invalid);}
        if size==0{return Ok(Vec::new());}
        let raw=unsafe{sqlite3_column_blob(self.0,n)};if raw.is_null(){return Err(Error::Invalid);}
        Ok(unsafe{std::slice::from_raw_parts(raw,size as usize)}.to_vec())
    }
}
#[derive(Debug,Clone,PartialEq,Eq)]
pub struct Row {pub observation:i64,pub wire:Vec<u16>,pub attributes:u32,pub size:u64,pub modified:u64,
    /// Class-37 filesystem ID, and the ID of the directory that enumerated it.
    /// Zero means the server gave no usable witness; neither is a handle ID.
    pub object:u64,pub parent:u64}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum State {Loading=0,Complete=1,Partial=2,Stopped=3}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub struct Snapshot {pub read:i64,pub revision:i64,pub count:i64,pub folders:i64,pub state:State}
/// One committed-prefix name query; user text is held only in this owner.
#[derive(Clone)]pub struct Find {pub snapshot:Snapshot,pub count:i64,pub folders:i64,key:Vec<u8>}
#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum Sort {Name,Size,Modified}
impl Sort {
    fn order(self,descending:bool)->&'static str {
        match(self,descending){
            (Self::Name,false)=>"sort,wire",(Self::Name,true)=>"sort DESC,wire DESC",
            (Self::Size,false)=>"size,sort,wire",(Self::Size,true)=>"size DESC,sort DESC,wire DESC",
            (Self::Modified,false)=>"modified,sort,wire",(Self::Modified,true)=>"modified DESC,sort DESC,wire DESC",
        }
    }
}
fn wire_bytes(name:&[u16])->Result<(Vec<u8>,Vec<u8>,Vec<u8>)> {
    if name.is_empty() || name.len()>2048{return Err(Error::Invalid);}
    let name_string=String::from_utf16(name).map_err(|_|Error::Invalid)?;
    if name_string.len()>4096 || name_string=="." || name_string==".." ||
        name_string.chars().any(|c|c=='/' || c=='\\' || c=='\0' || c.is_control()) {return Err(Error::Invalid);}
    let raw=name.iter().flat_map(|n|n.to_be_bytes()).collect();
    Ok((raw,natural_key(&name_string)?,search_key(&name_string,16384)?))
}
fn search_key(value:&str,cap:usize)->Result<Vec<u8>> {
    let key=value.to_lowercase().into_bytes();
    if key.is_empty()||key.len()>cap{Err(Error::Invalid)}else{Ok(key)}
}
/// Deterministic Unicode lowercase + ASCII numeric runs; not Finder locale order.
/// The raw UTF-16 blob breaks ties without normalizing distinct remote names.
fn natural_key(name:&str)->Result<Vec<u8>> {
    let lower=name.to_lowercase();let bytes=lower.as_bytes();let mut key=Vec::new();let mut i=0;
    while i<bytes.len() {
        if bytes[i].is_ascii_digit(){
            let start=i;while i<bytes.len() && bytes[i].is_ascii_digit(){i+=1;}
            let mut significant=start;while significant+1<i && bytes[significant]==b'0'{significant+=1;}
            let count=i-significant;key.push(1);key.extend((count as u16).to_be_bytes());key.extend(&bytes[significant..i]);key.push(0);
        }else{key.push(bytes[i]);i+=1;}
        if key.len()>12288{return Err(Error::Invalid);}
    }
    Ok(key)
}
struct Progress {stop:Arc<AtomicBool>,deadline:Instant,
    #[cfg(smb_catalog_qualification)] pause:Option<Arc<AtomicBool>>}
unsafe extern "C" fn progress(p:*mut c_void)->c_int {
    let p=unsafe{&*(p.cast::<Progress>())};
    #[cfg(smb_catalog_qualification)]
    if let Some(entered)=p.pause.as_ref(){
        entered.store(true,Ordering::Release);
        while !p.stop.load(Ordering::Acquire) && Instant::now()<p.deadline {std::thread::yield_now();}
    }
    i32::from(p.stop.load(Ordering::Acquire) || Instant::now()>p.deadline)
}
pub struct Catalog {
    db:*mut c_void,path:CString,parent:i32,file:i32,lease:i32,cap:u64,
    progress:Box<Progress>,transaction:bool,active:Option<i64>,pending:i64,pending_folders:i64,insert:Option<Statement>,
}
impl Drop for Catalog {
    fn drop(&mut self){
        if self.db.is_null(){return;}
        unsafe{sqlite3_progress_handler(self.db,0,None,std::ptr::null_mut());}
        if self.transaction{let _=self.exec("ROLLBACK");}
        self.insert.take();unsafe{sqlite3_close(self.db);}
    }
}
impl Catalog {
    /// The caller retains all three descriptors until this owner is closed.
    /// Existing or interrupted stores are never recovered implicitly here.
    pub fn create(path:&str,parent:i32,file:i32,lease:i32,cap:u64,stop:Arc<AtomicBool>,fault_vfs:Option<&str>)->Result<Self> {
        if fault_vfs.is_some() && !cfg!(smb_catalog_qualification){return Err(Error::Invalid);}
        let path=CString::new(path).map_err(|_|Error::Invalid)?;
        if unsafe{mex_smb_store_check(path.as_ptr(),parent,file,lease,cap,1)}!=0{return Err(Error::Authority);}
        let vfs=fault_vfs.map(CString::new).transpose().map_err(|_|Error::Invalid)?;let mut db=std::ptr::null_mut();
        let code=unsafe{sqlite3_open_v2(path.as_ptr(),&mut db,2|0x01000000|0x00040000,vfs.as_ref().map_or(std::ptr::null(),|s|s.as_ptr()))};
        if code!=0{if !db.is_null(){unsafe{sqlite3_close(db);}}return Err(Error::SQLite(code));}
        let mut value=Self{db,path,parent,file,lease,cap,progress:Box::new(Progress{stop,deadline:Instant::now()+Duration::from_secs(2),
            #[cfg(smb_catalog_qualification)] pause:None}),
            transaction:false,active:None,pending:0,pending_folders:0,insert:None};
        value.fresh()?;ok(unsafe{sqlite3_busy_timeout(db,100)})?;
        for (id,limit) in [(0,65536),(1,16384),(2,32),(3,32),(4,1),(7,0),(9,16)]{unsafe{sqlite3_limit(db,id,limit);}}
        // Reserve more than half the session quota for rollback growth/metadata.
        let pages=(cap.saturating_sub(262144)*45/100/4096).max(64);
        value.exec(&format!("PRAGMA page_size=4096;PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;PRAGMA fullfsync=ON;\
            PRAGMA foreign_keys=ON;PRAGMA cache_size=-1024;PRAGMA mmap_size=0;PRAGMA temp_store=MEMORY;\
            PRAGMA trusted_schema=OFF;PRAGMA max_page_count={pages};PRAGMA application_id=1296386130;PRAGMA user_version={VERSION};\
            CREATE TABLE session(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,state INTEGER NOT NULL CHECK(state IN(0,1))) STRICT;\
            INSERT INTO session VALUES(1,{VERSION},0);\
            CREATE TABLE reads(id INTEGER PRIMARY KEY,generation BLOB NOT NULL UNIQUE CHECK(length(generation)=16),\
              path BLOB NOT NULL CHECK(length(path)<=8192),parent BLOB NOT NULL CHECK(length(parent)=8),revision INTEGER NOT NULL CHECK(revision>=0),\
              count INTEGER NOT NULL CHECK(count>=0),folders INTEGER NOT NULL CHECK(folders>=0 AND folders<=count),\
              state INTEGER NOT NULL CHECK(state IN(0,1,2,3))) STRICT;\
            CREATE TABLE items(id INTEGER PRIMARY KEY,read INTEGER NOT NULL REFERENCES reads(id),\
              wire BLOB NOT NULL CHECK(length(wire)>0 AND length(wire)<=4096 AND length(wire)%2=0),\
              sort BLOB NOT NULL CHECK(length(sort)<=12288),search BLOB NOT NULL CHECK(length(search)>0 AND length(search)<=16384),\
              folder INTEGER NOT NULL CHECK(folder IN(0,1)),\
              attributes INTEGER NOT NULL CHECK(attributes>=0 AND attributes<=4294967295),\
              size INTEGER NOT NULL CHECK(size>=0),modified INTEGER NOT NULL CHECK(modified>=0),\
              object BLOB NOT NULL CHECK(length(object)=8),UNIQUE(read,wire)) STRICT;\
            CREATE INDEX names ON items(read,folder DESC,sort,wire);\
            CREATE INDEX sizes ON items(read,folder DESC,size,sort,wire);\
            CREATE INDEX dates ON items(read,folder DESC,modified,sort,wire);"))?;
        value.fresh()?;value.install_progress();
        value.insert=Some(Statement::new(db,"INSERT INTO items(read,wire,sort,search,folder,attributes,size,modified,object) VALUES(?,?,?,?,?,?,?,?,?)")?);
        Ok(value)
    }
    fn install_progress(&mut self){unsafe{sqlite3_progress_handler(self.db,1000,Some(progress),(&mut *self.progress as *mut Progress).cast());}}
    fn fresh(&self)->Result<()> {
        if unsafe{mex_smb_store_check(self.path.as_ptr(),self.parent,self.file,self.lease,self.cap,0)}!=0{Err(Error::Authority)}else{Ok(())}
    }
    fn begin_work(&mut self)->Result<()> {
        self.fresh()?;if self.progress.stop.load(Ordering::Acquire){return Err(Error::Stopped);}
        self.progress.deadline=Instant::now()+Duration::from_secs(2);Ok(())
    }
    fn exec(&self,sql:&str)->Result<()> {
        let sql=CString::new(sql).map_err(|_|Error::Invalid)?;
        ok(unsafe{sqlite3_exec(self.db,sql.as_ptr(),std::ptr::null(),std::ptr::null_mut(),std::ptr::null_mut())})
    }
    pub fn start(&mut self,generation:[u8;16],path:&[u16])->Result<Snapshot> {
        self.begin_work()?;
        if self.active.is_some() || generation==[0;16] || path.len()>4096{return Err(Error::Invalid);}
        // A path is already typed into separate admitted components by the protocol.
        let raw:Vec<_>=path.iter().flat_map(|n|n.to_be_bytes()).collect();
        let stmt=Statement::new(self.db,"INSERT INTO reads VALUES(NULL,?,?,?,0,0,0,0)")?;
        stmt.blob(1,&generation)?;stmt.blob(2,&raw)?;stmt.blob(3,&0u64.to_be_bytes())?;stmt.done()?;
        let read=unsafe{sqlite3_last_insert_rowid(self.db)};self.fresh()?;self.active=Some(read);
        self.snapshot(read)
    }
    /// The only parent witness accepted is the class-37 `.` entry returned by
    /// this same directory enumeration. Missing or unusable IDs leave actions
    /// unavailable without affecting metadata browsing.
    pub fn observe_parent(&mut self,index:u64)->Result<()> {
        self.begin_work()?;
        if index==0||index==u64::MAX{return Err(Error::Invalid);}
        let read=self.active.ok_or(Error::Invalid)?;
        if !self.transaction{self.exec("BEGIN IMMEDIATE")?;self.transaction=true;}
        let stmt=Statement::new(self.db,"UPDATE reads SET parent=? WHERE id=? AND parent=? AND state=0")?;
        stmt.blob(1,&index.to_be_bytes())?;stmt.int(2,read)?;stmt.blob(3,&0u64.to_be_bytes())?;stmt.done()?;
        if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Duplicate);}Ok(())
    }
    pub fn append(&mut self,wire:&[u16],attributes:u32,size:u64,modified:u64)->Result<bool> {
        self.append_with_identity(wire,attributes,size,modified,0)
    }
    pub fn append_with_identity(&mut self,wire:&[u16],attributes:u32,size:u64,modified:u64,object:u64)->Result<bool> {
        if self.progress.stop.load(Ordering::Acquire){return Err(Error::Stopped);}
        let read=self.active.ok_or(Error::Invalid)?;
        if size>i64::MAX as u64 || modified>i64::MAX as u64 || object==u64::MAX{return Err(Error::Invalid);}
        let (raw,key,search)=wire_bytes(wire)?;
        if !self.transaction{self.begin_work()?;self.exec("BEGIN IMMEDIATE")?;self.transaction=true;}
        let stmt=self.insert.as_ref().ok_or(Error::Invalid)?;
        stmt.int(1,read)?;stmt.blob(2,&raw)?;stmt.blob(3,&key)?;stmt.blob(4,&search)?;stmt.int(5,i64::from(attributes&16!=0))?;
        stmt.int(6,attributes as i64)?;stmt.int(7,size as i64)?;stmt.int(8,modified as i64)?;stmt.blob(9,&object.to_be_bytes())?;
        let done=stmt.done();let reset=stmt.reset();
        if let Err(error)=done {
            if matches!(error,Error::SQLite(code) if code&255==19){return Err(Error::Duplicate);}
            return Err(error);
        }
        reset?;self.pending=self.pending.checked_add(1).ok_or(Error::Invalid)?;
        if attributes&16!=0{self.pending_folders+=1;}
        if self.pending as usize>=CHECKPOINT {self.checkpoint()?;return Ok(true);}Ok(false)
    }
    pub fn checkpoint(&mut self)->Result<()> {
        self.begin_work()?;
        if !self.transaction{return Ok(());}
        let stmt=Statement::new(self.db,"UPDATE reads SET revision=revision+1,count=count+?,folders=folders+? WHERE id=? AND state=0")?;
        stmt.int(1,self.pending)?;stmt.int(2,self.pending_folders)?;stmt.int(3,self.active.ok_or(Error::Invalid)?)?;stmt.done()?;
        if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Invalid);}
        self.fresh()?;self.exec("COMMIT")?;self.transaction=false;self.pending=0;self.pending_folders=0;self.fresh()
    }
    /// Finish only after a genuine remote EOF, or mark Partial/Stopped explicitly.
    /// On failed SQLite work drop this owner: a rollback retains only its prefix.
    pub fn finish(&mut self,state:State)->Result<Snapshot> {
        if state==State::Loading{return Err(Error::Invalid);}self.checkpoint()?;self.begin_work()?;
        let read=self.active.ok_or(Error::Invalid)?;
        let stmt=Statement::new(self.db,"UPDATE reads SET revision=revision+1,state=? WHERE id=? AND state=0")?;
        stmt.int(1,state as i64)?;stmt.int(2,read)?;stmt.done()?;
        if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Invalid);}self.fresh()?;self.active=None;self.snapshot(read)
    }
    pub fn snapshot(&mut self,read:i64)->Result<Snapshot> {
        self.begin_work()?;
        if self.transaction{return Err(Error::Incomplete);}
        let stmt=Statement::new(self.db,"SELECT revision,count,folders,state FROM reads WHERE id=?")?;stmt.int(1,read)?;
        if !stmt.step()?{return Err(Error::Invalid);}let revision=stmt.number(0);let count=stmt.number(1);
        let folders=stmt.number(2);
        let state=match stmt.number(3){0=>State::Loading,1=>State::Complete,2=>State::Partial,3=>State::Stopped,_=>return Err(Error::Invalid)};
        if stmt.step()? || revision<0 || count<0 || folders<0 || folders>count{return Err(Error::Invalid);}
        self.fresh()?;Ok(Snapshot{read,revision,count,folders,state})
    }
    pub fn page(&mut self,snapshot:Snapshot,offset:i64,limit:usize,sort:Sort,descending:bool)->Result<Vec<Row>> {
        if offset<0 || limit==0 || limit>PAGE{return Err(Error::Invalid);}
        if self.snapshot(snapshot.read)?!=snapshot{return Err(Error::Stale);}
        let parent=self.parent(snapshot.read)?;
        let mut rows=Vec::with_capacity(limit);
        // Fix folder to one equality per range: both directions then use the
        // same persisted index, avoiding an unbounded temporary ORDER BY sort.
        for folder in [1,0] {
            let base=if folder==1{0}else{snapshot.folders};
            let count=if folder==1{snapshot.folders}else{snapshot.count-snapshot.folders};
            let start=(offset-base).max(0);if start>=count || rows.len()==limit{continue;}
            let sql=format!("SELECT id,wire,attributes,size,modified,object FROM items WHERE read=? AND folder=? ORDER BY {} LIMIT ? OFFSET ?",sort.order(descending));
            let stmt=Statement::new(self.db,&sql)?;stmt.int(1,snapshot.read)?;stmt.int(2,folder)?;
            stmt.int(3,(limit-rows.len()) as i64)?;stmt.int(4,start)?;
            while stmt.step()? {if rows.len()>=limit{return Err(Error::Invalid);}rows.push(Self::row(&stmt,parent)?);}
        }
        self.fresh()?;Ok(rows)
    }
    fn row(stmt:&Statement,parent:u64)->Result<Row>{
        let raw=stmt.bytes(1,4096)?;
        if raw.is_empty() || raw.len()%2!=0{return Err(Error::Invalid);}
        let wire:Vec<_>=raw.chunks_exact(2).map(|n|u16::from_be_bytes([n[0],n[1]])).collect();wire_bytes(&wire)?;
        let observation=stmt.number(0);let attributes=stmt.number(2);let size=stmt.number(3);let modified=stmt.number(4);
        if observation<=0 || attributes<0 || attributes>u32::MAX as i64 || size<0 || modified<0{return Err(Error::Invalid);}
        let object=Self::id_blob(stmt,5)?;
        Ok(Row{observation,wire,attributes:attributes as u32,size:size as u64,modified:modified as u64,object,parent})
    }
    pub fn find(&mut self,snapshot:Snapshot,query:&str)->Result<Find>{
        if query.is_empty()||query.len()>2048||query.contains('\0'){return Err(Error::Invalid);}
        let key=search_key(query,8192)?;
        if self.snapshot(snapshot.read).map_err(|e|if e==Error::Invalid{Error::Stale}else{e})?!=snapshot{return Err(Error::Stale);}
        self.begin_work()?;let mut counts=[0i64;2];
        for (i,folder) in [1,0].into_iter().enumerate(){
            let stmt=Statement::new(self.db,"SELECT COUNT(*) FROM items WHERE read=? AND folder=? AND instr(search,?)>0")?;
            stmt.int(1,snapshot.read)?;stmt.int(2,folder)?;stmt.blob(3,&key)?;
            if !stmt.step()?{return Err(Error::Invalid);}counts[i]=stmt.number(0);
            if stmt.step()?||counts[i]<0{return Err(Error::Invalid);}
        }
        let count=counts[0].checked_add(counts[1]).ok_or(Error::Invalid)?;
        if counts[0]>snapshot.folders||count>snapshot.count{return Err(Error::Invalid);}
        self.fresh()?;Ok(Find{snapshot,count,folders:counts[0],key})
    }
    pub fn find_page(&mut self,find:&Find,offset:i64,limit:usize,sort:Sort,descending:bool)->Result<Vec<Row>>{
        if offset<0||limit==0||limit>PAGE{return Err(Error::Invalid);}
        let snapshot=find.snapshot;
        if self.snapshot(snapshot.read).map_err(|e|if e==Error::Invalid{Error::Stale}else{e})?!=snapshot{return Err(Error::Stale);}
        self.begin_work()?;let parent=self.parent(snapshot.read)?;let mut rows=Vec::with_capacity(limit);
        for folder in [1,0]{
            let base=if folder==1{0}else{find.folders};let count=if folder==1{find.folders}else{find.count-find.folders};
            let start=(offset-base).max(0);if start>=count||rows.len()==limit{continue;}
            let sql=format!("SELECT id,wire,attributes,size,modified,object FROM items WHERE read=? AND folder=? AND instr(search,?)>0 ORDER BY {} LIMIT ? OFFSET ?",sort.order(descending));
            let stmt=Statement::new(self.db,&sql)?;stmt.int(1,snapshot.read)?;stmt.int(2,folder)?;stmt.blob(3,&find.key)?;
            stmt.int(4,(limit-rows.len())as i64)?;stmt.int(5,start)?;
            while stmt.step()?{if rows.len()>=limit{return Err(Error::Invalid);}rows.push(Self::row(&stmt,parent)?);}
        }
        if rows.len() as i64!=((find.count-offset).max(0)).min(limit as i64){return Err(Error::Stale);}
        self.fresh()?;Ok(rows)
    }
    fn id_blob(stmt:&Statement,column:i32)->Result<u64>{
        let bytes=stmt.bytes(column,8)?;if bytes.len()!=8{return Err(Error::Invalid);}
        let id=u64::from_be_bytes(bytes.try_into().map_err(|_|Error::Invalid)?);
        if id==u64::MAX{return Err(Error::Invalid);}Ok(id)
    }
    fn parent(&mut self,read:i64)->Result<u64>{
        let stmt=Statement::new(self.db,"SELECT parent FROM reads WHERE id=?")?;stmt.int(1,read)?;
        if !stmt.step()?{return Err(Error::Invalid);}let parent=Self::id_blob(&stmt,0)?;
        if stmt.step()?{return Err(Error::Invalid);}Ok(parent)
    }
    pub fn close(mut self)->Result<()> {
        self.begin_work()?;if self.transaction || self.active.is_some(){return Err(Error::Incomplete);}
        self.exec("UPDATE session SET state=1 WHERE id=1 AND state=0")?;self.fresh()?;
        self.insert.take();unsafe{sqlite3_progress_handler(self.db,0,None,std::ptr::null_mut());}
        let code=unsafe{sqlite3_close(self.db)};if code!=0{return Err(Error::SQLite(code));}
        self.db=std::ptr::null_mut();Ok(())
    }
    /// A browser tab retains only its current directory result. Back/Forward
    /// admits a new read; retired observations never become file authority.
    /// Reuse SQLite's freelist without replacing the parent-held database.
    pub fn retire(&mut self,read:i64)->Result<()> {
        self.begin_work()?;
        if self.transaction || self.active.is_some() || self.snapshot(read)?.state==State::Loading{return Err(Error::Incomplete);}
        self.exec("BEGIN IMMEDIATE")?;self.transaction=true;
        let items=Statement::new(self.db,"DELETE FROM items WHERE read=?")?;items.int(1,read)?;items.done()?;
        let reads=Statement::new(self.db,"DELETE FROM reads WHERE id=?")?;reads.int(1,read)?;reads.done()?;
        if unsafe{sqlite3_changes(self.db)}!=1{return Err(Error::Invalid);}
        self.fresh()?;self.exec("COMMIT")?;self.transaction=false;self.fresh()
    }
    /// Close actual SQLite work without claiming that an interrupted session is
    /// complete. Cancellation disables publication, not the required rollback.
    pub fn drain(mut self)->Result<()> {
        unsafe{sqlite3_progress_handler(self.db,0,None,std::ptr::null_mut());}
        if unsafe{sqlite3_get_autocommit(self.db)}==0 {self.exec("ROLLBACK")?;}
        self.transaction=false;self.insert.take();
        ok(unsafe{sqlite3_close(self.db)})?;self.db=std::ptr::null_mut();Ok(())
    }
    #[cfg(smb_catalog_qualification)]
    pub fn qualification_small_cache(&mut self)->Result<()> {self.exec("PRAGMA cache_size=8")}
    #[cfg(smb_catalog_qualification)]
    pub fn qualification_page_interrupt(&mut self,entered:Arc<AtomicBool>){self.progress.pause=Some(entered);}
    #[cfg(smb_catalog_qualification)]
    pub fn qualification_resume_query(&mut self){self.progress.pause=None;}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn raw_identity_does_not_merge_unicode_composition(){
        let a=wire_bytes(&"Café.txt".encode_utf16().collect::<Vec<_>>()).unwrap();
        let b=wire_bytes(&"Cafe\u{301}.txt".encode_utf16().collect::<Vec<_>>()).unwrap();assert_ne!(a.0,b.0);
        for name in ["",".","..","a/b","a\\b","a\0b","a\nb"]{assert!(wire_bytes(&name.encode_utf16().collect::<Vec<_>>()).is_err());}
        assert!(wire_bytes(&[0xd800]).is_err());assert!(wire_bytes(&vec![b'a' as u16;2049]).is_err());
    }
    #[test] fn natural_order_is_bounded_and_explicit(){
        assert!(natural_key("Item 2").unwrap()<natural_key("Item 10").unwrap());
        assert_eq!(natural_key("ITEM 0002").unwrap(),natural_key("item 2").unwrap());
        assert!(natural_key(&"a1".repeat(2048)).unwrap().len()<=12288);
    }
}

include!("selected_catalog.rs");
