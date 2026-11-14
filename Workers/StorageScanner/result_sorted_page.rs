// Optional read-only sorting. No ingest/schema/index change and no whole-parent
// in-memory sort: name seeks use the qualified unique index; size uses257 rows.
const PAGE_ORDER_NAMES:[&str;6]=["name_ascending","name_descending","logical_descending","logical_ascending","allocated_descending","allocated_ascending"];
#[derive(Debug,Clone,PartialEq,Eq)]
struct PageKey {mode:u8,amount:Option<u64>,name:Vec<u8>,id:u64}
impl Ord for PageKey {
    fn cmp(&self,other:&Self)->std::cmp::Ordering {
        use std::cmp::Ordering;
        let mode=self.mode.cmp(&other.mode);if mode!=Ordering::Equal{return mode;}
        if self.mode<2 {
            return (if self.mode==0{self.name.cmp(&other.name)}else{other.name.cmp(&self.name)}).then_with(||self.id.cmp(&other.id));
        }
        self.amount.is_none().cmp(&other.amount.is_none()).then_with(||{
            if self.mode==2 || self.mode==4 {other.amount.cmp(&self.amount)}else{self.amount.cmp(&other.amount)}
        }).then_with(||self.name.cmp(&other.name)).then_with(||self.id.cmp(&other.id))
    }
}
impl PartialOrd for PageKey {fn partial_cmp(&self,other:&Self)->Option<std::cmp::Ordering>{Some(self.cmp(other))}}
struct PageRow {key:PageKey,kind:u64,payload:[u8;52],aggregate:Option<Value>}
impl PartialEq for PageRow {fn eq(&self,other:&Self)->bool{self.key==other.key}}
impl Eq for PageRow {}
impl Ord for PageRow {fn cmp(&self,other:&Self)->std::cmp::Ordering{self.key.cmp(&other.key)}}
impl PartialOrd for PageRow {fn partial_cmp(&self,other:&Self)->Option<std::cmp::Ordering>{Some(self.cmp(other))}}
impl PageRow {
    fn read(row:&Statement,parent:u64,mode:u8)->Result<Self> {
        let id=row.integer(0)?;let name=row.bytes(1,255)?.ok_or("store_row")?;let kind=row.integer(2)?;
        if id<=parent || id>=i64::MAX as u64 || name.is_empty() || name.contains(&0) || name.contains(&47) || name==b"." || name==b".." || kind>4{return Err("store_row");}
        let payload:[u8;52]=decode_payload(&row.bytes(3,52)?.ok_or("store_row")?)?.try_into().map_err(|_|"store_row")?;
        let own=filtered_value(&payload)?; // validates all field states even for non-regular objects
        let aggregate=row.bytes(4,175)?.map(|v|decode_value(&v)).transpose()?;
        if (kind==1)!=aggregate.is_some(){return Err("store_row");}
        let amount=if mode<2 || kind>1 {None}else{
            let value=aggregate.as_ref().unwrap_or(&own);let files=u64_at(&value.0,0);
            let offset=40+(if mode<4{0}else{3})*25;
            let missing=u64_at(&value.0,offset+8).checked_add(u64_at(&value.0,offset+16)).ok_or("store_row")?;
            if missing>files{return Err("store_row");}
            if value.0[offset+24]!=0 || files>0 && missing==files {None}else{Some(u64_at(&value.0,offset))}
        };
        Ok(Self{key:PageKey{mode,amount,name,id},kind,payload,aggregate})
    }
    fn encoded(&self)->String {
        json_map(vec![("id",quote(&self.key.id.to_string())),("name",quote(&base64(&self.key.name))),("type",self.kind.to_string()),
            ("payload",quote(&base64(&self.payload))),("value",self.aggregate.map(|v|quote(&base64(&v.0))).unwrap_or("null".into()))])
    }
}
fn ranked_page(owner:Rc<Connection>,parent:u64,cursor:u64,mode:u8)->Result<(Vec<PageRow>,Option<PageKey>,bool)> {
    if mode>5{return Err("store_sort");}
    let name=page_cursor(Rc::clone(&owner),parent,cursor)?;
    let previous=if cursor==0 {None}else if mode<2 {Some(PageKey{mode,amount:None,name,id:cursor})}else{
        let row=Statement::new(Rc::clone(&owner),"SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes n LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.id=?")?;
        row.number(1,parent)?;row.number(2,cursor)?;if !row.row()? {return Err("store_cursor");}
        let key=PageRow::read(&row,parent,mode)?.key;if row.row()?{return Err("store_cursor");}Some(key)
    };
    let mut values=if mode<2 {
        // INDEXED BY pins the existing UNIQUE(parent,name) index so a future
        // query-plan change cannot allocate a temporary all-parent sort.
        let sql=match (mode,cursor==0) {
            (0,_)=>"SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes AS n INDEXED BY sqlite_autoindex_nodes_1 LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.name>? ORDER BY n.name ASC LIMIT 257",
            (_,true)=>"SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes AS n INDEXED BY sqlite_autoindex_nodes_1 LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? ORDER BY n.name DESC LIMIT 257",
            _=>"SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes AS n INDEXED BY sqlite_autoindex_nodes_1 LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.name<? ORDER BY n.name DESC LIMIT 257",
        };
        let rows=Statement::new(owner,sql)?;rows.number(1,parent)?;
        if mode==0 || cursor!=0 {rows.blob(2,Some(previous.as_ref().map(|v|v.name.as_slice()).unwrap_or(b"")))?;}
        let mut values=Vec::with_capacity(257);
        while rows.row()? {
            if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
            values.push(PageRow::read(&rows,parent,mode)?);
            if values.len()>257{return Err("store_rows");}
        }values
    }else{
        let rows=Statement::new(owner,"SELECT n.id,n.name,n.kind,n.payload,r.value FROM nodes AS n INDEXED BY node_page LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=?")?;
        rows.number(1,parent)?;let mut heap=std::collections::BinaryHeap::with_capacity(257);
        while rows.row()? {
            if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
            let row=PageRow::read(&rows,parent,mode)?;
            if previous.as_ref().is_some_and(|after|row.key<=*after){continue;}
            if heap.len()<257 {heap.push(row);}else if heap.peek().is_some_and(|worst:&PageRow|row<*worst){heap.pop();heap.push(row);}
        }heap.into_sorted_vec()
    };
    let more=values.len()>256;values.truncate(256);
    Ok((values,previous,more))
}
fn sorted_page(owner:Rc<Connection>,parent:u64,cursor:u64,mode:u8)->Result<()> {
    let (values,previous,more)=ranked_page(owner,parent,cursor,mode)?;
    for chunk in values.chunks(64) {
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        send(json_map(vec![("kind",quote("rows")),("rows",format!("[{}]",chunk.iter().map(PageRow::encoded).collect::<Vec<_>>().join(",")))]))?;
    }
    if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
    send(json_map(vec![("kind",quote("end")),("count",values.len().to_string()),("sorted_page_revision","1".into()),
        ("order",quote(PAGE_ORDER_NAMES[mode as usize])),("parent",quote(&parent.to_string())),("after",quote(&cursor.to_string())),
        ("after_name",quote(&base64(previous.as_ref().map(|v|v.name.as_slice()).unwrap_or(b"")))),
        ("after_bytes",previous.as_ref().and_then(|v|v.amount).map(|v|quote(&v.to_string())).unwrap_or("null".into())),
        ("after_unknown",(mode>=2 && previous.as_ref().is_some_and(|v|v.amount.is_none())).to_string()),("has_more",more.to_string())]))
}

#[cfg(test)] mod sorted_page_tests {
    use super::*;
    fn fixture(count:u64)->Rc<Connection> {
        let db=Connection::open_existing(c":memory:").unwrap();db.execute(&schema()).unwrap();
        let row=Statement::new(Rc::clone(&db),"INSERT INTO nodes VALUES(?,0,?,0,NULL,NULL,NULL,?)").unwrap();
        for id in 1..=count {
            row.number(1,id).unwrap();row.blob(2,Some(format!("file-{:04}",count+1-id).as_bytes())).unwrap();
            let o=Observation{object_type:Some(1),values:[Some(id%17);4],..Default::default()};
            row.blob(3,Some(&encode_payload(&payload(&o)).unwrap())).unwrap();row.done().unwrap();
        }db
    }
    #[test] fn name_and_size_pages_have_exact_ties_and_no_duplicates() {
        let db=fixture(700);
        for mode in 0..6 {
            let mut all=vec![];let mut cursor=0;
            loop {
                let (rows,after,more)=ranked_page(Rc::clone(&db),0,cursor,mode).unwrap();
                if let Some(after)=after{assert!(rows.first().is_none_or(|v|v.key>after));}
                assert!(rows.windows(2).all(|v|v[0].key<v[1].key));
                cursor=rows.last().map(|v|v.key.id).unwrap_or(cursor);all.extend(rows.into_iter().map(|v|v.key));if !more{break;}
            }
            assert_eq!(all.len(),700);assert!(all.windows(2).all(|v|v[0]<v[1]));
            assert_eq!(all.iter().map(|v|v.id).collect::<std::collections::HashSet<_>>().len(),700);
            if mode==0{assert_eq!(all[0].name,b"file-0001");}if mode==1{assert_eq!(all[0].name,b"file-0700");}
            if mode==2 || mode==4{assert_eq!(all[0].amount,Some(16));}if mode==3 || mode==5{assert_eq!(all[0].amount,Some(0));}
        }
    }
    #[test] fn empty_exact_boundary_foreign_cursor_and_unknown_amounts() {
        for count in [0,256,257] {let (rows,_,more)=ranked_page(fixture(count),0,0,2).unwrap();assert_eq!(rows.len(),count.min(256) as usize);assert_eq!(more,count>256);}
        let db=fixture(2);assert!(ranked_page(Rc::clone(&db),1,2,2).is_err());assert!(ranked_page(Rc::clone(&db),0,3,2).is_err());
        assert!(ranked_page(Rc::clone(&db),0,0,6).is_err());
        db.execute("UPDATE nodes SET payload=x'ff00000000' WHERE id=1").unwrap();assert!(ranked_page(Rc::clone(&db),0,0,2).is_err());
        let unknown=PageKey{mode:3,amount:None,name:b"first".to_vec(),id:1};
        let known=PageKey{mode:3,amount:Some(u64::MAX),name:b"last".to_vec(),id:2};assert!(known<unknown);
        assert!(PageKey{mode:2,..known}<PageKey{mode:2,..unknown});
    }
    #[test] fn large_parent_keeps_bounded_pages_and_cursor_order() {
        let db=fixture(100_000);
        let (first,_,more)=ranked_page(Rc::clone(&db),0,0,2).unwrap();assert_eq!(first.len(),256);assert!(more);
        assert_eq!(first[0].key.amount,Some(16));
        let cursor=first.last().unwrap().key.id;
        let (second,after,more)=ranked_page(db,0,cursor,2).unwrap();assert_eq!(second.len(),256);assert!(more);
        assert!(second.iter().all(|v|v.key>after.clone().unwrap()));
        let ids=first.iter().chain(second.iter()).map(|v|v.key.id).collect::<std::collections::HashSet<_>>();assert_eq!(ids.len(),512);
    }
}
