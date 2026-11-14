// Optional source-free global ranking. The heap and ancestry remain fixed size;
// no ingestion/index/schema change, SQL temporary sort or source descriptor.
const LARGEST_FILES_LIMIT:usize=32;
fn ranked_largest_files(owner:Rc<Connection>,metric:u8)->Result<(Vec<PageRow>,u64,u64)> {
    let mode=match metric {0=>2,3=>4,_=>return Err("store_metric")};
    let rows=Statement::new(owner,"SELECT id,name,kind,payload,NULL FROM nodes WHERE kind=0 ORDER BY id")?;
    let mut heap=std::collections::BinaryHeap::with_capacity(LARGEST_FILES_LIMIT);
    let (mut known,mut unknown)=(0u64,0u64);
    while rows.row()? {
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        let row=PageRow::read(&rows,0,mode)?;
        if row.kind!=0{return Err("store_row");}
        if row.key.amount.is_none(){unknown=unknown.checked_add(1).ok_or("store_overflow")?;continue;}
        known=known.checked_add(1).ok_or("store_overflow")?;
        if heap.len()<LARGEST_FILES_LIMIT {heap.push(row);}
        else if heap.peek().is_some_and(|worst:&PageRow|row<*worst){heap.pop();heap.push(row);}
    }
    Ok((heap.into_sorted_vec(),known,unknown))
}
fn largest_file_path(owner:Rc<Connection>,node:u64,startup:bool)->Result<(u64,Vec<u8>)> {
    if node==0 || node>=i64::MAX as u64 || startup && node<=2{return Err("store_row");}
    let row=Statement::new(Rc::clone(&owner),"SELECT parent,name,kind FROM nodes WHERE id=?")?;
    let root=Statement::new(owner,"SELECT kind,parent IS NULL,coalesce(parent,0) FROM nodes WHERE id=?")?;
    let mut current=node;let mut names=Vec::new();let mut length=0usize;
    loop {
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        if current==0 || startup && current<=2 {
            if startup && current==0{return Err("store_source");}
            root.number(1,current)?;
            if !root.row()? || root.integer(0)?!=1 || root.integer(1)?!=if current==0{1}else{0} || root.integer(2)?!=0 || root.row()? {return Err("store_source");}
            names.reverse();return Ok((current,names.join(&b'/')));
        }
        if names.len()>=MAX_DEPTH{return Err("store_depth");}
        row.number(1,current)?;if !row.row()?{return Err("store_cursor");}
        let parent=row.integer(0)?;let name=row.bytes(1,255)?.ok_or("store_row")?;let kind=row.integer(2)?;
        if parent>=current || name.is_empty() || name.contains(&0) || name.contains(&47) || name==b"." || name==b".."
            || kind!=if names.is_empty(){0}else{1} {return Err("store_row");}
        length=length.checked_add(name.len()+usize::from(!names.is_empty())).ok_or("store_path")?;
        if length>8192{return Err("store_path");}
        names.push(name);if row.row()?{return Err("store_row");}row.reset()?;current=parent;
    }
}
fn largest_files(owner:Rc<Connection>,metric:u8,startup:bool)->Result<()> {
    let (rows,known,unknown)=ranked_largest_files(Rc::clone(&owner),metric)?;
    // Four worst-case8KiB raw paths fit inside the existing64KiB frame bound.
    // Entire result: eight row frames plus one end, below512KiB.
    let mut chunk=Vec::with_capacity(4);
    for row in &rows {
        let (source,path)=largest_file_path(Rc::clone(&owner),row.key.id,startup)?;
        if path.rsplit(|v|*v==47).next()!=Some(row.key.name.as_slice()){return Err("store_row");}
        chunk.push(json_map(vec![("id",quote(&row.key.id.to_string())),("name",quote(&base64(&row.key.name))),
            ("payload",quote(&base64(&row.payload))),("source",source.to_string()),("path",quote(&base64(&path)))]));
        if chunk.len()==4 {send(json_map(vec![("kind",quote("largest_rows")),("rows",format!("[{}]",chunk.join(",")))]))?;chunk.clear();}
    }
    if !chunk.is_empty(){send(json_map(vec![("kind",quote("largest_rows")),("rows",format!("[{}]",chunk.join(",")))]))?;}
    if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
    send(json_map(vec![("kind",quote("largest_end")),("largest_files_revision","1".into()),("metric",metric.to_string()),
        ("count",rows.len().to_string()),("rankable",quote(&known.to_string())),("unknown",quote(&unknown.to_string())),("startup",startup.to_string())]))
}

#[cfg(test)] mod largest_file_tests {
    use super::*;
    fn fixture(count:u64)->Rc<Connection> {
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        let directory=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(1,0,x'466f6c646572',1,NULL,NULL,NULL,?)").unwrap();
        directory.blob(1,Some(&encode_payload(&payload(&Observation::default())).unwrap())).unwrap();directory.done().unwrap();
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,1,?,0,NULL,NULL,NULL,?)").unwrap();
        for index in 0..count {
            row.number(1,index+2).unwrap();row.blob(2,Some(format!("file-{index:06}").as_bytes())).unwrap();
            let o=Observation{object_type:Some(1),values:[Some(index%17);4],..Default::default()};
            row.blob(3,Some(&encode_payload(&payload(&o)).unwrap())).unwrap();row.done().unwrap();
        }db
    }
    #[test] fn exact_boundaries_ties_zero_and_literal_paths() {
        for count in [0,1,31,32,33,700] {
            let db=fixture(count);
            for metric in [0,3] {
                let (rows,known,unknown)=ranked_largest_files(Rc::clone(&db),metric).unwrap();
                assert_eq!((rows.len(),known,unknown),(count.min(32) as usize,count,0));
                let mut literal=(0..count).map(|n|(n%17,format!("file-{n:06}"),n+2)).collect::<Vec<_>>();
                literal.sort_by(|a,b|b.0.cmp(&a.0).then_with(||a.1.cmp(&b.1)).then_with(||a.2.cmp(&b.2)));literal.truncate(32);
                assert_eq!(rows.iter().map(|v|(v.key.amount.unwrap(),String::from_utf8(v.key.name.clone()).unwrap(),v.key.id)).collect::<Vec<_>>(),literal);
                for row in rows {
                    let (source,path)=largest_file_path(Rc::clone(&db),row.key.id,false).unwrap();assert_eq!(source,0);
                    assert_eq!(path,[b"Folder/".as_slice(),row.key.name.as_slice()].concat());
                }
            }
        }
    }
    #[test] fn missing_values_raw_names_bad_rows_and_startup_sources() {
        let db=fixture(2);
        let update=Statement::new(Rc::clone(&db),"UPDATE nodes SET payload=? WHERE id=2").unwrap();
        update.blob(1,Some(&encode_payload(&payload(&Observation{object_type:Some(1),values:[None;4],..Default::default()})).unwrap())).unwrap();update.done().unwrap();
        let (rows,known,unknown)=ranked_largest_files(Rc::clone(&db),0).unwrap();assert_eq!((rows.len(),known,unknown),(1,1,1));
        assert!(ranked_largest_files(Rc::clone(&db),1).is_err());
        db.execute("UPDATE nodes SET name=x'ff' WHERE id=3").unwrap();
        assert_eq!(largest_file_path(Rc::clone(&db),3,false).unwrap().1,b"Folder/\xff");
        assert_eq!(largest_file_path(Rc::clone(&db),3,true).unwrap().0,1);
        assert!(largest_file_path(Rc::clone(&db),2,true).is_err());
        assert!(largest_file_path(Rc::clone(&db),0,false).is_err());assert!(largest_file_path(Rc::clone(&db),99,false).is_err());
        let invalid=Statement::new(Rc::clone(&db),"UPDATE nodes SET payload=? WHERE id=3").unwrap();
        let mut bytes=encode_payload(&payload(&Observation::default())).unwrap();bytes[0]=255;
        invalid.blob(1,Some(&bytes)).unwrap();invalid.done().unwrap();assert!(ranked_largest_files(db,0).is_err());
    }
    #[test] fn large_catalog_retains_only_thirty_two_rows() {
        let (rows,known,unknown)=ranked_largest_files(fixture(100_000),3).unwrap();
        assert_eq!((rows.len(),known,unknown),(32,100_000,0));assert!(rows.windows(2).all(|v|v[0].key<v[1].key));
    }
    #[test] fn startup_sources_and_bad_ancestor_kind_are_explicit() {
        let db=fixture(0);let p=encode_payload(&payload(&Observation::default())).unwrap();
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,NULL,NULL,NULL,?)").unwrap();
        for (id,parent,name,kind) in [(2,0,b"Unrelated label".as_slice(),1),(3,1,b"Data file".as_slice(),0),(4,2,b"System file".as_slice(),0)] {
            row.number(1,id).unwrap();row.number(2,parent).unwrap();row.blob(3,Some(name)).unwrap();row.number(4,kind).unwrap();row.blob(5,Some(&p)).unwrap();row.done().unwrap();
        }
        assert_eq!(largest_file_path(Rc::clone(&db),3,true).unwrap(),(1,b"Data file".to_vec()));
        assert_eq!(largest_file_path(Rc::clone(&db),4,true).unwrap(),(2,b"System file".to_vec()));
        db.execute("UPDATE nodes SET kind=0 WHERE id=1").unwrap();assert!(largest_file_path(db,3,true).is_err());
        // Source roots are explicit catalog boundaries; an ordinary non-root
        // ancestor must still be a directory.
        let db=fixture(1);db.execute("UPDATE nodes SET kind=0 WHERE id=1").unwrap();assert!(largest_file_path(db,2,false).is_err());
    }
    #[test] fn exact_path_byte_limit_does_not_charge_an_extra_separator() {
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,NULL,NULL,NULL,?)").unwrap();
        let p=encode_payload(&payload(&Observation::default())).unwrap();
        for id in 1..=33 {
            let name=if id==1{vec![b'a']}else{vec![if id==33{b'c'}else{b'b'};if id==33{254}else{255}]};
            row.number(1,id).unwrap();row.number(2,id-1).unwrap();row.blob(3,Some(&name)).unwrap();row.number(4,if id==33{0}else{1}).unwrap();row.blob(5,Some(&p)).unwrap();row.done().unwrap();
        }
        assert_eq!(largest_file_path(Rc::clone(&db),33,false).unwrap().1.len(),8192);
        let update=Statement::new(Rc::clone(&db),"UPDATE nodes SET name=? WHERE id=33").unwrap();update.blob(1,Some(&vec![b'c';255])).unwrap();update.done().unwrap();
        assert!(largest_file_path(db,33,false).is_err());
    }
}
