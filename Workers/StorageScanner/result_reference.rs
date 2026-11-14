// Experimental first-observation index. Reference and namespace row share the
// writer transaction; the deferred FK disallows committing a dangling fact.
fn reference_facts(facts:ObjectFacts)->Vec<u8> {
    let mut bytes=vec![0;50];
    for (i,v) in facts.values.into_iter().enumerate(){if let Some(v)=v{bytes[i*9]=1;put(&mut bytes,i*9+1,v);}}
    if let Some(v)=facts.links{bytes[36]=1;put(&mut bytes,37,v);}
    if let Some(v)=facts.flags{bytes[45]=1;bytes[46..50].copy_from_slice(&v.to_be_bytes());}bytes
}
struct ReferenceIndex {owner:Rc<Connection>,source:u64,buffer:RefCell<Option<Rc<PendingNodes>>>,insert:Statement,find:Statement,update:Statement,directory:Statement}
fn ref_error(value:&'static str)->super::catalog::Error {
    if value=="store_quota"{super::catalog::Error::Sqlite(13)}else{super::catalog::Error::InvalidRow}
}
impl ReferenceIndex {
    fn install(owner:&Connection)->super::catalog::Result<()> {
        owner.execute("CREATE TABLE object_facts(source INTEGER NOT NULL CHECK(source IN(1,2)),device BLOB NOT NULL CHECK(length(device)=4),inode BLOB NOT NULL CHECK(length(inode)=8),first_node INTEGER NOT NULL REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,edges INTEGER NOT NULL CHECK(edges>=1),fallback BLOB CHECK(fallback IS NULL OR length(fallback)=50),PRIMARY KEY(source,device,inode)) WITHOUT ROWID,STRICT;
            CREATE UNIQUE INDEX object_first ON object_facts(first_node);
            CREATE TABLE visited_directories(source INTEGER NOT NULL CHECK(source IN(1,2)),device BLOB NOT NULL CHECK(length(device)=4),inode BLOB NOT NULL CHECK(length(inode)=8),PRIMARY KEY(source,device,inode)) WITHOUT ROWID,STRICT;")
    }
    fn new(owner:Rc<Connection>)->super::catalog::Result<Self>{Self::for_source(owner,1)}
    fn for_source(owner:Rc<Connection>,source:u64)->super::catalog::Result<Self> {
        if !(1..=2).contains(&source){return Err(super::catalog::Error::InvalidRow);}
        let build=||->Result<Self>{Ok(Self{
            insert:Statement::new(Rc::clone(&owner),"INSERT INTO object_facts VALUES(?,?,?,?,1,?) ON CONFLICT(source,device,inode) DO NOTHING")?,
            find:Statement::new(Rc::clone(&owner),"SELECT n.kind,n.identity,n.links,n.flags,n.payload,o.edges,o.fallback FROM object_facts o JOIN nodes n ON n.id=o.first_node WHERE o.source=? AND o.device=? AND o.inode=?")?,
            update:Statement::new(Rc::clone(&owner),"UPDATE object_facts SET edges=? WHERE source=? AND device=? AND inode=?")?,
            directory:Statement::new(Rc::clone(&owner),"INSERT INTO visited_directories VALUES(?,?,?) ON CONFLICT(source,device,inode) DO NOTHING")?,
            owner:Rc::clone(&owner),source,buffer:RefCell::new(None),
        })};build().map_err(ref_error)
    }
    fn attach_writer_buffer(&self,buffer:Rc<PendingNodes>){*self.buffer.borrow_mut()=Some(buffer);}
    fn flush_writer_nodes(&self)->Result<()> {if let Some(buffer)=self.buffer.borrow().as_ref(){buffer.flush()?;}Ok(())}
    fn bind(&self,stmt:&Statement,start:i32,id:[u64;2])->Result<()> {
        // Darwin dev_t is32 bits; reject a wider supplied value, never truncate.
        let device=u32::try_from(id[0]).map_err(|_|"store_identity")?;
        stmt.number(start,self.source)?;stmt.blob(start+1,Some(&device.to_be_bytes()))?;stmt.blob(start+2,Some(&id[1].to_be_bytes()))
    }
    fn object(&self,id:[u64;2],facts:ObjectFacts,node:u64,entry_error:u32)->super::catalog::Result<ObjectAdmission> {
        self.admit(id,facts,node,entry_error).map_err(ref_error)
    }
    fn admit(&self,id:[u64;2],facts:ObjectFacts,node:u64,entry_error:u32)->Result<ObjectAdmission> {
        self.bind(&self.insert,1,id)?;self.insert.number(4,node)?;
        let fallback=if entry_error!=0 {Some(reference_facts(facts))}else{None};self.insert.blob(5,fallback.as_deref())?;self.insert.done()?;
        let changes=unsafe{super::catalog::changed_rows(self.owner.handle())};
        if changes==1{return Ok(ObjectAdmission{fresh:true,changed:facts.links==Some(0)});}
        if changes!=0{return Err("store_index");}
        self.flush_writer_nodes()?;
        self.bind(&self.find,1,id)?;
        if !self.find.row()? || self.find.integer(0)?!=0 {return Err("store_index");}
        let observed=self.find.bytes(1,16)?;let fallback=self.find.bytes(6,50)?;
        let identity=[id[0].to_be_bytes(),id[1].to_be_bytes()].concat();
        if fallback.is_some() {
            if observed.is_some(){return Err("store_index");}
        }else if observed.as_deref()!=Some(identity.as_slice()){return Err("store_index");}
        let links=self.find.bytes(2,8)?.map(|v|v.try_into().map(u64::from_be_bytes).map_err(|_|"store_index")).transpose()?;
        let flags=self.find.bytes(3,4)?.map(|v|v.try_into().map(u32::from_be_bytes).map_err(|_|"store_index")).transpose()?;
        let p=decode_payload(&self.find.bytes(4,52)?.ok_or("store_index")?)?;let mut values=[None;4];
        if fallback.is_none(){for (i,value) in values.iter_mut().enumerate(){*value=match p[i*13]{0=>None,1=>Some(u64_at(&p,i*13+1)),_=>return Err("store_index")};}}
        let edges=self.find.integer(5)?.checked_add(1).filter(|n|*n<=i64::MAX as u64).ok_or("store_overflow")?;
        if self.find.row()? {return Err("store_index");}self.find.reset()?;
        self.update.number(1,edges)?;self.bind(&self.update,2,id)?;self.update.done()?;
        if unsafe{super::catalog::changed_rows(self.owner.handle())}!=1{return Err("store_index");}
        Ok(ObjectAdmission{fresh:false,changed:facts.links==Some(0)||fallback.as_ref().map_or(values!=facts.values||links!=facts.links||flags!=facts.flags,|v|*v!=reference_facts(facts))||facts.links.is_some_and(|v|edges>v)})
    }
    fn directory(&self,id:[u64;2])->super::catalog::Result<bool> {
        let run=||->Result<bool>{self.bind(&self.directory,1,id)?;self.directory.done()?;
            match unsafe{super::catalog::changed_rows(self.owner.handle())}{0=>Ok(false),1=>Ok(true),_=>Err("store_index")}};
        run().map_err(ref_error)
    }
    fn object_counts(&self)->super::catalog::Result<(u64,u64)>{self.counts(false).map_err(ref_error)}
    fn counts(&self,all:bool)->Result<(u64,u64)> {
        self.flush_writer_nodes()?;
        let rows=Statement::new(Rc::clone(&self.owner),if all {
            "SELECT n.links,o.edges,o.fallback FROM object_facts o JOIN nodes n ON n.id=o.first_node"
        }else{"SELECT n.links,o.edges,o.fallback FROM object_facts o JOIN nodes n ON n.id=o.first_node WHERE o.source=?"})?;
        if !all{rows.number(1,self.source)?;}
        let (mut total,mut external)=(0u64,0u64);
        while rows.row()? {
            total=total.checked_add(1).ok_or("store_overflow")?;
            let fallback=rows.bytes(2,50)?;let raw_links=if let Some(ref f)=fallback {if f.len()!=50{return Err("store_index");}match f[36]{0=>None,1=>Some(f[37..45].to_vec()),_=>return Err("store_index")}}else{rows.bytes(0,8)?};
            let links=raw_links.map(|v|v.try_into().map(u64::from_be_bytes).map_err(|_|"store_index")).transpose()?;
            let edges=rows.integer(1)?;if links.is_some_and(|v|v>edges){external+=1;}
        }Ok((total,external))
    }
}
#[cfg(test)]
mod reference_tests {
    use super::*;
    fn setup()->(Rc<Connection>,ReferenceIndex) {
        let owner=Connection::open_existing(c":memory:").unwrap();owner.execute(&schema()).unwrap();ReferenceIndex::install(&owner).unwrap();owner.execute("COMMIT;BEGIN").unwrap();
        let index=ReferenceIndex::new(Rc::clone(&owner)).unwrap();(owner,index)
    }
    fn node(owner:&Rc<Connection>,node:u64,id:[u64;2],facts:ObjectFacts) {
        let s=Statement::new(Rc::clone(owner),"INSERT INTO nodes VALUES(?,0,?,0,?,?,?,?)").unwrap();
        s.number(1,node).unwrap();s.blob(2,Some(node.to_string().as_bytes())).unwrap();
        s.blob(3,Some(&[id[0].to_be_bytes(),id[1].to_be_bytes()].concat())).unwrap();
        s.blob(4,facts.links.as_ref().map(|_|facts.links.unwrap().to_be_bytes()).as_ref().map(|v|v.as_slice())).unwrap();
        let flags=facts.flags.map(u32::to_be_bytes);s.blob(5,flags.as_ref().map(|v|v.as_slice())).unwrap();
        let p=payload(&Observation{object_type:Some(1),values:facts.values,..Default::default()});s.blob(6,Some(&encode_payload(&p).unwrap())).unwrap();s.done().unwrap();
    }
    #[test] fn exact_identity_change_source_and_rollback() {
        let (owner,index)=setup();let facts=ObjectFacts{values:[Some(u64::MAX),Some(0),None,Some(4096)],links:Some(3),flags:Some(u32::MAX)};
        let id=[u32::MAX as u64,u64::MAX];
        assert_eq!(index.object(id,facts,1,0).unwrap(),ObjectAdmission{fresh:true,changed:false});node(&owner,1,id,facts);
        assert_eq!(index.object(id,facts,2,0).unwrap(),ObjectAdmission{fresh:false,changed:false});node(&owner,2,id,facts);
        let changed=ObjectFacts{values:[Some(0);4],..facts};
        assert!(index.object(id,changed,3,0).unwrap().changed);node(&owner,3,id,changed);
        assert!(index.object(id,facts,4,0).unwrap().changed);node(&owner,4,id,facts);
        assert_eq!(index.object_counts().unwrap(),(1,0));
        assert!(index.object([u64::MAX,1],facts,5,0).is_err());
        let other=ReferenceIndex::for_source(Rc::clone(&owner),2).unwrap();
        assert!(other.object(id,facts,5,0).unwrap().fresh);node(&owner,5,id,facts);
        assert_eq!(other.object_counts().unwrap(),(1,1));assert_eq!(index.counts(true).unwrap(),(2,1));
        owner.execute("ROLLBACK;BEGIN IMMEDIATE").unwrap();
        assert!(index.object(id,facts,1,0).unwrap().fresh); // No reference survived rollback.
        assert!(owner.execute("COMMIT").is_err()); // No dangling first observation commits.
        owner.execute("ROLLBACK").unwrap();
    }
    #[test] fn first_observation_is_checked_even_when_link_count_is_one() {
        let (owner,index)=setup();let facts=ObjectFacts{values:[Some(1);4],links:Some(1),flags:None};let id=[1,2];
        assert!(index.object(id,facts,1,0).unwrap().fresh);node(&owner,1,id,facts);owner.execute("COMMIT;BEGIN").unwrap();
        assert_eq!(index.object(id,facts,2,0).unwrap(),ObjectAdmission{fresh:false,changed:true});
        assert!(index.directory([1,u64::MAX]).unwrap());assert!(!index.directory([1,u64::MAX]).unwrap());
        owner.execute("ROLLBACK").unwrap();
    }
    #[test] fn error_tagged_first_observations_keep_exact_bookkeeping_facts() {
        let (owner,index)=setup();let id=[1,2];let facts=ObjectFacts{values:[Some(u64::MAX),None,Some(0),Some(1)],links:Some(3),flags:Some(17)};
        assert!(index.object(id,facts,1,13).unwrap().fresh);
        let row=Statement::new(Rc::clone(&owner),"INSERT INTO nodes VALUES(1,0,x'65',0,NULL,NULL,NULL,?)").unwrap();
        let p=payload(&Observation{object_type:Some(1),error:13,values:facts.values,..Default::default()});row.blob(1,Some(&encode_payload(&p).unwrap())).unwrap();row.done().unwrap();
        assert_eq!(index.object(id,facts,2,13).unwrap(),ObjectAdmission{fresh:false,changed:false});node(&owner,2,id,facts);
        assert_eq!(index.object_counts().unwrap(),(1,1));
        assert!(index.object(id,ObjectFacts{flags:Some(18),..facts},3,0).unwrap().changed);node(&owner,3,id,facts);
        owner.execute("COMMIT").unwrap();
    }
    #[test] fn reference_admission_matches_an_independent_identity_map() {
        use std::collections::HashMap;
        let (owner,index)=setup();let mut reference=HashMap::new();
        for n in 1..=4096u64 {
            let id=[(n/3)%7,u64::MAX-(n/3)];
            let facts=ObjectFacts{values:[Some(n%13),Some(u64::MAX),None,Some(0)],links:if n%5==0{None}else{Some(3)},flags:Some((n%3) as u32)};
            let expected=if let Some((old,edges))=reference.get_mut(&id) {let old:&ObjectFacts=old;*edges+=1;ObjectAdmission{fresh:false,changed:*old!=facts||facts.links.is_some_and(|v|*edges>v)}}
                else{reference.insert(id,(facts,1u64));ObjectAdmission{fresh:true,changed:false}};
            assert_eq!(index.object(id,facts,n,0).unwrap(),expected);node(&owner,n,id,facts);
        }
        owner.execute("COMMIT").unwrap();assert_eq!(index.object_counts().unwrap().0,reference.len() as u64);
    }

}
