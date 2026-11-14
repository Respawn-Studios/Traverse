// Stored, source-free filtered drill-down. A bounded ancestor chain and one
// current child subtotal replace a hierarchy map. Ordinary result writers emit
// depth-first IDs; refuse a noncontiguous child rather than return wrong totals.
#[derive(Clone)]
#[cfg_attr(not(b06_layout_explanations),derive(Copy))]
struct FilterAncestor { id:u64, role:u64, project:u64,
    #[cfg(b06_layout_explanations)] name:Vec<u8>,
}
fn filtered_value(payload:&[u8])->Result<Value> {
    if payload.len()!=52{return Err("store_row");}
    let mut value=Value::default();put(&mut value.0,0,1);
    for metric in 0..4 {
        let p=metric*13;let start=40+metric*25;let number=u64_at(payload,p+1);
        let error=u32::from_be_bytes(payload[p+9..p+13].try_into().map_err(|_|"store_row")?);
        if error>i32::MAX as u32 || (payload[p]!=1 && number!=0) || (payload[p]!=2 && error!=0){return Err("store_row");}
        match payload[p] {0=>put(&mut value.0,start+8,1),1=>put(&mut value.0,start,number),2=>put(&mut value.0,start+16,1),_=>return Err("store_row")}
    }Ok(value)
}
struct FilteredResult { ranking:RankedValues, total:Value, direct:Value }
fn filtered_rules(owner:Rc<Connection>)->Result<()> {
    let rules=Statement::new(owner,"SELECT revision FROM classification_rules WHERE id=1").map_err(|_|"store_classification_revision")?;
    if !rules.row()? || rules.integer(0)?!=CLASSIFICATION_REVISION || rules.row()?{return Err("store_classification_revision");}Ok(())
}
fn visit_filtered(owner:Rc<Connection>,folder:u64,facet:u64,key:u64,projected:bool,layouts:Option<bool>,
    mut visit:impl FnMut(u64,Option<u64>,u64,&[u8],&[u8],usize,Option<u64>)->Result<()>)->Result<()> {
    #[cfg(not(b06_layout_explanations))] let _=layouts;
    if !(3..=7).contains(&facet) || facet==3 && key>=FILE_TYPE_COUNT as u64 || facet==4 && key>=13
        || facet>3 && !projected || key>=i64::MAX as u64{return Err("store_filter");}
    if facet>5 {
        #[cfg(not(b06_application_layouts))] return Err("store_filter");
        #[cfg(b06_application_layouts)] if layouts.is_none() || facet==6 && key>=super::layout_hints::COUNT as u64 || facet==7 && key!=0{return Err("store_filter");}
    }
    let folder_check=Statement::new(Rc::clone(&owner),"SELECT kind FROM nodes WHERE id=?")?;
    folder_check.number(1,folder)?;if !folder_check.row()? || folder_check.integer(0)?!=1{return Err("store_cursor");}drop(folder_check);
    let rows=Statement::new(Rc::clone(&owner),"SELECT parent,name,payload FROM nodes WHERE kind=0 ORDER BY id")?;
    let ancestor=Statement::new(Rc::clone(&owner),if cfg!(b06_layout_explanations) && layouts.is_some() {
        "SELECT n.parent,c.role,c.project,n.name FROM nodes n LEFT JOIN contexts c ON c.node=n.id WHERE n.id=? AND n.kind=1"
    }else{"SELECT n.parent,c.role,c.project FROM nodes n LEFT JOIN contexts c ON c.node=n.id WHERE n.id=? AND n.kind=1"})?;
    let mut path:Vec<FilterAncestor>=Vec::with_capacity(MAX_DEPTH+3);
    #[cfg(b06_layout_explanations)] let (mut layout_hint,mut docker)=(0,false);
    #[cfg(not(b06_layout_explanations))] let layout_hint=0;
    #[cfg(b06_application_layouts)] let mut layout_root=None;
    #[cfg(not(b06_application_layouts))] let layout_root=None;
    while rows.row()? {
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        let parent=rows.integer(0)?;
        if path.last().map(|v|v.id)!=Some(parent) {
            let mut suffix=Vec::with_capacity(MAX_DEPTH+3);let mut current=parent;
            loop {
                if let Some(position)=path.iter().position(|v|v.id==current) {path.truncate(position+1);break;}
                if suffix.len()>MAX_DEPTH+2{return Err("store_depth");}
                ancestor.number(1,current)?;if !ancestor.row()?{return Err("store_parent");}
                let next=ancestor.integer(0)?;
                suffix.push(FilterAncestor{id:current,role:ancestor.integer(1)?,project:ancestor.integer(2)?,
                    #[cfg(b06_layout_explanations)] name:if layouts.is_some(){ancestor.bytes(3,255)?.ok_or("store_row")?}else{vec![]},
                });ancestor.reset()?;
                if current==0 {path.clear();break;}
                if next>=current{return Err("store_parent");}current=next;
            }
            path.extend(suffix.into_iter().rev());
            if path.len()>MAX_DEPTH+3{return Err("store_depth");}
            #[cfg(b06_layout_explanations)]
            if let Some(startup)=layouts {
                use super::layout_hints::{self,Anchor};
                let anchor=if startup {match path.get(1).map(|v|(v.id,v.name.as_slice())) {
                    Some((1,b"Data"))=>Anchor::StartupData,Some((2,b"System"))=>Anchor::StartupSystem,_=>Anchor::Unknown,
                }}else{Anchor::Unknown};
                let mut parts=[b"".as_slice();MAX_DEPTH];let mut count=0;let mut steam=None;
                #[cfg(b06_application_layouts)] let mut ids=[0u64;MAX_DEPTH];
                for node in &path {
                    if node.id==0 || startup && node.id<=2 {continue;}
                    if count>=parts.len(){return Err("store_depth");}
                    if node.name==b"steamapps" && node.role==9 {steam=Some(count);}
                    parts[count]=&node.name;
                    #[cfg(b06_application_layouts)] {ids[count]=node.id;}
                    count+=1;
                }
                let parts=&parts[..count];
                let evidence=layout_hints::directories(parts,anchor,steam);
                layout_hint=evidence.hint as usize;
                #[cfg(b06_application_layouts)] {layout_root=if layout_hint==0{None}else{Some(*ids.get(evidence.root).ok_or("store_layout")?)};}
                docker=layout_hints::docker_parent(parts,anchor) && layout_hint==0;
            }
        }
        let Some(position)=path.iter().position(|v|v.id==folder) else{continue;};
        let context=path.last().ok_or("store_parent")?;
        let matches=match facet {3=>file_type(&rows.bytes(1,255)?.ok_or("store_row")?) as u64==key,4=>context.role==key,5=>context.project==key,6|7=>true,_=>false};
        if !matches {continue;}
        let name=rows.bytes(1,255)?.ok_or("store_row")?;
        let payload=decode_payload(&rows.bytes(2,52)?.ok_or("store_row")?)?;
        let mut child=if parent==folder {None}else{Some(path.get(position+1).ok_or("store_parent")?.id)};
        #[cfg(b06_layout_explanations)] let layout_hint=if docker && name==b"Docker.raw"{super::layout_hints::Hint::DockerVirtualDisk as usize}else{layout_hint};
        #[cfg(b06_application_layouts)] let layout_root=if docker && name==b"Docker.raw"{Some(parent)}else{layout_root};
        if facet==6 && layout_hint as u64!=key{continue;}
        if facet==6 && folder==0 && layout_root.is_some(){child=layout_root;}
        visit(parent,child,context.role,&name,&payload,layout_hint,layout_root)?;
    }
    Ok(())
}
fn filtered_rows(owner:Rc<Connection>,folder:u64,facet:u64,key:u64,metric:u64,projected:bool)->Result<FilteredResult> {
    if metric>3{return Err("store_filter");}
    let mut ranking=RankedValues{metric:metric as usize,..Default::default()};
    let (mut total,mut direct)=(Value::default(),Value::default());
    let (mut branch,mut branch_value)=(None,Value::default());
    #[cfg(b06_application_layouts)] let scope=if facet==6{Some(layout_startup(Rc::clone(&owner))?)}else{None};
    #[cfg(not(b06_application_layouts))] let scope=None;
    visit_filtered(owner,folder,facet,key,projected,scope,|_,child,_,_,payload,_,_| {
        let value=filtered_value(payload)?;total.merge(&value)?;
        let Some(child)=child else{return direct.merge(&value);};
        if branch!=Some(child) {
            if let Some(old)=branch {
                if child<=old{return Err("store_order");}
                ranking.push(old,branch_value)?;branch_value=Value::default();
            }
            branch=Some(child);
        }
        branch_value.merge(&value)
    })?;
    if let Some(child)=branch {ranking.push(child,branch_value)?;}
    Ok(FilteredResult{ranking,total,direct})
}
#[cfg(b06_classification_v3)]
fn other_name_bucket(name:&[u8])->usize {
    let Some(dot)=name.iter().rposition(|b|*b==46) else{return 0;};
    if dot==0{return 1;}if dot+1==name.len(){return 2;}
    let suffix=&name[dot+1..];if suffix.eq_ignore_ascii_case(b"bin") || suffix.eq_ignore_ascii_case(b"dat"){3}else{4}
}
#[cfg(b06_classification_v3)]
fn explain_other(owner:Rc<Connection>,folder:u64,projected:bool,startup:bool)->Result<()> {
    if !projected{return Err("classification_incomplete");}
    let mut roles=[Value::default();13];let mut names=[Value::default();5];let mut total=Value::default();
    #[cfg(b06_layout_explanations)] let mut layouts=[Value::default();super::layout_hints::COUNT];
    let with_layouts=if cfg!(b06_layout_explanations){Some(startup)}else{None};
    visit_filtered(owner,folder,3,0,projected,with_layouts,|_,_,role,name,payload,hint,_| {
        #[cfg(not(b06_layout_explanations))] let _=hint;
        let value=filtered_value(payload)?;
        #[cfg(b06_layout_explanations)] layouts.get_mut(hint).ok_or("store_layout")?.merge(&value)?;
        roles.get_mut(role as usize).ok_or("store_filter")?.merge(&value)?;
        names[other_name_bucket(name)].merge(&value)?;total.merge(&value)
    })?;
    let encode=|values:&[Value]|format!("[{}]",values.iter().enumerate().map(|(id,v)|json_map(vec![("id",id.to_string()),("value",quote(&base64(&v.0)))])).collect::<Vec<_>>().join(","));
    let mut fields=vec![("kind",quote("other_explanation")),("classification_revision",CLASSIFICATION_REVISION.to_string()),("parent",quote(&folder.to_string())),
        ("value",quote(&base64(&total.0))),("roles",encode(&roles)),("name_patterns",encode(&names))];
    #[cfg(b06_layout_explanations)] fields.extend([("layout_revision","1".into()),("layouts",encode(&layouts))]);
    #[cfg(not(b06_layout_explanations))] let _=&mut fields;
    send(json_map(fields))
}
#[cfg(b06_application_layouts)]
include!("result_application_layouts.rs");
fn filtered_breakdown(owner:Rc<Connection>,folder:u64,facet:u64,key:u64,metric:u64,projected:bool)->Result<()> {
    filtered_rules(Rc::clone(&owner))?;
    let value=filtered_rows(Rc::clone(&owner),folder,facet,key,metric,projected)?;
    let mut rows=vec![];
    for (id,total) in &value.ranking.best {
        let name=Statement::new(Rc::clone(&owner),"SELECT name FROM nodes WHERE id=? AND kind=1")?;name.number(1,*id)?;
        if !name.row()?{return Err("store_row");}
        rows.push(json_map(vec![("folder",quote(&id.to_string())),("name",quote(&base64(&name.bytes(0,255)?.ok_or("store_row")?))),("hint","0".into()),("value",quote(&base64(&total.0)))]));
    }
    if u64_at(&value.direct.0,0)>0 {rows.push(json_map(vec![("folder","null".into()),("name",quote("")),("hint","6".into()),("value",quote(&base64(&value.direct.0)))]));}
    send(json_map(vec![("kind",quote("breakdown")),("metric",metric.to_string()),("filter_facet",facet.to_string()),("filter_key",quote(&key.to_string())),("parent",quote(&folder.to_string())),
        ("value",quote(&base64(&value.total.0))),("rows",format!("[{}]",rows.join(","))),("remainder",quote(&base64(&value.ranking.remainder.0)))]))
}

#[cfg(b06_classification_v3)]
fn project_composition_values(owner:Rc<Connection>,folder:u64,key:u64,projected:bool)->Result<(Value,Vec<Value>,Vec<Value>)> {
    if !projected || (key==0 && folder!=0) || (key>0 && folder.checked_add(1)!=Some(key)) {return Err("store_project");}
    filtered_rules(Rc::clone(&owner))?;
    let mut total=Value::default();let mut types=vec![Value::default();FILE_TYPE_COUNT];let mut roles=vec![Value::default();13];
    visit_filtered(owner,folder,5,key,projected,None,|_,_,role,name,payload,_,_| {
        let value=filtered_value(payload)?;
        total.merge(&value)?;
        types.get_mut(file_type(name)).ok_or("store_type")?.merge(&value)?;
        roles.get_mut(usize::try_from(role).map_err(|_|"store_role")?).ok_or("store_role")?.merge(&value)
    })?;
    Ok((total,types,roles))
}
#[cfg(b06_classification_v3)]
fn project_composition(owner:Rc<Connection>,folder:u64,key:u64,metric:u64,projected:bool)->Result<()> {
    let (total,types,roles)=project_composition_values(owner,folder,key,projected)?;
    let encode=|values:Vec<Value>|->String {
        let rows:Vec<String>=values.into_iter().enumerate().filter(|(_,v)|u64_at(&v.0,0)>0)
            .map(|(id,v)|json_map(vec![("key",quote(&id.to_string())),("value",quote(&base64(&v.0)))] )).collect();
        format!("[{}]",rows.join(","))
    };
    send(json_map(vec![("kind",quote("project-composition")),("revision","1".into()),
        ("classification_revision",CLASSIFICATION_REVISION.to_string()),("metric",metric.to_string()),
        ("parent",quote(&folder.to_string())),("project",quote(&key.to_string())),
        ("value",quote(&base64(&total.0))),("file_types",encode(types)),("roles",encode(roles))]))
}

#[cfg(test)]
mod filtered_tests {
    use super::*;
    fn fixture(interleaved:bool)->Rc<Connection> {
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        let add=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,NULL,NULL,NULL,?)").unwrap();
        let mut observations=vec![(1,0,b"one".as_slice(),1,0),(2,1,b"movie.mp4".as_slice(),0,10),(3,1,b"x".as_slice(),0,20),
            (4,0,b"two".as_slice(),1,0),(5,4,b"picture.png".as_slice(),0,30),(6,4,b"y".as_slice(),0,40),(7,0,b"direct".as_slice(),0,50)];
        if interleaved {observations.push((8,1,b"late".as_slice(),0,60));}
        for (id,parent,name,k,bytes) in observations {
            let o=Observation{object_type:Some(if k==0{1}else{2}),values:[Some(bytes);4],..Default::default()};
            add.number(1,id).unwrap();add.number(2,parent).unwrap();add.blob(3,Some(name)).unwrap();add.number(4,k).unwrap();add.blob(5,Some(&encode_payload(&payload(&o)).unwrap())).unwrap();add.done().unwrap();
        }
        db.execute("INSERT INTO contexts VALUES(0,0,0),(1,9,2),(4,3,0)").unwrap();db
    }
    #[test] fn changed_or_missing_rule_provenance_refuses_without_reclassifying_old_results() {
        let db=fixture(false);assert!(filtered_rules(Rc::clone(&db)).is_ok());
        db.execute("DELETE FROM classification_rules").unwrap();assert!(filtered_rules(Rc::clone(&db)).is_err());
        db.execute("DROP TABLE classification_rules").unwrap();assert!(filtered_rules(Rc::clone(&db)).is_err());
        db.execute("CREATE TABLE classification_rules(id INTEGER PRIMARY KEY,revision INTEGER);INSERT INTO classification_rules VALUES(1,99)").unwrap();
        assert!(filtered_rules(db).is_err());
    }
    #[test] fn filtered_partitions_keep_the_filter_in_child_and_direct_totals() {
        let db=fixture(false);
        for (facet,key,expected) in [(3,0,110),(3,6,10),(4,9,30),(5,0,120),(5,2,30)] {
            let r=filtered_rows(Rc::clone(&db),0,facet,key,0,true).unwrap();
            assert_eq!(u64_at(&r.total.0,40),expected);
            let mut sum=r.direct;sum.merge(&r.ranking.remainder).unwrap();for (_,v) in r.ranking.best {sum.merge(&v).unwrap();}assert_eq!(sum,r.total);
        }
        let r=filtered_rows(Rc::clone(&db),1,3,0,0,true).unwrap();assert_eq!(u64_at(&r.total.0,40),20);assert_eq!(r.total,r.direct);
        assert_eq!(u64_at(&filtered_rows(Rc::clone(&db),0,3,0,0,false).unwrap().total.0,40),110);
        assert!(filtered_rows(Rc::clone(&db),0,4,0,0,false).is_err());
        assert!(filtered_rows(Rc::clone(&db),99,3,0,0,true).is_err());
        assert!(filtered_rows(Rc::clone(&db),0,3,999,0,true).is_err());
    }
    #[cfg(b06_classification_v3)]
    #[test] fn project_composition_partitions_one_exact_project_and_refuses_foreign_roots() {
        let db=fixture(false);
        let (total,types,roles)=project_composition_values(Rc::clone(&db),1,2,true).unwrap();
        assert_eq!(u64_at(&total.0,40),30);assert_eq!(u64_at(&roles[9].0,40),30);
        assert_eq!(u64_at(&types[6].0,40),10);assert_eq!(u64_at(&types[0].0,40),20);
        for values in [types,roles] {let mut sum=Value::default();for value in values {sum.merge(&value).unwrap();}assert_eq!(sum,total);}
        assert!(project_composition_values(Rc::clone(&db),0,2,true).is_err());
        assert!(project_composition_values(Rc::clone(&db),1,0,true).is_err());
        assert!(project_composition_values(Rc::clone(&db),1,2,false).is_err());
        db.execute("UPDATE contexts SET project=7 WHERE node=1").unwrap();
        let (empty,_,_)=project_composition_values(db,1,2,true).unwrap();assert_eq!(empty,Value::default());
    }
    #[test] fn noncontiguous_children_refuse_instead_of_duplicating_chart_totals() {
        assert!(filtered_rows(fixture(true),0,3,0,0,true).is_err());
    }
    #[test] fn filtered_metrics_preserve_failed_missing_zero_and_overflow() {
        let o=Observation{object_type:Some(1),values:[Some(u64::MAX),None,Some(0),None],..Default::default()};
        let mut a=filtered_value(&payload(&o)).unwrap();assert_eq!(a,Value::observation(&o));
        a.merge(&filtered_value(&payload(&o)).unwrap()).unwrap();assert_eq!(a.0[64],1);
        let b=Observation{error:13,..o};assert_eq!(filtered_value(&payload(&b)).unwrap(),Value::observation(&b));
        let mut invalid=payload(&b);invalid[0]=8;assert!(filtered_value(&invalid).is_err());
    }
}

#[cfg(all(test,b06_layout_explanations))]
mod layout_query_tests {
    use super::*;
    #[test] fn stored_layouts_partition_exactly_and_require_startup_provenance() {
        let cases=[
            ("Data/Users/generated/Projects/Machine.pvm/disk.dat",10,10usize),
            ("Data/Users/generated/.cache/huggingface/hub/models--org--name/blobs/opaque",20,14),
            ("Data/Users/generated/.cache/huggingface/hub/datasets--org--name/blobs/opaque",30,15),
            ("Data/Users/generated/.cache/huggingface/hub/spaces--org--name/blobs/opaque",40,16),
            ("Data/Users/generated/Library/Application Support/MobileSync/Backup/id/opaque",50,11),
            ("Data/Users/generated/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",60,18),
            ("Data/Users/generated/Library/Developer/Xcode/Archives/date/opaque",70,7),
            ("Data/Users/generated/Library/Android/sdk/opaque",80,8),
            ("Data/Users/generated/Projects/Library/Application Support/MobileSync/Backup/opaque",90,0),
        ];
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        let mut records=std::collections::BTreeMap::new();
        for (path,bytes,_) in cases {
            let parts=path.split('/').map(|v|v.as_bytes().to_vec()).collect::<Vec<_>>();
            for end in 1..parts.len(){records.insert(parts[..end].to_vec(),(1,0));}
            records.insert(parts,(0,bytes));
        }
        let mut ids=std::collections::BTreeMap::from([(Vec::<Vec<u8>>::new(),0u64),
            (vec![b"Data".to_vec()],1),(vec![b"System".to_vec()],2)]);
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,NULL,NULL,NULL,?)").unwrap();
        for (id,name) in [(1,b"Data".as_slice()),(2,b"System".as_slice())] {
            row.number(1,id).unwrap();row.number(2,0).unwrap();row.blob(3,Some(name)).unwrap();row.number(4,1).unwrap();
            row.blob(5,Some(&encode_payload(&payload(&Observation::default())).unwrap())).unwrap();row.done().unwrap();
        }
        db.execute("INSERT INTO contexts VALUES(1,0,0),(2,12,0)").unwrap();
        let mut next=3u64;
        for (parts,(kind,bytes)) in records {
            if ids.contains_key(&parts){continue;}
            let parent=ids[&parts[..parts.len()-1]];
            row.number(1,next).unwrap();row.number(2,parent).unwrap();row.blob(3,Some(parts.last().unwrap())).unwrap();row.number(4,kind).unwrap();
            let o=Observation{object_type:Some(if kind==0{1}else{2}),values:[Some(bytes);4],..Default::default()};
            row.blob(5,Some(&encode_payload(&payload(&o)).unwrap())).unwrap();row.done().unwrap();
            if kind==1 {db.execute(&format!("INSERT INTO contexts VALUES({next},0,0)")).unwrap();}
            ids.insert(parts,next);next+=1;
        }
        db.execute("INSERT INTO contexts VALUES(0,0,0)").unwrap();
        for startup in [false,true] {
            let mut actual=[Value::default();super::super::layout_hints::COUNT];
            // This generated catalog has exactly one synthetic Data root at1.
            visit_filtered(Rc::clone(&db),0,3,0,true,Some(startup),|_,_,_,_,p,hint,_|actual[hint].merge(&filtered_value(p)?)).unwrap();
            let mut expected=[0u64;19];
            // Existing v3 treats .raw as an image suffix. This explanation
            // must retain the Other filter, not recategorize that file.
            for (path,bytes,hint) in cases {
                if path.ends_with("Docker.raw"){continue;}
                expected[if startup || hint==10{hint}else{0}]+=bytes;
            }
            for (hint,total) in actual.iter().enumerate() {
                for metric in 0..4 {assert_eq!(u64_at(&total.0,40+metric*25),expected[hint]);}
            }
            assert_eq!(actual.iter().map(|v|u64_at(&v.0,40)).sum::<u64>(),390);
        }
    }
}
