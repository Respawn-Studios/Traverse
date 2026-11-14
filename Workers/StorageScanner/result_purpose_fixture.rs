// Test-only, synthetic metadata through the real writer. It receives catalog
// descriptors only; no source tree, file bodies or personal scan are involved.
pub fn generated_purpose(args:&[String])->Result<()> {
    let (policy,args)=super::policy::Profile::arguments(args)?;
    if args.len()!=10 || args[2]!="--result-quota" || args[4]!="--session" || args[6]!="--projects" || args[8]!="--paired"{return Err("fixture_arguments");}
    let count=super::Options::unsigned(&args[7])?;
    if !matches!(count,16|10000|50000) || !matches!(args[9].as_str(),"0"|"1"){return Err("fixture_bound");}
    let paired=args[9]=="1";let began=std::time::Instant::now();
    let mut writer=Writer::open(&args[1],super::Options::unsigned(&args[3])?,&args[5],policy)?;
    if paired{writer.prepare_startup()?;}
    writer.bind_root(1,1)?;
    fn emit(writer:&mut Writer,path:&str,directory:bool,size:u64)->Result<()> {
        let path=path.as_bytes();let split=path.iter().rposition(|b|*b==47);let name=path.get(split.map_or(0,|p|p+1)..).ok_or("fixture_path")?;let parent=split.map_or(b"".as_slice(),|p|&path[..p]);
        let inode=writer.count+10;let device=writer.source+1;
        let observation=Observation{name:name.to_vec(),dev:Some(device),ino:Some(inode),links:Some(1),flags:Some(0),object_type:Some(if directory{2}else{1}),
            values:if directory{[None;4]}else{[Some(size),Some(size+7),Some(size*2),if size%7==0{None}else{Some(size*2+11)}]},..Default::default()};
        writer.begin_observation()?;
        if directory {if !writer.directory([device,inode])?{return Err("fixture_identity");}}
        else{writer.object([device,inode],ObjectFacts{values:observation.values,links:Some(1),flags:Some(0)},0)?;}
        writer.accept(&observation,path,parent)
    }
    if paired {
        emit(&mut writer,"Cargo.toml",false,0)?;emit(&mut writer,".cache",true,0)?;emit(&mut writer,".cache/root.bin",false,43)?;
    }
    for index in 0..count {
        if paired && index==count/2 {writer.next_source()?;writer.bind_root(2,1)?;}
        let project=format!("Project-{index:05}");emit(&mut writer,&project,true,0)?;
        emit(&mut writer,&format!("{project}/Cargo.toml"),false,0)?;
        emit(&mut writer,&format!("{project}/.cache"),true,0)?;
        emit(&mut writer,&format!("{project}/.cache/a.bin"),false,index%37)?;
        emit(&mut writer,&format!("{project}/.cache/b.bin"),false,index%23)?;
        if index%1000==0 {
            emit(&mut writer,&format!("{project}/.cache/huggingface"),true,0)?;
            emit(&mut writer,&format!("{project}/.cache/huggingface/model.bin"),false,101)?;
            emit(&mut writer,&format!("{project}/Nested"),true,0)?;
            emit(&mut writer,&format!("{project}/Nested/Cargo.toml"),false,0)?;
            emit(&mut writer,&format!("{project}/Nested/.cache"),true,0)?;
            emit(&mut writer,&format!("{project}/Nested/.cache/c.bin"),false,29)?;
            emit(&mut writer,&format!("{project}/.npm"),true,0)?;
            emit(&mut writer,&format!("{project}/.npm/d.bin"),false,31)?;
        }
    }
    emit(&mut writer,"Library",true,0)?;emit(&mut writer,"Library/Caches",true,0)?;emit(&mut writer,"Library/Caches/shared.bin",false,47)?;
    writer.seal(false,true,b"/Generated")?;
    let mut resources=super::Resources::default();if unsafe{super::b06_resources(&mut resources)}!=0{return Err("fixture_resources");}
    #[allow(unused_mut)] // Extra fields exist only in diagnostic builds.
    let mut fields=vec![("kind",quote("purpose_fixture")),("entries",quote(&writer.committed().to_string())),("classification_revision",CLASSIFICATION_REVISION.to_string()),
        ("paired",paired.to_string()),("peak_rss",quote(&resources.peak_rss.to_string())),("elapsed_ns",quote(&began.elapsed().as_nanos().to_string()))];
    #[cfg(b06_statement_profile)] fields.push(("projection_profile",writer.projection_profile.clone().unwrap_or_else(||"null".into())));
    #[cfg(b06_stage_profile)] fields.push(("stage_profile",super::profiling::summary()));
    send(json_map(fields))
}
