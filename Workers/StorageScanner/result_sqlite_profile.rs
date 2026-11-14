// Numeric, experimental diagnosis only. No ordinary protocol/schema change.
unsafe extern "C" {
    fn sqlite3_db_status(db:*mut c_void,operation:c_int,current:*mut c_int,high:*mut c_int,reset:c_int)->c_int;
}
#[derive(Default)]
struct SqliteProfile { totals:[u64;4], failures:[Option<i32>;4], samples:u64 }
impl SqliteProfile {
    fn sample(&mut self,db:*mut c_void) {
        // Reset each supported counter every checkpoint, before its signed-int
        // range can accumulate across a large scan. Unsupported/error counters
        // stay unavailable rather than silently becoming numeric zero.
        for (index,operation) in [7,8,9,12].into_iter().enumerate() {
            if self.failures[index].is_some(){continue;}
            let (mut current,mut high)=(0,0);
            let code=unsafe{sqlite3_db_status(db,operation,&mut current,&mut high,1)};
            if code!=0 || current<0 {self.failures[index]=Some(if code!=0{code}else{-1});continue;}
            match self.totals[index].checked_add(current as u64) {
                Some(total)=>self.totals[index]=total,
                None=>self.failures[index]=Some(-2),
            }
        }
        self.samples=self.samples.saturating_add(1);
    }
    fn json(&self,statements:Option<String>)->String {
        let names=["cache_hit","cache_miss","cache_write","cache_spill"];
        let mut values=names.into_iter().enumerate().map(|(index,name)|{
            let value=match self.failures[index] {
                Some(code)=>json_map(vec![("state",quote("unavailable")),("code",code.to_string())]),
                None=>json_map(vec![("state",quote("returned")),("value",quote(&self.totals[index].to_string()))]),
            };(name,value)
        }).collect::<Vec<_>>();
        values.push(("samples",quote(&self.samples.to_string())));
        if let Some(statements)=statements{values.push(("statements",statements));}json_map(values)
    }
}
impl Writer {
    pub fn sqlite_profile(&mut self)->String {
        self.sqlite_profile.sample(self.owner.handle());
        #[cfg(b06_statement_profile)] let statements=Some(self.sample_statement_work());
        #[cfg(not(b06_statement_profile))] let statements=None;
        self.sqlite_profile.json(statements)
    }
}
