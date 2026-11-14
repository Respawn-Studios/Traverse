#!/usr/bin/env python3
"""Independent standard-library archive generation; no owner input paths."""
import hashlib,io,json,sys,tarfile
sys.dont_write_bytecode=True
from tar_packet import d,reserve,audit,directory

def archive(rows,format=tarfile.USTAR_FORMAT):
    buffer=io.BytesIO()
    with tarfile.open(fileobj=buffer,mode='w',format=format,encoding='utf-8')as writer:
        for name,body,kind in rows:
            info=tarfile.TarInfo(name);info.uid=info.gid=0;info.mtime=0
            info.mode=0o755 if kind=='folder'else 0o644
            if kind=='folder':info.type=tarfile.DIRTYPE
            elif kind=='link':info.type=tarfile.SYMTYPE;info.linkname='../never-follow'
            elif kind=='hardlink':info.type=tarfile.LNKTYPE;info.linkname='Member.txt'
            elif kind=='fifo':info.type=tarfile.FIFOTYPE
            else:info.size=len(body)
            writer.addfile(info,io.BytesIO(body)if kind=='file'else None)
    return buffer.getvalue()

def oracle(data):
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:',encoding='utf-8')as reader:
        rows=[];bodies=[]
        for entry in reader:
            kind='file'if entry.isfile()else'directory'if entry.isdir()else'symbolicLink'if entry.issym()else'hardLink'if entry.islnk()else'special'
            rows.append(dict(path=entry.name.removeprefix('./'),kind=kind,bytes=entry.size,dataOffset=entry.offset_data))
            if entry.isfile()and entry.size:bodies.append(dict(offset=entry.offset_data,bytes=entry.size))
    return dict(rows=rows,payloadRanges=bodies)

def change_header(data,mutate):
    value=bytearray(data);mutate(value);value[148:156]=b'        '
    checksum=sum(value[:512]);value[148:156]=f'{checksum:06o}\0 '.encode();return bytes(value)

def main():
    root=reserve('fixtures');folder=directory(root/'source/archives');rows={};ordinary=[('Folder',b'','folder'),('Folder/Empty',b'','folder'),
        ('Folder/.hidden',b'','file'),('Folder/Member.bin',bytes((i*31+7)%251 for i in range(65553)),'file'),
        ('Folder/._opaque',b'generated AppleDouble remains opaque','file'),('Note.txt',b'abc','file')]
    def save(name,data,expected='complete'):
        path=folder/(name+'.tar')
        with path.open('xb')as output:output.write(data)
        rows[name]=dict(sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),expected=expected)
        if expected=='complete':rows[name].update(oracle(data))
    base=archive(ordinary);save('ustar',base)
    save('pax',archive([('Résumé/'+'n'*120,b'abc','file')],tarfile.PAX_FORMAT))
    save('gnu',archive([('./'+'long-'*30,b'abc','file')],tarfile.GNU_FORMAT))
    save('root-and-links',archive([('./',b'','folder'),('./Member.txt',b'abc','file'),('./Link',b'','link'),('./Hard',b'','hardlink'),('./Pipe',b'','fifo')]))
    save('empty',archive([]))
    many=archive([(f'f{index:05}.txt',b'','file')for index in range(19999)])
    save('metadata-limit',many)
    save('checksum',bytes([base[0]^1])+base[1:],'malformed')
    save('truncated',base[:600],'malformed')
    first_end=next(index for index in range(0,len(base),512)if base[index:index+1024]==b'\0'*1024)
    # Derive the real terminator from the independent reader, rather than an
    # all-zero regular member body which may occur earlier.
    with tarfile.open(fileobj=io.BytesIO(base),mode='r:')as reader:
        members=reader.getmembers();last=members[-1];first_end=last.offset_data+((last.size+511)//512)*512
    save('one-zero',base[:first_end+512],'malformed');save('no-zero',base[:first_end],'malformed')
    save('nonzero-trailer',base[:first_end+1024]+b'x'+b'\0'*511,'malformed')
    save('unknown-type',change_header(base,lambda value:value.__setitem__(156,83)),'unsupported')
    save('bad-magic',change_header(base,lambda value:value.__setitem__(slice(257,263),b'other\0')),'unsupported')
    save('base256-size',change_header(base,lambda value:value.__setitem__(124,128)),'unsupported')
    for name in ['../Escape','/Absolute','A/../Escape','A//Member','C:Drive','Back\\slash','Control\x01','Bidi\u202e']:
        save('unsafe-'+str(len(rows)),archive([(name,b'abc','file')]),'unsafeName')
    save('global-pax',change_header(archive([('n'*120,b'abc','file')],tarfile.PAX_FORMAT),lambda value:value.__setitem__(156,103)),'unsupported')
    save('duplicate',archive([('Same',b'a','file'),('Same',b'b','file')]),'ambiguousNames')
    save('case-collision',archive([('Name',b'a','file'),('name',b'b','file')]),'ambiguousNames')
    save('unicode-collision',archive([('café',b'a','file'),('cafe\u0301',b'b','file')],tarfile.PAX_FORMAT),'ambiguousNames')
    d.put(root/'inputs.json',dict(generatedOnly=True,archives=rows,generatedInputBytes=sum(value['bytes']for value in rows.values()),
        expectedReaderBodyReads=0,networkRequests=0,keychainCalls=0,sourceSHA256=d.digest(__import__('pathlib').Path(__file__))))
    usage=audit();d.put(root/'evidence/result.json',dict(passed=True,archives=len(rows),inputBytes=usage['tarInputBytes'],networkRequests=0,usage=usage))
    print(json.dumps(dict(case=root.name,passed=True,archives=len(rows),inputBytes=usage['tarInputBytes'])),flush=True)
if __name__=='__main__':main()
