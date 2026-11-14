// Stored metadata only. A location is not permission or mutation authority.
// Root0 belongs to a single ordinary scope; startup sources1/2 are explicit
// synthetic catalog rows, never inferred from a directory's display name.
fn location_chain(owner:Rc<Connection>,node:u64,startup:bool)->Result<(u64,Vec<String>)> {
    if node>=i64::MAX as u64 || startup && node==0{return Err("store_source");}
    let row=Statement::new(owner,"SELECT parent,name,kind,identity,flags FROM nodes WHERE id=?")?;
    let mut current=node;let mut chain=vec![];let mut bytes=0;
    loop {
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        if current==0 || startup && current<=2 {
            chain.reverse();return Ok((current,chain));
        }
        if chain.len()>=MAX_DEPTH{return Err("store_depth");}
        row.number(1,current)?;
        if !row.row()?{return Err("store_cursor");}
        let parent=row.integer(0)?;let name=row.bytes(1,255)?.ok_or("store_row")?;let kind=row.integer(2)?;
        let identity=row.bytes(3,16)?.ok_or("store_location_unavailable")?;
        let flags=row.bytes(4,4)?.ok_or("store_location_unavailable")?;
        if parent>=current || name.is_empty() || name.contains(&0) || name.contains(&47) || name==b"." || name==b".."
            || identity.len()!=16 || flags.len()!=4 || kind>1 || !chain.is_empty() && kind!=1{return Err("store_location_unavailable");}
        bytes+=name.len()+1;if bytes>8192{return Err("store_path");}
        let device=u64_at(&identity,0);let inode=u64_at(&identity,8);
        if device==0 || inode==0{return Err("store_location_unavailable");}
        let flags=u32::from_be_bytes(flags.try_into().map_err(|_|"store_row")?);
        chain.push(json_map(vec![("id",quote(&current.to_string())),("parent",quote(&parent.to_string())),
            ("name",quote(&base64(&name))),("type",kind.to_string()),("device",quote(&device.to_string())),
            ("inode",quote(&inode.to_string())),("flags",quote(&flags.to_string()))]));
        row.reset()?;current=parent;
    }
}
fn stored_location(owner:Rc<Connection>,node:u64,startup:bool)->Result<()> {
    let (source,chain)=location_chain(owner,node,startup)?;
    send(json_map(vec![("kind",quote("location")),("location_revision","1".into()),
        ("classification_revision",CLASSIFICATION_REVISION.to_string()),("node",quote(&node.to_string())),
        ("source",source.to_string()),("chain",format!("[{}]",chain.join(",")))]))
}

#[cfg(test)]
mod location_tests {
    use super::*;
    fn fixture()->Rc<Connection> {
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,?,?,?,?)").unwrap();
        for (id,parent,name,kind) in [(1,0,b"Data".as_slice(),1),(2,0,b"System".as_slice(),1),
            (3,1,b"source".as_slice(),1),(4,3,b"file.bin".as_slice(),0),(5,3,b"link".as_slice(),2)] {
            row.number(1,id).unwrap();row.number(2,parent).unwrap();row.blob(3,Some(name)).unwrap();row.number(4,kind).unwrap();
            row.blob(5,Some(&[1u64.to_be_bytes(),id.to_be_bytes()].concat())).unwrap();row.blob(6,Some(&1u64.to_be_bytes())).unwrap();
            row.blob(7,Some(&0u32.to_be_bytes())).unwrap();row.blob(8,Some(&encode_payload(&payload(&Observation::default())).unwrap())).unwrap();row.done().unwrap();
        }db
    }
    #[test] fn startup_source_ids_do_not_depend_on_display_names() {
        let db=fixture();let (source,path)=location_chain(Rc::clone(&db),4,true).unwrap();
        assert_eq!(source,1);assert_eq!(path.len(),2);assert!(path[0].contains("c291cmNl"));
        let (source,path)=location_chain(db,4,false).unwrap();assert_eq!(source,0);assert_eq!(path.len(),3);
    }
    #[test] fn combined_root_links_and_missing_identity_refuse() {
        let db=fixture();assert!(location_chain(Rc::clone(&db),0,true).is_err());
        assert!(location_chain(Rc::clone(&db),5,false).is_err());
        assert!(location_chain(Rc::clone(&db),99,false).is_err());
        db.execute("UPDATE nodes SET identity=NULL WHERE id=3").unwrap();assert!(location_chain(db,4,false).is_err());
    }
    #[test] fn captured_chain_preserves_binary_names_without_reinterpreting_them() {
        let db=fixture();db.execute("UPDATE nodes SET name=x'ff' WHERE id=4").unwrap();
        let (_,chain)=location_chain(db,4,false).unwrap();assert!(chain.last().unwrap().contains("/w=="));
    }
}
