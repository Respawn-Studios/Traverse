//! Isolated startup-volume mode. The Swift owner supplies positively verified
//! roots3/7 and acknowledges one transition through control pipe8 after fresh
//! topology validation. This is not a crash/reopen/resume protocol.
use super::*;
fn physical(fd:i32)->Result<Identity> {
    let mut value=Identity::default();
    if unsafe{b06_physical_identity(fd,&mut value)}!=0 || value.local==0 || value.mode&0o170000!=0o040000 {return Err("physical_identity");}
    Ok(value)
}
fn same(a:&Identity,b:&Identity)->bool {a.dev==b.dev && a.ino==b.ino && a.fsid0==b.fsid0 && a.fsid1==b.fsid1}
fn source(id:u64,namespace:&Identity,real:&Identity)->String {
    json_map(vec![("id",quote(&id.to_string())),("namespace_dev",quote(&namespace.dev.to_string())),("namespace_ino",quote(&namespace.ino.to_string())),
        ("physical_dev",quote(&real.dev.to_string())),("physical_ino",quote(&real.ino.to_string())),
        ("fsid0",quote(&(real.fsid0 as u32).to_string())),("fsid1",quote(&(real.fsid1 as u32).to_string()))])
}
fn acknowledge(scanner:&mut Scanner,from:u64,to:u64)->Result<()> {
    scanner.emit("member_transition",vec![("from",quote(&from.to_string())),("to",quote(&to.to_string()))]);
    let began=Instant::now();
    loop {
        if scanner.stopped(){return Err("cancelled");}
        if began.elapsed().as_secs()>=10{return Err("topology_changed");}
        let mut fd=PollDescriptor{fd:8,events:1,revents:0};let ready=unsafe{poll(&mut fd,1,50)};
        if ready<0 && errno()!=4{return Err("topology_changed");}
        if ready>0 {
            let mut byte=0u8;
            if unsafe{read(8,(&mut byte as *mut u8).cast(),1)}==1 && byte==1{return Ok(());}
            return Err("topology_changed");
        }
    }
}
pub fn run(args:&[String])->bool {
    let run=||->Result<Scanner> {
        let (metadata_policy,args)=policy::Profile::arguments(args)?;
        let keys=["--startup-result","--result-quota","--session","--data-dev","--data-ino","--system-dev","--system-ino"];
        if args.len()!=14 || args.chunks_exact(2).zip(keys).any(|(p,k)|p[0]!=k){return Err("startup_arguments");}
        let number=|i:usize|Options::unsigned(&args[i]);let quota=number(3)?;
        if !(1<<20..=result::MAX_STORE_BYTES).contains(&quota){return Err("store_quota");}
        let make=|dev:u64,ino:u64|Options::parse(&["--root-fd".into(),"3".into(),"--expected-dev".into(),dev.to_string(),"--expected-ino".into(),ino.to_string(),"--session".into(),args[5].clone()]);
        let mut first=make(number(7)?,number(9)?)?;let mut second=make(number(11)?,number(13)?)?;second.root_fd=7;
        first.metadata_policy=metadata_policy;second.metadata_policy=metadata_policy;
        first.maximum_depth=result::MAX_DEPTH;second.maximum_depth=result::MAX_DEPTH;
        let mut a=Identity::default();let mut b=Identity::default();
        if unsafe{b06_identity(3,&mut a)}!=0 || unsafe{b06_identity(7,&mut b)}!=0 || a.dev!=first.dev || a.ino!=first.ino || b.dev!=second.dev || b.ino!=second.ino{return Err("root_identity_or_boundary");}
        let data=physical(3)?;let system=physical(7)?;
        let mut scanner=Scanner::new(first);scanner.data_physical=Some(data);
        scanner.startup_sources=Some(format!("[{},{}]",source(1,&a,&data),source(2,&b,&system)));
        let mut writer=result::Writer::open(&args[1],quota,&args[5],metadata_policy)?;writer.prepare_startup()?;scanner.result=Some(writer);
        let result=(||->Result<()> {
            scanner.scan()?;
            if scanner.stopped(){return Ok(());}
            scanner.result.as_mut().ok_or("store_source")?.next_source()?;
            acknowledge(&mut scanner,1,2)?;
            if !same(&physical(3)?,&data) || !same(&physical(7)?,&system){return Err("topology_changed");}
            scanner.options=second;scanner.scan()?;
            if !same(&physical(3)?,&data) || !same(&physical(7)?,&system){return Err("topology_changed");}
            if !scanner.stopped(){acknowledge(&mut scanner,2,0)?;}
            Ok(())
        })();
        if let Err(error)=result {if let Some(writer)=scanner.result.as_mut(){writer.taint();}scanner.failure(error,errno());}
        Ok(scanner)
    };
    // Both inherited roots stay alive for alias revalidation until sealing and
    // the owned worker exit. No borrowed descriptor is released by a member.
    let _roots=[Descriptor(3),Descriptor(7),Descriptor(8)];
    match run(){Ok(mut scanner)=>{scanner.finish();scanner.complete},Err(_)=>{eprintln!("startup_result_refused");false}}
}

impl Scanner {
    /// Foreign physical directories are non-accounting references. A Data
    /// alias is admitted only through its original catalog identity plus fresh
    /// no-symlink opens under BOTH held roots; a display path grants no access.
    pub(super) fn startup_boundary(&mut self,o:&Observation,pending:&Pending)->Result<bool> {
        let foreign=o.dev.is_some_and(|dev|dev!=self.root_identity.dev);
        let firmlink=o.flags.is_some_and(|flags|flags&0x0080_0000!=0);
        if !foreign && !firmlink {return Ok(false);}
        let mut absolute=self.root_namespace.clone();if !absolute.ends_with(b"/"){absolute.push(47);}
        if !pending.path.is_empty(){absolute.extend_from_slice(&pending.path);absolute.push(47);}absolute.extend_from_slice(&o.name);
        if policy::excludes_for(&absolute,o.kind()=="directory",self.options.metadata_policy){self.issue("policy_excluded",0);return Ok(true);}
        let mut target=None;
        if o.error==0 && o.kind()=="directory" && self.result.as_ref().is_some_and(|w|w.startup_source()==2) {
            let mut logical=pending.path.clone();if !logical.is_empty(){logical.push(47);}logical.extend_from_slice(&o.name);
            let logical_path=CString::new(logical).map_err(|_|"alias_scope")?;
            let alias=unsafe{b06_open_directory(7,logical_path.as_ptr())};
            if alias>=0 {
                let alias=Descriptor(alias);
                if let Ok(observed)=physical(alias.0) {
                    // Bulk enumeration reports the sealed System placeholder's
                    // identity for a firmlink, even with RETURN_REALDEV. Resolve
                    // its physical directory first; only a verified Data member
                    // may be looked up in the original Data observation ledger.
                    if is_data_member(&observed,self.data_physical.as_ref()) {
                        if let Some((id,path))=self.result.as_ref().ok_or("store_source")?.alias_target([observed.dev,observed.ino])? {
                            let target_path=CString::new(if path.is_empty(){b".".to_vec()}else{path}).map_err(|_|"alias_scope")?;
                            let data=unsafe{b06_open_directory(3,target_path.as_ptr())};
                            if data>=0 {
                                let data=Descriptor(data);
                                if physical(data.0).is_ok_and(|v|same(&v,&observed)) && physical(alias.0).is_ok_and(|v|same(&v,&observed)) {
                                    target=Some(id);
                                }
                            }
                        }
                    }
                }
            }
        }
        if o.kind()=="directory" {self.result.as_mut().ok_or("store_source")?.record_alias(o,&pending.path,target)?;}
        if target.is_none(){self.issue("boundary_excluded",0);}
        Ok(true)
    }
}

fn is_data_member(value:&Identity,data:Option<&Identity>)->bool {
    data.is_some_and(|root|root.dev==value.dev && root.fsid0==value.fsid0 && root.fsid1==value.fsid1)
}
#[cfg(test)]
mod alias_tests {
    use super::*;
    #[test] fn alias_uses_resolved_physical_member_not_system_placeholder() {
        let data=Identity{dev:1,ino:2,fsid0:3,fsid1:4,..Identity::default()};
        let resolved=Identity{ino:100,..data};
        assert!(is_data_member(&resolved,Some(&data)));
        assert!(!is_data_member(&Identity{dev:5,..resolved},Some(&data)));
        assert!(!is_data_member(&Identity{fsid1:5,..resolved},Some(&data)));
        assert!(!is_data_member(&resolved,None));
    }
}
