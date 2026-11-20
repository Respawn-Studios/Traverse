//! Bounded, explicitly supplied key material. No path, config, agent, shell or
//! credential lookup. Admission belongs after the exact host-review evidence.
#![deny(warnings)]
use std::{fmt, sync::Arc, time::{SystemTime,UNIX_EPOCH}};
use russh::keys::{self, ssh_key::{self, certificate::CertType, private::KeypairData}, Algorithm, Certificate, HashAlg, PrivateKey, PublicKey};
use russh::keys::signature::Signer as _;
use rsa::traits::PrivateKeyParts;
use zeroize::Zeroizing;

pub const MAXIMUM_KEY_BYTES:usize=32768;
pub const MAXIMUM_CERTIFICATE_BYTES:usize=8192;
pub const MAXIMUM_PASSPHRASE_BYTES:usize=4096;
pub const MAXIMUM_BCRYPT_ROUNDS:u32=64;
#[derive(Clone,Copy,PartialEq,Eq)]
pub enum Failure{Input,Format,Passphrase,Cost,Algorithm,Inconsistent,Signing,Closed,CertificateExpired,CertificateNotYetValid}
impl fmt::Debug for Failure{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{f.write_str("<SSH key could not be used>")}}
impl From<russh::SendError> for Failure{fn from(_:russh::SendError)->Self{Self::Closed}}

enum Material{Native(Arc<PrivateKey>),Rsa(Box<ring::rsa::KeyPair>)}
pub struct PreparedKey{public:PublicKey,material:Material,certificate:Option<Certificate>,
    certificate_attempted:bool,signatures:u8}
impl fmt::Debug for PreparedKey{fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result{f.write_str("<prepared SSH identity>")}}

/// Only modern, qualified underlying key algorithms. SK stubs, DSA, custom
/// providers and SHA-1 signatures do not enter this private-key path.
pub fn admitted_public(public:&PublicKey)->Result<(),Failure>{
    match public.algorithm(){
        Algorithm::Ed25519|Algorithm::Ecdsa{..}=>Ok(()),
        Algorithm::Rsa{..}=>{
            let rsa=public.key_data().rsa().ok_or(Failure::Algorithm)?;
            let n=rsa.n().as_positive_bytes().ok_or(Failure::Algorithm)?;
            let e=rsa.e().as_positive_bytes().ok_or(Failure::Algorithm)?;
            // Matching ring's supported local signing range also bounds public
            // verification allocations. Moduli must be genuinely >= 2048 bits.
            let bits=n.len().checked_mul(8).and_then(|bits|bits.checked_sub(n.first().map_or(8,|n|n.leading_zeros())as usize)).ok_or(Failure::Algorithm)?;
            if !(2048..=4096).contains(&bits)||e.len()>4{return Err(Failure::Algorithm)}
            let exponent=e.iter().fold(0u64,|v,b|(v<<8)|u64::from(*b));
            if exponent<65537||exponent&1==0{return Err(Failure::Algorithm)}Ok(())
        },
        _=>Err(Failure::Algorithm),
    }
}

impl PreparedKey{
    pub fn decode(bytes:Zeroizing<Vec<u8>>,passphrase:Zeroizing<String>)->Result<Self,Failure>{
        if bytes.is_empty()||bytes.len()>MAXIMUM_KEY_BYTES||passphrase.len()>MAXIMUM_PASSPHRASE_BYTES
            ||bytes.contains(&0)||passphrase.contains('\0'){return Err(Failure::Input)}
        let text=std::str::from_utf8(&bytes).map_err(|_|Failure::Format)?.trim();
        let key=if text.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"){
            if !text.ends_with("-----END OPENSSH PRIVATE KEY-----"){return Err(Failure::Format)}
            let key=PrivateKey::from_openssh(text).map_err(|_|Failure::Format)?;
            admitted_public(key.public_key())?;
            if key.is_encrypted(){
                match key.kdf(){
                    ssh_key::Kdf::Bcrypt{salt,rounds}if (1..=MAXIMUM_BCRYPT_ROUNDS).contains(rounds)
                        &&(16..=64).contains(&salt.len())=>{},
                    _=>return Err(Failure::Cost),
                }
                match key.cipher(){
                    ssh_key::Cipher::Aes128Ctr|ssh_key::Cipher::Aes192Ctr|ssh_key::Cipher::Aes256Ctr
                    |ssh_key::Cipher::Aes128Cbc|ssh_key::Cipher::Aes192Cbc|ssh_key::Cipher::Aes256Cbc=>{},
                    _=>return Err(Failure::Format),
                }
                if passphrase.is_empty(){return Err(Failure::Passphrase)}
                key.decrypt(passphrase.as_bytes()).map_err(|_|Failure::Passphrase)?
            }else{
                if !matches!(key.kdf(),ssh_key::Kdf::None){return Err(Failure::Format)}key
            }
        }else{
            // Plain PKCS#1/PKCS#8/SEC1 are bounded. Encrypted PEM/PPK have
            // different KDF contracts and must not reach a generic decoder
            // before their own cost preflight has been qualified.
            let pair=[("RSA PRIVATE KEY","-----BEGIN RSA PRIVATE KEY-----"),
                ("PRIVATE KEY","-----BEGIN PRIVATE KEY-----"),("EC PRIVATE KEY","-----BEGIN EC PRIVATE KEY-----")]
                .into_iter().find(|(_,begin)|text.starts_with(begin)).ok_or(Failure::Format)?;
            if !text.ends_with(&format!("-----END {}-----",pair.0))||text.contains("Proc-Type:")||text.contains("DEK-Info:")
                ||text.lines().filter(|line|line.starts_with("-----BEGIN")).count()!=1{return Err(Failure::Format)}
            if !text.lines().skip(1).take_while(|line|!line.starts_with("-----END ")).all(|line|
                !line.is_empty()&&line.len()<=128&&line.bytes().all(|b|b.is_ascii_alphanumeric()||matches!(b,b'+'|b'/'|b'='))){return Err(Failure::Format)}
            keys::decode_secret_key(text,None).map_err(|_|Failure::Format)?
        };
        admitted_public(key.public_key())?;
        let public=key.public_key().clone();
        let material=match key.key_data(){
            KeypairData::Rsa(rsa)=>Material::Rsa(Box::new(prepare_rsa(rsa)?)),
            KeypairData::Ed25519(_)|KeypairData::Ecdsa(_)=>Material::Native(Arc::new(key)),
            _=>return Err(Failure::Algorithm),
        };
        let mut prepared=Self{public,material,certificate:None,certificate_attempted:false,signatures:0};
        // Reject mismatched components before an authentication offer. The
        // public verifier also catches malformed Ed25519/ECDSA keypairs.
        let mut probe=[0u8;32];ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(),&mut probe).map_err(|_|Failure::Signing)?;
        let hash=if matches!(prepared.material,Material::Rsa(_)){Some(HashAlg::Sha256)}else{None};
        prepared.signature(&probe,hash)?;
        Ok(prepared)
    }
    pub fn public(&self)->&PublicKey{&self.public}
    /// Bind exactly one selected user certificate to this private-key signer.
    /// Signature and time checks reject stale or corrupt input; the server owns
    /// CA trust, principal and critical-option policy for user authentication.
    pub fn bind_user_certificate(&mut self,bytes:&[u8])->Result<Certificate,Failure>{
        self.certificate_attempted=true;
        self.certificate=None;
        if bytes.is_empty()||bytes.len()>MAXIMUM_CERTIFICATE_BYTES||bytes.contains(&0){return Err(Failure::Input)}
        let text=std::str::from_utf8(bytes).map_err(|_|Failure::Format)?;
        let text=text.strip_suffix('\n').unwrap_or(text);
        if text.bytes().any(|b|b.is_ascii_control()){return Err(Failure::Format)}
        let certificate=Certificate::from_openssh(text).map_err(|_|Failure::Format)?;
        if certificate.cert_type()!=CertType::User{return Err(Failure::Format)}
        if certificate.public_key()!=self.public.key_data(){return Err(Failure::Inconsistent)}
        certificate.verify_signature().map_err(|_|Failure::Format)?;
        let now=SystemTime::now().duration_since(UNIX_EPOCH).map_err(|_|Failure::Format)?.as_secs();
        if certificate.valid_after()>now{return Err(Failure::CertificateNotYetValid)}
        if now>=certificate.valid_before(){return Err(Failure::CertificateExpired)}
        self.certificate=Some(certificate.clone());
        Ok(certificate)
    }
    fn signature(&mut self,data:&[u8],hash:Option<HashAlg>)->Result<ssh_key::Signature,Failure>{
        if data.is_empty()||data.len()>32768{return Err(Failure::Input)}
        let signature=match &self.material{
            Material::Native(key)=>{
                if hash.is_some()||matches!(key.algorithm(),Algorithm::Rsa{..}){return Err(Failure::Algorithm)}
                key.try_sign(data).map_err(|_|Failure::Signing)?
            },
            Material::Rsa(key)=>{
                let encoding:&'static dyn ring::signature::RsaEncoding=match hash{
                    Some(HashAlg::Sha256)=>&ring::signature::RSA_PKCS1_SHA256,
                    Some(HashAlg::Sha512)=>&ring::signature::RSA_PKCS1_SHA512,
                    _=>return Err(Failure::Algorithm),
                };
                let mut bytes=vec![0;key.public().modulus_len()];
                key.sign(encoding,&ring::rand::SystemRandom::new(),data,&mut bytes).map_err(|_|Failure::Signing)?;
                ssh_key::Signature::new(Algorithm::Rsa{hash},bytes).map_err(|_|Failure::Signing)?
            },
        };
        keys::signature::Verifier::verify(&self.public,data,&signature).map_err(|_|Failure::Inconsistent)?;
        Ok(signature)
    }
}

fn prepare_rsa(key:&ssh_key::private::RsaKeypair)->Result<ring::rsa::KeyPair,Failure>{
    let private=key.private();
    for component in[private.d(),private.p(),private.q(),private.iqmp()]{
        if component.as_positive_bytes().is_none_or(|b|b.is_empty()||b.len()>512){return Err(Failure::Algorithm)}
    }
    // Local bounded CRT preparation only. ring owns all private signatures.
    let computed=rsa::PrivateKey::try_from(key).map_err(|_|Failure::Inconsistent)?;
    let dp=Zeroizing::new(computed.dp().ok_or(Failure::Inconsistent)?.to_be_bytes().to_vec());
    let dq=Zeroizing::new(computed.dq().ok_or(Failure::Inconsistent)?.to_be_bytes().to_vec());
    let components=ring::rsa::KeyPairComponents{
        public_key:ring::rsa::PublicKeyComponents{n:key.public().n().as_positive_bytes().ok_or(Failure::Algorithm)?,
            e:key.public().e().as_positive_bytes().ok_or(Failure::Algorithm)?},
        d:private.d().as_positive_bytes().ok_or(Failure::Algorithm)?,
        p:private.p().as_positive_bytes().ok_or(Failure::Algorithm)?,
        q:private.q().as_positive_bytes().ok_or(Failure::Algorithm)?,
        dP:&dp[..],dQ:&dq[..],qInv:private.iqmp().as_positive_bytes().ok_or(Failure::Algorithm)?,
    };
    ring::rsa::KeyPair::from_components(&components).map_err(|_|Failure::Inconsistent)
}

impl russh::Signer for PreparedKey{
    type Error=Failure;
    async fn auth_sign(&mut self,identity:&keys::agent::AgentIdentity,hash:Option<HashAlg>,mut data:Vec<u8>)->Result<Vec<u8>,Failure>{
        match identity{
            keys::agent::AgentIdentity::PublicKey{key,..}if !self.certificate_attempted&&key==&self.public=>{},
            keys::agent::AgentIdentity::Certificate{certificate,..}
                if self.certificate.as_ref()==Some(certificate)&&certificate.public_key()==self.public.key_data()=>{},
            _=>return Err(Failure::Algorithm),
        }
        if self.signatures>=2{return Err(Failure::Input)}self.signatures+=1;
        let signature=self.signature(&data,hash)?;
        use keys::ssh_encoding::Encode;
        let mut encoded=Vec::new();signature.encode(&mut encoded).map_err(|_|Failure::Signing)?;
        data.extend((encoded.len()as u32).to_be_bytes());data.extend(encoded);Ok(data)
    }
}

#[cfg(test)]mod tests{
    use super::*;
    fn selected_key(algorithm:Algorithm)->(PrivateKey,PreparedKey){
        let private=PrivateKey::random(&mut rand::rng(),algorithm).unwrap();
        let text=private.to_openssh(ssh_key::LineEnding::LF).unwrap();
        let prepared=PreparedKey::decode(Zeroizing::new(text.as_bytes().to_vec()),Zeroizing::new(String::new())).unwrap();
        (private,prepared)
    }
    fn selected_user_key()->(PrivateKey,PreparedKey){selected_key(Algorithm::Ed25519)}
    #[test]
    fn selected_rsa_key_signs_with_both_modern_hashes() {
        let (_, mut prepared) = selected_key(Algorithm::Rsa { hash: None });
        let challenge = b"Generated SSH signing check";
        for hash in [HashAlg::Sha256, HashAlg::Sha512] {
            let signature = prepared.signature(challenge, Some(hash)).unwrap();
            assert_eq!(signature.algorithm(), Algorithm::Rsa { hash: Some(hash) });
        }
    }

    fn certificate(subject:&PrivateKey,kind:CertType,after:u64,before:u64)->Certificate{
        let ca=PrivateKey::random(&mut rand::rng(),Algorithm::Ed25519).unwrap();
        let mut builder=ssh_key::certificate::Builder::new(vec![7;16],subject.public_key().key_data().clone(),after,before).unwrap();
        builder.cert_type(kind).unwrap();builder.valid_principal("generated").unwrap();builder.sign(&ca).unwrap()
    }
    #[tokio::test]
    async fn selected_user_certificate_matches_key_and_never_enables_plain_signing(){
        let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let(private,mut prepared)=selected_user_key();
        let cert=certificate(&private,CertType::User,now-60,now+60);
        let text=format!("{}\n",cert.to_openssh().unwrap());
        assert_eq!(prepared.bind_user_certificate(text.as_bytes()).unwrap(),cert);
        let plain=keys::agent::AgentIdentity::PublicKey{key:private.public_key().clone(),comment:String::new()};
        assert!(russh::Signer::auth_sign(&mut prepared,&plain,None,vec![7]).await.is_err());
        let other_cert=keys::agent::AgentIdentity::Certificate{
            certificate:certificate(&private,CertType::User,now-60,now+60),comment:String::new()};
        assert!(russh::Signer::auth_sign(&mut prepared,&other_cert,None,vec![7]).await.is_err());
        let selected=keys::agent::AgentIdentity::Certificate{certificate:cert,comment:String::new()};
        assert!(russh::Signer::auth_sign(&mut prepared,&selected,None,vec![7]).await.is_ok());
        assert_eq!(prepared.bind_user_certificate(b"invalid").err(),Some(Failure::Format));
        assert!(russh::Signer::auth_sign(&mut prepared,&plain,None,vec![7]).await.is_err());
        assert!(russh::Signer::auth_sign(&mut prepared,&selected,None,vec![7]).await.is_err());
    }
    #[tokio::test]
    async fn selected_ecdsa_user_certificate_uses_matching_private_key(){
        let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let(private,mut prepared)=selected_key(Algorithm::Ecdsa{curve:keys::EcdsaCurve::NistP256});
        let cert=certificate(&private,CertType::User,now-60,now+60);
        prepared.bind_user_certificate(cert.to_openssh().unwrap().as_bytes()).unwrap();
        let selected=keys::agent::AgentIdentity::Certificate{certificate:cert,comment:String::new()};
        assert!(russh::Signer::auth_sign(&mut prepared,&selected,None,vec![7]).await.is_ok());
    }
    #[test]
    fn selected_user_certificate_refuses_wrong_key_type_and_time(){
        let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let(private,mut prepared)=selected_user_key();
        let(other,_)=selected_user_key();
        let valid=certificate(&private,CertType::User,now-60,now+60);
        let other_text=certificate(&other,CertType::User,now-60,now+60).to_openssh().unwrap();
        assert_eq!(prepared.bind_user_certificate(other_text.as_bytes()).err(),Some(Failure::Inconsistent));
        let host_text=certificate(&private,CertType::Host,now-60,now+60).to_openssh().unwrap();
        assert_eq!(prepared.bind_user_certificate(host_text.as_bytes()).err(),Some(Failure::Format));
        let expired=certificate(&private,CertType::User,now-120,now-60).to_openssh().unwrap();
        assert_eq!(prepared.bind_user_certificate(expired.as_bytes()).err(),Some(Failure::CertificateExpired));
        let future=certificate(&private,CertType::User,now+60,now+120).to_openssh().unwrap();
        assert_eq!(prepared.bind_user_certificate(future.as_bytes()).err(),Some(Failure::CertificateNotYetValid));
        let mut corrupt=valid.to_bytes().unwrap();*corrupt.last_mut().unwrap()^=1;
        let corrupt=Certificate::from_bytes(&corrupt).unwrap().to_openssh().unwrap();
        assert_eq!(prepared.bind_user_certificate(corrupt.as_bytes()).err(),Some(Failure::Format));
        assert_eq!(prepared.bind_user_certificate(b"not a certificate").err(),Some(Failure::Format));
        assert_eq!(prepared.bind_user_certificate(&vec![b'a';MAXIMUM_CERTIFICATE_BYTES+1]).err(),Some(Failure::Input));
        // A valid certificate never binds after a failed selection unless
        // the caller explicitly supplies it on a fresh attempt.
        assert_eq!(prepared.bind_user_certificate(valid.to_openssh().unwrap().as_bytes()).unwrap(),valid);
    }
    #[test]fn malformed_and_oversized_key_material_never_reaches_crypto(){
        for bytes in[vec![],vec![b'a';MAXIMUM_KEY_BYTES+1],b"arbitrary private data".to_vec(),b"\0".to_vec(),
            b"-----BEGIN ENCRYPTED PRIVATE KEY-----\nZg==\n-----END ENCRYPTED PRIVATE KEY-----".to_vec(),
            b"PuTTY-User-Key-File-3: ssh-ed25519".to_vec()]{
            assert!(PreparedKey::decode(Zeroizing::new(bytes),Zeroizing::new(String::new())).is_err());
        }
        assert_eq!(format!("{:?}",Failure::Passphrase),"<SSH key could not be used>");
    }
}
