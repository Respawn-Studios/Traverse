mod purpose_tests {
    use super::*;
    use std::collections::BTreeMap;
    #[derive(Clone)]
    struct Node {id:u64,parent:u64,name:Vec<u8>,kind:u64,role:u64,project:u64,marked:bool,value:Value}
    struct Fixture {nodes:Vec<Node>,startup:bool,data_last:Option<u64>}
    fn regular(numbers:[Option<u64>;4],error:bool)->Value {
        Value::observation(&Observation{object_type:Some(1),values:numbers,error:if error{5}else{0},..Default::default()})
    }
    impl Fixture {
        fn new(startup:bool)->Self {
            let mut nodes=vec![Node{id:0,parent:0,name:vec![],kind:1,role:0,project:0,marked:false,value:Value::default()}];
            if startup {for(id,name)in [(1,b"Data".as_slice()),(2,b"System".as_slice())]{nodes.push(Node{id,parent:0,name:name.to_vec(),kind:1,role:if id==2{12}else{0},project:0,marked:false,value:Value::default()});}}
            Self{nodes,startup,data_last:None}
        }
        fn folder(&mut self,parent:u64,name:&str,role:u64,project:u64,marked:bool)->u64 {
            let id=self.nodes.len()as u64;self.nodes.push(Node{id,parent,name:name.as_bytes().to_vec(),kind:1,role,project,marked,value:Value::default()});id
        }
        fn project(&mut self,parent:u64,name:&str)->u64 {
            let id=self.nodes.len()as u64;self.folder(parent,name,0,id+1,true)
        }
        fn file(&mut self,parent:u64,value:Value)->u64 {
            let id=self.nodes.len()as u64;self.nodes.push(Node{id,parent,name:format!("file-{id}.bin").into_bytes(),kind:0,role:0,project:0,marked:false,value});id
        }
        fn other(&mut self,parent:u64)->u64 {
            let id=self.nodes.len()as u64;let mut value=Value::default();put(&mut value.0,16,1);
            self.nodes.push(Node{id,parent,name:format!("link-{id}").into_bytes(),kind:2,role:0,project:0,marked:false,value});id
        }
        fn split(&mut self){self.data_last=Some(self.nodes.len()as u64-1);}
        fn entries(&self)->u64 {self.nodes.len()as u64-if self.startup{3}else{1}}
        fn reference(&self,role:u64)->BTreeMap<u64,Value> {
            let map:BTreeMap<_,_>=self.nodes.iter().map(|n|(n.id,n)).collect();let mut expected=BTreeMap::<u64,Value>::new();
            for file in self.nodes.iter().filter(|n|n.kind==0) {
                let parent=map[&file.parent];if parent.role!=role{continue;}
                let mut node=parent;let mut project=0;
                loop {
                    if node.project==node.id+1 && node.marked{project=node.id+1;break;}
                    if node.id==0 || self.startup && node.id<=2{break;}node=map[&node.parent];
                }
                expected.entry(project).or_default().merge(&file.value).unwrap();
            }expected
        }
        fn database(&self)->Rc<Connection> {
            let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
            let insert=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,?,?,?,NULL,NULL,NULL,?)").unwrap();
            for node in self.nodes.iter().skip(1) {
                insert.number(1,node.id).unwrap();insert.number(2,node.parent).unwrap();insert.blob(3,Some(&node.name)).unwrap();insert.number(4,node.kind).unwrap();
                insert.blob(5,Some(&encode_payload(&[0;52]).unwrap())).unwrap();insert.done().unwrap();
            }
            let mut whole=BTreeMap::<u64,Value>::new();let mut direct=BTreeMap::<u64,Value>::new();
            for node in &self.nodes {if node.kind==1 {whole.insert(node.id,Value::default());direct.insert(node.id,Value::default());}}
            for node in self.nodes.iter().rev() {
                if node.id==0{continue;}
                let mut value=if node.kind==1{whole[&node.id]}else{node.value};
                if node.kind==1 && !(self.startup && node.id<=2){let mut own=Value::default();put(&mut own.0,8,1);value.merge(&own).unwrap();}
                whole.get_mut(&node.parent).unwrap().merge(&value).unwrap();
                if node.kind==0 {direct.get_mut(&node.parent).unwrap().merge(&node.value).unwrap();}
            }
            let context=Statement::new(Rc::clone(&db),"INSERT INTO contexts VALUES(?,?,?)").unwrap();
            let marker=Statement::new(Rc::clone(&db),"INSERT INTO markers VALUES(?,2)").unwrap();
            let files=Statement::new(Rc::clone(&db),"INSERT INTO direct_files VALUES(?,?)").unwrap();
            let rollup=Statement::new(Rc::clone(&db),"INSERT INTO rollups VALUES(?,?)").unwrap();let mut roles=[Value::default();13];
            for node in self.nodes.iter().filter(|n|n.kind==1) {
                context.number(1,node.id).unwrap();context.number(2,node.role).unwrap();context.number(3,node.project).unwrap();context.done().unwrap();
                if node.marked{marker.number(1,node.id).unwrap();marker.done().unwrap();}
                files.number(1,node.id).unwrap();files.blob(2,Some(&encode_value(&direct[&node.id]))).unwrap();files.done().unwrap();
                rollup.number(1,node.id).unwrap();rollup.blob(2,Some(&encode_value(&whole[&node.id]))).unwrap();rollup.done().unwrap();
                roles[node.role as usize].merge(&direct[&node.id]).unwrap();
            }
            let group=Statement::new(Rc::clone(&db),"INSERT INTO groups VALUES(1,?,?)").unwrap();
            for(key,value)in roles.iter().enumerate(){group.number(1,key as u64).unwrap();group.blob(2,Some(&encode_value(value))).unwrap();group.done().unwrap();}
            if self.startup {
                let last=self.nodes.len()as u64-1;let data=self.data_last.unwrap();
                db.execute(&format!("CREATE TABLE source_roots(id INTEGER PRIMARY KEY,first_row INTEGER,last_row INTEGER,finished INTEGER);INSERT INTO source_roots VALUES(1,3,{data},1),(2,{}, {last},1)",data+1)).unwrap();
            }
            db.execute(&format!("UPDATE scan_state SET state=1,projected=1,entries={};COMMIT",self.entries())).unwrap();db
        }
        fn values(&self,db:Rc<Connection>,role:u64,project:Option<u64>,metric:u64)->Result<PurposeValues>{purpose_values(db,role,project,metric,self.startup,self.entries(),true)}
    }
    fn ranked(reference:&BTreeMap<u64,Value>,metric:u64)->(Vec<(u64,Value)>,Value) {
        // Materialized independent reference: fully sort completed groups.
        let offset=40+25*metric as usize;let mut rows:Vec<_>=reference.iter().map(|(k,v)|(*k,*v)).collect();
        rows.sort_by(|a,b|a.1.0[offset+24].cmp(&b.1.0[offset+24]).then_with(||u64_at(&b.1.0,offset).cmp(&u64_at(&a.1.0,offset))).then_with(||a.0.cmp(&b.0)));
        let mut remainder=Value::default();for(_,value)in rows.iter().skip(12){remainder.merge(value).unwrap();}rows.truncate(12);(rows,remainder)
    }
    #[test]fn purpose_namespace_matches_materialized_all_metric_reference_and_exact_remainder(){
        let mut f=Fixture::new(false);
        for i in 0..35u64 {
            let project=f.project(0,&format!("Project-{i}"));f.file(project,regular([Some(7);4],false));
            let cache=f.folder(project,".cache",3,0,false);f.file(cache,regular([Some(i%8),Some(100-i),Some(i*11),if i%3==0{None}else{Some(i)}],false));
            if i%5==0{f.file(cache,regular([None;4],true));}
        }
        let shared=f.folder(0,"Shared",3,0,false);f.file(shared,regular([Some(19);4],false));
        let db=f.database();let expected=f.reference(3);
        for metric in 0..4 {
            let result=f.values(Rc::clone(&db),3,None,metric).unwrap();let(best,remainder)=ranked(&expected,metric);
            assert_eq!(result.ranking.best,best);assert_eq!(result.ranking.remainder,remainder);assert_eq!(result.ranking.total,36);
            let mut total=Value::default();for value in expected.values(){total.merge(value).unwrap();}assert_eq!(result.total,total);
        }
    }
    #[test]fn nested_projects_finalize_then_outer_project_resumes_without_cache_attribution_changes(){
        let mut f=Fixture::new(false);let a=f.project(0,"Outer");let cache=f.folder(a,".cache",3,0,false);f.file(cache,regular([Some(11);4],false));
        let b=f.project(a,"Nested");let cache=f.folder(b,".cache",3,0,false);f.file(cache,regular([Some(23);4],false));
        let cache=f.folder(a,".npm",3,a+1,false);f.file(cache,regular([Some(31);4],false));
        let db=f.database();let result=f.values(Rc::clone(&db),3,None,0).unwrap();
        assert_eq!(result.ranking.best,vec![(a+1,regular([Some(42);4],false)),(b+1,regular([Some(23);4],false))].into_iter().map(|(id,mut value)|{put(&mut value.0,0,if id==a+1{2}else{1});(id,value)}).collect::<Vec<_>>());
        let old=Statement::new(db,"SELECT project FROM contexts WHERE role=3 ORDER BY node").unwrap();let mut observed=vec![];while old.row().unwrap(){observed.push(old.integer(0).unwrap());}assert_eq!(observed,vec![0,0,a+1]);
    }
    #[test]fn source_order_handles_project_on_data_root_and_empty_system_range(){
        for empty_system in [false,true] {
            let mut f=Fixture::new(true);f.nodes[1].project=2;f.nodes[1].marked=true;f.file(1,regular([Some(3);4],false));
            let cache=f.folder(1,".cache",3,0,false);f.file(cache,regular([Some(13);4],false));f.split();
            if !empty_system{let c=f.folder(2,"Outside",3,0,false);f.file(c,regular([Some(17);4],false));}
            let db=f.database();let result=f.values(Rc::clone(&db),3,None,0).unwrap();let expected=f.reference(3);assert_eq!(result.ranking.best,ranked(&expected,0).0);
            assert_eq!(f.values(db,3,Some(2),0).unwrap().total,regular([Some(13);4],false));
        }
    }
    #[test]fn empty_data_range_and_final_system_descendants_are_not_skipped(){
        let mut f=Fixture::new(true);f.split();let project=f.project(2,"Project");let cache=f.folder(project,".cache",3,0,false);f.file(cache,regular([Some(29);4],false));
        let db=f.database();assert_eq!(f.values(db,3,None,0).unwrap().ranking.best,vec![(project+1,regular([Some(29);4],false))]);
    }
    #[test]fn matching_locations_are_nonoverlapping_and_mixed_whole_values_remain_distinct(){
        let mut f=Fixture::new(false);let project=f.project(0,"Project");let cache=f.folder(project,".cache",3,0,false);f.file(cache,regular([Some(11);4],false));
        let sub=f.folder(cache,"Sub",3,0,false);f.file(sub,regular([Some(13);4],false));let model=f.folder(cache,"huggingface",4,0,false);f.file(model,regular([Some(101);4],false));f.other(cache);
        let other=f.folder(project,".npm",3,project+1,false);f.file(other,regular([Some(17);4],false));
        let db=f.database();let result=f.values(Rc::clone(&db),3,Some(project+1),0).unwrap();
        assert_eq!(result.ranking.best.iter().map(|(id,_)|*id).collect::<Vec<_>>(),vec![cache,other]);assert_eq!(u64_at(&result.total.0,40),41);
        let whole=purpose_rollup(db,cache).unwrap();assert_eq!(u64_at(&whole.0,40),125);assert_eq!(u64_at(&whole.0,16),1);assert_ne!(purpose_regular(whole),result.ranking.best[0].1);
    }
    #[test]fn shared_location_never_invents_a_project_owner(){
        let mut f=Fixture::new(false);let cache=f.folder(0,"Caches",3,0,false);f.file(cache,regular([Some(7);4],false));
        let db=f.database();assert_eq!(f.values(Rc::clone(&db),3,None,0).unwrap().ranking.best[0].0,0);assert_eq!(f.values(db,3,Some(0),0).unwrap().ranking.best[0].0,cache);
    }
    #[test]fn zero_unknown_failed_and_overflow_metrics_partition_without_integer_sum(){
        let mut f=Fixture::new(false);let project=f.project(0,"Project");let c=f.folder(project,".cache",3,0,false);
        f.file(c,regular([Some(u64::MAX),Some(0),None,Some(7)],false));f.file(c,regular([Some(1),Some(0),None,Some(9)],false));f.file(c,regular([None;4],true));
        let result=f.values(f.database(),3,None,0).unwrap();assert_eq!(result.total.0[64],1);assert_eq!(u64_at(&result.total.0,0),3);assert_eq!(u64_at(&result.total.0,98),2);assert_eq!(u64_at(&result.total.0,106),1);assert_eq!(result.total,result.ranking.best[0].1);
    }
    #[test]fn thousands_of_projects_have_no_global_map_or_partial_group_ranking(){
        let mut f=Fixture::new(false);for i in 0..5000 {let p=f.project(0,&format!("P{i}"));let c=f.folder(p,".cache",3,0,false);f.file(c,regular([Some((i%29)as u64);4],false));}
        let expected=f.reference(3);let result=f.values(f.database(),3,None,3).unwrap();let(best,remainder)=ranked(&expected,3);assert_eq!(result.ranking.best,best);assert_eq!(result.ranking.remainder,remainder);assert_eq!(result.ranking.total,5000);
    }
    #[test]fn noncontiguous_parent_reentry_refuses_the_whole_new_view(){
        let mut f=Fixture::new(false);let a=f.project(0,"A");let c=f.folder(a,".cache",3,0,false);f.file(c,regular([Some(1);4],false));let b=f.project(0,"B");f.file(b,regular([Some(2);4],false));let late=f.folder(a,".npm",3,a+1,false);f.file(late,regular([Some(3);4],false));
        assert!(matches!(f.values(f.database(),3,None,0),Err("store_purpose_order")));
    }
    #[test]fn source_ranges_foreign_projects_and_missing_contexts_fail_closed(){
        for mutation in ["UPDATE source_roots SET finished=0 WHERE id=2","UPDATE source_roots SET first_row=3 WHERE id=2","UPDATE contexts SET project=99 WHERE node=3","DELETE FROM contexts WHERE node=3"] {
            let mut f=Fixture::new(true);let p=f.project(1,"Project");let c=f.folder(p,".cache",3,0,false);f.file(c,regular([Some(5);4],false));f.split();let db=f.database();db.execute(mutation).unwrap();assert!(f.values(db,3,None,0).is_err(),"{mutation}");
        }
    }
    #[test]fn requested_project_marker_and_exact_role_partition_are_required(){
        let mut f=Fixture::new(false);let p=f.project(0,"Project");let c=f.folder(p,".cache",3,0,false);f.file(c,regular([Some(5);4],false));
        assert!(f.values(f.database(),3,Some(999),0).is_err());let db=f.database();db.execute("DELETE FROM markers").unwrap();assert!(f.values(db,3,None,0).is_err());
        let db=f.database();db.execute("DELETE FROM groups WHERE kind=1 AND key=3").unwrap();assert!(f.values(db,3,None,0).is_err());
        assert!(f.values(f.database(),13,None,0).is_err());assert!(f.values(f.database(),3,None,4).is_err());assert!(purpose_values(f.database(),3,None,0,false,f.entries(),false).is_err());
    }
    #[test]fn project_on_single_source_root_is_retained_without_a_nonempty_display_name(){
        let mut f=Fixture::new(false);f.nodes[0].project=1;f.nodes[0].marked=true;let c=f.folder(0,".cache",3,0,false);f.file(c,regular([Some(11);4],false));
        assert_eq!(f.values(f.database(),3,None,0).unwrap().ranking.best,vec![(1,regular([Some(11);4],false))]);
    }
    #[test]fn display_tail_is_bounded_literal_and_never_an_operation_path(){
        let mut f=Fixture::new(false);let mut parent=0;for i in 0..8{parent=f.folder(parent,&format!("part-{i}"),3,0,false);}
        f.file(parent,regular([Some(7);4],false));let db=f.database();let(source,names,truncated)=purpose_display_path(Rc::clone(&db),parent,false).unwrap();
        assert_eq!(source,0);assert!(truncated);assert_eq!(names,(2..8).map(|i|format!("part-{i}").into_bytes()).collect::<Vec<_>>());
        db.execute(&format!("UPDATE nodes SET name=x'ff' WHERE id={parent}")).unwrap();assert_eq!(purpose_display_path(db,parent,false).unwrap().1.last().unwrap(),&vec![255]);
    }
    #[test]fn display_source_is_explicit_and_roots_have_no_path_components(){
        let mut f=Fixture::new(true);let child=f.folder(1,"System",3,0,false);f.file(child,regular([Some(7);4],false));f.split();let db=f.database();
        assert_eq!(purpose_display_path(Rc::clone(&db),child,true).unwrap(),(1,vec![b"System".to_vec()],false));
        assert_eq!(purpose_display_path(Rc::clone(&db),1,true).unwrap(),(1,vec![],false));
        assert!(purpose_display_path(db,0,true).is_err());
    }
}
