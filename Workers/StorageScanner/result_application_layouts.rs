// Optional query revision1 over the existing v3 catalog. No new writer table,
// scan/sealing pass, source descriptor, body read or old-result reinterpretation.
fn layout_startup(owner:Rc<Connection>)->Result<bool> {
    let profile=Statement::new(owner,"SELECT revision FROM profile WHERE id=1")?;
    if !profile.row()?{return Err("store_profile");}
    let revision=profile.integer(0)?;
    if ![PROFILE,PROFILE+1].contains(&revision) || profile.row()?{return Err("store_profile");}
    Ok(revision==PROFILE+1)
}
fn application_layout_values(owner:Rc<Connection>,projected:bool,startup:bool)->Result<([Value;super::layout_hints::COUNT],Value)> {
    filtered_rules(Rc::clone(&owner))?;
    let mut values=[Value::default();super::layout_hints::COUNT];let mut total=Value::default();
    // Facet7 is private to this partition builder. The wire query grammar never
    // admits it, so an external filter cannot turn into an unfiltered result.
    visit_filtered(owner,0,7,0,projected,Some(startup),|_,_,_,_,payload,hint,_| {
        let value=filtered_value(payload)?;
        values.get_mut(hint).ok_or("store_layout")?.merge(&value)?;total.merge(&value)
    })?;
    Ok((values,total))
}
fn application_layout_groups(owner:Rc<Connection>,projected:bool,startup:bool)->Result<()> {
    let (values,total)=application_layout_values(Rc::clone(&owner),projected,startup)?;
    let root=Statement::new(owner,"SELECT value FROM rollups WHERE node=0")?;
    if !root.row()?{return Err("store_summary");}
    let expected=decode_value(&root.bytes(0,175)?.ok_or("store_summary")?)?;
    if u64_at(&total.0,0)!=u64_at(&expected.0,0) || total.0[40..]!=expected.0[40..]{return Err("store_layout_partition");}
    // A fixed vocabulary is small enough to expose every named layout. The
    // native pie independently bounds its slices; its All Layouts menu keeps
    // small categories reachable rather than hiding them in a remainder.
    let ordering=RankedValues::default();let mut named=vec![];
    for (key,value) in values.into_iter().enumerate(){if value.entries()?>0{named.push((key as u64,value));}}
    named.sort_by(|a,b|if ordering.before(a,b){std::cmp::Ordering::Less}else if ordering.before(b,a){std::cmp::Ordering::Greater}else{std::cmp::Ordering::Equal});
    let rows=named.iter().map(|(key,value)|json_map(vec![("key",quote(&key.to_string())),
        ("name",quote("")),("value",quote(&base64(&value.0)))])).collect::<Vec<_>>();
    send(json_map(vec![("kind",quote("application_layouts")),("layout_revision","1".into()),
        ("classification_revision",CLASSIFICATION_REVISION.to_string()),("value",quote(&base64(&total.0))),
        ("groups",format!("[{}]",rows.join(","))),("remainder",quote(&base64(&Value::default().0))),
        ("total_groups",quote(&named.len().to_string())),("project_count",quote("0"))]))
}

#[cfg(test)]
mod application_layout_tests {
    use super::*;
    fn fixture(paths:&[(&str,u64)],startup:bool)->Rc<Connection> {
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        db.execute(&format!("INSERT INTO profile VALUES(1,{},zeroblob(36),{ROWS});INSERT INTO contexts VALUES(0,0,0)",PROFILE+u64::from(startup))).unwrap();
        let mut records=std::collections::BTreeMap::new();
        for (path,bytes) in paths {
            let parts=path.split('/').map(|v|v.as_bytes().to_vec()).collect::<Vec<_>>();
            for end in 1..parts.len(){records.insert(parts[..end].to_vec(),(1,0));}
            records.insert(parts,(0,*bytes));
        }
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,NULL,NULL,NULL,?)").unwrap();
        let mut ids=std::collections::BTreeMap::from([(Vec::<Vec<u8>>::new(),0u64)]);
        for (index,(parts,(kind,bytes))) in records.into_iter().enumerate() {
            let id=index as u64+1;let parent=ids[&parts[..parts.len()-1]];let name=parts.last().unwrap();
            row.number(1,id).unwrap();row.number(2,parent).unwrap();row.blob(3,Some(name)).unwrap();row.number(4,kind).unwrap();
            let observation=Observation{object_type:Some(if kind==0{1}else{2}),values:[Some(bytes),Some(bytes+1),Some(0),None],..Default::default()};
            row.blob(5,Some(&encode_payload(&payload(&observation)).unwrap())).unwrap();row.done().unwrap();
            if kind==1 {
                let role=if parts.iter().any(|v|v==b"steamapps") && !parts.iter().any(|v|v==b"Lookalike"){9}else{0};
                db.execute(&format!("INSERT INTO contexts VALUES({id},{role},0)")).unwrap();
            }
            ids.insert(parts,id);
        }db
    }
    fn folder(db:Rc<Connection>,name:&[u8])->u64 {
        let value=Statement::new(db,"SELECT id FROM nodes WHERE kind=1 AND name=?").unwrap();value.blob(1,Some(name)).unwrap();
        assert!(value.row().unwrap());value.integer(0).unwrap()
    }
    #[test] fn layouts_span_all_file_types_and_jump_to_the_evidenced_root() {
        let db=fixture(&[("Apps/Editor.app/Contents/movie.mp4",10),("Apps/Editor.app/Contents/settings.json",20),
            ("Apps/Editor.app/Contents/opaque",30),("Unrelated.app-file/x.bin",40)],false);
        let (groups,total)=application_layout_values(Rc::clone(&db),true,false).unwrap();
        assert_eq!(u64_at(&groups[1].0,40),60);assert_eq!(u64_at(&groups[0].0,40),40);
        assert_eq!(u64_at(&total.0,40),100);
        let root=filtered_rows(Rc::clone(&db),0,6,1,0,true).unwrap();
        assert_eq!(root.ranking.best.len(),1);assert_eq!(root.ranking.best[0].0,folder(Rc::clone(&db),b"Editor.app"));
        assert_eq!(root.total,groups[1]);
        let child=filtered_rows(Rc::clone(&db),folder(db,b"Editor.app"),6,1,0,true).unwrap();
        assert_eq!(child.total,groups[1]);assert_eq!(child.ranking.best.len(),1);
    }
    #[test] fn layout_partitions_preserve_all_four_metrics_unknowns_and_zeros() {
        let db=fixture(&[("A.app/video.mov",3),("Machine.pvm/disk.dat",9),("Unknown/image.png",0)],false);
        let (groups,total)=application_layout_values(db,true,false).unwrap();
        let mut merged=Value::default();for value in groups{merged.merge(&value).unwrap();}
        assert_eq!(merged,total);assert_eq!(u64_at(&total.0,0),3);
        assert_eq!(u64_at(&total.0,40),12);assert_eq!(u64_at(&total.0,65),15);
        assert_eq!(u64_at(&total.0,90),0);assert_eq!(u64_at(&total.0,123),3);
    }
    #[test] fn steam_requires_existing_context_and_keeps_its_filter_in_every_child() {
        let db=fixture(&[("Games/steamapps/common/Game/movie.mp4",7),("Games/steamapps/workshop/id/content.bin",11),
            ("Lookalike/steamapps/common/Game/opaque",13)],false);
        let (groups,_)=application_layout_values(Rc::clone(&db),true,false).unwrap();
        assert_eq!(u64_at(&groups[2].0,40),7);assert_eq!(u64_at(&groups[3].0,40),11);assert_eq!(u64_at(&groups[0].0,40),13);
        let result=filtered_rows(db,0,6,2,0,true).unwrap();assert_eq!(result.total,groups[2]);
    }
    #[test] fn layout_queries_refuse_unprojected_unknown_keys_and_changed_rules() {
        let db=fixture(&[("A.app/file.txt",1)],false);
        assert!(application_layout_values(Rc::clone(&db),false,false).is_err());
        assert!(filtered_rows(Rc::clone(&db),0,6,19,0,true).is_err());
        db.execute("DELETE FROM classification_rules").unwrap();
        assert!(application_layout_values(db,true,false).is_err());
    }
}
