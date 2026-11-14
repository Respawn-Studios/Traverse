//! Conservative metadata-only exclusions. A path match never grants access.
pub const REVISION: &str = "local-metadata-v1";

/// The broader policy is available only in the separately qualified helper.
/// A policy selection changes lexical exclusions; it never grants OS access.
#[derive(Clone,Copy,Debug,Default,PartialEq,Eq)]
pub enum Profile { #[default] Standard, ApplicationData }
impl Profile {
    pub fn revision(self)->&'static str {match self {
        Self::Standard=>REVISION,Self::ApplicationData=>"local-metadata-app-data-v1",
    }}
    pub fn parse(value:&str)->Result<Self,&'static str> {match value {
        REVISION=>Ok(Self::Standard),
        "local-metadata-app-data-v1" if cfg!(b06_app_data)=>Ok(Self::ApplicationData),
        _=>Err("metadata_policy"),
    }}
    /// An optional, canonical trailing pair. Ordinary helpers reject it.
    pub fn arguments(args:&[String])->Result<(Self,&[String]),&'static str> {
        if args.len()>=2 && args[args.len()-2]=="--metadata-policy" {
            if !cfg!(b06_app_data){return Err("metadata_policy");}
            Ok((Self::parse(&args[args.len()-1])?,&args[..args.len()-2]))
        }else {Ok((Self::Standard,args))}
    }
}

pub fn excludes(path: &[u8], directory: bool) -> bool {
    excludes_for(path,directory,Profile::Standard)
}
pub fn excludes_for(path:&[u8],directory:bool,profile:Profile)->bool {
    #[cfg(b06_stage_profile)] let _timer=super::profiling::measure(super::profiling::Stage::InputPolicy);
    let folded: Vec<u8> = path.iter().map(u8::to_ascii_lowercase).collect();
    if excludes_folded(&folded,directory,profile){return true;}
    // Only exclusion matching gains a logical spelling. Never open or grant
    // access through the rewritten path; the original FD/namespace stays used.
    const PREFIX:&[u8]=b"/system/volumes/data";
    if let Some(suffix)=folded.strip_prefix(PREFIX){
        if suffix.starts_with(b"/"){return excludes_folded(suffix,directory,profile);}
    }
    false
}

const PRIVATE_LIBRARY:&[&[u8]]=&[b"mail",b"messages",b"safari",b"calendars",b"contacts",
    b"reminders",b"personalizationportrait",b"autosave information"];
const CONTAINERS:&[&[u8]]=&[b"containers",b"group containers"];
fn private_library(parts:&[&[u8]])->bool {
    parts.first().is_some_and(|p|PRIVATE_LIBRARY.contains(p))
        || (parts.len()>=2 && parts[0]==b"application support"
            && [b"com.apple.tcc".as_slice(),b"addressbook",b"callhistorydb"].contains(&parts[1]))
        || (parts.len()>=2 && parts[0]==b"metadata" && parts[1]==b"corespotlight")
}
fn private_container(name:&[u8])->bool {
    // Known private Apple container families, with component boundaries.
    // Arbitrary third-party names are not interpreted as access grants.
    const FAMILIES:&[&[u8]]=&[b"com.apple.mail",b"com.apple.messages",b"com.apple.ichat",
        b"com.apple.mobilesms",b"com.apple.safari",b"com.apple.ical",b"com.apple.calendaragent",
        b"com.apple.calendars",b"com.apple.addressbook",b"com.apple.contacts",b"com.apple.reminders",
        b"com.apple.personalizationportrait",b"com.apple.passwords",b"com.apple.keychainaccess",
        b"com.apple.tcc"];
    let name=name.strip_prefix(b"group.").unwrap_or(name);
    FAMILIES.iter().any(|p|name==*p || name.strip_prefix(*p).is_some_and(|s|s.starts_with(b".")))
}
fn excludes_folded(path:&[u8],directory:bool,profile:Profile)->bool{
    let parts: Vec<&[u8]> = path.split(|b| *b == b'/').filter(|p| !p.is_empty()).collect();
    const COMPONENTS: &[&[u8]] = &[b".ssh", b".gnupg", b".aws", b".azure", b".kube", b".netrc",
        b".npmrc", b".pypirc", b"keychains", b"credentials", b"secrets", b".trash", b".trashes",
        b"cloudstorage", b"mobile documents"];
    if parts.iter().enumerate().any(|(i, part)| COMPONENTS.contains(part)
        || ((directory || i + 1 < parts.len()) && part.ends_with(b".photoslibrary"))) { return true; }
    if !path.starts_with(b"/") { return false; }
    if parts.first().is_some_and(|p| [b"network".as_slice(), b"net", b".vol"].contains(p)) { return true; }
    if parts.len() >= 3 && parts[..3] == [b"library".as_slice(), b"application support", b"com.apple.tcc"] { return true; }
    if parts.len() < 4 || parts[0] != b"users" || parts[2] != b"library" { return false; }
    if private_library(&parts[3..]) {return true;}
    if !CONTAINERS.contains(&parts[3]) {return false;}
    if profile==Profile::Standard {return true;}
    if parts.len()>=5 && private_container(parts[4]) {return true;}
    // Keep private Library classes excluded inside admitted app containers,
    // including explicit roots below those classes. Nested containers remain
    // conservative rather than recursively broadening the exception.
    (5..parts.len()).any(|i|parts[i]==b"library"
        && (private_library(&parts[i+1..]) || parts.get(i+1).is_some_and(|p|CONTAINERS.contains(p))))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn application_data_vectors_and_physical_aliases() {
        let mut count=0;
        for line in include_str!("policy-app-data-vectors.tsv").lines().filter(|v|!v.is_empty() && !v.starts_with('#')) {
            let v:Vec<_>=line.split('\t').collect();assert_eq!(v.len(),4);
            for (profile,column) in [(Profile::Standard,1),(Profile::ApplicationData,2)] {
                let expected=match v[column]{"0"=>false,"1"=>true,_=>panic!("vector shape")};
                assert_eq!(excludes_for(v[3].as_bytes(),v[0]=="d",profile),expected,"{} {:?}",v[3],profile);
                let alias=format!("/System/Volumes/Data{}",v[3]);
                assert_eq!(excludes_for(alias.as_bytes(),v[0]=="d",profile),expected,"alias {} {:?}",v[3],profile);
            }
            count+=1;
        }
        assert!(count>=40);
    }
    #[test] fn original_vectors_are_unchanged_outside_container_roots() {
        for line in include_str!("policy-vectors.tsv").lines().filter(|v|!v.is_empty() && !v.starts_with('#')) {
            let v:Vec<_>=line.split('\t').collect();assert_eq!(v.len(),3);
            assert_eq!(excludes(v[2].as_bytes(),v[0]=="d"),v[1]=="1");
            if !v[2].to_ascii_lowercase().contains("/containers") && !v[2].to_ascii_lowercase().contains("/group containers") {
                assert_eq!(excludes_for(v[2].as_bytes(),v[0]=="d",Profile::ApplicationData),v[1]=="1");
            }
        }
    }
    #[test] fn policy_arguments_are_canonical_and_do_not_silently_fall_back() {
        assert_eq!(Profile::parse("unknown"),Err("metadata_policy"));
        assert_eq!(Profile::parse("local-metadata-app-data-v1").is_ok(),cfg!(b06_app_data));
        assert_eq!(Profile::arguments(&[]).unwrap().0,Profile::Standard);
        let args=vec!["--metadata-policy".into(),"local-metadata-app-data-v1".into()];
        assert_eq!(Profile::arguments(&args).is_ok(),cfg!(b06_app_data));
    }
}

pub fn self_test() -> Result<usize, &'static str> {
    let mut count = 0;
    for line in include_str!("policy-vectors.tsv").lines().filter(|line| !line.starts_with('#') && !line.is_empty()) {
        let columns: Vec<&str> = line.split('\t').collect();
        if columns.len() != 3 || !["d", "f"].contains(&columns[0]) || !["0", "1"].contains(&columns[1]) {
            return Err("policy_vector_shape");
        }
        if excludes(columns[2].as_bytes(), columns[0] == "d") != (columns[1] == "1") { return Err("policy_vector"); }
        count += 1;
    }
    if count == 0 { return Err("policy_vectors_empty"); } Ok(count)
}
