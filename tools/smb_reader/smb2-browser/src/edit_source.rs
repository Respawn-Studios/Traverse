//! Two checked Open sources on one encrypted SMB connection. Browsing may
//! retire the catalog; these fixed rows never acquire a remote handle.
use super::{catalog::SelectedRow,download_wire,edit_wire,wire::Issue};
use smb2::client::selected_download::FileSnapshot;
use std::collections::HashMap;

#[derive(Clone)]
pub struct Source {
    pub selection:download_wire::Selection,
    pub row:SelectedRow,
    pub baseline:FileSnapshot,
    pub digest:[u8;32],
}
#[derive(Default)]
pub struct Sources { entries:HashMap<String,Source> }
pub fn eligible(row:&SelectedRow,baseline:&FileSnapshot)->bool {
    row.item.object!=0 && row.item.object!=u64::MAX
        && row.item.parent!=0 && row.item.parent!=u64::MAX
        && row.item.object!=row.item.parent && baseline.index==row.item.object
        && baseline.size==row.item.size && baseline.modified==row.item.modified
        && baseline.attributes==row.item.attributes && baseline.links==1
        && baseline.volume_serial!=0 && baseline.size<=1<<20
}
impl Sources {
    pub fn can_open(&self,token:&str)->bool { self.entries.len()<2 && !self.entries.contains_key(token) }
    pub fn capture(&mut self,selection:download_wire::Selection,row:SelectedRow,
        baseline:FileSnapshot,digest:[u8;32])->Result<(),Issue>{
        if !self.can_open(&selection.token) || !eligible(&row,&baseline){return Err(Issue::Invalid);}
        self.entries.insert(selection.token.clone(),Source{selection,row,baseline,digest});Ok(())
    }
    pub fn get(&self,edit:&edit_wire::Selection)->Option<Source>{
        let source=self.entries.get(edit.source.as_ref()?)?;
        (source.selection.generation==edit.generation
            && source.selection.revision==edit.revision
            && source.selection.observation==edit.observation).then(||source.clone())
    }
    pub fn advance(&mut self,edit:&edit_wire::Selection,after:FileSnapshot)->Result<(),Issue>{
        let source=self.entries.get_mut(edit.source.as_ref().ok_or(Issue::Invalid)?).ok_or(Issue::Invalid)?;
        if source.selection.generation!=edit.generation || source.selection.revision!=edit.revision
            || source.selection.observation!=edit.observation || source.baseline!=edit.baseline
            || source.digest!=edit.before || after.index!=source.row.item.object
            || after.volume_serial!=source.baseline.volume_serial || after.size!=edit.edited_len {
            return Err(Issue::Invalid);
        }
        source.baseline=after;source.digest=edit.edited;Ok(())
    }
    pub fn release(&mut self,token:&str){self.entries.remove(token);}
    #[cfg(test)]pub fn count(&self)->usize{self.entries.len()}
}

#[cfg(test)]mod tests {
    use super::*;
    use smb2::client::selected_edit::EditAttributeContract;
    fn source(number:u64)->(download_wire::Selection,SelectedRow,FileSnapshot,[u8;32]){
        let token=format!("77777777-7777-4777-8777-{number:012X}");
        let selection=download_wire::Selection{token,ordinal:number,number,generation:
            "88888888-8888-4888-8888-888888888888".into(),revision:3,observation:number as i64};
        let row=SelectedRow{directory:"Captured\\Parent".encode_utf16().collect(),
            item:super::super::catalog::Row{observation:number as i64,wire:"Source.txt".encode_utf16().collect(),
                attributes:0x20,size:7,modified:10,object:number+40,parent:33}};
        let snapshot=FileSnapshot{size:7,allocated:4096,created:1,modified:10,changed:11,
            attributes:0x20,links:1,index:number+40,volume_created:2,volume_serial:3};
        (selection,row,snapshot,[number as u8;32])
    }
    fn edit(source:&download_wire::Selection,snapshot:FileSnapshot,digest:[u8;32])->edit_wire::Selection{
        edit_wire::Selection{token:"99999999-9999-4999-8999-999999999999".into(),ordinal:4,number:7,
            generation:source.generation.clone(),revision:source.revision,observation:source.observation,
            baseline:snapshot,before:digest,edited_len:8,edited:[9;32],
            attribute_contract:EditAttributeContract::ArchiveWriteCreationApproxV3,
            source:Some(source.token.clone())}
    }
    #[test]fn two_open_sources_are_fixed_and_advance_independently(){
        let mut retained=Sources::default();
        let (a,row_a,before_a,digest_a)=source(1);
        let (b,row_b,before_b,digest_b)=source(2);
        retained.capture(a.clone(),row_a.clone(),before_a.clone(),digest_a).unwrap();
        retained.capture(b.clone(),row_b,before_b.clone(),digest_b).unwrap();
        assert_eq!(retained.count(),2);
        assert!(!retained.can_open(&source(3).0.token));
        let edit_a=edit(&a,before_a.clone(),digest_a);
        let edit_b=edit(&b,before_b.clone(),digest_b);
        let mut after_b=before_b.clone();after_b.size=8;after_b.modified=12;
        retained.advance(&edit_b,after_b.clone()).unwrap();
        assert_eq!(retained.get(&edit_a).unwrap().baseline,before_a);
        assert_eq!(retained.get(&edit_a).unwrap().row,row_a);
        assert_eq!(retained.get(&edit_b).unwrap().baseline,after_b);
        assert_eq!(retained.get(&edit_b).unwrap().digest,[9;32]);
        retained.release(&a.token);retained.release(&a.token);
        assert!(retained.get(&edit_a).is_none());
        assert!(retained.can_open(&source(3).0.token));
    }
    #[test]fn source_identity_and_per_editor_baseline_are_required(){
        let mut retained=Sources::default();let (a,row,before,digest)=source(1);
        assert!(eligible(&row,&before));
        let mut replaced=before.clone();replaced.index+=1;
        assert!(!eligible(&row,&replaced));
        let mut linked=before.clone();linked.links=2;
        assert!(!eligible(&row,&linked));
        let mut wrong_row=row.clone();wrong_row.item.object+=1;
        assert!(retained.capture(a.clone(),wrong_row,before.clone(),digest).is_err());
        retained.capture(a.clone(),row,before.clone(),digest).unwrap();
        let mut wrong=edit(&a,before.clone(),digest);wrong.observation+=1;
        assert!(retained.get(&wrong).is_none());
        let mut foreign=edit(&a,before.clone(),digest);
        foreign.source=Some(source(2).0.token);
        assert!(retained.get(&foreign).is_none());
        let mut stale=edit(&a,before.clone(),[0;32]);
        let mut after=before.clone();after.size=8;
        assert!(retained.advance(&stale,after.clone()).is_err());
        stale.before=digest;retained.advance(&stale,after).unwrap();
        assert!(retained.advance(&stale,before).is_err());
    }
}
