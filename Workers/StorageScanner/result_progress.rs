// Experimental committed-prefix snapshots. No reader opens an unsealed store.
// Candidate aggregates become publishable only after COMMIT and fresh authority.
use std::cell::Cell;
struct ProgressTotals {
    candidate:Cell<Value>,committed:Value,types:[Value;FILE_TYPE_COUNT],count:u64,
}
impl Default for ProgressTotals {
    fn default()->Self{Self{candidate:Cell::new(Value::default()),committed:Value::default(),types:[Value::default();FILE_TYPE_COUNT],count:0}}
}
impl ProgressTotals {
    fn commit(&mut self,count:u64,types:&[Value;FILE_TYPE_COUNT])->Result<()> {
        // State-only commits after Stop must not publish a rolled-back tail.
        if count<=self.count{return Ok(());}
        let total=self.candidate.get();let mut sum=Value::default();
        for value in types {
            if (8..40).step_by(8).any(|p|u64_at(&value.0,p)!=0){return Err("prefix_partition");}
            sum.merge(value)?;
        }
        if total.entries()?!=count || u64_at(&sum.0,0)!=u64_at(&total.0,0) || sum.0[40..]!=total.0[40..]{return Err("prefix_partition");}
        self.committed=total;self.types=*types;self.count=count;Ok(())
    }
    fn frame(&self)->Vec<(&'static str,String)> {
        let groups=self.types.iter().enumerate().map(|(id,value)|json_map(vec![("id",id.to_string()),("value",quote(&base64(&value.0)))])).collect::<Vec<_>>();
        vec![("committed",quote(&self.count.to_string())),("value",quote(&base64(&self.committed.0))),("types",format!("[{}]",groups.join(",")))]
    }
}
impl Writer { pub fn committed_totals(&self)->Vec<(&'static str,String)>{self.progress.frame()} }

#[cfg(test)]
mod progress_tests {
    use super::*;
    #[test]fn only_successful_committed_candidates_are_published(){
        let o=Observation{object_type:Some(1),values:[Some(10),None,Some(0),None],..Default::default()};
        let one=Value::observation(&o);let mut p=ProgressTotals::default();let mut types=[Value::default();FILE_TYPE_COUNT];types[0]=one;
        p.candidate.set(one);assert_eq!(p.count,0);p.commit(1,&types).unwrap();assert_eq!(p.committed,one);
        let mut two=one;two.merge(&one).unwrap();p.candidate.set(two);types[0]=two;
        // A rollback followed by a scan-state commit has the old row count.
        p.commit(1,&types).unwrap();assert_eq!(p.committed,one);assert_eq!(p.types[0],one);
        p.commit(2,&types).unwrap();assert_eq!(p.committed,two);
        assert!(p.frame().iter().find(|p|p.0=="types").unwrap().1.len()<4096);
    }
    #[test]fn mismatched_partitions_and_counts_refuse(){
        let mut p=ProgressTotals::default();assert!(p.commit(1,&[Value::default();FILE_TYPE_COUNT]).is_err());
        let o=Observation{object_type:Some(1),values:[Some(10);4],..Default::default()};p.candidate.set(Value::observation(&o));
        assert!(p.commit(1,&[Value::default();FILE_TYPE_COUNT]).is_err());assert_eq!(p.count,0);
    }
}
