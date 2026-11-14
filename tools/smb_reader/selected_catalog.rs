// Included only by the copied Download worker's existing catalog module.
// One exact completed observation; no UI path or page offset supplies authority.
#[derive(Clone,PartialEq,Eq)]
pub struct SelectedRow {pub directory:Vec<u16>,pub item:Row}
impl std::fmt::Debug for SelectedRow{fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result{f.write_str("<selected SMB catalog row>")}}
impl Catalog {
    pub fn selected(&mut self,snapshot:Snapshot,generation:[u8;16],observation:i64)->Result<SelectedRow> {
        self.begin_work()?;
        if self.active.is_some()||snapshot.state!=State::Complete||observation<=0||generation==[0;16]{return Err(Error::Invalid);}
        if self.snapshot(snapshot.read)?!=snapshot{return Err(Error::Stale);}
        let stmt=Statement::new(self.db,"SELECT r.path,i.wire,i.attributes,i.size,i.modified FROM items i JOIN reads r ON r.id=i.read WHERE i.read=? AND i.id=? AND r.generation=?")?;
        stmt.int(1,snapshot.read)?;stmt.int(2,observation)?;stmt.blob(3,&generation)?;
        if !stmt.step()?{return Err(Error::Stale);}
        let raw=stmt.bytes(0,8192)?;let name=stmt.bytes(1,4096)?;
        if raw.len()%2!=0||name.is_empty()||name.len()%2!=0{return Err(Error::Invalid);}
        let directory=raw.chunks_exact(2).map(|v|u16::from_be_bytes([v[0],v[1]])).collect::<Vec<_>>();
        let wire=name.chunks_exact(2).map(|v|u16::from_be_bytes([v[0],v[1]])).collect::<Vec<_>>();wire_bytes(&wire)?;
        // Recheck stored path component shape without mapping or normalizing.
        if !directory.is_empty(){for component in directory.split(|v|*v==92){wire_bytes(component)?;}}
        let attributes=stmt.number(2);let size=stmt.number(3);let modified=stmt.number(4);
        if attributes<0||attributes>u32::MAX as i64||attributes&0x450!=0||size<0||size>1<<30||modified<0||stmt.step()?{return Err(Error::Invalid);}
        self.fresh()?;Ok(SelectedRow{directory,item:Row{observation,wire,attributes:attributes as u32,size:size as u64,modified:modified as u64}})
    }
}
