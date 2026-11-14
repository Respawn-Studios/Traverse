// Unselected input-lifetime experiment. No reference or statement escapes a
// call. SQLite reset alone does not release SQLITE_STATIC blob references.
enum ScopedInput<'a> { Number(u64), Blob(Option<&'a [u8]>) }
struct ScopedReset<'statement,'values> {
    statement:&'statement Statement,
    _pinned:&'values [ScopedInput<'values>],
}
impl Drop for ScopedReset<'_,'_> {
    fn drop(&mut self) {
        // Reset can report the preceding step failure while still resetting.
        // Clear must run even then, and even after a partial bind failure.
        unsafe { sqlite3_reset(self.statement.raw); }
        if unsafe{sqlite3_clear_bindings(self.statement.raw)}!=0 {
            // A valid owned statement must clear. Never return dangling inputs
            // if an unexpected SQLite API invariant has been violated.
            std::process::abort();
        }
    }
}
impl Statement {
    fn execute_scoped<'values>(&self,values:&'values [ScopedInput<'values>])->Result<()> {
        let _reset=ScopedReset{statement:self,_pinned:values};
        for (index,value) in values.iter().enumerate() {
            let index=i32::try_from(index+1).map_err(|_|"store_row")?;
            match value {
                ScopedInput::Number(value)=>self.number(index,*value)?,
                ScopedInput::Blob(value)=>{
                    check(unsafe{match value {
                        Some(bytes)=>sqlite3_bind_blob(self.raw,index,bytes.as_ptr().cast(),
                            i32::try_from(bytes.len()).map_err(|_|"store_row")?,0),
                        None=>sqlite3_bind_null(self.raw,index),
                    }})?;
                },
            }
        }
        if self.row()?{return Err("store_query");}
        Ok(())
    }
}

#[cfg(b06_binding_probe)]
struct BindingProbeRow {id:u64,name:Vec<u8>,identity:[u8;16],links:[u8;8],flags:[u8;4],payload:Vec<u8>}
#[cfg(b06_binding_probe)]
impl BindingProbeRow {
    fn make(id:u64)->Result<Self> {
        let mut identity=[0;16];identity[..8].copy_from_slice(&1u64.to_be_bytes());identity[8..].copy_from_slice(&id.to_be_bytes());
        let values=[Some(id%17),Some(id),Some(4096),Some(if id%5==0{u64::MAX}else{8192})];
        let bytes=payload(&Observation{object_type:Some(1),values,..Default::default()});
        Ok(Self{id,name:format!("generated-{id:06}").into_bytes(),identity,links:1u64.to_be_bytes(),flags:0u32.to_be_bytes(),payload:encode_payload(&bytes)?})
    }
    fn parameters(&self)->[ScopedInput<'_>;8] {[
        ScopedInput::Number(self.id),ScopedInput::Number(0),ScopedInput::Blob(Some(&self.name)),ScopedInput::Number(0),
        ScopedInput::Blob(Some(&self.identity)),ScopedInput::Blob(Some(&self.links)),ScopedInput::Blob(Some(&self.flags)),ScopedInput::Blob(Some(&self.payload)),
    ]}
    fn insert_copy(&self,statement:&Statement)->Result<()> {
        statement.number(1,self.id)?;statement.number(2,0)?;statement.blob(3,Some(&self.name))?;statement.number(4,0)?;
        statement.blob(5,Some(&self.identity))?;statement.blob(6,Some(&self.links))?;statement.blob(7,Some(&self.flags))?;
        statement.blob(8,Some(&self.payload))?;statement.done()
    }
}
#[cfg(b06_binding_probe)]
pub fn binding_component(lane:&str)->Result<String> {
    if !matches!(lane,"copy"|"scoped"){return Err("component_lane");}
    const COUNT:u64=100_000;
    let owner=Connection::open_existing(c":memory:").map_err(|_|"component_open")?;
    owner.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY,parent INTEGER NOT NULL,name BLOB NOT NULL,kind INTEGER NOT NULL,identity BLOB,links BLOB,flags BLOB,payload BLOB NOT NULL,UNIQUE(parent,name)) STRICT;CREATE INDEX sample_page ON samples(parent,id);BEGIN;").map_err(|_|"component_schema")?;
    let statement=Statement::new(Rc::clone(&owner),"INSERT INTO samples VALUES(?,?,?,?,?,?,?,?)")?;
    let began=std::time::Instant::now();
    for id in 1..=COUNT {
        let value=BindingProbeRow::make(id)?;
        if lane=="copy"{value.insert_copy(&statement)?;}else{statement.execute_scoped(&value.parameters())?;}
    }
    let elapsed=began.elapsed().as_nanos();
    owner.execute("COMMIT").map_err(|_|"component_commit")?;
    let rows=Statement::new(Rc::clone(&owner),"SELECT id,parent,name,kind,identity,links,flags,payload FROM samples ORDER BY id")?;
    let mut id=0;let mut digest=super::Digest::default();
    while rows.row()? {
        id+=1;let expected=BindingProbeRow::make(id)?;
        if rows.integer(0)?!=id || rows.integer(1)?!=0 || rows.integer(3)?!=0 {return Err("component_number");}
        let mut exact=id.to_be_bytes().to_vec();
        for (column,wanted) in [(2,expected.name.as_slice()),(4,&expected.identity),(5,&expected.links),(6,&expected.flags),(7,&expected.payload)] {
            let actual=rows.bytes(column,255)?.ok_or("component_null")?;
            if actual!=wanted{return Err("component_readback");}
            exact.extend_from_slice(&(actual.len()as u64).to_be_bytes());exact.extend_from_slice(&actual);
        }
        digest.add(&exact);
    }
    if id!=COUNT{return Err("component_count");}
    Ok(json_map(vec![("lane",quote(lane)),("rows",COUNT.to_string()),("elapsed_ns",quote(&elapsed.to_string())),
        ("verified","true".into()),("digest_xor",quote(&super::Digest::hex(&digest.xor))),("digest_sum",quote(&super::Digest::hex(&digest.sum)))]))
}

#[cfg(test)] mod scoped_binding_tests {
    use super::*;
    #[test] fn copied_rows_survive_input_reuse_and_null_is_not_empty() {
        let owner=Connection::open_existing(c":memory:").unwrap();owner.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY,value BLOB)").unwrap();
        let statement=Statement::new(Rc::clone(&owner),"INSERT INTO samples VALUES(?,?)").unwrap();
        let mut bytes=vec![0,255,7];
        statement.execute_scoped(&[ScopedInput::Number(1),ScopedInput::Blob(Some(&bytes))]).unwrap();bytes.fill(42);
        statement.execute_scoped(&[ScopedInput::Number(2),ScopedInput::Blob(Some(&[]))]).unwrap();
        statement.execute_scoped(&[ScopedInput::Number(3),ScopedInput::Blob(None)]).unwrap();drop(bytes);
        let read=Statement::new(owner,"SELECT id,value FROM samples ORDER BY id").unwrap();
        assert!(read.row().unwrap());assert_eq!(read.bytes(1,3).unwrap(),Some(vec![0,255,7]));
        assert!(read.row().unwrap());assert_eq!(read.bytes(1,3).unwrap(),Some(vec![]));
        assert!(read.row().unwrap());assert_eq!(read.bytes(1,3).unwrap(),None);assert!(!read.row().unwrap());
    }
    #[test] fn partial_bind_and_number_overflow_clear_every_input() {
        let owner=Connection::open_existing(c":memory:").unwrap();let read=Statement::new(owner,"SELECT ?1").unwrap();
        for number in [0,u64::MAX] {
            let bytes=vec![1,2,3];
            assert!(read.execute_scoped(&[ScopedInput::Blob(Some(&bytes)),ScopedInput::Number(number)]).is_err());drop(bytes);
            assert!(read.row().unwrap());assert_eq!(read.bytes(0,3).unwrap(),None);read.reset().unwrap();
        }
    }
    #[test] fn unexpected_row_and_failed_step_release_inputs_before_return() {
        let owner=Connection::open_existing(c":memory:").unwrap();let read=Statement::new(Rc::clone(&owner),"SELECT ?1").unwrap();
        let bytes=vec![4,5,6];assert!(read.execute_scoped(&[ScopedInput::Blob(Some(&bytes))]).is_err());drop(bytes);
        assert!(read.row().unwrap());assert_eq!(read.bytes(0,3).unwrap(),None);read.reset().unwrap();
        owner.execute("CREATE TABLE one(value BLOB CHECK(length(value)=3));BEGIN;").unwrap();
        let insert=Statement::new(Rc::clone(&owner),"INSERT INTO one VALUES(?)").unwrap();
        assert!(insert.execute_scoped(&[ScopedInput::Blob(Some(&[1,2]))]).is_err());
        insert.execute_scoped(&[ScopedInput::Blob(Some(&[3,4,5]))]).unwrap();owner.execute("ROLLBACK").unwrap();
        let count=Statement::new(owner,"SELECT count(*) FROM one").unwrap();assert!(count.row().unwrap());assert_eq!(count.integer(0).unwrap(),0);
    }
    #[test] fn prepared_owner_lives_until_the_last_scoped_statement() {
        let owner=Connection::open_existing(c":memory:").unwrap();owner.execute("CREATE TABLE one(value BLOB)").unwrap();
        let insert=Statement::new(Rc::clone(&owner),"INSERT INTO one VALUES(?)").unwrap();drop(owner);
        for value in 0..256u64 {let bytes=value.to_be_bytes();insert.execute_scoped(&[ScopedInput::Blob(Some(&bytes))]).unwrap();}
    }
}
