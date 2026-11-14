// Isolated sealed-result audit. No source access, name output, stored rule
// mutation or ordinary query routing. Exactly sixteen values per revision.
fn classification_audit(owner:Rc<Connection>)->Result<()> {
    let rows=Statement::new(owner,"SELECT name,payload FROM nodes WHERE kind=0 ORDER BY id")?;
    let mut old=[Value::default();16];let mut new=[Value::default();16];
    let (mut total,mut changed)=(Value::default(),Value::default());
    while rows.row()? {
        if unsafe{super::b06_cancelled()}!=0{return Err("cancelled");}
        let name=rows.bytes(0,255)?.ok_or("store_row")?;
        let value=filtered_value(&decode_payload(&rows.bytes(1,52)?.ok_or("store_row")?)?)?;
        let before=file_type_revision(&name,2);let after=file_type_revision(&name,3);
        old.get_mut(before).ok_or("audit_type")?.merge(&value)?;
        new.get_mut(after).ok_or("audit_type")?.merge(&value)?;
        total.merge(&value)?;if before!=after{changed.merge(&value)?;}
    }
    let encode=|values:&[Value]|format!("[{}]",values.iter().map(|v|quote(&base64(&v.0))).collect::<Vec<_>>().join(","));
    send(json_map(vec![("kind",quote("classification_audit")),("revision","1".into()),
        ("old",encode(&old)),("new",encode(&new)),("total",quote(&base64(&total.0))),("changed",quote(&base64(&changed.0)))]))
}
