// Isolated generated observations, not a source tree or a personal scan.
// Compiled only into the explicitly requested qualification executable.
pub fn generated_classification(args:&[String])->Result<()> {
    let (policy,args)=super::policy::Profile::arguments(args)?;
    if args.len()!=6 || args[2]!="--result-quota" || args[4]!="--session"{return Err("fixture_arguments");}
    let root=b"/Users/generated";
    let files=[("Assets.car",101u64),("Info.plist",103),("icon.ICNS",107),("raw.bin",109),("game.dat",113),
        ("README",127),(".dotname",131),("trailing.",137),("unknown.zzy",139),("Near.car-backup",149),
        ("Library/Containers/com.example/item.car",151),("Library/Group Containers/group.example/cache.bin",157),
        ("Library/Developer/Xcode/DerivedData/Module/a.o",163),("Library/Developer/Xcode/DerivedData-old/Module/b.dat",167),
        ("Example.app/Contents/Resources/assets.car",173),("Project/Cargo.toml",179),("Project/target/generated.plist",181),
        ("Library/Containers/com.apple.mail/private.dat",191),("Library/Keychains/private.dat",193)];
    let mut rows=std::collections::BTreeMap::<Vec<u8>,Option<u64>>::new();
    for (path,size) in files {
        let bytes=path.as_bytes();let mut absolute=root.to_vec();absolute.push(47);absolute.extend_from_slice(bytes);
        if super::policy::excludes_for(&absolute,false,policy){continue;}
        for (index,byte) in bytes.iter().enumerate(){if *byte==47{rows.insert(bytes[..index].to_vec(),None);}}
        rows.insert(bytes.to_vec(),Some(size));
    }
    // Raw full-path order interleaves `DerivedData-old` before descendants of
    // `DerivedData` because '-' precedes '/'. Component order preserves DFS.
    let mut rows=rows.into_iter().collect::<Vec<_>>();
    rows.sort_by(|a,b|a.0.split(|b|*b==47).cmp(b.0.split(|b|*b==47)));
    if rows.len()>64{return Err("fixture_bound");}
    let mut writer=Writer::open(&args[1],super::Options::unsigned(&args[3])?,&args[5],policy)?;writer.bind_root(1,1)?;
    for (index,(path,size)) in rows.iter().enumerate() {
        let split=path.iter().rposition(|b|*b==47);let name=&path[split.map_or(0,|v|v+1)..];let parent=split.map_or(b"".as_slice(),|v|&path[..v]);
        let mut observation=Observation{name:name.to_vec(),dev:Some(1),ino:Some(index as u64+2),links:Some(1),flags:Some(0),
            object_type:Some(if size.is_some(){1}else{2}),..Default::default()};
        if let Some(n)=size {observation.values=[Some(*n),Some(n+1),Some(n*2),Some(n*2+3)];}
        writer.begin_observation()?;
        if size.is_some(){writer.object([1,index as u64+2],ObjectFacts{values:observation.values,links:Some(1),flags:Some(0)},0)?;}
        else if !writer.directory([1,index as u64+2])?{return Err("fixture_identity");}
        writer.accept(&observation,path,parent)?;
    }
    writer.seal(false,true,root)?;
    send(json_map(vec![("kind",quote("classification_fixture")),("entries",quote(&rows.len().to_string())),("classification_revision",CLASSIFICATION_REVISION.to_string())]))
}
