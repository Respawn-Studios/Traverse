// Optional, source-free semantic queries. Directory aggregates and a bounded
// source-local DFS stack replace all-file decoding, sorting and hierarchy maps.
// Existing classification attribution is untouched: this basis is containment.
#[cfg(b06_qualification)]
static PURPOSE_PROGRESS_CONTROL:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
struct PurposeQueryCancellation {owner:Rc<Connection>}
impl PurposeQueryCancellation {
    fn new(owner:Rc<Connection>)->Self {
        unsafe extern "C" fn cancelled(_: *mut c_void)->c_int {
            #[cfg(b06_qualification)]
            if PURPOSE_PROGRESS_CONTROL.load(std::sync::atomic::Ordering::Relaxed)>0 {
                let interval=PURPOSE_PROGRESS_CONTROL.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
                if interval==4 {
                    let frame=b"{\"kind\":\"purpose-query-entered\",\"vm_intervals\":4}\n";
                    if unsafe{super::write(1,frame.as_ptr().cast(),frame.len())}!=frame.len()as isize{return 1;}
                }
            }
            unsafe{super::b06_cancelled()}
        }
        unsafe{sqlite3_progress_handler(owner.handle(),1000,Some(cancelled),std::ptr::null_mut());}
        Self{owner}
    }
}
impl Drop for PurposeQueryCancellation {
    fn drop(&mut self){unsafe{sqlite3_progress_handler(self.owner.handle(),0,None,std::ptr::null_mut());}}
}
fn purpose_cancelled()->Result<()> {if unsafe{super::b06_cancelled()}!=0{Err("cancelled")}else{Ok(())}}
fn purpose_regular(mut value:Value)->Value {
    value.0[8..40].fill(0);value
}
fn purpose_direct(value:Value)->Result<Value> {
    if value.0[8..40].iter().any(|v|*v!=0){return Err("store_purpose_value");}
    for metric in 0..4 {
        let offset=40+metric*25;
        if u64_at(&value.0,offset+8).checked_add(u64_at(&value.0,offset+16)).is_none_or(|count|count>u64_at(&value.0,0)){return Err("store_purpose_value");}
    }Ok(value)
}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
struct PurposeSource {root:u64,first:u64,last:u64,directories:u64}
fn purpose_rollup(owner:Rc<Connection>,id:u64)->Result<Value> {
    let row=Statement::new(owner,"SELECT value FROM rollups WHERE node=?")?;row.number(1,id)?;
    if !row.row()?{return Err("store_purpose_rollup");}
    let value=decode_value(&row.bytes(0,175)?.ok_or("store_row")?)?;
    if row.row()?{return Err("store_purpose_rollup");}Ok(value)
}
fn purpose_sources(owner:Rc<Connection>,startup:bool,entries:u64)->Result<Vec<PurposeSource>> {
    if entries>=i64::MAX as u64-2{return Err("store_source");}
    let whole=purpose_rollup(Rc::clone(&owner),0)?;
    if whole.entries()?!=entries{return Err("store_source");}
    if !startup{return Ok(vec![PurposeSource{root:0,first:1,last:entries,directories:u64_at(&whole.0,8)}]);}
    let rows=Statement::new(Rc::clone(&owner),"SELECT id,first_row,last_row,finished FROM source_roots ORDER BY id LIMIT 3")?;
    let mut sources=Vec::with_capacity(2);let mut total=Value::default();let mut first=3;
    while rows.row()? {
        let id=rows.integer(0)?;let next=rows.integer(1)?;let last=rows.integer(2)?;
        if sources.len()>=2 || id!=sources.len()as u64+1 || rows.integer(3)?!=1 || next!=first || last<next-1 || last>entries+2{return Err("store_source");}
        let value=purpose_rollup(Rc::clone(&owner),id)?;
        if value.entries()?!=last+1-next{return Err("store_source");}
        total.merge(&value)?;sources.push(PurposeSource{root:id,first:next,last,directories:u64_at(&value.0,8)});first=last+1;
    }
    if sources.len()!=2 || first!=entries+3 || total!=whole{return Err("store_source");}Ok(sources)
}
struct PurposeDirectory {id:u64,parent:u64,role:u64,project:u64,marked:bool,direct:Value,whole:Value}
struct PurposeFrame {id:u64,namespace:u64,recognized:bool,project_value:Value,location:bool,location_value:Value}
struct PurposeValues {total:Value,ranking:RankedValues}
struct PurposeVisitor {
    role:u64,selected:Option<u64>,metric:usize,path:Vec<PurposeFrame>,ranking:RankedValues,
    total:Value,role_total:Value,unassigned:Value,all_files:Value,visited:u64,found_project:bool,
}
impl PurposeVisitor {
    fn new(role:u64,selected:Option<u64>,metric:u64)->Result<Self> {
        if role>=13 || metric>3 || selected.is_some_and(|v|v>=i64::MAX as u64){return Err("store_filter");}
        Ok(Self{role,selected,metric:metric as usize,path:Vec::with_capacity(MAX_DEPTH+1),ranking:RankedValues{metric:metric as usize,..Default::default()},
            total:Value::default(),role_total:Value::default(),unassigned:Value::default(),all_files:Value::default(),visited:0,found_project:selected==Some(0)})
    }
    fn close(&mut self)->Result<()> {
        let old=self.path.pop().ok_or("store_purpose_order")?;
        if self.selected.is_none() && old.recognized {self.ranking.push(old.id.checked_add(1).ok_or("store_project")?,old.project_value)?;}
        if old.location {self.ranking.push(old.id,old.location_value)?;}Ok(())
    }
    fn accept(&mut self,row:PurposeDirectory,root:bool)->Result<()> {
        purpose_cancelled()?;
        if row.role>=13 || row.project>=i64::MAX as u64{return Err("store_context");}
        if root {
            if !self.path.is_empty(){return Err("store_purpose_order");}
        }else{
            let parent=self.path.iter().position(|p|p.id==row.parent).ok_or("store_purpose_order")?;
            while self.path.len()>parent+1 {self.close()?;}
            if row.id<=row.parent || self.path.len()>=MAX_DEPTH+1{return Err("store_purpose_order");}
        }
        let recognized=row.project==row.id.checked_add(1).ok_or("store_project")?;
        if recognized && (!row.marked || matches!(row.role,1|2|3|4|6|7|8|9|10|11|12)){return Err("store_project");}
        if row.project!=0 && !recognized && !self.path.iter().any(|p|p.recognized && p.id+1==row.project){return Err("store_project");}
        let namespace=if recognized{row.project}else{self.path.last().map(|p|p.namespace).unwrap_or(0)};
        if self.selected==Some(namespace) && recognized{self.found_project=true;}
        let matches=row.role==self.role;
        let selected=matches && self.selected.is_none_or(|v|v==namespace);
        let location=self.selected.is_some() && selected && !self.path.iter().any(|p|p.location);
        let value=purpose_direct(row.direct)?;
        if u64_at(&value.0,0)>u64_at(&row.whole.0,0){return Err("store_purpose_value");}
        self.all_files.merge(&value)?;self.visited=self.visited.checked_add(1).ok_or("store_overflow")?;
        self.path.push(PurposeFrame{id:row.id,namespace,recognized,project_value:Value::default(),location,location_value:Value::default()});
        if matches {self.role_total.merge(&value)?;}
        if selected {
            self.total.merge(&value)?;
            if self.selected.is_none() {
                if namespace==0 {self.unassigned.merge(&value)?;}
                else{self.path.iter_mut().rev().find(|p|p.recognized && p.id+1==namespace).ok_or("store_project")?.project_value.merge(&value)?;}
            }else{
                self.path.iter_mut().find(|p|p.location).ok_or("store_purpose_order")?.location_value.merge(&value)?;
            }
        }Ok(())
    }
    fn finish_source(&mut self,source:PurposeSource,whole:Value)->Result<()> {
        while !self.path.is_empty(){self.close()?;}
        if self.visited!=source.directories+1 || self.all_files!=purpose_regular(whole){return Err("store_purpose_partition");}
        self.visited=0;self.all_files=Value::default();Ok(())
    }
    fn finish(mut self,expected_role:Value)->Result<PurposeValues> {
        if !self.path.is_empty() || self.visited!=0 || self.role_total!=expected_role || self.selected.is_some() && !self.found_project{return Err("store_purpose_partition");}
        if self.selected.is_none(){self.ranking.push(0,self.unassigned)?;}
        let mut sum=self.ranking.remainder;for (_,value)in &self.ranking.best{sum.merge(value)?;}
        if sum!=self.total{return Err("store_purpose_partition");}
        debug_assert_eq!(self.metric,self.ranking.metric);
        Ok(PurposeValues{total:self.total,ranking:self.ranking})
    }
}
fn purpose_values(owner:Rc<Connection>,role:u64,project:Option<u64>,metric:u64,startup:bool,entries:u64,projected:bool)->Result<PurposeValues> {
    if !projected || CLASSIFICATION_REVISION!=4{return Err("classification_incomplete");}
    filtered_rules(Rc::clone(&owner))?;
    let _cancellation=PurposeQueryCancellation::new(Rc::clone(&owner));
    let sources=purpose_sources(Rc::clone(&owner),startup,entries)?;
    let metadata=Statement::new(Rc::clone(&owner),"SELECT n.parent,n.kind,n.name,c.role,c.project,m.marker,d.value,r.value FROM nodes n JOIN contexts c ON c.node=n.id LEFT JOIN markers m ON m.node=n.id LEFT JOIN direct_files d ON d.node=n.id JOIN rollups r ON r.node=n.id WHERE n.id=?")?;
    let read=|id:u64,source:PurposeSource,root:bool|->Result<PurposeDirectory>{
        metadata.number(1,id)?;
        if !metadata.row()? || metadata.integer(1)?!=1{return Err("store_context");}
        let parent=metadata.integer(0)?;let name=metadata.bytes(2,255)?.ok_or("store_row")?;
        if root {
            if parent!=0 || id!=source.root || (startup && name!=if id==1{b"Data".as_slice()}else{b"System".as_slice()}) || !startup && !name.is_empty(){return Err("store_source");}
        }else if id<source.first || id>source.last || parent!=source.root && !(source.first..id).contains(&parent) || name.is_empty() || name.contains(&0) || name.contains(&47) || name==b"." || name==b".."{return Err("store_source");}
        let whole=decode_value(&metadata.bytes(7,175)?.ok_or("store_row")?)?;
        let direct=match metadata.bytes(6,175)? {Some(raw)=>decode_value(&raw)?,None=>{if whole.entries()?!=0{return Err("store_purpose_value");}Value::default()}};
        let marked=unsafe{sqlite3_column_type(metadata.raw,5)}!=5;
        if marked && metadata.integer(5)?>6{return Err("store_project");}
        let row=PurposeDirectory{id,parent,role:metadata.integer(3)?,project:metadata.integer(4)?,marked,direct,whole};
        if metadata.row()?{return Err("store_context");}metadata.reset()?;Ok(row)
    };
    let page=Statement::new(Rc::clone(&owner),"SELECT node FROM contexts WHERE node>? AND node<=? ORDER BY node LIMIT 256")?;
    let mut visitor=PurposeVisitor::new(role,project,metric)?;
    if startup {
        // The synthetic root is outside both physical source intervals.
        let synthetic=Statement::new(Rc::clone(&owner),"SELECT n.kind,n.name,c.project,m.marker,d.value FROM nodes n JOIN contexts c ON c.node=n.id LEFT JOIN markers m ON m.node=c.node LEFT JOIN direct_files d ON d.node=c.node WHERE n.id=0")?;
        if !synthetic.row()? || synthetic.integer(0)?!=1 || synthetic.bytes(1,255)?.as_deref()!=Some(b"") || synthetic.integer(2)?!=0 || unsafe{sqlite3_column_type(synthetic.raw,3)}!=5 || decode_value(&synthetic.bytes(4,175)?.ok_or("store_source")?)?!=Value::default() || synthetic.row()?{return Err("store_source");}
    }
    for source in sources {
        let row=read(source.root,source,true)?;let whole=row.whole;visitor.accept(row,true)?;
        let mut after=source.first-1;
        loop {
            purpose_cancelled()?;page.number(1,after)?;page.number(2,source.last)?;
            let mut ids=Vec::with_capacity(256);while page.row()?{ids.push(page.integer(0)?);}page.reset()?;
            if ids.is_empty(){break;}
            for id in ids {
                if id<=after{return Err("store_purpose_order");}
                visitor.accept(read(id,source,false)?,false)?;after=id;
            }
        }
        visitor.finish_source(source,whole)?;
    }
    let group=Statement::new(Rc::clone(&owner),"SELECT value FROM groups WHERE kind=1 AND key=?")?;group.number(1,role)?;
    let expected=if group.row()?{purpose_direct(decode_value(&group.bytes(0,175)?.ok_or("store_row")?)?)?}else{Value::default()};
    visitor.finish(expected)
}
// Display only, never operation authority. Keep the last six literal names;
// still validate the entire bounded chain and retain its explicit source tag.
fn purpose_display_path(owner:Rc<Connection>,mut id:u64,startup:bool)->Result<(u64,Vec<Vec<u8>>,bool)> {
    let row=Statement::new(owner,"SELECT parent,name,kind FROM nodes WHERE id=?")?;let(mut names,mut depth,mut bytes)=(Vec::with_capacity(6),0,0);
    while id!=0 && !(startup && id<=2) {
        purpose_cancelled()?;
        if depth>=MAX_DEPTH{return Err("store_depth");}
        row.number(1,id)?;if !row.row()? || row.integer(2)?!=1{return Err("store_parent");}
        let parent=row.integer(0)?;let name=row.bytes(1,255)?.ok_or("store_row")?;
        if parent>=id || name.is_empty() || name.contains(&0) || name.contains(&47) || name==b"." || name==b".."{return Err("store_path");}
        bytes+=name.len()+1;if bytes>8192{return Err("store_path");}
        if names.len()<6{names.push(name);}depth+=1;id=parent;row.reset()?;
    }
    if startup && id==0{return Err("store_source");}
    names.reverse();Ok((id,names,depth>6))
}
fn purpose_query(owner:Rc<Connection>,role:u64,project:Option<u64>,metric:u64,startup:bool,entries:u64,projected:bool)->Result<()> {
    let values=purpose_values(Rc::clone(&owner),role,project,metric,startup,entries,projected)?;
    let mut rows=Vec::with_capacity(12);
    for (key,value)in &values.ranking.best {
        let id=if project.is_some(){Some(*key)}else if *key>0{Some(key-1)}else{None};
        let name=if let Some(id)=id {
            let label=Statement::new(Rc::clone(&owner),"SELECT name FROM nodes WHERE id=? AND kind=1")?;label.number(1,id)?;
            if !label.row()?{return Err("store_row");}label.bytes(0,255)?.ok_or("store_row")?
        }else{vec![]};
        let mut row=vec![("key",quote(&key.to_string())),("name",quote(&base64(&name))),("value",quote(&base64(&value.0)))];
        if project.is_some(){
            let whole=purpose_rollup(Rc::clone(&owner),*key)?;
            let matching=purpose_regular(whole)==*value && whole.0[16..40].iter().all(|v|*v==0);
            row.extend([("whole_value",quote(&base64(&whole.0))),("whole_recorded_match",matching.to_string())]);
            let (source,path,truncated)=purpose_display_path(Rc::clone(&owner),*key,startup)?;
            row.extend([("display_source",source.to_string()),("display_path",format!("[{}]",path.iter().map(|name|quote(&base64(name))).collect::<Vec<_>>().join(","))),("display_truncated",truncated.to_string())]);
        }
        rows.push(json_map(row));
    }
    let mut frame=vec![("kind",quote(if project.is_some(){"purpose-locations"}else{"purpose-projects"})),("revision","1".into()),
        ("basis",quote("project-namespace-v1")),("classification_revision",CLASSIFICATION_REVISION.to_string()),("role",role.to_string()),("metric",metric.to_string()),
        ("value",quote(&base64(&values.total.0))),("rows",format!("[{}]",rows.join(","))),("remainder",quote(&base64(&values.ranking.remainder.0))),("total_groups",quote(&values.ranking.total.to_string()))];
    if let Some(project)=project{frame.push(("project",quote(&project.to_string())));}
    send(json_map(frame))
}

#[cfg(test)]
include!("result_purpose_tests.rs");
