//! Versioned temporary results for explicit analysis. No file bodies, history
//! database, persistent index or automatic recovery/resumption are used here.
//! All statements and identity indexes share one connection and transaction.
use super::{Observation, Result as ScanResult, base64, json_map, quote};
use super::catalog::{Connection, ObjectAdmission, ObjectFacts};
#[cfg(not(b06_reference_index))]
use super::catalog::IdentityIndex as ResultIndex;
#[cfg(b06_reference_index)]
use ReferenceIndex as ResultIndex;
use std::ffi::{c_char,c_int,c_void,CString};
use std::rc::Rc;

#[cfg(all(b06_classification_v4,not(all(b06_classification_v3,b06_adaptive_checkpoint,b06_deep128,b06_live_totals,b06_checkpoint4096,b06_app_data))))]
compile_error!("Classification v4 requires the complete qualified adaptive/depth/policy contract");
#[cfg(all(b06_chart_overview,not(b06_classification_v4)))]
compile_error!("The optional chart overview requires classification v4");
#[cfg(all(b06_purpose_journey,not(b06_classification_v4)))]
compile_error!("Purpose namespace queries require the unchanged classification v4 contract");
pub const REVISION: &str = if cfg!(b06_classification_v4){"full-result-data-v4"}else if cfg!(b06_adaptive_checkpoint){"full-result-adaptive-v1"}else if cfg!(b06_deep128){"full-result-depth128-v1"}else if cfg!(b06_classification_v3){"full-result-classification-v3"}else if cfg!(b06_app_data){"full-result-policy-v1"}else if cfg!(b06_dense_names){"full-result-v2"}else{"full-result-v1"};
pub const STARTUP_REVISION:&str=if cfg!(b06_classification_v4){"startup-result-data-v4"}else if cfg!(b06_adaptive_checkpoint){"startup-result-adaptive-v1"}else if cfg!(b06_deep128){"startup-result-depth128-v1"}else if cfg!(b06_classification_v3){"startup-result-classification-v3"}else if cfg!(b06_app_data){"startup-result-policy-v1"}else if cfg!(b06_dense_names){"startup-result-v2"}else{"startup-result-v1"};
pub const CLASSIFICATION_REVISION:u64=if cfg!(b06_classification_v4){4}else if cfg!(b06_classification_v3){3}else{2};
const FILE_TYPE_COUNT:usize=if cfg!(b06_classification_v4){17}else if cfg!(b06_classification_v3){16}else{15};
pub const MAX_DEPTH: usize = if cfg!(b06_deep128){128}else{64};
pub const MAX_STORE_BYTES:u64=2<<30;
pub const CHECKPOINT_ROWS:u64=if cfg!(b06_adaptive_checkpoint){16384}else if cfg!(b06_checkpoint4096){4096}else{1024};
const ROWS:u64=CHECKPOINT_ROWS;
#[cfg(b06_adaptive_checkpoint)]
include!("result_checkpoint.rs");
type Result<T> = std::result::Result<T, &'static str>;
unsafe extern "C" {
    #[cfg(any(b06_purpose_journey,b06_statement_profile))]
    fn sqlite3_progress_handler(db:*mut c_void,count:c_int,callback:Option<unsafe extern "C" fn(*mut c_void)->c_int>,context:*mut c_void);
    fn sqlite3_prepare_v2(db:*mut c_void,sql:*const c_char,size:c_int,stmt:*mut *mut c_void,tail:*mut *const c_char)->c_int;
    fn sqlite3_finalize(stmt:*mut c_void)->c_int;
    fn sqlite3_reset(stmt:*mut c_void)->c_int;
    fn sqlite3_clear_bindings(stmt:*mut c_void)->c_int;
    fn sqlite3_bind_int64(stmt:*mut c_void,index:c_int,value:i64)->c_int;
    fn sqlite3_bind_blob(stmt:*mut c_void,index:c_int,value:*const c_void,length:c_int,destructor:isize)->c_int;
    fn sqlite3_bind_null(stmt:*mut c_void,index:c_int)->c_int;
    fn sqlite3_step(stmt:*mut c_void)->c_int;
    fn sqlite3_column_int64(stmt:*mut c_void,index:c_int)->i64;
    fn sqlite3_column_type(stmt:*mut c_void,index:c_int)->c_int;
    fn sqlite3_column_blob(stmt:*mut c_void,index:c_int)->*const c_void;
    fn sqlite3_column_bytes(stmt:*mut c_void,index:c_int)->c_int;
    fn sqlite3_busy_timeout(db:*mut c_void,ms:c_int)->c_int;
    fn b06_result_check(path:*const c_char,quota:u64,reading:c_int)->c_int;
    fn b06_result_pin()->c_int;
    fn b06_result_directory(device:*mut u64,inode:*mut u64)->c_int;
    fn b06_result_physical_directory(device:*mut u64,inode:*mut u64)->c_int;
}
fn check(code:i32)->Result<()> {if code==0 {Ok(())}else{Err(if code==13 {"store_quota"}else{"store_write"})}}
fn index_error(error:super::catalog::Error)->&'static str {
    if error==super::catalog::Error::Sqlite(13){"store_quota"}else{"store_index"}
}

struct Statement {raw:*mut c_void,_owner:Rc<Connection>}
impl Statement {
    fn new(owner:Rc<Connection>,sql:&str)->Result<Self> {
        let text=CString::new(sql).map_err(|_|"store_query")?;let mut raw=std::ptr::null_mut();
        let code=unsafe{sqlite3_prepare_v2(owner.handle(),text.as_ptr(),-1,&mut raw,std::ptr::null_mut())};
        if code!=0 {if !raw.is_null(){unsafe{sqlite3_finalize(raw);}}return Err("store_query");}
        Ok(Self{raw,_owner:owner})
    }
    fn number(&self,index:i32,value:u64)->Result<()> {
        check(unsafe{sqlite3_bind_int64(self.raw,index,i64::try_from(value).map_err(|_|"store_overflow")?)})
    }
    fn blob(&self,index:i32,value:Option<&[u8]>)->Result<()> {
        check(unsafe{match value {
            Some(value)=>sqlite3_bind_blob(self.raw,index,value.as_ptr().cast(),value.len() as i32,-1),
            None=>sqlite3_bind_null(self.raw,index),
        }})
    }
    fn row(&self)->Result<bool> {match unsafe{sqlite3_step(self.raw)} {100=>Ok(true),101=>Ok(false),13=>Err("store_quota"),_=>Err("store_query")}}
    fn reset(&self)->Result<()> {check(unsafe{sqlite3_reset(self.raw)})?;check(unsafe{sqlite3_clear_bindings(self.raw)})}
    fn done(&self)->Result<()> {if self.row()? {return Err("store_query");}self.reset()}
    fn integer(&self,index:i32)->Result<u64> {let value=unsafe{sqlite3_column_int64(self.raw,index)};u64::try_from(value).map_err(|_|"store_row")}
    fn bytes(&self,index:i32,max:usize)->Result<Option<Vec<u8>>> {
        if unsafe{sqlite3_column_type(self.raw,index)}==5 {return Ok(None);}
        let count=unsafe{sqlite3_column_bytes(self.raw,index)};
        if unsafe{sqlite3_column_type(self.raw,index)}!=4 || count<0 || count as usize>max {return Err("store_row");}
        if count==0 {return Ok(Some(vec![]));}
        let p=unsafe{sqlite3_column_blob(self.raw,index)};if p.is_null(){return Err("store_row");}
        Ok(Some(unsafe{std::slice::from_raw_parts(p.cast::<u8>(),count as usize)}.to_vec()))
    }
}
impl Drop for Statement {fn drop(&mut self){unsafe{sqlite3_finalize(self.raw);}}}
#[cfg(b06_scoped_bindings)]
include!("result_scoped_bindings.rs");

fn u64_at(value:&[u8],offset:usize)->u64 {u64::from_be_bytes(value[offset..offset+8].try_into().unwrap())}
fn put(value:&mut [u8],offset:usize,number:u64) {value[offset..offset+8].copy_from_slice(&number.to_be_bytes());}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct Value(pub [u8;140]);
impl Default for Value {fn default()->Self{Self([0;140])}}
impl Value {
    fn decode(value:&[u8])->Result<Self> {
        let value:[u8;140]=value.try_into().map_err(|_|"store_row")?;
        for metric in 0..4 {
            let start=40+metric*25;
            if value[start+24]>1 || (value[start+24]==1 && u64_at(&value,start)!=0){return Err("store_row");}
        }
        Ok(Self(value))
    }
    fn observation(o:&Observation)->Self {
        let mut result=Self::default();put(&mut result.0,kind(o)*8,1);
        if o.kind()=="regular" {for metric in 0..4 {
            let offset=40+metric*25;
            if o.error!=0 {put(&mut result.0,offset+16,1);}
            else if let Some(value)=o.values[metric] {put(&mut result.0,offset,value);}
            else {put(&mut result.0,offset+8,1);}
        }}result
    }
    pub fn merge(&mut self,other:&Self)->Result<()> {
        for offset in (0..40).step_by(8) {
            let value=u64_at(&self.0,offset).checked_add(u64_at(&other.0,offset)).ok_or("store_overflow")?;
            put(&mut self.0,offset,value);
        }
        for metric in 0..4 {
            let offset=40+metric*25;
            let (sum,overflow)=u64_at(&self.0,offset).overflowing_add(u64_at(&other.0,offset));
            let overflow=overflow || self.0[offset+24]!=0 || other.0[offset+24]!=0;
            put(&mut self.0,offset,if overflow{0}else{sum});self.0[offset+24]=u8::from(overflow);
            for support in [8,16] {
                let value=u64_at(&self.0,offset+support).checked_add(u64_at(&other.0,offset+support)).ok_or("store_overflow")?;
                put(&mut self.0,offset+support,value);
            }
        }Ok(())
    }
    pub fn entries(&self)->Result<u64> {
        (0..5).try_fold(0u64,|value,index|value.checked_add(u64_at(&self.0,index*8)).ok_or("store_overflow"))
    }
}
// Scan every group, retain only the best12 and an exact remainder. Letting
// SQLite sort all140-byte aggregates with temp_store=MEMORY is unbounded.
#[derive(Default)]
struct RankedValues {best:Vec<(u64,Value)>,remainder:Value,total:u64,metric:usize}
impl RankedValues {
    fn before(&self,a:&(u64,Value),b:&(u64,Value))->bool {
        let offset=40+self.metric*25;
        a.1.0[offset+24].cmp(&b.1.0[offset+24]).then_with(||b.1.0[offset..offset+8].cmp(&a.1.0[offset..offset+8])).then_with(||a.0.cmp(&b.0)).is_lt()
    }
    fn push(&mut self,key:u64,value:Value)->Result<()> {
        if value.entries()?==0{return Ok(());}
        self.total=self.total.checked_add(1).ok_or("store_overflow")?;
        let row=(key,value);let position=self.best.iter().position(|old|self.before(&row,old)).unwrap_or(self.best.len());
        if position>=12 {return self.remainder.merge(&value);}
        self.best.insert(position,row);
        if self.best.len()>12 {self.remainder.merge(&self.best.pop().ok_or("store_row")?.1)?;}
        Ok(())
    }
}
fn kind(o:&Observation)->usize {match o.kind(){"regular"=>0,"directory"=>1,"symlink"=>2,"other"=>3,_=>4}}
fn payload(o:&Observation)->[u8;52] {
    let mut bytes=[0;52];for metric in 0..4 {
        let start=metric*13;
        if o.error!=0 {bytes[start]=2;bytes[start+9..start+13].copy_from_slice(&o.error.to_be_bytes());}
        else if let Some(value)=o.values[metric] {bytes[start]=1;put(&mut bytes,start+1,value);}
    }bytes
}
include!("result_types.rs");
#[cfg(b06_sqlite_profile)]
include!("result_sqlite_profile.rs");
#[cfg(b06_statement_profile)]
include!("result_statement_profile.rs");
#[cfg(all(b06_statement_profile,not(b06_sqlite_profile)))]
compile_error!("Statement diagnosis requires the isolated SQLite profile");
#[cfg(any(b06_compact_values,test))]
include!("result_compact.rs");
const PROFILE:u64=1+2*(cfg!(b06_compact_values) as u64)+4*(cfg!(b06_reference_index) as u64)+8*(cfg!(b06_dense_names) as u64)+16*(cfg!(b06_app_data) as u64)+32*(cfg!(b06_checkpoint4096) as u64)+64*(cfg!(b06_classification_v3) as u64)+128*(cfg!(b06_deep128)as u64)+256*(cfg!(b06_adaptive_checkpoint)as u64)+512*(cfg!(b06_classification_v4)as u64);
fn encode_value(value:&Value)->Vec<u8> {
    #[cfg(b06_compact_values)] {compact_value(value)}
    #[cfg(not(b06_compact_values))] {value.0.to_vec()}
}
fn decode_value(bytes:&[u8])->Result<Value> {
    #[cfg(b06_compact_values)] {expand_value(bytes)}
    #[cfg(not(b06_compact_values))] {Value::decode(bytes)}
}
#[cfg(any(not(b06_stack_metadata),test))]
fn encode_payload(bytes:&[u8])->Result<Vec<u8>> {
    #[cfg(b06_compact_values)] {compact_payload(bytes)}
    #[cfg(not(b06_compact_values))] {Ok(bytes.to_vec())}
}
fn decode_payload(bytes:&[u8])->Result<Vec<u8>> {
    #[cfg(b06_compact_values)] {expand_payload(bytes)}
    #[cfg(not(b06_compact_values))] {if bytes.len()!=52 {Err("store_row")}else{Ok(bytes.to_vec())}}
}
fn schema()->String {
    let mut schema=SCHEMA.replace("PRAGMA user_version=1;",&format!("PRAGMA user_version={PROFILE};")).replace("revision IN(1,2)",&format!("revision IN({},{})",PROFILE,PROFILE+1));
    // Isolated bounded page-cache experiment. No format/barrier/query change.
    #[cfg(b06_cache8)]
    { schema=schema.replace("PRAGMA cache_size=-1024;","PRAGMA cache_size=-8192;"); }
    if cfg!(b06_checkpoint4096){schema=schema.replace("transaction_rows=1024","transaction_rows=4096");}
    if cfg!(b06_adaptive_checkpoint){schema=schema.replace("transaction_rows=4096","transaction_rows=16384");}
    if cfg!(b06_classification_v3){schema=schema.replace("revision=2",&format!("revision={CLASSIFICATION_REVISION}")).replace("classification_rules VALUES(1,2)",&format!("classification_rules VALUES(1,{CLASSIFICATION_REVISION})"));}
    if cfg!(b06_compact_values) {
        schema=schema.replace("length(payload)=52","length(payload) BETWEEN 5 AND 45")
            .replace("length(value)=140","length(value) BETWEEN 22 AND 175")
            .replace("zeroblob(52)","x'0100000000'");
    }
    if cfg!(b06_dense_names) {
        // Qualification candidate: primary namespace order removes node_page
        // and the separate(parent,name) uniqueness tree. SQLite still carries
        // the primary key in secondary indexes; measure the full layout rather
        // than assuming names are physically stored only once.
        schema=schema.replace("id INTEGER PRIMARY KEY CHECK(id>=0),parent INTEGER REFERENCES nodes(id)",
            "id INTEGER NOT NULL UNIQUE CHECK(id>=0),parent INTEGER NOT NULL REFERENCES nodes(id)")
            .replace("id=0 AND parent IS NULL","id=0 AND parent=0")
            .replace(",UNIQUE(parent,name)) STRICT;",",PRIMARY KEY(parent,name)) WITHOUT ROWID,STRICT;")
            .replace("CREATE INDEX node_page ON nodes(parent,id);","")
            .replace("INSERT INTO nodes VALUES(0,NULL,","INSERT INTO nodes VALUES(0,0,");
    }
    schema
}

#[cfg(b06_reference_index)]
include!("result_reference.rs");
include!("result_refresh.rs");

const SCHEMA:&str=include_str!("result.sql");
struct Authority {path:CString,quota:u64,reading:bool}
impl Authority {
    fn new(path:&str,quota:u64,reading:bool)->Result<Self> {
        let result=Self{path:CString::new(path).map_err(|_|"store_authority")?,quota,reading};
        result.fresh()?;
        if unsafe{b06_result_pin()}!=0 {return Err("store_authority");}
        result.fresh()?;Ok(result)
    }
    fn fresh(&self)->Result<()> {
        #[cfg(b06_live_totals)] let _timer=super::profiling::measure(super::profiling::Stage::Authority);
        if unsafe{b06_result_check(self.path.as_ptr(),self.quota,i32::from(self.reading))}==0 {Ok(())}
        else{Err(if super::errno()==27 {"store_quota"}else{"store_authority"})}
    }
}

#[derive(Clone)]
struct Folder {id:u64,path:Vec<u8>,total:Value,files:Value}
pub struct Writer {
    owner:Rc<Connection>,authority:Authority,index:ResultIndex,
    pending:Rc<PendingNodes>,
    insert:Statement,rollup:Statement,files:Statement,marker:Statement,types_statement:Statement,
    folders:Vec<Folder>,types:[Value;FILE_TYPE_COUNT],count:u64,committed:u64,open:bool,tainted:bool,
    directory:[u64;2],pub ready:bool,
    source:u64,
    pub complete:bool,
    #[cfg(b06_live_totals)] progress:ProgressTotals,
    #[cfg(b06_sqlite_profile)] sqlite_profile:SqliteProfile,
    #[cfg(b06_statement_profile)] statement_profile:StatementWorkProfile,
    #[cfg(b06_statement_profile)] projection_profile:Option<String>,
    #[cfg(b06_adaptive_checkpoint)] last_checkpoint:std::time::Instant,
    #[cfg(b06_reuse_statements)] transactions:[Statement;3],
}
impl Writer {
    pub fn open(path:&str,quota:u64,session:&str,metadata_policy:super::policy::Profile)->Result<Self> {
        if metadata_policy!=super::policy::Profile::Standard && !cfg!(b06_app_data){return Err("metadata_policy");}
        let authority=Authority::new(path,quota,false)?;
        let owner=Connection::open_existing(c"result.sqlite").map_err(|_|"store_open")?;
        #[cfg(b06_statement_profile)] let statement_profile=StatementWorkProfile::new(Rc::clone(&owner));
        if unsafe{sqlite3_busy_timeout(owner.handle(),50)}!=0 {return Err("store_open");}
        // No import/reopen/resume: only an admitted zero-length, newly owned
        // database can initialize this revision. Old or interrupted stores refuse.
        let empty=Statement::new(Rc::clone(&owner),"SELECT count(*) FROM sqlite_schema")?;
        if !empty.row()? || empty.integer(0)?!=0 || empty.row()? {return Err("store_not_empty");}drop(empty);
        owner.execute(&schema()).map_err(|_|"store_schema")?;
        #[cfg(not(b06_reference_index))]
        owner.install_identity_schema().map_err(|_|"store_schema")?;
        #[cfg(b06_reference_index)]
        ReferenceIndex::install(&owner).map_err(|_|"store_schema")?;
        owner.execute(&format!("PRAGMA max_page_count={};",(quota/2/4096).max(128))).map_err(|_|"store_quota")?;
        let profile=Statement::new(Rc::clone(&owner),&format!("INSERT INTO profile VALUES(1,{},?,{ROWS})",PROFILE))?;
        profile.blob(1,Some(session.as_bytes()))?;profile.done()?;
        if cfg!(b06_app_data) {
            owner.execute("CREATE TABLE metadata_policy(id INTEGER PRIMARY KEY CHECK(id=1),revision BLOB NOT NULL CHECK(length(revision) BETWEEN 1 AND 64)) STRICT;").map_err(|_|"store_policy")?;
            let policy=Statement::new(Rc::clone(&owner),"INSERT INTO metadata_policy VALUES(1,?)")?;
            policy.blob(1,Some(metadata_policy.revision().as_bytes()))?;policy.done()?;
        }
        let index=ResultIndex::new(Rc::clone(&owner)).map_err(|_|"store_index")?;
        let pending=Rc::new(PendingNodes::new(Rc::clone(&owner))?);
        #[cfg(b06_reference_index)]
        index.attach_writer_buffer(Rc::clone(&pending));
        let mut directory=[0;2];if unsafe{b06_result_directory(&mut directory[0],&mut directory[1])}!=0{return Err("store_authority");}
        let mut value=Self{
            #[cfg(b06_reuse_statements)] transactions:[
                Statement::new(Rc::clone(&owner),"BEGIN IMMEDIATE")?,
                Statement::new(Rc::clone(&owner),"COMMIT")?,
                Statement::new(Rc::clone(&owner),"ROLLBACK")?],
            insert:Statement::new(Rc::clone(&owner),"INSERT INTO nodes VALUES(?,?,?,?,?,?,?,?)")?,
            rollup:Statement::new(Rc::clone(&owner),"INSERT INTO rollups VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=excluded.value")?,
            files:Statement::new(Rc::clone(&owner),"INSERT INTO direct_files VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=excluded.value")?,
            marker:Statement::new(Rc::clone(&owner),"INSERT INTO markers VALUES(?,?) ON CONFLICT(node) DO UPDATE SET marker=min(markers.marker,excluded.marker)")?,
            types_statement:Statement::new(Rc::clone(&owner),"INSERT INTO groups VALUES(0,?,?) ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value")?,
            owner,authority,index,pending,folders:vec![Folder{id:0,path:vec![],total:Value::default(),files:Value::default()}],
            types:[Value::default();FILE_TYPE_COUNT],count:0,committed:0,open:true,tainted:false,directory,ready:false,source:0,complete:false,
            #[cfg(b06_live_totals)] progress:ProgressTotals::default(),
            #[cfg(b06_sqlite_profile)] sqlite_profile:SqliteProfile::default(),
            #[cfg(b06_statement_profile)] statement_profile,
            #[cfg(b06_statement_profile)] projection_profile:None,
            #[cfg(b06_adaptive_checkpoint)] last_checkpoint:std::time::Instant::now(),
        };
        value.begin()?;value.checkpoint()?;value.commit()?;Ok(value)
    }
    pub fn excludes_store(&self,device:Option<u64>,inode:Option<u64>)->bool {device.zip(inode)==Some((self.directory[0],self.directory[1]))}
    fn statement(&self,sql:&str)->Result<Statement> {Statement::new(Rc::clone(&self.owner),sql)}
    fn transaction(&self,sql:&str)->Result<()> {
        #[cfg(b06_reuse_statements)] {
            let index=match sql {"BEGIN IMMEDIATE"=>0,"COMMIT"=>1,"ROLLBACK"=>2,_=>return Err("store_transaction")};
            return self.transactions[index].done();
        }
        #[cfg(not(b06_reuse_statements))] self.owner.execute(sql).map_err(|_|"store_write")
    }
    pub fn bind_root(&mut self,device:u64,inode:u64)->Result<()> {
        self.begin()?;
        let root=self.statement("UPDATE nodes SET identity=? WHERE id=?")?;
        #[cfg(not(b06_stack_metadata))] let bytes=[device.to_be_bytes(),inode.to_be_bytes()].concat();
        #[cfg(b06_stack_metadata)] let bytes=stack_identity(device,inode);
        root.blob(1,Some(&bytes))?;root.number(2,self.source)?;root.done()?;
        if !self.index.directory([device,inode]).map_err(index_error)? {return Err("duplicate_directory");}Ok(())
    }
    /// Commit the preceding complete observation before starting another. The
    /// caller then records identity, node and directory admission atomically.
    pub fn begin_observation(&mut self)->Result<bool> {
        #[cfg(not(b06_adaptive_checkpoint))]
        let publish=self.open && self.count>self.committed && self.count%ROWS==0;
        #[cfg(b06_adaptive_checkpoint)]
        let publish=self.open && self.count.saturating_sub(self.committed)>=4096 &&
            adaptive_checkpoint_due(self.count,self.committed,self.last_checkpoint.elapsed().as_nanos());
        if publish {self.checkpoint()?;self.commit()?;}
        self.begin()?;Ok(publish)
    }
    fn begin(&mut self)->Result<()> {
        if self.tainted{return Err("store_write");}
        if !self.open {self.authority.fresh()?;self.transaction("BEGIN IMMEDIATE")?;self.open=true;}Ok(())
    }
    fn commit(&mut self)->Result<()> {
        #[cfg(b06_live_totals)] let _timer=super::profiling::measure(super::profiling::Stage::Commit);
        if self.open {self.pending.flush()?;self.authority.fresh()?;{
                #[cfg(b06_live_totals)] let _timer=super::profiling::measure(super::profiling::Stage::SqliteCommit);
                self.transaction("COMMIT")?;
            }self.open=false;self.committed=self.count;self.authority.fresh()?;
            #[cfg(b06_sqlite_profile)] self.sqlite_profile.sample(self.owner.handle());
            #[cfg(b06_live_totals)] self.progress.commit(self.count,&self.types)?;
            #[cfg(b06_adaptive_checkpoint)] {self.last_checkpoint=std::time::Instant::now();}
        }Ok(())
    }
    pub fn committed(&self)->u64 {self.committed}
    pub fn object(&self,identity:[u64;2],facts:ObjectFacts,entry_error:u32)->Result<ObjectAdmission> {
        if !self.open{return Err("store_transaction");}
        #[cfg(not(b06_reference_index))] {let _=entry_error;self.index.object(identity,facts).map_err(index_error)}
        #[cfg(b06_reference_index)] {self.index.object(identity,facts,self.count+1+if self.source==0{0}else{2},entry_error).map_err(index_error)}
    }
    pub fn directory(&self,identity:[u64;2])->Result<bool> {
        if !self.open{return Err("store_transaction");}self.index.directory(identity).map_err(index_error)
    }
    pub fn counts(&self)->Result<(u64,u64)> {
        if self.source==0 {return self.index.object_counts().map_err(|_|"store_index");}
        #[cfg(b06_reference_index)] {return self.index.counts(true);}
        #[cfg(not(b06_reference_index))] {
        let count=self.statement("SELECT count(*),coalesce(sum(CASE WHEN links>edges THEN 1 ELSE 0 END),0) FROM object_facts")?;
        if !count.row()? {return Err("store_index");}Ok((count.integer(0)?,count.integer(1)?))
        }
    }
    pub fn taint(&mut self) {self.tainted=true;}
    fn store_value(statement:&Statement,key:u64,value:&Value)->Result<()> {
        statement.number(1,key)?;statement.blob(2,Some(&encode_value(value)))?;statement.done()
    }
    fn close_folder(&mut self)->Result<()> {
        let folder=self.folders.pop().ok_or("store_ancestors")?;
        Self::store_value(&self.rollup,folder.id,&folder.total)?;
        Self::store_value(&self.files,folder.id,&folder.files)?;
        self.folders.last_mut().ok_or("store_ancestors")?.total.merge(&folder.total)
    }
    pub fn accept(&mut self,o:&Observation,path:&[u8],parent:&[u8])->ScanResult<()> {
        if !self.open || path.is_empty() || path.len()>8192 || o.name.is_empty() || o.name.len()>255 ||
            o.name.contains(&0) || o.name.contains(&47) || o.name==b"." || o.name==b".." {return Err("store_row");}
        let depth=path.split(|b|*b==47).count();if depth>MAX_DEPTH {return Err("depth_limit");}
        while self.folders.len()>1 && self.folders.last().unwrap().path!=parent {self.close_folder()?;}
        let parent_id=self.folders.last().filter(|folder|folder.path==parent).ok_or("store_ancestors")?.id;
        let ordinal=self.count.checked_add(1).ok_or("store_overflow")?;
        let id=ordinal.checked_add(if self.source==0{0}else{2}).filter(|v|*v<i64::MAX as u64).ok_or("store_overflow")?;
        let kind=kind(o);
        if kind==0 {self.pending.push(PendingNode::observed(id,parent_id,o)?)?;}
        else {self.pending.flush()?;
        self.insert.number(1,id)?;self.insert.number(2,parent_id)?;self.insert.blob(3,Some(&o.name))?;self.insert.number(4,kind as u64)?;
        #[cfg(not(b06_stack_metadata))]
        let identity=if o.error==0 {o.dev.zip(o.ino).map(|(dev,ino)|[dev.to_be_bytes(),ino.to_be_bytes()].concat())}else{None};
        #[cfg(b06_stack_metadata)]
        let identity=if o.error==0 {o.dev.zip(o.ino).map(|(dev,ino)|stack_identity(dev,ino))}else{None};
        let links=if o.error==0 {o.links.map(u64::to_be_bytes)}else{None};
        let flags=if o.error==0 {o.flags.map(u32::to_be_bytes)}else{None};
        self.insert.blob(5,identity.as_ref().map(|v|v.as_slice()))?;self.insert.blob(6,links.as_ref().map(|v|v.as_slice()))?;
        self.insert.blob(7,flags.as_ref().map(|v|v.as_slice()))?;
        #[cfg(not(b06_stack_metadata))] self.insert.blob(8,Some(&encode_payload(&payload(o))?))?;
        #[cfg(b06_stack_metadata)] self.insert.blob(8,Some(StackPayload::encode(&payload(o))?.slice()))?;
        self.insert.done()?;
        }
        let value=Value::observation(o);let frame=self.folders.last_mut().ok_or("store_ancestors")?;
        frame.total.merge(&value)?;
        if kind==0 {frame.files.merge(&value)?;self.types[file_type(&o.name)].merge(&value)?;}
        if let Some(key)=project_marker(&o.name,kind) {self.marker.number(1,parent_id)?;self.marker.number(2,key)?;self.marker.done()?;}
        if kind==1 {
            Self::store_value(&self.rollup,id,&Value::default())?;
            if depth<MAX_DEPTH {
                if self.folders.len()>=MAX_DEPTH {return Err("store_ancestors");}
                self.folders.push(Folder{id,path:path.to_vec(),total:Value::default(),files:Value::default()});
            }
        }
        self.count=ordinal;Ok(())
    }
    fn checkpoint(&self)->Result<()> {
        #[cfg(b06_live_totals)] let _timer=super::profiling::measure(super::profiling::Stage::Checkpoint);
        self.pending.flush()?;
        let mut child=Value::default();
        for folder in self.folders.iter().rev() {
            let mut value=folder.total;value.merge(&child)?;
            Self::store_value(&self.rollup,folder.id,&value)?;
            Self::store_value(&self.files,folder.id,&folder.files)?;child=value;
        }
        for (kind,value) in self.types.iter().enumerate(){Self::store_value(&self.types_statement,kind as u64,value)?;}
        if self.source>0 {
            let other=self.statement("SELECT value FROM rollups WHERE node=?")?;
            other.number(1,if self.source==1{2}else{1})?;
            if !other.row()? {return Err("store_source");}
            child.merge(&decode_value(&other.bytes(0,175)?.ok_or("store_source")?)?)?;
            Self::store_value(&self.rollup,0,&child)?;
        }
        #[cfg(b06_live_totals)] self.progress.candidate.set(child);
        Ok(())
    }
    /// Stop/failure never commits a half-admitted row or an identity without
    /// its observation. The last checkpoint is a useful honest partial result.
    pub fn seal(&mut self,discard_pending:bool,complete:bool,root:&[u8])->Result<()> {
        #[cfg(b06_live_totals)] let _timer=super::profiling::measure(super::profiling::Stage::Seal);
        let interrupted=discard_pending || self.tainted;
        if interrupted {
            // SQLITE_FULL may already have rolled the transaction back. A
            // second ROLLBACK must not hide the last durable checkpoint.
            if self.owner.in_transaction() {self.transaction("ROLLBACK")?;}
            self.pending.discard();
            self.open=false;
            self.count=self.committed;
        } else {self.checkpoint()?;self.finish_source()?;self.commit()?;}
        self.tainted=false;
        let projected=if !interrupted && unsafe{super::b06_cancelled()}==0 {
            match self.project(root) {
                Ok(())=>true,
                Err("cancelled"|"store_quota")=>{
                    if self.owner.in_transaction(){self.transaction("ROLLBACK")?;}
                    self.open=false;false
                },
                Err(error)=>return Err(error),
            }
        }else{false};
        self.begin()?;
        if self.source>0 {
            let source=self.statement("UPDATE source_roots SET last_row=? WHERE id=?")?;
            source.number(1,self.committed+2)?;source.number(2,self.source)?;source.done()?;
        }
        let state=self.statement("UPDATE scan_state SET state=?,entries=?,projected=? WHERE id=1 AND state=0")?;
        state.number(1,if complete && projected{1}else{2})?;state.number(2,self.committed)?;state.number(3,u64::from(projected))?;state.done()?;
        self.commit()?;self.authority.fresh()?;self.ready=true;self.complete=complete && projected;Ok(())
    }
    fn project(&mut self,root:&[u8])->Result<()> {
        #[cfg(b06_statement_profile)] let projection_began=std::time::Instant::now();
        #[cfg(b06_statement_profile)] let (mut role_ns,mut directories,mut projection_pages)=(0u64,0u64,0u64);
        let parent=self.statement("SELECT c.role,c.project,n.name FROM contexts c JOIN nodes n ON n.id=c.node WHERE c.node=?")?;
        let marked=self.statement("SELECT marker FROM markers WHERE node=?")?;
        let context=self.statement("INSERT INTO contexts VALUES(?,?,?)")?;
        let direct=self.statement("SELECT value FROM direct_files WHERE node=?")?;
        let group=self.statement("SELECT value FROM groups WHERE kind=? AND key=?")?;
        let store=self.statement("INSERT INTO groups VALUES(?,?,?) ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value")?;
        // Roles have a fixed 0...12 domain; projects remain catalog-backed.
        // Flush touched cumulative totals with each existing projection page so
        // committed contexts and groups always describe the same prefix.
        let mut role_totals=[Value::default();13];let mut role_touched=[false;13];
        let mut cursor=0;let root_parts:Vec<&[u8]>=root.split(|b|*b==47).filter(|v|!v.is_empty()).collect();
        let root_role=classify(&root_parts,0,false);let mut first=true;
        #[cfg(b06_reuse_statements)] let pages=[
            self.statement("SELECT id,parent,name FROM nodes WHERE kind=1 ORDER BY id LIMIT 256")?,
            self.statement("SELECT id,parent,name FROM nodes WHERE kind=1 AND id>? ORDER BY id LIMIT 256")?];
        loop {
            if unsafe{super::b06_cancelled()}!=0 {return Err("cancelled");}
            #[cfg(b06_reuse_statements)] let page=&pages[usize::from(!first)];
            #[cfg(not(b06_reuse_statements))]
            let page=self.statement(if first {"SELECT id,parent,name FROM nodes WHERE kind=1 ORDER BY id LIMIT 256"}
                else {"SELECT id,parent,name FROM nodes WHERE kind=1 AND id>? ORDER BY id LIMIT 256"})?;
            if !first {page.number(1,cursor)?;}
            let mut rows=Vec::with_capacity(256);
            while page.row()? {rows.push((page.integer(0)?,page.integer(1)?,page.bytes(2,255)?.ok_or("store_row")?));}
            #[cfg(b06_reuse_statements)] page.reset()?;
            if rows.is_empty(){break;}
            self.begin()?;
            for (id,parent_id,name) in rows {
                if unsafe{super::b06_cancelled()}!=0 {return Err("cancelled");}
                #[cfg(b06_statement_profile)] {directories+=1;}
                let (mut role,mut project)=(root_role,0);let mut parent_name=vec![];
                if id>0 {
                    parent.number(1,parent_id)?;if !parent.row()?{return Err("store_context");}
                    role=parent.integer(0)?;project=parent.integer(1)?;parent_name=parent.bytes(2,255)?.ok_or("store_row")?;parent.reset()?;
                }
                marked.number(1,id)?;let has_marker=marked.row()?;marked.reset()?;
                if id>0 {
                    let p=if parent_id==0 {root_parts.last().copied().unwrap_or(b"")}else{parent_name.as_slice()};
                    role=classify(&[p,&name],role,project>0);
                    #[cfg(b06_classification_v3)]
                    if !matches!(role,2|3|4|6|7|8|9|10|11|12) && name==b"DerivedData" && derived_data_parent(Rc::clone(&self.owner),parent_id,&root_parts)? {role=10;}
                }
                if self.source>0 && id==2 {role=12;}
                let steam_name=if id==0 {root_parts.last().copied().unwrap_or(b"")}else{&name};
                if steam_name==b"steamapps" {
                    let common=self.statement("SELECT 1 FROM nodes WHERE parent=? AND name=x'636f6d6d6f6e' AND kind=1")?;
                    common.number(1,id)?;if common.row()? {role=9;}
                }
                if has_marker && !matches!(role,1|2|3|4|6|7|8|9|10|11|12) {project=id+1;}
                if name==b".cache" || name==b"Caches" && (parent_name==b"Library" || parent_id==0 && root_parts.last()==Some(&b"Library".as_slice())) {project=0;}
                context.number(1,id)?;context.number(2,role)?;context.number(3,project)?;context.done()?;
                direct.number(1,id)?;
                let value=if direct.row()? {Some(decode_value(&direct.bytes(0,175)?.ok_or("store_row")?)?)}else{None};direct.reset()?;
                if let Some(value)=value {
                    #[cfg(b06_statement_profile)] let role_began=std::time::Instant::now();
                    let slot=usize::try_from(role).map_err(|_|"store_context")?;
                    role_totals.get_mut(slot).ok_or("store_context")?.merge(&value)?;
                    *role_touched.get_mut(slot).ok_or("store_context")?=true;
                    #[cfg(b06_statement_profile)] {role_ns=role_ns.saturating_add(role_began.elapsed().as_nanos().min(u64::MAX as u128)as u64);}
                    group.number(1,2)?;group.number(2,project)?;
                    let mut total=if group.row()? {decode_value(&group.bytes(0,175)?.ok_or("store_row")?)?}else{Value::default()};group.reset()?;
                    total.merge(&value)?;store.number(1,2)?;store.number(2,project)?;store.blob(3,Some(&encode_value(&total)))?;store.done()?;
                }
                cursor=id;
            }
            #[cfg(b06_statement_profile)] let role_flush_began=std::time::Instant::now();
            for (role,(value,touched)) in role_totals.iter().zip(&role_touched).enumerate() {
                if *touched {store.number(1,1)?;store.number(2,role as u64)?;store.blob(3,Some(&encode_value(value)))?;store.done()?;}
            }
            #[cfg(b06_statement_profile)] {role_ns=role_ns.saturating_add(role_flush_began.elapsed().as_nanos().min(u64::MAX as u128)as u64);}
            self.commit()?;
            role_touched.fill(false);
            #[cfg(b06_statement_profile)] {projection_pages+=1;}
            #[cfg(b06_classification_quota)]
            if first {
                // Isolated generated-store fault: fail a real file-backed
                // allocation AFTER a committed projection page, not a mocked
                // error. The earlier namespace/type checkpoints remain valid.
                self.owner.execute("CREATE TABLE qualification_fill(value BLOB)").map_err(|_|"store_quota")?;
                let count=self.statement("PRAGMA page_count")?;
                if !count.row()?{return Err("store_quota");}let pages=count.integer(0)?;drop(count);
                self.owner.execute(&format!("PRAGMA max_page_count={pages}")).map_err(|_|"store_quota")?;
                self.begin()?;
                match self.owner.execute("INSERT INTO qualification_fill VALUES(zeroblob(2097152))") {
                    Err(super::catalog::Error::Sqlite(13))=>return Err("store_quota"),
                    _=>return Err("qualification_failure"),
                }
            }
            first=false;
        }
        #[cfg(b06_statement_profile)] {
            self.projection_profile=Some(json_map(vec![("state",quote("returned")),
                ("elapsed_ns",quote(&projection_began.elapsed().as_nanos().to_string())),("role_ns",quote(&role_ns.to_string())),
                ("directories",quote(&directories.to_string())),("pages",quote(&projection_pages.to_string())),
                ("group_read",projection_statement_work(&group)),("group_write",projection_statement_work(&store))]));
        }
        Ok(())
    }
}
impl Drop for Writer {fn drop(&mut self){if self.open {let _=self.transaction("ROLLBACK");}}}
#[cfg(any(b06_stack_metadata,test))]
fn stack_identity(device:u64,inode:u64)->[u8;16] {
    let mut bytes=[0;16];bytes[..8].copy_from_slice(&device.to_be_bytes());bytes[8..].copy_from_slice(&inode.to_be_bytes());bytes
}
include!("result_startup.rs");
include!("result_breakdown.rs");
include!("result_filtered.rs");
#[cfg(b06_purpose_journey)]
include!("result_purpose.rs");
#[cfg(b06_stored_locations)]
include!("result_locations.rs");
#[cfg(b06_sorted_pages)]
include!("result_sorted_page.rs");
#[cfg(all(b06_sorted_pages,b06_largest_files))]
include!("result_largest_files.rs");
#[cfg(b06_classification_audit)]
include!("result_audit.rs");
#[cfg(all(b06_qualification,b06_classification_v3))]
include!("result_classification_fixture.rs");
#[cfg(all(b06_qualification,b06_purpose_journey))]
include!("result_purpose_fixture.rs");

// Rule profile1 uses observed names only. Generated/dependency scopes cannot
// create nested projects. No rule claims bytes are disposable or exclusive.
fn project_marker(name:&[u8],kind:usize)->Option<u64> {
    if (kind==0 || kind==1) && name==b".git" {return Some(0);}
    if kind!=0{return None;}
    match name {b"Package.swift"=>Some(1),b"Cargo.toml"=>Some(2),b"pubspec.yaml"=>Some(3),b"pyproject.toml"=>Some(4),b"package.json"=>Some(5),b"go.mod"=>Some(6),_=>None}
}
fn classify(parts:&[&[u8]],inherited:u64,project:bool)->u64 {classify_revision(parts,inherited,project,CLASSIFICATION_REVISION)}
fn classify_revision(parts:&[&[u8]],inherited:u64,project:bool,revision:u64)->u64 {
    let cache_path=parts.windows(2).any(|p|p[0]==b"Library" && p[1]==b"Caches");
    if parts.contains(&b"huggingface".as_slice()) && (parts.contains(&b".cache".as_slice()) || cache_path || inherited==3){return 4;}
    if matches!(inherited,2|3|4|6|7|8|9|10|11|12){return inherited;}
    if revision>=3 {
        if let Some(index)=parts.windows(4).position(|p|p==[b"Library".as_slice(),b"Developer",b"Xcode",b"DerivedData"]) {
            let prior=classify_revision(&parts[..index+3],inherited,project,2);
            if matches!(prior,0|1|5){return 10;}
        }
    }
    for (i,name) in parts.iter().enumerate() {
        match *name {
            b".git"=>return 6,b"node_modules"|b"Pods"|b".venv"|b"venv"=>return 2,
            b"__pycache__"|b".pytest_cache"|b".mypy_cache"=>return 7,
            b".dart_tool"|b".pub-cache"=>return 8,b".cache"|b".npm"=>return 3,
            b".gradle"|b".m2"=>return 10,
            b"registry" if i>0 && parts[i-1]==b".cargo"=>return 10,
            name if name.ends_with(b".app")=>return 11,
            b"Caches" if i>0 && parts[i-1]==b"Library"=>return 3,
            b"Application Support" if i>0 && parts[i-1]==b"Library"=>return 5,
            b"Containers"|b"Group Containers" if revision>=3 && i>0 && parts[i-1]==b"Library"=>return 5,
            b"build"|b"dist"|b"target"|b".build" if project=>return 1,
            _=>{}
        }
    }inherited
}

#[cfg(b06_classification_v3)]
fn derived_data_parent(owner:Rc<Connection>,mut id:u64,root:&[&[u8]])->Result<bool> {
    // Only the rare candidate name needs this bounded three-ancestor query.
    // No path lookup/source descriptor and no growing hierarchy is retained.
    let row=Statement::new(owner,"SELECT parent,name FROM nodes WHERE id=? AND kind=1")?;
    let mut expected=[b"Xcode".as_slice(),b"Developer",b"Library"].into_iter();
    while let Some(name)=expected.next() {
        if id==0 {
            let rest=std::iter::once(name).chain(expected).collect::<Vec<_>>();
            return Ok(root.iter().rev().take(rest.len()).copied().eq(rest));
        }
        row.number(1,id)?;if !row.row()? {return Err("store_parent");}
        if row.bytes(1,255)?.as_deref()!=Some(name){return Ok(false);}
        let parent=row.integer(0)?;if parent>=id {return Err("store_parent");}id=parent;row.reset()?;
    }
    Ok(true)
}

fn page_cursor(owner:Rc<Connection>,parent:u64,cursor:u64)->Result<Vec<u8>> {
    if parent>=i64::MAX as u64 || cursor>=i64::MAX as u64{return Err("store_cursor");}
    let folder=Statement::new(Rc::clone(&owner),"SELECT kind FROM nodes WHERE id=?")?;
    folder.number(1,parent)?;if !folder.row()? || folder.integer(0)?!=1 {return Err("store_cursor");}
    if cursor==0{return Ok(vec![]);}
    let previous=Statement::new(owner,"SELECT parent,name FROM nodes WHERE id=?")?;previous.number(1,cursor)?;
    if !previous.row()? || previous.integer(0)?!=parent {return Err("store_cursor");}
    previous.bytes(1,255)?.filter(|v|!v.is_empty()).ok_or("store_cursor")
}

/// Queries run in a short-lived, descriptor-anchored read-only child. No
/// process-global CWD change, database connection or growing tree enters UI.
fn chart_project_count(owner:Rc<Connection>)->Result<u64> {
    let projects=Statement::new(owner,"SELECT count(*) FROM contexts WHERE project=node+1")?;
    if !projects.row()? {return Err("store_row");}projects.integer(0)
}

// Shared bounded ranking for legacy single-facet and the optional overview.
// This performs no source lookup: project labels come from the sealed catalog.
fn chart_groups(owner:Rc<Connection>,facet:u64,project_count:u64)->Result<String> {
    let rows=Statement::new(Rc::clone(&owner),"SELECT key,value FROM groups WHERE kind=?")?;
    rows.number(1,facet)?;let mut ranking=RankedValues::default();
    while rows.row()? {
        let value=decode_value(&rows.bytes(1,175)?.ok_or("store_row")?)?;
        ranking.push(rows.integer(0)?,value)?;
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
    }
    let mut page=vec![];
    for (key,value) in &ranking.best {
        let name=if facet==2 && *key>0 {
            let label=Statement::new(Rc::clone(&owner),"SELECT name FROM nodes WHERE id=?")?;
            label.number(1,*key-1)?;if !label.row()? {return Err("store_row");}label.bytes(0,255)?.ok_or("store_row")?
        }else{vec![]};
        page.push(json_map(vec![("key",quote(&key.to_string())),("name",quote(&base64(&name))),("value",quote(&base64(&value.0)))]));
    }
    Ok(json_map(vec![("kind",quote("groups")),("groups",format!("[{}]",page.join(","))),("remainder",quote(&base64(&ranking.remainder.0))),("total_groups",quote(&ranking.total.to_string())),("project_count",quote(&project_count.to_string()))]))
}

pub fn query(path:&str,quota:u64,session:&str,mode:&str,parent:u64,cursor:u64,facet:u64,metadata_policy:super::policy::Profile,filter_key:Option<u64>)->Result<()> {
    let maximum_filter=if cfg!(b06_application_layouts){6}else{5};
    if filter_key.is_some() && (!matches!(mode,"breakdown"|"explain-other"|"project-composition-v1"|"purpose-projects-v1"|"purpose-locations-v1") && !(cfg!(all(b06_qualification,b06_purpose_journey)) && mode=="purpose-stop-control-v1") || !(3..=maximum_filter).contains(&facet)) || filter_key.is_none() && facet>=3 && mode!="sorted-page" {return Err("store_filter");}
    if unsafe{super::b06_set_utility_qos()}!=0 {return Err("worker_qos");}
    let authority=Authority::new(path,quota,true)?;
    let owner=Connection::open_read_only(c"result.sqlite").map_err(|_|"store_open")?;
    owner.execute("PRAGMA query_only=ON;PRAGMA cache_size=-1024;PRAGMA temp_store=MEMORY;").map_err(|_|"store_open")?;
    let profile=Statement::new(Rc::clone(&owner),"SELECT revision,session FROM profile WHERE id=1")?;
    if !profile.row()? || !([PROFILE,PROFILE+1].contains(&profile.integer(0)?)) || profile.bytes(1,36)?.as_deref()!=Some(session.as_bytes()) {return Err("store_profile");}
    let revision=profile.integer(0)?;if profile.row()? {return Err("store_profile");}drop(profile);
    if cfg!(b06_classification_v3){filtered_rules(Rc::clone(&owner))?;}
    if cfg!(b06_app_data) {
        let policy=Statement::new(Rc::clone(&owner),"SELECT revision FROM metadata_policy WHERE id=1")?;
        if !policy.row()? || policy.bytes(0,64)?.as_deref()!=Some(metadata_policy.revision().as_bytes()) || policy.row()? {return Err("store_policy");}
    }else if metadata_policy!=super::policy::Profile::Standard {return Err("store_policy");}
    let state=Statement::new(Rc::clone(&owner),"SELECT state,entries,projected FROM scan_state WHERE id=1")?;
    if !state.row()? || !matches!(state.integer(0)?,1|2){return Err("store_not_ready");}
    let complete=state.integer(0)?==1;let entries=state.integer(1)?;let projected=state.integer(2)?==1;drop(state);
    if cfg!(b06_app_data) {
        let mut prelude=vec![("kind",quote("policy")),("revision",quote(metadata_policy.revision())),("session",quote(session))];
        if cfg!(b06_classification_v3){prelude.push(("classification_revision",CLASSIFICATION_REVISION.to_string()));}
        #[cfg(b06_deep128)] prelude.push(("maximum_depth",MAX_DEPTH.to_string()));
        #[cfg(b06_adaptive_checkpoint)] prelude.push(("checkpoint_revision","1".into()));
        send(json_map(prelude))?;
    }
    match mode {
        #[cfg(all(b06_qualification,b06_purpose_journey))]
        "purpose-stop-control-v1"=>{
            if facet!=4 || parent!=0 || cursor!=0 || filter_key!=Some(3){return Err("store_filter");}
            PURPOSE_PROGRESS_CONTROL.store(1,std::sync::atomic::Ordering::Relaxed);
            purpose_query(Rc::clone(&owner),3,None,0,revision==PROFILE+1,entries,projected)?;
        },
        #[cfg(b06_purpose_journey)]
        "purpose-projects-v1"|"purpose-locations-v1"=>{
            if facet!=4 || cursor>3 || mode=="purpose-projects-v1" && parent!=0{return Err("store_filter");}
            purpose_query(Rc::clone(&owner),filter_key.ok_or("store_filter")?,if mode=="purpose-locations-v1"{Some(parent)}else{None},cursor,revision==PROFILE+1,entries,projected)?;
        },
        #[cfg(b06_chart_overview)]
        "chart-overview-v1"=>{
            if !cfg!(b06_classification_v4) || parent!=0 || cursor!=0 || facet!=0 || filter_key.is_some(){return Err("store_filter");}
            let count=chart_project_count(Rc::clone(&owner))?;
            let types=chart_groups(Rc::clone(&owner),0,count)?;
            let roles=if projected{chart_groups(Rc::clone(&owner),1,count)?}else{"null".into()};
            let projects=if projected{chart_groups(Rc::clone(&owner),2,count)?}else{"null".into()};
            send(json_map(vec![("kind",quote("chart-overview")),("revision","1".into()),("classification_revision",CLASSIFICATION_REVISION.to_string()),
                ("projected",projected.to_string()),("file_types",types),("storage_roles",roles),("projects",projects)]))?;
        },
        #[cfg(all(b06_sorted_pages,b06_largest_files))]
        "largest-files"=>{
            if parent!=0 || cursor!=0 || filter_key.is_some() || !matches!(facet,0|1){return Err("store_filter");}
            largest_files(Rc::clone(&owner),if facet==0{0}else{3},revision==PROFILE+1)?;
        },
        #[cfg(b06_sorted_pages)]
        "sorted-page"=>{
            if facet>5 || filter_key.is_some(){return Err("store_sort");}
            sorted_page(Rc::clone(&owner),parent,cursor,facet as u8)?;
        },
        #[cfg(b06_stored_locations)]
        "location"=>{
            if cursor!=0 || facet!=0 || filter_key.is_some(){return Err("store_filter");}
            stored_location(Rc::clone(&owner),parent,revision==PROFILE+1)?;
        },
        #[cfg(b06_application_layouts)]
        "application-layouts"=>{
            if parent!=0 || cursor!=0 || facet!=0 || filter_key.is_some(){return Err("store_filter");}
            application_layout_groups(Rc::clone(&owner),projected,revision==PROFILE+1)?;
        },
        #[cfg(b06_classification_audit)]
        "classification-audit"=>{
            if parent!=0 || cursor!=0 || facet!=0 || filter_key.is_some(){return Err("audit_scope");}
            classification_audit(Rc::clone(&owner))?;
        },
        #[cfg(b06_classification_v3)]
        "explain-other"=>{
            if facet!=3 || filter_key!=Some(0){return Err("store_filter");}
            explain_other(Rc::clone(&owner),parent,projected,revision==PROFILE+1)?;
        },
        "breakdown"=>if let Some(key)=filter_key {filtered_breakdown(Rc::clone(&owner),parent,facet,key,cursor,projected)?}
            else{breakdown(Rc::clone(&owner),parent,facet,cursor,projected)?},
        #[cfg(b06_classification_v3)]
        "project-composition-v1"=>{
            if facet!=5 || cursor>3 {return Err("store_filter");}
            project_composition(Rc::clone(&owner),parent,filter_key.ok_or("store_filter")?,cursor,projected)?;
        },
        "summary"=>{
            let root=Statement::new(Rc::clone(&owner),"SELECT value FROM rollups WHERE node=0")?;
            if !root.row()? {return Err("store_summary");}
            let value=decode_value(&root.bytes(0,175)?.ok_or("store_summary")?)?;let bytes=value.0;
            if value.entries()?!=entries {return Err("store_summary");}
            let mut summary=vec![("kind",quote("summary")),("complete",complete.to_string()),("projected",projected.to_string()),("entries",quote(&entries.to_string())),("value",quote(&base64(&bytes)))];
            if revision==PROFILE+1 {
                let roots=Statement::new(Rc::clone(&owner),"SELECT s.id,s.finished,r.value FROM source_roots s JOIN rollups r ON r.node=s.id ORDER BY s.id")?;
                let mut sources=vec![];while roots.row()? {
                    sources.push(json_map(vec![("id",quote(&roots.integer(0)?.to_string())),("finished",(roots.integer(1)?==1).to_string()),("value",quote(&base64(&decode_value(&roots.bytes(2,175)?.ok_or("store_source")?)?.0)))]));
                }
                if sources.len()!=2{return Err("store_source");}
                let aliases=Statement::new(Rc::clone(&owner),"SELECT coalesce(sum(verified),0),coalesce(sum(1-verified),0) FROM aliases")?;
                if !aliases.row()? {return Err("store_source");}
                summary.extend([("sources",format!("[{}]",sources.join(","))),("verified_aliases",quote(&aliases.integer(0)?.to_string())),("unresolved_aliases",quote(&aliases.integer(1)?.to_string()))]);
            }
            send(json_map(summary))?;
        }
        "page"=>{
            let after=page_cursor(Rc::clone(&owner),parent,cursor)?;
            let rows=Statement::new(Rc::clone(&owner),if cfg!(b06_dense_names) {
                "SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes n LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.name>? ORDER BY n.name LIMIT 256"
            }else{"SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes n LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.id>? ORDER BY n.id LIMIT 256"})?;
            rows.number(1,parent)?;
            if cfg!(b06_dense_names){rows.blob(2,Some(&after))?;}else{rows.number(2,cursor)?;}
            let mut page=Vec::with_capacity(64);let mut count=0;
            while rows.row()? {
                let payload=decode_payload(&rows.bytes(3,52)?.ok_or("store_row")?)?;
                let value=rows.bytes(4,175)?.map(|v|decode_value(&v)).transpose()?;
                page.push(json_map(vec![("id",quote(&rows.integer(0)?.to_string())),("name",quote(&base64(&rows.bytes(1,255)?.ok_or("store_row")?))),
                    ("type",rows.integer(2)?.to_string()),("payload",quote(&base64(&payload))),("value",value.map(|v|quote(&base64(&v.0))).unwrap_or("null".into()))]));
                count+=1;if page.len()==64 {send(json_map(vec![("kind",quote("rows")),("rows",format!("[{}]",page.join(",")))]))?;page.clear();}
            }
            if !page.is_empty(){send(json_map(vec![("kind",quote("rows")),("rows",format!("[{}]",page.join(",")))]))?;}
            let mut end=vec![("kind",quote("end")),("count",count.to_string())];
            if cfg!(b06_dense_names){end.extend([("order",quote("raw_name")),("parent",quote(&parent.to_string())),("after",quote(&cursor.to_string())),("after_name",quote(&base64(&after)))]);}
            send(json_map(end))?;
        }
        "groups"=>{
            if facet>2{return Err("store_facet");}
            if facet>0 && !projected {return Err("classification_incomplete");}
            let count=chart_project_count(Rc::clone(&owner))?;
            send(chart_groups(Rc::clone(&owner),facet,count)?)?;
        }
        _=>return Err("store_query"),
    }
    authority.fresh()?;Ok(())
}

/// Compiled only in the isolated scale binary. This feeds observations, not
/// filesystem entries; it grants no source access and creates no source tree.
#[cfg(b06_qualification)]
pub fn generated_stream(args:&[String])->Result<()> {
    if args.len()!=8 || args[2]!="--result-quota" || args[4]!="--session" || args[6]!="--observations" || args[7]!="1000000" {return Err("scale_arguments");}
    let began=std::time::Instant::now();
    let mut writer=Writer::open(&args[1],super::Options::unsigned(&args[3])?,&args[5],super::policy::Profile::Standard)?;
    writer.bind_root(1,1)?;
    for group in 0..1000u64 {
        let name=format!("d-{group:04}").into_bytes();
        let folder=Observation{name:name.clone(),dev:Some(1),ino:Some(10_000_000+group),links:Some(1),flags:Some(0),object_type:Some(2),mount:Some(0),..Default::default()};
        writer.begin_observation()?;writer.accept(&folder,&name,b"")?;
        if !writer.directory([1,10_000_000+group])? {return Err("scale_directory");}
        for file in 0..999u64 {
            if unsafe{super::b06_cancelled()}!=0 {return Err("cancelled");}
            let ordinal=group*999+file;let object=ordinal/2;
            let o=Observation{name:format!("f-{file:04}.txt").into_bytes(),dev:Some(1),ino:Some(object+2),links:Some(2),flags:Some(0),object_type:Some(1),error:0,
                values:[Some(object),Some(object+10),Some(4096),Some(8192)],..Default::default()};
            writer.begin_observation()?;
            let admitted=writer.object([1,object+2],ObjectFacts{values:o.values,links:o.links,flags:o.flags},0)?;
            if admitted.changed || admitted.fresh!=(ordinal%2==0) {return Err("scale_object");}
            let mut path=name.clone();path.push(47);path.extend_from_slice(&o.name);
            writer.accept(&o,&path,&name)?;
        }
    }
    writer.seal(false,true,b"/Generated")?;
    if writer.committed()!=1_000_000 || writer.counts()? != (499500,0) {return Err("scale_count");}
    let mut resources=super::Resources::default();if unsafe{super::b06_resources(&mut resources)}!=0{return Err("scale_resources");}
    send(json_map(vec![("kind",quote("scale")),("entries",quote("1000000")),("objects",quote("499500")),
        ("peak_rss",quote(&resources.peak_rss.to_string())),("elapsed_ns",quote(&began.elapsed().as_nanos().to_string()))]))
}

pub fn query_arguments(args:&[String])->Result<()> {
    let (metadata_policy,args)=super::policy::Profile::arguments(args)?;
    if args.len()!=14 && args.len()!=16 {return Err("query_arguments");}
    let names=["--read-result","--result-quota","--session","--query","--parent","--after","--facet"];
    for (pair,name) in args.chunks_exact(2).zip(names){if pair[0]!=name{return Err("query_arguments");}}
    let value=|i:usize|super::Options::unsigned(args[i].as_str());
    // Reuse the normal session parser's exact UUID contract, without opening
    // or inheriting a source. Query children receive only store descriptors.
    super::Options::parse(&["--root-fd".into(),"3".into(),"--expected-dev".into(),"1".into(),"--expected-ino".into(),"1".into(),"--session".into(),args[5].clone()])?;
    let key=if args.len()==16 {if args[14]!="--filter-key"{return Err("query_arguments");}Some(value(15)?)}else{None};
    query(&args[1],value(3)?,&args[5],&args[7],value(9)?,value(11)?,value(13)?,metadata_policy,key)
}
fn send(line:String)->Result<()> {
    let line=line+"\n";if line.len()>65536{return Err("query_frame");}
    let bytes=line.as_bytes();let mut offset=0;let began=std::time::Instant::now();
    while offset<bytes.len() {
        if unsafe{super::b06_cancelled()}!=0 || began.elapsed().as_secs()>=5 {return Err("query_stopped");}
        let count=unsafe{super::write(1,bytes.as_ptr().add(offset).cast(),bytes.len()-offset)};
        if count>0 {offset+=count as usize;}else if count<0 && matches!(super::errno(),4|35) {
            let mut descriptor=super::PollDescriptor{fd:1,events:4,revents:0};unsafe{super::poll(&mut descriptor,1,20);}
        }else{return Err("query_output");}
    }Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn data_file_revision_preserves_old_assignments_and_literal_near_misses() {
        for suffix in ["csv","tsv","parquet","arrow","arrows","feather","orc","avro","npy","npz","h5","hdf5","fits","netcdf","rds","rdata"] {
            let name=format!("Generated.{suffix}");
            assert_eq!(file_type_revision(name.as_bytes(),4),16,"{suffix}");
            assert_eq!(file_type_revision(name.to_ascii_uppercase().as_bytes(),4),16,"uppercase {suffix}");
            for revision in [2,3] {assert_eq!(file_type_revision(name.as_bytes(),revision),if matches!(suffix,"csv"|"tsv"){2}else{0});}
        }
        for name in ["Generated.nc","Generated.cdf","Generated.fit","Generated.bin","Generated.dat","Generated.ipc","Generated.pq",".RData",".csv","table.parquet.","table.parquet-backup"] {
            assert_eq!(file_type_revision(name.as_bytes(),4),0,"near miss {name}");
        }
        assert_eq!(file_type_revision(b"table.csv.gz",4),8);
        assert_eq!(file_type_revision(b"Generated.jsonl",4),2);
        assert_eq!(file_type_revision(b"Weights.safetensors",4),11);
        assert_eq!(file_type_revision(b"State.sqlite",4),13);
        assert_eq!(file_type_revision(b"raw_\xff.NPZ",4),16);
    }
    #[test] fn shared_classification_vectors_preserve_old_rules_and_new_near_misses() {
        let mut count=0;
        for row in include_str!("classification-v3-vectors.tsv").lines().filter(|s|!s.is_empty() && !s.starts_with('#')) {
            let p=row.split('\t').collect::<Vec<_>>();assert_eq!(p.len(),4);count+=1;
            for revision in [2u64,3] {
                let expected=p[(revision-1) as usize].parse::<usize>().unwrap();
                let actual=if p[0]=="f"{file_type_revision(p[3].as_bytes(),revision)}
                    else{classify_revision(&p[3].as_bytes().split(|b|*b==47).collect::<Vec<_>>(),0,false,revision) as usize};
                assert_eq!(actual,expected,"{row} revision {revision}");
            }
        }
        assert_eq!(count,33);
        assert_eq!(file_type_revision(b"raw_\xff.CAR",3),15);
        for inherited in [2,3,4,6,7,8,9,10,11,12] {
            assert_eq!(classify_revision(&[b"Library",b"Developer",b"Xcode",b"DerivedData"],inherited,false,3),inherited);
        }
    }
    #[test] fn stack_encoding_matches_vector_encoder_and_sqlite_copies_binding_bytes() {
        for number in [0,1,127,128,16383,16384,u32::MAX as u64,u64::MAX] {
            for states in 0..81u32 {
                let mut fixed=[0;52];let mut remaining=states;
                for index in 0..4 {let state=(remaining%3) as u8;remaining/=3;let offset=index*13;fixed[offset]=state;
                    if state==1{put(&mut fixed,offset+1,number);}else if state==2{fixed[offset+9..offset+13].copy_from_slice(&u32::MAX.to_be_bytes());}}
                let stack=StackPayload::encode(&fixed).unwrap();assert_eq!(stack.slice(),compact_payload(&fixed).unwrap());
                assert_eq!(expand_payload(stack.slice()).unwrap(),fixed);
            }
            assert_eq!(stack_identity(number,!number).to_vec(),[number.to_be_bytes(),(!number).to_be_bytes()].concat());
        }
        for mut invalid in [[0;51].to_vec(),[0;53].to_vec(),[0;52].to_vec()] {
            if invalid.len()==52 {invalid[0]=2;}
            assert!(StackPayload::encode(&invalid).is_err());
        }
        let owner=Connection::open_existing(c":memory:").unwrap();owner.execute("CREATE TABLE copy(value BLOB)").unwrap();
        let insert=Statement::new(Rc::clone(&owner),"INSERT INTO copy VALUES(?)").unwrap();
        let mut bytes=stack_identity(u64::MAX,42);insert.blob(1,Some(&bytes)).unwrap();bytes.fill(0);
        insert.done().unwrap();let read=Statement::new(owner,"SELECT value FROM copy").unwrap();assert!(read.row().unwrap());
        assert_eq!(read.bytes(0,16).unwrap().unwrap(),stack_identity(u64::MAX,42));assert_eq!(bytes,[0;16]);
    }
    #[test] fn page_cursors_are_parent_bound_and_names_keep_binary_order() {
        let owner=Connection::open_existing(c":memory:").unwrap();owner.execute(&schema()).unwrap();
        let insert=Statement::new(Rc::clone(&owner),"INSERT INTO nodes VALUES(?,0,?,1,NULL,NULL,NULL,?)").unwrap();
        for (id,name) in [(1,b"z".as_slice()),(2,b"a".as_slice()),(3,b"a\xff".as_slice()),(4,b"A".as_slice())] {
            insert.number(1,id).unwrap();insert.blob(2,Some(name)).unwrap();insert.blob(3,Some(&encode_payload(&[0;52]).unwrap())).unwrap();insert.done().unwrap();
        }
        assert_eq!(page_cursor(Rc::clone(&owner),0,2).unwrap(),b"a");
        assert!(page_cursor(Rc::clone(&owner),1,2).is_err());
        assert!(page_cursor(Rc::clone(&owner),99,0).is_err());
        assert!(page_cursor(Rc::clone(&owner),0,99).is_err());
        let rows=Statement::new(Rc::clone(&owner),"SELECT id,name FROM nodes WHERE parent=0 AND name>x'' ORDER BY name LIMIT 256").unwrap();
        let mut ids=vec![];while rows.row().unwrap(){ids.push(rows.integer(0).unwrap());}
        assert_eq!(ids,vec![4,2,3,1]);
        // No normalization or lossy UTF8 collision; duplicate raw names refuse.
        insert.number(1,5).unwrap();insert.blob(2,Some(b"a")).unwrap();insert.blob(3,Some(&encode_payload(&[0;52]).unwrap())).unwrap();
        assert!(insert.done().is_err());
    }
    #[test] fn checked_values_keep_unknown_error_zero_and_overflow_distinct() {
        let o=Observation{object_type:Some(1),values:[Some(u64::MAX),None,Some(0),None],..Default::default()};
        let mut value=Value::observation(&o);let mut b=o.clone();b.error=13;value.merge(&Value::observation(&b)).unwrap();
        assert_eq!(u64_at(&value.0,40),u64::MAX);assert_eq!(u64_at(&value.0,56),1);assert_eq!(u64_at(&value.0,73),1);
        b.error=0;b.values=[Some(1);4];value.merge(&Value::observation(&b)).unwrap();
        assert_eq!(value.0[64],1);assert_eq!(u64_at(&value.0,40),0);assert_eq!(value.entries().unwrap(),3);
        assert_eq!(Value::decode(&value.0).unwrap(),value);
    }
    #[test] fn rules_are_names_only_and_generated_markers_do_not_create_projects() {
        assert_eq!(project_marker(b".git",0),Some(0));assert_eq!(project_marker(b"Cargo.toml",2),None);
        assert_eq!(classify(&[b"Library",b"Caches",b"huggingface"],0,false),4);
        assert_eq!(classify(&[b".npm"],0,false),3);
        assert_eq!(classify(&[b"my-target"],0,true),0);
        assert_eq!(classify(&[b"target"],0,true),1);
        assert_eq!(file_type(b"raw_\xff.MP4"),6);assert_eq!(file_type(b".txt"),0);
        for name in [b"pak01_001.VPK".as_slice(),b"game.pak",b"data.pck"] {assert_eq!(file_type(name),8);}
        for name in [b"state.db-wal".as_slice(),b"state.sqlite3-shm"] {assert_eq!(file_type(name),13);}
    }
    #[test] fn group_ranking_retains_twelve_and_reconciles_the_whole_stream() {
        let mut ranked=RankedValues::default();let mut reference=vec![];let mut total=Value::default();
        for ordinal in 0..10_007u64 {
            let key=ordinal*7919%10_007;
            let mut value=Value::observation(&Observation{object_type:Some(1),values:[Some(key%11),Some(key),Some(0),None],..Default::default()});
            if key%499==0 {put(&mut value.0,40,0);value.0[64]=1;}
            total.merge(&value).unwrap();ranked.push(key,value).unwrap();reference.push((key,value));
            assert!(ranked.best.len()<=12);
        }
        reference.sort_by_key(|(key,v)|(v.0[64],std::cmp::Reverse(u64_at(&v.0,40)),*key));
        assert_eq!(ranked.best,reference[..12]);assert_eq!(ranked.total,10_007);
        let mut combined=ranked.remainder;for (_,v) in &ranked.best {combined.merge(v).unwrap();}
        assert_eq!(combined,total);
    }
}

#[cfg(b06_live_totals)]
include!("result_progress.rs");

include!("result_nodes.rs");
