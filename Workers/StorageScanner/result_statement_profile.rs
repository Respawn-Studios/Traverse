// Experimental numeric diagnosis only. No SQL text, bindings or pointer values
// escape. The callback has a pinned numeric context and the same Rc DB owner.
use std::cell::Cell as WorkCell;
unsafe extern "C" {
    fn sqlite3_stmt_status(statement:*mut c_void,operation:c_int,reset:c_int)->c_int;
    fn sqlite3_next_stmt(database:*mut c_void,previous:*mut c_void)->*mut c_void;
    fn sqlite3_libversion_number()->c_int;
}
const WORK_ROLES:[&str;10]=["node_insert","object_insert","object_find","object_update","directory_insert",
    "folder_rollup","direct_files","markers","type_totals","other_live"];
const WORK_COUNTERS:[&str;6]=["full_scan_steps","sorts","automatic_index_rows","vm_steps","reprepares","runs"];
// Sample projection-local statements before they are finalized. These counters
// are separate from the terminal snapshot of retained ingestion statements.
fn projection_statement_work(statement:&Statement)->String {
    let mut fields=vec![("state",quote("returned"))];
    for (index,name) in WORK_COUNTERS.iter().enumerate() {
        let value=unsafe{sqlite3_stmt_status(statement.raw,index as c_int+1,0)};
        if value<0{return json_map(vec![("state",quote("unavailable"))]);}
        fields.push((*name,quote(&(value as u64).to_string())));
    }
    json_map(fields)
}
#[derive(Clone,Copy,Default)]
struct StatementWork {totals:[u64;6],peak_memory:u64,peak_live:u64}
struct WorkBudget {ticks:WorkCell<u64>,maximum:u64,interval:c_int,exhausted:WorkCell<bool>}
unsafe extern "C" fn statement_work_progress(context:*mut c_void)->c_int {
    if context.is_null(){return 1;}
    // SQLite invokes this synchronously on the connection's sole thread. This
    // context stays pinned until the callback is disabled in the owner's Drop.
    let value=unsafe{&*context.cast::<WorkBudget>()};
    let next=value.ticks.get().saturating_add(1);value.ticks.set(next);
    if next>=value.maximum {value.exhausted.set(true);1}else{0}
}
struct StatementWorkProfile {
    owner:Rc<Connection>,budget:Box<WorkBudget>,groups:[StatementWork;10],
    failed:Option<&'static str>,samples:u64,version:i32,
}
impl StatementWorkProfile {
    fn new(owner:Rc<Connection>)->Self {Self::with_budget(owner,10_000,50_000)}
    fn with_budget(owner:Rc<Connection>,interval:c_int,maximum:u64)->Self {
        let mut budget=Box::new(WorkBudget{ticks:WorkCell::new(0),maximum,interval,exhausted:WorkCell::new(false)});
        let version=unsafe{sqlite3_libversion_number()};
        // The actual catalog already requires STRICT tables (SQLite3.37+).
        let failed=if version<3_037_000{Some("sqlite_version")}else{None};
        unsafe{sqlite3_progress_handler(owner.handle(),interval,Some(statement_work_progress),
            std::ptr::from_mut(&mut*budget).cast());}
        Self{owner,budget,groups:[StatementWork::default();10],failed,samples:0,version}
    }
    fn sample(&mut self,roles:[*mut c_void;9])->String {
        self.samples=self.samples.saturating_add(1);
        if self.budget.exhausted.get(){self.failed=Some("instruction_budget");}
        let mut statement=unsafe{sqlite3_next_stmt(self.owner.handle(),std::ptr::null_mut())};
        let mut count=0;let(mut memory,mut live)=([0u64;10],[0u64;10]);
        while !statement.is_null()&&self.failed.is_none(){
            if count==128 {self.failed=Some("statement_bound");break;}count+=1;
            let group=roles.iter().position(|p|*p==statement).unwrap_or(9);live[group]+=1;
            for index in 0..6 {
                let value=unsafe{sqlite3_stmt_status(statement,index as c_int+1,1)};
                if value<0{self.failed=Some("counter_unavailable");break;}
                match self.groups[group].totals[index].checked_add(value as u64){
                    Some(total)=>self.groups[group].totals[index]=total,None=>{self.failed=Some("counter_overflow");break;},
                }
            }
            let heap=unsafe{sqlite3_stmt_status(statement,99,0)};
            if heap<0{self.failed=Some("memory_unavailable");break;}
            match memory[group].checked_add(heap as u64){Some(total)=>memory[group]=total,None=>{self.failed=Some("memory_overflow");break;}}
            statement=unsafe{sqlite3_next_stmt(self.owner.handle(),statement)};
        }
        for index in 0..10 {
            self.groups[index].peak_memory=self.groups[index].peak_memory.max(memory[index]);
            self.groups[index].peak_live=self.groups[index].peak_live.max(live[index]);
        }
        self.json()
    }
    fn json(&self)->String {
        let mut fields=vec![("state",quote(if self.failed.is_some(){"unavailable"}else{"returned"})),
            ("scope",quote("live_retained_statements_only")),("finalized_statements_included","false".into()),
            ("sqlite_version",self.version.to_string()),("samples",quote(&self.samples.to_string())),
            ("progress_callbacks",quote(&self.budget.ticks.get().to_string())),
            ("progress_interval",self.budget.interval.to_string()),("maximum_progress_callbacks",quote(&self.budget.maximum.to_string()))];
        if let Some(reason)=self.failed {fields.push(("reason",quote(reason)));}
        else {
            let groups=WORK_ROLES.into_iter().enumerate().map(|(index,name)|{
                let value=&self.groups[index];let mut row=WORK_COUNTERS.into_iter().enumerate()
                    .map(|(n,key)|(key,quote(&value.totals[n].to_string()))).collect::<Vec<_>>();
                row.push(("peak_statement_memory",quote(&value.peak_memory.to_string())));
                row.push(("maximum_live_statements",quote(&value.peak_live.to_string())));(name,json_map(row))
            }).collect::<Vec<_>>();fields.push(("groups",json_map(groups)));
        }json_map(fields)
    }
}
impl Drop for StatementWorkProfile {
    fn drop(&mut self){
        // Unregister while both the pinned context and its retained connection
        // still exist. No callback context survives this profile owner.
        unsafe{sqlite3_progress_handler(self.owner.handle(),0,None,std::ptr::null_mut());}
    }
}
impl Writer {
    fn sample_statement_work(&mut self)->String {
        let mut roles=[std::ptr::null_mut();9];
        roles[0]=self.insert.raw;roles[5]=self.rollup.raw;roles[6]=self.files.raw;roles[7]=self.marker.raw;roles[8]=self.types_statement.raw;
        #[cfg(b06_reference_index)]{roles[1]=self.index.insert.raw;roles[2]=self.index.find.raw;roles[3]=self.index.update.raw;roles[4]=self.index.directory.raw;}
        self.statement_profile.sample(roles)
    }
}
#[cfg(test)]mod statement_work_tests {
    use super::*;
    #[test]fn actual_sqlite_counters_reset_without_double_counting_and_capture_real_sort_work(){
        let owner=Connection::open_existing(c":memory:").unwrap();
        owner.execute("CREATE TABLE generated(value INTEGER);INSERT INTO generated VALUES(3),(1),(2);").unwrap();
        let statement=Statement::new(Rc::clone(&owner),"SELECT value FROM generated ORDER BY value DESC").unwrap();
        let mut profile=StatementWorkProfile::new(Rc::clone(&owner));
        let mut count=0;while statement.row().unwrap(){count+=1;}statement.reset().unwrap();assert_eq!(count,3);
        let mut roles=[std::ptr::null_mut();9];roles[0]=statement.raw;
        let output=profile.sample(roles);assert!(profile.failed.is_none());
        let first=profile.groups[0];assert!(first.totals[0]>0&&first.totals[1]>0&&first.totals[3]>0);assert_eq!(first.totals[5],1);
        assert!(first.peak_memory>0&&output.contains("live_retained_statements_only"));
        profile.sample(roles);assert_eq!(profile.groups[0].totals,first.totals);
        assert!(!output.contains("SELECT")&&!output.contains("generated(value"));
    }
    #[test]fn progress_budget_really_interrupts_and_callback_removal_allows_connection_reuse(){
        let owner=Connection::open_existing(c":memory:").unwrap();
        let mut profile=StatementWorkProfile::with_budget(Rc::clone(&owner),1,100);
        let sql="WITH RECURSIVE n(x) AS(VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<10000)SELECT sum(x)FROM n";
        assert_eq!(owner.execute(sql),Err(super::super::catalog::Error::Sqlite(9)));
        let output=profile.sample([std::ptr::null_mut();9]);assert_eq!(profile.failed,Some("instruction_budget"));
        assert!(output.contains("unavailable")&&!output.contains("\"groups\""));
        drop(profile);assert!(owner.execute(sql).is_ok());
    }
    #[test]fn live_statement_cap_is_explicit_and_unavailable_is_not_zero_work(){
        let owner=Connection::open_existing(c":memory:").unwrap();let mut profile=StatementWorkProfile::new(Rc::clone(&owner));
        let statements=(0..129).map(|_|Statement::new(Rc::clone(&owner),"SELECT 1").unwrap()).collect::<Vec<_>>();
        let output=profile.sample([std::ptr::null_mut();9]);assert_eq!(profile.failed,Some("statement_bound"));
        assert!(output.contains("unavailable")&&!output.contains("\"groups\""));drop(statements);
    }
    #[test]fn pinned_callback_owns_its_connection_after_the_callers_reference_is_dropped(){
        let owner=Connection::open_existing(c":memory:").unwrap();let mut profile=StatementWorkProfile::new(Rc::clone(&owner));
        let statement=Statement::new(Rc::clone(&owner),"SELECT 1").unwrap();drop(owner);
        assert!(statement.row().unwrap());assert!(!statement.row().unwrap());statement.reset().unwrap();
        drop(statement);profile.sample([std::ptr::null_mut();9]);assert!(profile.failed.is_none());
        assert_eq!(Rc::strong_count(&profile.owner),1);drop(profile);
    }
}
