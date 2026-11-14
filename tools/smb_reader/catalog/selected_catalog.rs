// Included only by the copied Download worker's existing catalog module.
// One exact completed observation; no UI path or page offset supplies authority.
#[derive(Clone,PartialEq,Eq)]
pub struct SelectedRow {pub directory:Vec<u16>,pub item:Row}
impl std::fmt::Debug for SelectedRow{fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result{f.write_str("<selected SMB catalog row>")}}
impl Catalog {
    pub fn selected(&mut self,snapshot:Snapshot,generation:[u8;16],observation:i64)->Result<SelectedRow> {self.selected_kind(snapshot,generation,observation,false)}
    pub fn selected_folder(&mut self,snapshot:Snapshot,generation:[u8;16],observation:i64)->Result<SelectedRow>{self.selected_kind(snapshot,generation,observation,true)}
    fn selected_kind(&mut self,snapshot:Snapshot,generation:[u8;16],observation:i64,folder:bool)->Result<SelectedRow>{
        self.begin_work()?;
        if self.active.is_some()||snapshot.state!=State::Complete||observation<=0||generation==[0;16]{return Err(Error::Invalid);}
        if self.snapshot(snapshot.read)?!=snapshot{return Err(Error::Stale);}
        let stmt=Statement::new(self.db,"SELECT r.path,i.wire,i.attributes,i.size,i.modified,i.object,r.parent FROM items i JOIN reads r ON r.id=i.read WHERE i.read=? AND i.id=? AND r.generation=?")?;
        stmt.int(1,snapshot.read)?;stmt.int(2,observation)?;stmt.blob(3,&generation)?;
        if !stmt.step()?{return Err(Error::Stale);}
        let raw=stmt.bytes(0,8192)?;let name=stmt.bytes(1,4096)?;
        if raw.len()%2!=0||name.is_empty()||name.len()%2!=0{return Err(Error::Invalid);}
        let directory=raw.chunks_exact(2).map(|v|u16::from_be_bytes([v[0],v[1]])).collect::<Vec<_>>();
        let wire=name.chunks_exact(2).map(|v|u16::from_be_bytes([v[0],v[1]])).collect::<Vec<_>>();wire_bytes(&wire)?;
        // Recheck stored path component shape without mapping or normalizing.
        if !directory.is_empty(){for component in directory.split(|v|*v==92){wire_bytes(component)?;}}
        let attributes=stmt.number(2);let size=stmt.number(3);let modified=stmt.number(4);
        let object=Self::id_blob(&stmt,5)?;let parent=Self::id_blob(&stmt,6)?;
        if attributes<0||attributes>u32::MAX as i64||(if folder{attributes&0x450!=0x10}else{attributes&0x450!=0})||size<0||size>1<<30||modified<0||stmt.step()?{return Err(Error::Invalid);}
        self.fresh()?;Ok(SelectedRow{directory,item:Row{observation,wire,attributes:attributes as u32,size:size as u64,modified:modified as u64,object,parent}})
    }
    /// Actions require the exact selected file or directory class, and both class-37
    /// filesystem witnesses. Their opaque values never become path authority.
    pub fn selected_action(&mut self,snapshot:Snapshot,generation:[u8;16],observation:i64,directory_action:bool)->Result<SelectedRow>{
        self.begin_work()?;
        if self.active.is_some()||snapshot.state!=State::Complete||observation<=0||generation==[0;16]{return Err(Error::Invalid);}
        if self.snapshot(snapshot.read)?!=snapshot{return Err(Error::Stale);}
        let stmt=Statement::new(self.db,"SELECT r.path,i.wire,i.attributes,i.size,i.modified,i.object,r.parent,i.folder FROM items i JOIN reads r ON r.id=i.read WHERE i.read=? AND i.id=? AND r.generation=?")?;
        stmt.int(1,snapshot.read)?;stmt.int(2,observation)?;stmt.blob(3,&generation)?;
        if !stmt.step()?{return Err(Error::Stale);}
        let raw=stmt.bytes(0,8192)?;let name=stmt.bytes(1,4096)?;
        if raw.len()%2!=0||name.is_empty()||name.len()%2!=0{return Err(Error::Invalid);}
        let directory=raw.chunks_exact(2).map(|v|u16::from_be_bytes([v[0],v[1]])).collect::<Vec<_>>();
        let wire=name.chunks_exact(2).map(|v|u16::from_be_bytes([v[0],v[1]])).collect::<Vec<_>>();wire_bytes(&wire)?;
        if !directory.is_empty(){for component in directory.split(|v|*v==92){wire_bytes(component)?;}}
        let attributes=stmt.number(2);let size=stmt.number(3);let modified=stmt.number(4);
        let object=Self::id_blob(&stmt,5)?;let parent=Self::id_blob(&stmt,6)?;
        if attributes<0||attributes>u32::MAX as i64||attributes&0x450!=if directory_action{0x10}else{0}
            ||stmt.number(7)!=i64::from(directory_action)||size<0||modified<0
            ||object==0||parent==0||object==parent||stmt.step()?{return Err(Error::Invalid);}
        self.fresh()?;Ok(SelectedRow{directory,item:Row{observation,wire,attributes:attributes as u32,size:size as u64,modified:modified as u64,object,parent}})
    }
}
