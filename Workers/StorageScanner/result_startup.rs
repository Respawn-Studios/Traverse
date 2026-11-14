// Two explicit physical sources, one temporary catalog. Synthetic source-root
// rows and verified alias references never enter namespace entry/byte totals.
impl Writer {
    pub fn prepare_startup(&mut self)->Result<()> {
        if self.count!=0 || self.source!=0 {return Err("store_source");}
        // Physical traversal must also exclude its own temporary directory by
        // PHYSICAL identity. fstat's synthetic Data-view inode is different.
        if unsafe{b06_result_physical_directory(&mut self.directory[0],&mut self.directory[1])}!=0{return Err("store_authority");}
        self.begin()?;
        let setup=format!("UPDATE profile SET revision={};PRAGMA user_version={};",PROFILE+1,PROFILE+1)+"
            CREATE TABLE source_roots(id INTEGER PRIMARY KEY CHECK(id IN(1,2)),first_row INTEGER NOT NULL,last_row INTEGER NOT NULL,finished INTEGER NOT NULL CHECK(finished IN(0,1))) STRICT;
            INSERT INTO source_roots VALUES(1,3,2,0),(2,0,0,0);
            INSERT INTO nodes VALUES(1,0,x'44617461',1,NULL,NULL,NULL,zeroblob(52)),(2,0,x'53797374656d',1,NULL,NULL,NULL,zeroblob(52));
            CREATE INDEX node_object ON nodes(identity) WHERE kind=1;
            CREATE TABLE aliases(parent INTEGER NOT NULL REFERENCES nodes(id),name BLOB NOT NULL CHECK(length(name) BETWEEN 1 AND 255 AND instr(name,x'00')=0 AND instr(name,x'2f')=0),target INTEGER REFERENCES nodes(id),identity BLOB CHECK(identity IS NULL OR length(identity)=16),verified INTEGER NOT NULL CHECK(verified IN(0,1)),PRIMARY KEY(parent,name),CHECK((target IS NOT NULL)=verified)) WITHOUT ROWID,STRICT;";
        let setup=if cfg!(b06_compact_values){setup.replace("zeroblob(52)","x'0100000000'")}else{setup};
        self.owner.execute(&setup).map_err(|_|"store_source")?;
        for id in 0..=2 {Self::store_value(&self.rollup,id,&Value::default())?;Self::store_value(&self.files,id,&Value::default())?;}
        self.source=1;self.folders[0].id=1;self.checkpoint()?;self.commit()
    }
    pub fn next_source(&mut self)->Result<()> {
        if self.source!=1 || self.tainted{return Err("store_source");}
        self.begin()?;while self.folders.len()>1 {self.close_folder()?;}
        self.checkpoint()?;
        let state=self.statement("UPDATE source_roots SET last_row=?,finished=1 WHERE id=1")?;
        state.number(1,self.count+2)?;state.done()?;
        let next=self.statement("UPDATE source_roots SET first_row=? WHERE id=2")?;
        next.number(1,self.count+3)?;next.done()?;self.commit()?;
        self.source=2;self.index=ResultIndex::for_source(Rc::clone(&self.owner),2).map_err(index_error)?;
        #[cfg(b06_reference_index)]
        self.index.attach_writer_buffer(Rc::clone(&self.pending));
        self.folders=vec![Folder{id:2,path:vec![],total:Value::default(),files:Value::default()}];Ok(())
    }
    pub fn finish_source(&self)->Result<()> {
        if self.source==0{return Ok(());}
        let state=self.statement("UPDATE source_roots SET last_row=?,finished=1 WHERE id=?")?;
        state.number(1,self.count+2)?;state.number(2,self.source)?;state.done()
    }
    pub fn startup_source(&self)->u64 {self.source}
    pub fn alias_target(&self,identity:[u64;2])->Result<Option<(u64,Vec<u8>)>> {
        if self.source!=2{return Ok(None);}
        let row=self.statement("SELECT n.id FROM nodes n,source_roots s WHERE s.id=1 AND n.kind=1 AND n.identity=? AND (n.id=1 OR n.id BETWEEN s.first_row AND s.last_row) LIMIT 2")?;
        let bytes=[identity[0].to_be_bytes(),identity[1].to_be_bytes()].concat();row.blob(1,Some(&bytes))?;
        if !row.row()? {return Ok(None);}
        let target=row.integer(0)?;if row.row()? {return Err("alias_ambiguous");}drop(row);
        let mut id=target;let mut parts:Vec<Vec<u8>>=vec![];
        while id!=1 {
            if id<=2 || parts.len()>=MAX_DEPTH{return Err("alias_scope");}
            let row=self.statement("SELECT parent,name FROM nodes WHERE id=? AND kind=1")?;row.number(1,id)?;
            if !row.row()?{return Err("alias_scope");}
            let parent=row.integer(0)?;let name=row.bytes(1,255)?.ok_or("alias_scope")?;
            if parent>=id || name.is_empty() || name.contains(&0) || name.contains(&47) || name==b"." || name==b".." {return Err("alias_scope");}
            parts.push(name);id=parent;
        }
        parts.reverse();let path=parts.join(&47);if path.len()>8192{return Err("alias_scope");}
        Ok(Some((target,path)))
    }
    pub fn record_alias(&mut self,o:&Observation,parent:&[u8],target:Option<u64>)->Result<()> {
        self.begin()?;
        while self.folders.len()>1 && self.folders.last().unwrap().path!=parent {self.close_folder()?;}
        let parent=self.folders.last().filter(|v|v.path==parent).ok_or("alias_parent")?.id;
        let row=self.statement("INSERT INTO aliases VALUES(?,?,?,?,?)")?;
        row.number(1,parent)?;row.blob(2,Some(&o.name))?;
        if let Some(id)=target {row.number(3,id)?;}else{check(unsafe{sqlite3_bind_null(row.raw,3)})?;}
        let identity=o.dev.zip(o.ino).map(|(a,b)|[a.to_be_bytes(),b.to_be_bytes()].concat());
        row.blob(4,identity.as_deref())?;row.number(5,u64::from(target.is_some()))?;row.done()
    }
}
