//! Isolated, numeric-only scan diagnosis. Timings are inclusive, not additive.
use std::{cell::RefCell,collections::BTreeMap,time::Instant};
#[derive(Clone,Copy)]
pub enum Stage { Open, Identity, Namespace, Bulk, Parse, Admission, Commit, Seal, Authority, Checkpoint, SqliteCommit,
    #[cfg(b06_stage_profile)] Digest, #[cfg(b06_stage_profile)] ObjectAccounting,
    #[cfg(b06_stage_profile)] StoredRow, #[cfg(b06_stage_profile)] InputPolicy }
const NAMES:[&str;15]=["directory_open_ns","identity_ns","namespace_ns","bulk_ns","parse_ns","admission_ns","commit_ns","seal_ns","catalog_authority_ns","checkpoint_ns","sqlite_commit_ns",
    "canonical_digest_ns","object_accounting_ns","stored_row_ns","input_policy_ns"];
#[derive(Default)]
struct Counters { times:[u64;15],notices:BTreeMap<(u64,&'static str,i32),u64>,other_notices:u64,last_prefix_ns:u64 }
thread_local! {static COUNTERS:RefCell<Counters>=RefCell::new(Counters::default());}
pub struct Scope { stage:Stage,start:Option<Instant> }
pub fn measure(stage:Stage)->Scope {Scope{stage,start:if cfg!(b06_stage_profile){Some(Instant::now())}else{None}}}
#[cfg(all(b06_parallel_metadata,b06_stage_profile))]
pub fn add_elapsed(stage:Stage,nanoseconds:u64){COUNTERS.with(|v|{let mut v=v.borrow_mut();let i=stage as usize;v.times[i]=v.times[i].saturating_add(nanoseconds);});}
impl Drop for Scope {
    fn drop(&mut self){let Some(start)=self.start else{return;};let ns=start.elapsed().as_nanos().min(u64::MAX as u128) as u64;
        COUNTERS.with(|v|{let mut v=v.borrow_mut();let i=self.stage as usize;v.times[i]=v.times[i].saturating_add(ns);});}
}
pub fn notice(source:u64,code:&'static str,error:i32){
    let key=(source.min(2),code,if (0..=255).contains(&error){error}else{-1});
    COUNTERS.with(|v|{let mut v=v.borrow_mut();if v.notices.contains_key(&key)||v.notices.len()<64{
        let count=v.notices.entry(key).or_default();*count=count.saturating_add(1);
    }else{v.other_notices=v.other_notices.saturating_add(1);}});
}
pub fn prefix_due(ns:u64)->bool {COUNTERS.with(|v|{let mut v=v.borrow_mut();
    if ns.saturating_sub(v.last_prefix_ns)<250_000_000 {false}else{v.last_prefix_ns=ns;true}
})}
pub fn summary()->String {COUNTERS.with(|v|{let v=v.borrow();
    // The ordinary native protocol has an exact eleven-stage vocabulary.
    // Experimental child timers never change that contract.
    let mut fields:Vec<(&str,String)>=NAMES[..11].iter().zip(v.times).map(|(key,n)|(*key,super::quote(&n.to_string()))).collect();
    let rows=v.notices.iter().map(|((source,code,error),count)|super::json_map(vec![("source",source.to_string()),("code",super::quote(code)),("errno",error.to_string()),("count",super::quote(&count.to_string()))])).collect::<Vec<_>>();
    fields.push(("timings_enabled",cfg!(b06_stage_profile).to_string()));
    fields.push(("notice_buckets",format!("[{}]",rows.join(","))));fields.push(("other_notices",super::quote(&v.other_notices.to_string())));super::json_map(fields)
})}
#[cfg(b06_stage_profile)]
pub fn admission_summary()->String {COUNTERS.with(|v|{let v=v.borrow();
    super::json_map(NAMES[11..].iter().zip(v.times[11..].iter()).map(|(key,n)|(*key,super::quote(&n.to_string()))).collect())
})}

#[cfg(test)]
mod tests {
    #[test] fn child_diagnostics_do_not_expand_the_native_stage_vocabulary() {
        let ordinary=super::summary();
        assert!(ordinary.contains("\"admission_ns\"") && ordinary.contains("\"sqlite_commit_ns\""));
        for key in &super::NAMES[11..] {assert!(!ordinary.contains(key));}
        #[cfg(b06_stage_profile)] {
            let child=super::admission_summary();
            for key in &super::NAMES[11..] {assert!(child.contains(key));}
            for key in &super::NAMES[..11] {assert!(!child.contains(key));}
        }
    }
}
