//! Bounded server-prompt contract. No UI, saved answer, command or credential lookup.
use russh::client::KeyboardInteractiveAuthResponse;
use zeroize::Zeroizing;
pub const MAX_ROUNDS:u8=8;
pub const MAX_PROMPTS:usize=8;
pub const MAX_ANSWER:usize=4096;
pub const MAX_ANSWERS:usize=8192;
#[derive(Debug,Clone,Copy,PartialEq,Eq)]pub enum Failure{Denied,Bounds,Phase}
pub struct Prompt{pub text:String,pub echo:bool}
pub struct Challenge{pub name:String,pub instructions:String,pub prompts:Vec<Prompt>}
pub enum Step{Complete,Challenge(Challenge)}
pub fn step(reply:KeyboardInteractiveAuthResponse)->Result<Step,Failure>{
    match reply{
        KeyboardInteractiveAuthResponse::Success=>Ok(Step::Complete),
        KeyboardInteractiveAuthResponse::Failure{..}=>Err(Failure::Denied),
        KeyboardInteractiveAuthResponse::InfoRequest{name,instructions,prompts}=>{
            if name.len()>256||instructions.len()>4096||prompts.len()>MAX_PROMPTS
                ||prompts.iter().any(|p|p.prompt.len()>1024){return Err(Failure::Bounds)}
            Ok(Step::Challenge(Challenge{name,instructions,prompts:prompts.into_iter().map(|p|Prompt{text:p.prompt,echo:p.echo}).collect()}))
        },
    }
}
pub fn answers(values:Zeroizing<Vec<String>>,count:usize)->Result<Zeroizing<Vec<String>>,Failure>{
    if count>MAX_PROMPTS||values.len()!=count||values.iter().any(|s|s.len()>MAX_ANSWER||s.contains('\0'))
        ||values.iter().try_fold(0usize,|n,s|n.checked_add(s.len())).is_none_or(|n|n>MAX_ANSWERS){return Err(Failure::Bounds)}
    Ok(values)
}
#[derive(Default)]pub struct Rounds{round:u8,awaiting:Option<usize>,finished:bool}
impl Rounds{
    pub fn challenge(&mut self,count:usize)->Result<u8,Failure>{
        if self.finished||self.awaiting.is_some()||self.round>=MAX_ROUNDS||count>MAX_PROMPTS{return Err(Failure::Phase)}
        self.round+=1;self.awaiting=Some(count);Ok(self.round)
    }
    pub fn response(&mut self,round:u8,values:Zeroizing<Vec<String>>)->Result<Zeroizing<Vec<String>>,Failure>{
        if self.finished||round!=self.round{return Err(Failure::Phase)}
        let count=self.awaiting.ok_or(Failure::Phase)?;
        let result=answers(values,count)?;self.awaiting=None;Ok(result)
    }
    pub fn complete(&mut self)->Result<(),Failure>{
        if self.finished||self.awaiting.is_some(){return Err(Failure::Phase)}self.finished=true;Ok(())
    }
}
#[cfg(test)]mod tests{
    use super::*;
    fn response(values:&[&str])->Zeroizing<Vec<String>>{Zeroizing::new(values.iter().map(|v|v.to_string()).collect())}
    #[test]fn exact_round_count_and_explicit_empty_challenge(){
        let mut rounds=Rounds::default();assert!(rounds.response(0,response(&[])).is_err());
        assert_eq!(rounds.challenge(0),Ok(1));assert!(rounds.complete().is_err());
        assert!(rounds.response(2,response(&[])).is_err());assert!(rounds.response(1,response(&[])).is_ok());
        assert!(rounds.response(1,response(&[])).is_err());assert_eq!(rounds.challenge(1),Ok(2));
        assert!(rounds.response(2,response(&[""])).is_ok());assert_eq!(rounds.complete(),Ok(()));
        assert!(rounds.challenge(1).is_err());assert!(rounds.complete().is_err());
    }
    #[test]fn bounded_rounds_and_answer_shape(){
        let mut rounds=Rounds::default();
        for round in 1..=MAX_ROUNDS{assert_eq!(rounds.challenge(2),Ok(round));
            assert!(rounds.response(round,response(&["only one"])).is_err());
            assert!(rounds.response(round,response(&["account","code"])).is_ok());}
        assert!(rounds.challenge(0).is_err());
        assert!(answers(response(&["a\0b"]),1).is_err());assert!(answers(response(&[&"x".repeat(4097)]),1).is_err());
        assert!(answers(response(&[&"x".repeat(4096),&"x".repeat(4096),"x"]),3).is_err());
    }
    #[test]fn server_text_and_prompt_count_are_bounded_without_rewriting(){
        fn reply(name:String,instructions:String,count:usize,text:String)->KeyboardInteractiveAuthResponse{
            KeyboardInteractiveAuthResponse::InfoRequest{name,instructions,prompts:(0..count).map(|_|russh::client::Prompt{prompt:text.clone(),echo:false}).collect()}
        }
        assert!(step(reply(String::new(),String::new(),0,String::new())).is_ok());
        for value in [reply("x".repeat(257),String::new(),0,String::new()),reply(String::new(),"x".repeat(4097),0,String::new()),
            reply(String::new(),String::new(),9,String::new()),reply(String::new(),String::new(),1,"x".repeat(1025))]{assert!(matches!(step(value),Err(Failure::Bounds)))}
        let Step::Challenge(value)=step(reply("literal".into(),"\u{202e}untrusted".into(),1,"code:\n".into())).unwrap()else{panic!()};
        assert_eq!(value.instructions,"\u{202e}untrusted");assert_eq!(value.prompts[0].text,"code:\n");
    }
}
