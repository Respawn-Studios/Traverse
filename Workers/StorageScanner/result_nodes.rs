// One same-thread namespace buffer; qualified with the existing writer and reference index.
use std::cell::RefCell;
const NODE_BATCH:usize=16;
struct PendingNode {
    id:u64,parent:u64,name:[u8;255],name_len:u8,
    identity:Option<[u8;16]>,links:Option<[u8;8]>,flags:Option<[u8;4]>,payload:Vec<u8>,
}
impl PendingNode {
    fn observed(id:u64,parent:u64,o:&Observation)->Result<Self> {
        if kind(o)!=0 || o.name.is_empty() || o.name.len()>255 || o.name.contains(&0) ||
            o.name.contains(&47) || o.name==b"." || o.name==b".." {return Err("store_row");}
        let mut name=[0;255];name[..o.name.len()].copy_from_slice(&o.name);
        let identity=if o.error==0 {o.dev.zip(o.ino).map(|(dev,ino)|{
            let mut v=[0;16];v[..8].copy_from_slice(&dev.to_be_bytes());v[8..].copy_from_slice(&ino.to_be_bytes());v
        })}else{None};
        Ok(Self{id,parent,name,name_len:o.name.len() as u8,identity,
            links:if o.error==0{o.links.map(u64::to_be_bytes)}else{None},
            flags:if o.error==0{o.flags.map(u32::to_be_bytes)}else{None},payload:encode_payload(&payload(o))?})
    }
    fn bind(&self,s:&Statement,start:i32)->Result<()> {
        s.number(start,self.id)?;s.number(start+1,self.parent)?;
        s.blob(start+2,Some(&self.name[..usize::from(self.name_len)]))?;s.number(start+3,0)?;
        s.blob(start+4,self.identity.as_ref().map(|v|v.as_slice()))?;
        s.blob(start+5,self.links.as_ref().map(|v|v.as_slice()))?;
        s.blob(start+6,self.flags.as_ref().map(|v|v.as_slice()))?;s.blob(start+7,Some(&self.payload))
    }
}
struct PendingNodes {rows:RefCell<Vec<PendingNode>>,failed:std::cell::Cell<bool>,single:Statement,full:Statement}
impl PendingNodes {
    fn new(owner:Rc<Connection>)->Result<Self> {
        let sql="INSERT INTO nodes VALUES".to_owned()+&["(?,?,?,?,?,?,?,?)";NODE_BATCH].join(",");
        Ok(Self{rows:RefCell::new(Vec::with_capacity(NODE_BATCH)),failed:std::cell::Cell::new(false),
            single:Statement::new(Rc::clone(&owner),"INSERT INTO nodes VALUES(?,?,?,?,?,?,?,?)")?,full:Statement::new(owner,&sql)?})
    }
    fn push(&self,row:PendingNode)->Result<()> {
        if self.failed.get(){return Err("store_write");}
        {let mut rows=self.rows.borrow_mut();if rows.len()>=NODE_BATCH{return Err("store_write");}rows.push(row);}
        if self.rows.borrow().len()==NODE_BATCH {self.flush()?;}Ok(())
    }
    fn flush(&self)->Result<()> {
        if self.failed.get(){return Err("store_write");}
        let mut rows=self.rows.borrow_mut();
        let result=(||->Result<()>{
            if rows.len()==NODE_BATCH {
                for (i,row) in rows.iter().enumerate(){row.bind(&self.full,(i*8+1) as i32)?;}
                self.full.done()?;
            }else{for row in rows.iter(){row.bind(&self.single,1)?;self.single.done()?;}}
            Ok(())
        })();
        if result.is_ok(){rows.clear();}else{self.failed.set(true);}result
    }
    // Only after rollback, or on a pre-commit Stop. Drop never publishes rows.
    fn discard(&self) {
        self.rows.borrow_mut().clear();
        // reset reports the previous step's error; rollback already owns that
        // outcome. Clear bindings as well, without interpreting a retry as success.
        for s in [&self.single,&self.full]{unsafe{sqlite3_reset(s.raw);sqlite3_clear_bindings(s.raw);}}
        self.failed.set(false);
    }
}

#[cfg(all(test,b06_reference_index))]
mod bounded_node_tests {
    use super::*;
    fn setup()->(Rc<Connection>,Rc<PendingNodes>,ReferenceIndex) {
        let owner=Connection::open_existing(c":memory:").unwrap();owner.execute(&schema()).unwrap();ReferenceIndex::install(&owner).unwrap();
        owner.execute("COMMIT;BEGIN IMMEDIATE").unwrap();let pending=Rc::new(PendingNodes::new(Rc::clone(&owner)).unwrap());
        let index=ReferenceIndex::new(Rc::clone(&owner)).unwrap();index.attach_writer_buffer(Rc::clone(&pending));(owner,pending,index)
    }
    fn observation(n:u64)->Observation {
        Observation{name:format!("{n}.bin").into_bytes(),object_type:Some(1),dev:Some(7),ino:Some(n),links:Some(1),
            flags:Some(u32::MAX),values:[Some(u64::MAX),Some(0),None,Some(4096)],..Default::default()}
    }
    fn scalar(owner:&Rc<Connection>,sql:&str)->u64 {let s=Statement::new(Rc::clone(owner),sql).unwrap();assert!(s.row().unwrap());let value=s.integer(0).unwrap();assert!(!s.row().unwrap());value}
    fn accept(p:&PendingNodes,index:&ReferenceIndex,n:u64,o:&Observation)->ObjectAdmission {
        let facts=ObjectFacts{values:o.values,links:o.links,flags:o.flags};let admitted=index.object([o.dev.unwrap(),o.ino.unwrap()],facts,n,o.error).unwrap();
        p.push(PendingNode::observed(n,0,o).unwrap()).unwrap();admitted
    }
    #[test] fn raw_rows_and_every_tail_match_literal_observations() {
        for count in [0,1,2,15,16,17,31,32,33,255] {
            let (owner,p,index)=setup();
            for n in 1..=count {assert!(accept(&p,&index,n,&observation(n)).fresh);assert!(p.rows.borrow().len()<16);}
            p.flush().unwrap();owner.execute("COMMIT").unwrap();assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),count);
            for n in 1..=count {
                let s=Statement::new(Rc::clone(&owner),"SELECT parent,name,kind,identity,links,flags,payload FROM nodes WHERE id=?").unwrap();s.number(1,n).unwrap();assert!(s.row().unwrap());
                assert_eq!(s.integer(0).unwrap(),0);assert_eq!(s.bytes(1,255).unwrap().unwrap(),format!("{n}.bin").as_bytes());assert_eq!(s.integer(2).unwrap(),0);
                assert_eq!(s.bytes(3,16).unwrap().unwrap(),[7u64.to_be_bytes(),n.to_be_bytes()].concat());
                assert_eq!(s.bytes(4,8).unwrap().unwrap(),1u64.to_be_bytes());assert_eq!(s.bytes(5,4).unwrap().unwrap(),u32::MAX.to_be_bytes());
                let value=decode_payload(&s.bytes(6,52).unwrap().unwrap()).unwrap();
                for (i,wanted) in [Some(u64::MAX),Some(0),None,Some(4096)].into_iter().enumerate(){assert_eq!(value[i*13],u8::from(wanted.is_some()));if let Some(w)=wanted{assert_eq!(u64_at(&value,i*13+1),w);}}
                assert!(!s.row().unwrap());
            }
            let fk=Statement::new(Rc::clone(&owner),"PRAGMA foreign_key_check").unwrap();assert!(!fk.row().unwrap());
        }
    }
    #[test] fn repeated_identity_flushes_before_join_and_keeps_first_facts() {
        let (owner,p,index)=setup();let first=observation(1);assert!(accept(&p,&index,1,&first).fresh);
        assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),0);
        let mut second=first;second.name=b"alias.bin".to_vec();second.links=Some(2);
        let v=accept(&p,&index,2,&second);assert!(!v.fresh&&v.changed);
        assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),1);
        assert_eq!(index.object_counts().unwrap(),(1,0));assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),2);
    }
    #[test] fn error_unknown_and_zero_link_first_facts_keep_exact_fallbacks() {
        let (_,p,index)=setup();let mut first=observation(1);first.error=13;first.links=None;first.flags=None;first.values=[None,Some(u64::MAX),Some(0),None];
        assert!(accept(&p,&index,1,&first).fresh);let mut other=first;other.name=b"alias".to_vec();assert!(!accept(&p,&index,2,&other).changed);
        other.name=b"changed".to_vec();other.links=Some(0);assert!(accept(&p,&index,3,&other).changed);assert_eq!(index.object_counts().unwrap(),(1,0));
    }
    #[test] fn source_switch_reattaches_same_buffer_without_merging_identity() {
        let (owner,p,index)=setup();let first=observation(1);assert!(accept(&p,&index,1,&first).fresh);p.flush().unwrap();owner.execute("COMMIT;BEGIN IMMEDIATE").unwrap();
        let other=ReferenceIndex::for_source(Rc::clone(&owner),2).unwrap();other.attach_writer_buffer(Rc::clone(&p));
        let mut second=observation(1);second.name=b"source2".to_vec();assert!(accept(&p,&other,2,&second).fresh);
        assert_eq!(other.counts(true).unwrap(),(2,0));owner.execute("COMMIT").unwrap();
    }
    #[test] fn every_uncommitted_tail_discards_identity_and_node_together() {
        for tail in 1..16 {
            let (owner,p,index)=setup();accept(&p,&index,1,&observation(1));p.flush().unwrap();owner.execute("COMMIT;BEGIN IMMEDIATE").unwrap();
            for n in 2..=tail+1 {accept(&p,&index,n,&observation(n));}
            owner.execute("ROLLBACK").unwrap();p.discard();owner.execute("BEGIN IMMEDIATE").unwrap();
            assert_eq!(index.object_counts().unwrap(),(1,0));assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),1);
            assert!(accept(&p,&index,2,&observation(2)).fresh);p.flush().unwrap();owner.execute("COMMIT").unwrap();
        }
    }
    #[test] fn failed_batch_is_sticky_and_never_retries_before_rollback() {
        let (owner,p,index)=setup();owner.execute("CREATE TRIGGER refuse_node BEFORE INSERT ON nodes WHEN NEW.id=8 BEGIN SELECT RAISE(ABORT,'generated');END;").unwrap();
        for n in 1..16 {accept(&p,&index,n,&observation(n));}
        let last=observation(16);assert!(index.object([7,16],ObjectFacts{values:last.values,links:last.links,flags:last.flags},16,0).unwrap().fresh);
        assert!(p.push(PendingNode::observed(16,0,&last).unwrap()).is_err());
        assert!(p.flush().is_err());assert!(p.push(PendingNode::observed(17,0,&observation(17)).unwrap()).is_err());
        assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),0);assert!(owner.execute("COMMIT").is_err());
        owner.execute("ROLLBACK;BEGIN IMMEDIATE").unwrap();p.discard();accept(&p,&index,1,&observation(1));p.flush().unwrap();owner.execute("COMMIT").unwrap();
    }
    #[test] fn drop_cannot_publish_pending_nodes_or_dangling_facts() {
        let (owner,p,index)=setup();accept(&p,&index,1,&observation(1));drop(index);drop(p);
        assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),0);assert!(owner.execute("COMMIT").is_err());owner.execute("ROLLBACK").unwrap();
    }
    #[test] fn names_parent_constraints_and_duplicate_batch_stay_enforced() {
        let (owner,p,_)=setup();let mut o=observation(1);
        for bad in [vec![],vec![b'x';256],b"a/b".to_vec(),b".".to_vec(),b"..".to_vec(),vec![0]]{o.name=bad;assert!(PendingNode::observed(1,0,&o).is_err());}
        o.name=vec![b'x';255];p.push(PendingNode::observed(1,0,&o).unwrap()).unwrap();p.flush().unwrap();
        o=observation(2);p.push(PendingNode::observed(2,999,&o).unwrap()).unwrap();assert!(p.flush().is_err());
        owner.execute("ROLLBACK;BEGIN IMMEDIATE").unwrap();p.discard();
        for n in 1..=16 {let mut row=observation(n);row.name=b"duplicate".to_vec();let value=p.push(PendingNode::observed(n,0,&row).unwrap());assert_eq!(value.is_ok(),n<16);}
        assert_eq!(scalar(&owner,"SELECT count(*) FROM nodes WHERE id>0"),0);
    }
}
