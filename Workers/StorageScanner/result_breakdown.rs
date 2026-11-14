// Bounded chart drill-down over stored metadata only. The child receives no
// source descriptor and never resolves a display title into a filesystem path.
fn breakdown(owner:Rc<Connection>,parent:u64,facet:u64,metric:u64,projected:bool)->Result<()> {
    if metric>3{return Err("store_metric");}
    let statement=|sql:&str|Statement::new(Rc::clone(&owner),sql);
    let mut folder=parent;let mut libraries=None;
    if facet==1 {
        if parent!=9 || !projected {return Err("classification_incomplete");}
        let roots=statement("SELECT n.id,r.value FROM nodes n JOIN contexts c ON c.node=n.id JOIN rollups r ON r.node=n.id WHERE c.role=9 AND NOT EXISTS(SELECT 1 FROM contexts p WHERE p.node=n.parent AND p.role=9)")?;
        let mut ranking=RankedValues{metric:metric as usize,..Default::default()};let mut total=Value::default();
        while roots.row()? {
            let value=decode_value(&roots.bytes(1,175)?.ok_or("store_row")?)?;
            total.merge(&value)?;ranking.push(roots.integer(0)?,value)?;
            if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        }
        if ranking.total==1 {folder=ranking.best[0].0;}else{libraries=Some((ranking,total));}
    }else if facet!=0 {return Err("store_facet");}
    let mut label=vec![];
    let (ranking,total,direct)=if let Some((ranked,total))=libraries {
        (ranked,total,Value::default())
    }else {
        let root=statement("SELECT n.name,r.value FROM nodes n JOIN rollups r ON r.node=n.id WHERE n.id=? AND n.kind=1")?;
        root.number(1,folder)?;if !root.row()?{return Err("store_cursor");}
        label=root.bytes(0,255)?.ok_or("store_row")?;let total=decode_value(&root.bytes(1,175)?.ok_or("store_row")?)?;drop(root);
        let rows=statement("SELECT n.id,r.value FROM nodes n JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.kind=1")?;
        rows.number(1,folder)?;let mut ranking=RankedValues{metric:metric as usize,..Default::default()};
        while rows.row()? {
            let value=decode_value(&rows.bytes(1,175)?.ok_or("store_row")?)?;
            if u64_at(&value.0,0)>0 {ranking.push(rows.integer(0)?,value)?;}
            if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        }
        let direct=statement("SELECT value FROM direct_files WHERE node=?")?;direct.number(1,folder)?;
        let value=if direct.row()? {decode_value(&direct.bytes(0,175)?.ok_or("store_row")?)?}else{Value::default()};
        (ranking,total,value)
    };
    let mut rows=vec![];
    for (id,value) in &ranking.best {
        let row=statement("SELECT name FROM nodes WHERE id=?")?;row.number(1,*id)?;
        if !row.row()?{return Err("store_row");}let name=row.bytes(0,255)?.ok_or("store_row")?;
        let hint=if label==b"steamapps" {match name.as_slice(){b"common"=>1,b"workshop"=>2,b"downloading"|b"temp"=>3,b"shadercache"=>4,_=>0}}
            else if label==b"workshop" {match name.as_slice(){b"content"=>5,b"downloads"|b"temp"=>3,_=>0}}else{0};
        rows.push(json_map(vec![("folder",quote(&id.to_string())),("name",quote(&base64(&name))),("hint",hint.to_string()),("value",quote(&base64(&value.0)))]));
    }
    if u64_at(&direct.0,0)>0 {rows.push(json_map(vec![("folder","null".into()),("name",quote("")),("hint","6".into()),("value",quote(&base64(&direct.0)))]));}
    send(json_map(vec![("kind",quote("breakdown")),("metric",metric.to_string()),("value",quote(&base64(&total.0))),("rows",format!("[{}]",rows.join(","))),("remainder",quote(&base64(&ranking.remainder.0)))]))
}
