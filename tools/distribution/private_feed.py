#!/usr/bin/env python3
"""Prepare a private signed feed from one admitted final DMG; never publishes.

The invitation password is not an input. Only the exact app-owned signing-key
account is read by the pinned upstream signer. A deployment is a separate action.
"""
import argparse,base64,datetime,hashlib,html,io,json,plistlib,re,subprocess,sys,tarfile
from email.utils import format_datetime
from pathlib import Path
from xml.sax.saxutils import escape
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from distribution import release_candidate,release_notes,source_capsule,sparkle,preflight
from distribution.traverse_packet import REPO,require_case,directory,put,audit

PUBLIC_KEY='MG4sBFr76ad6D4nGo+i2VuZ4hxVMEQZToBUjYyui3IA='
ORIGIN='https://respawn-studios.com'
BASE=ORIGIN+'/products/traverse/updates'

def admit(config,item,entry):
    checked=release_candidate.configuration(config)
    if checked.get('shippingCandidate')is not True or checked.get('privateUpdater')is not True \
        or checked['channel']!='developer-id' or checked['accessPolicy']!='sandbox-selected-v1':
        raise ValueError('Only a new updater-enabled shipping case can supply a feed')
    requested=checked['versionOverride'];receipt=item.get('admission',{})
    if item.get('version')!=requested['version']or item.get('build')!=requested['build'] \
        or entry['version']!=item['version']or str(entry['build'])!=item['build']or entry['state']=='unreleased':
        raise ValueError('Frozen release notes, case and artifact must agree')
    if item.get('filename')!='Traverse-'+item['version']+'-'+item['build']+'-arm64.dmg' \
        or item.get('architecture')!='arm64'or item.get('minimumOS')!='15.0' \
        or not re.fullmatch('[a-f0-9]{64}',item.get('sha256',''))or type(item.get('bytes'))is not int \
        or not 0<item['bytes']<=128<<20:
        raise ValueError('Only the bounded current arm64 DMG contract is admitted')
    exact=dict(schema=1,bundleID='com.respawnstudios.traverse',version=item['version'],build=item['build'],
        channel='Developer ID',team='CDLNJRG82U',timestamped=True,stapled=True,gatekeeper='accepted',
        container='dmg',containerStapled=True,containerGatekeeper='accepted')
    if not all(type(receipt.get(k))is type(v)and receipt[k]==v for k,v in exact.items()):
        raise ValueError('App and container signing/notarization admission are required')
    return checked

def notes(entry):
    return ('<!doctype html><html lang="en"><meta charset="utf-8"><title>Traverse '+html.escape(entry['version'])+'</title>'
        '<body><h1>'+html.escape(entry['title'])+'</h1><p>Traverse '+html.escape(entry['version'])+' · '
        +html.escape(entry['date'])+'</p><p>'+html.escape(entry['summary'])+'</p><ul>'
        +''.join('<li>'+html.escape(change)+'</li>'for change in entry['changes'])+'</ul></body></html>').encode()

def appcast(item,entry,archive_signature,note_signature,note_bytes):
    for sig in [archive_signature,note_signature]:
        if not re.fullmatch('[A-Za-z0-9+/]{86}==',sig):raise ValueError('Exact Ed25519 signature required')
    date=datetime.datetime.combine(datetime.date.fromisoformat(entry['date']),datetime.time(12),datetime.timezone.utc)
    return (f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Traverse private beta</title><link>{ORIGIN}/products/traverse/</link><description>Private beta updates</description>
<item><title>Traverse {escape(item['version'])}</title><link>{ORIGIN}/products/traverse/</link>
<sparkle:version>{item['build']}</sparkle:version><sparkle:shortVersionString>{escape(item['version'])}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<pubDate>{format_datetime(date)}</pubDate>
<sparkle:releaseNotesLink sparkle:edSignature="{note_signature}" sparkle:length="{note_bytes}">{BASE}/notes/{item['build']}.html</sparkle:releaseNotesLink>
<enclosure url="{BASE}/archives/{item['sha256']}.dmg" length="{item['bytes']}" type="application/octet-stream" sparkle:edSignature="{archive_signature}"/>
</item></channel></rss>
''').encode()

def frozen_history(case,item):
    manifest=json.loads(source_capsule.read_at(case,'archive-inputs.json',1<<20))['sourceSHA256']
    proof=json.loads(source_capsule.read_at(case,'source/frozen-source.json',1<<20))
    capsule=case/'source'/('Frozen-'+item['version']+'-'+item['build']+'-sources.tar.gz')
    payload=source_capsule.read_at(capsule.parent,capsule.name,source_capsule.MAX_ARCHIVE_BYTES)
    creation=proof['creation']
    checked=source_capsule.inspect_payload(payload,manifest,creation['sha256'])
    if any(checked[key]!=creation[key] for key in ('files','sourceBytes','archiveBytes','sha256')):
        raise ValueError('Frozen source receipt differs from verified capsule')
    with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz')as archive:
        member=archive.getmember('Distribution/ReleaseHistory.json')
        if member.size>256<<10:raise ValueError('Frozen release history bound reached')
        data=archive.extractfile(member).read(member.size)
    return release_notes.decode(data)

def verify_signature(path,signature):
    # Independent verification against the shipped public key, not merely the
    # private account selected by the signer. Node is existing release tooling.
    script="""const fs=require('node:fs'),c=require('node:crypto');const p=JSON.parse(fs.readFileSync(0,'utf8'));
const key=c.createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(p.public,'base64')]),format:'der',type:'spki'});
process.exit(c.verify(null,fs.readFileSync(p.path),key,Buffer.from(p.signature,'base64'))?0:1);"""
    value=dict(path=str(path),public=PUBLIC_KEY,signature=signature)
    result=subprocess.run(['node','-e',script],input=json.dumps(value).encode(),capture_output=True,timeout=15)
    if result.returncode:raise RuntimeError('Signature does not match the shipped public key')

def prepare(case):
    config=json.loads(source_capsule.read_at(case,'configuration.json',8192))
    # Refuse retained non-updater and local-review cases before opening Keychain.
    if config.get('privateUpdater')is not True or config.get('shippingCandidate')is not True:
        raise ValueError('A fresh updater-enabled shipping case is required')
    manifest=json.loads(source_capsule.read_at(case,'dmg/manifest.json',65536))
    if manifest.get('schema')!=1 or len(manifest.get('artifacts',[]))!=1:raise ValueError('Exact final artifact required')
    item=manifest['artifacts'][0]
    history=frozen_history(case,item)
    entry=release_notes.release_for_build(history,item['version'],item['build'])
    if entry is None:raise ValueError('Frozen release notes are missing')
    admit(config,item,entry)
    output=case/'private-updates'
    if output.exists()or output.is_symlink():raise ValueError('Preserve the existing signed feed')
    app=case/'notarized/Traverse.app'
    report=preflight.inspect(app,'com.respawnstudios.traverse','CDLNJRG82U','developer-id')
    if any(not row['passed']for row in report['checks']):
        raise ValueError('Distribution preflight did not pass')
    info=plistlib.loads(source_capsule.read_at(app,'Contents/Info.plist',1<<20))
    if info.get('SUPublicEDKey')!=PUBLIC_KEY:raise ValueError('App public key differs')
    image=case/'dmg'/item['filename'];before=source_capsule.read_at(image.parent,image.name,128<<20)
    if len(before)!=item['bytes']or hashlib.sha256(before).hexdigest()!=item['sha256']:raise ValueError('DMG differs from admission')
    sparkle.verify();directory(output)
    signer=sparkle.UNPACKED/'bin/sign_update'
    def sign(path):
        return subprocess.check_output([str(signer),'--account','Respawn-Traverse-Update-Signing-v1',
            '--disable-signing-warning','-p',str(path)],timeout=45).decode().strip()
    archive_signature=sign(image);verify_signature(image,archive_signature)
    note=output/(item['build']+'.html');note.write_bytes(notes(entry))
    note_signature=sign(note);verify_signature(note,note_signature)
    feed=output/'appcast.xml';feed.write_bytes(appcast(item,entry,archive_signature,note_signature,note.stat().st_size))
    sign(feed)
    # Independent footer/public-key verification is also exercised by the
    # website's actual upstream-signature interoperability test.
    feed_bytes=feed.read_bytes();tag=b'<!-- sparkle-signatures:\n';index=feed_bytes.rfind(tag)
    match=re.fullmatch(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n',feed_bytes[index:])
    if index<0 or match is None or int(match[2])!=index:raise RuntimeError('Invalid signed feed footer')
    unsigned=output/'feed-signature-input.bin';unsigned.write_bytes(feed_bytes[:index])
    verify_signature(unsigned,match[1].decode())
    if source_capsule.read_at(image.parent,image.name,128<<20)!=before:raise RuntimeError('DMG changed while signing')
    def record(path):return dict(filename=path.name,bytes=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    catalog=dict(schema=1,publicKey=PUBLIC_KEY,feed=record(feed),
        notes=[dict(**record(note),route=note.name,edSignature=note_signature)],artifactIDs=[item['id']])
    put(output/'updates.json',catalog)
    put(output/'prepared.json',dict(passed=True,published=False,artifactSHA256=item['sha256'],version=item['version'],build=item['build'],
        invitationRead=False,privateKeyExported=False,packet=audit()))
    print(json.dumps(dict(case=case.name,prepared=True,published=False,build=item['build'])),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--case',required=True);args=parser.parse_args();prepare(require_case(args.case))
