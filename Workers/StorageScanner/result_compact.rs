// Experimental storage codec only; the native-facing protocol stays fixed.
// Every integer is unsigned canonical LEB128; zero, absent, error and overflow
// retain distinct tags. Bounds apply before allocation or slice reads.
fn compact_uint(out:&mut Vec<u8>,mut value:u64) {
    loop { let byte=(value&127) as u8;value>>=7;out.push(byte|if value>0{128}else{0});if value==0{break;} }
}
fn compact_read(bytes:&[u8],cursor:&mut usize)->Result<u64> {
    let mut value=0u64;
    for i in 0..10 {
        let byte=*bytes.get(*cursor).ok_or("store_codec")?;*cursor+=1;
        if i==9 && byte>1 {return Err("store_codec");}
        value|=u64::from(byte&127)<<(i*7);
        if byte&128==0 {
            if i>0 && byte==0{return Err("store_codec");}return Ok(value);
        }
    }Err("store_codec")
}
#[cfg(any(not(b06_stack_metadata),test))]
fn compact_payload(fixed:&[u8])->Result<Vec<u8>> {
    if fixed.len()!=52{return Err("store_codec");}
    let mut out=vec![1];
    for chunk in fixed.chunks_exact(13) {
        let number=u64_at(chunk,1);let error=u32::from_be_bytes(chunk[9..13].try_into().unwrap());
        out.push(chunk[0]);match chunk[0] {
            0 if number==0 && error==0=>{},
            1 if error==0=>compact_uint(&mut out,number),
            2 if number==0 && error>0=>compact_uint(&mut out,u64::from(error)),
            _=>return Err("store_codec"),
        }
    }Ok(out)
}
#[cfg(any(b06_stack_metadata,test))]
struct StackPayload {bytes:[u8;45],len:usize}
#[cfg(any(b06_stack_metadata,test))]
impl StackPayload {
    fn slice(&self)->&[u8]{&self.bytes[..self.len]}
    fn number(&mut self,mut value:u64) {
        loop {let b=(value&127) as u8;value>>=7;self.bytes[self.len]=b|if value>0{128}else{0};self.len+=1;if value==0{break;}}
    }
    fn encode(fixed:&[u8])->Result<Self> {
        if fixed.len()!=52{return Err("store_codec");}
        let mut out=Self{bytes:[0;45],len:1};out.bytes[0]=1;
        for chunk in fixed.chunks_exact(13) {
            let number=u64_at(chunk,1);let error=u32::from_be_bytes(chunk[9..13].try_into().unwrap());
            out.bytes[out.len]=chunk[0];out.len+=1;
            match chunk[0] {
                0 if number==0 && error==0=>{},1 if error==0=>out.number(number),
                2 if number==0 && error>0=>out.number(u64::from(error)),_=>return Err("store_codec"),
            }
        }Ok(out)
    }
}
fn expand_payload(bytes:&[u8])->Result<Vec<u8>> {
    if bytes.first()!=Some(&1) || bytes.len()>45{return Err("store_codec");}
    let mut result=vec![0;52];let mut cursor=1;
    for metric in 0..4 {
        let state=*bytes.get(cursor).ok_or("store_codec")?;cursor+=1;let offset=metric*13;result[offset]=state;
        match state {
            0=>{},1=>put(&mut result,offset+1,compact_read(bytes,&mut cursor)?),
            2=>{let value=u32::try_from(compact_read(bytes,&mut cursor)?).map_err(|_|"store_codec")?;
                if value==0{return Err("store_codec");}result[offset+9..offset+13].copy_from_slice(&value.to_be_bytes());},
            _=>return Err("store_codec"),
        }
    }
    if cursor!=bytes.len(){return Err("store_codec");}Ok(result)
}
fn compact_value(value:&Value)->Vec<u8> {
    let mut out=vec![1];for offset in (0..40).step_by(8){compact_uint(&mut out,u64_at(&value.0,offset));}
    for metric in 0..4 {let offset=40+metric*25;out.push(value.0[offset+24]);for part in [0,8,16]{compact_uint(&mut out,u64_at(&value.0,offset+part));}}
    out
}
fn expand_value(bytes:&[u8])->Result<Value> {
    if bytes.first()!=Some(&1) || bytes.len()>175{return Err("store_codec");}
    let mut value=Value::default();let mut cursor=1;
    for offset in (0..40).step_by(8){put(&mut value.0,offset,compact_read(bytes,&mut cursor)?);}
    for metric in 0..4 {
        let offset=40+metric*25;let overflow=*bytes.get(cursor).ok_or("store_codec")?;cursor+=1;
        if overflow>1{return Err("store_codec");}value.0[offset+24]=overflow;
        for part in [0,8,16]{put(&mut value.0,offset+part,compact_read(bytes,&mut cursor)?);}
    }
    if cursor!=bytes.len(){return Err("store_codec");}Value::decode(&value.0)
}
#[cfg(test)]
mod compact_tests {
    use super::*;
    #[test] fn exact_fields_and_noncanonical_controls() {
        for v in [0,1,127,128,16383,16384,u32::MAX as u64,u64::MAX] {
            let mut payload=payload(&Observation{object_type:Some(1),values:[Some(v),None,Some(0),Some(u64::MAX)],..Default::default()});
            payload[13]=2;payload[22..26].copy_from_slice(&13u32.to_be_bytes());
            let encoded=compact_payload(&payload).unwrap();assert_eq!(expand_payload(&encoded).unwrap(),payload);
            for end in 0..encoded.len(){assert!(expand_payload(&encoded[..end]).is_err());}
            let mut trailing=encoded.clone();trailing.push(0);assert!(expand_payload(&trailing).is_err());
            let mut aggregate=Value::observation(&Observation{object_type:Some(1),values:[Some(v),None,Some(0),Some(u64::MAX)],..Default::default()});
            put(&mut aggregate.0,40+3*25,0);aggregate.0[139]=1;
            let encoded=compact_value(&aggregate);assert_eq!(expand_value(&encoded).unwrap(),aggregate);
            for end in 0..encoded.len(){assert!(expand_value(&encoded[..end]).is_err());}
            let mut trailing=encoded;trailing.push(0);assert!(expand_value(&trailing).is_err());
        }
        for bytes in [&[0x80,0][..],&[0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,2],&[0x80;10]] {assert!(compact_read(bytes,&mut 0).is_err());}
        let mut bad=payload(&Observation::default());bad[0]=3;assert!(compact_payload(&bad).is_err());
        let mut value=compact_value(&Value::default());value[6]=2;assert!(expand_value(&value).is_err());
    }
}
