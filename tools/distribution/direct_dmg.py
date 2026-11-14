#!/usr/bin/env python3
"""Owned drag-install disk image; no Finder automation or shared-device actions.

Use the repo-local packaging venv from dmg-requirements.txt. Each attachment is
bound to this case's exact image path and mountpoint before normal detachment.
Signing and Apple submission are explicit later actions, never retries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from distribution.traverse_packet import REPO, TOOLING, require_case, directory, put, audit
from distribution import preflight, release_candidate

def qualified_metadata(case,info):
    version,build=info['CFBundleShortVersionString'],str(info['CFBundleVersion'])
    if (version,build) in [('0.1.0','1'),('0.1.1','2'),('0.1.2','3')]:return version,build
    config=json.loads((case/'configuration.json').read_bytes())
    return release_candidate.shipping_metadata(config,info)

def run(case,args,label,timeout=120):
    try:result=subprocess.run(args,cwd=REPO,capture_output=True,timeout=timeout,check=False)
    except subprocess.TimeoutExpired as error:
        path=case/'evidence'/(label+'-timeout-'+str(time.time_ns())+'.log')
        with path.open('xb') as f:f.write((error.stdout or b'')[:1024*1024]);f.write((error.stderr or b'')[:1024*1024]);f.write(b'\nOwned command reached its deadline. Inspect attachment state before retry.\n')
        raise RuntimeError(label+' timed out; retained '+str(path.relative_to(REPO))) from error
    if len(result.stdout)+len(result.stderr)>2*1024*1024: raise RuntimeError('Output limit')
    path=case/'evidence'/(label+'-'+str(time.time_ns())+'.log')
    with path.open('xb') as f:f.write(result.stdout);f.write(result.stderr)
    if result.returncode:raise RuntimeError(label+' failed; retained '+str(path.relative_to(REPO)))
    audit()
    return result.stdout,result.stderr

def app_facts(case,app):
    run(case,['codesign','--verify','--deep','--strict',str(app)],'dmg-app-verify')
    run(case,['xcrun','stapler','validate',str(app)],'dmg-app-ticket')
    out,err=run(case,['codesign','-d','--verbose=4',str(app)],'dmg-app-signature')
    facts=dict(line.split('=',1) for line in (out+err).decode().splitlines() if '=' in line)
    if facts.get('Identifier')!='com.respawnstudios.traverse' or facts.get('TeamIdentifier')!='CDLNJRG82U' or 'Timestamp' not in facts:raise RuntimeError('Unexpected signed app')
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    qualified_metadata(case,info)
    if info['LSMinimumSystemVersion']!='15.0':raise RuntimeError('Unexpected release metadata')
    return facts['CDHash']

def release_metadata(case):
    info=plistlib.loads((case/'notarized/Traverse.app/Contents/Info.plist').read_bytes())
    return qualified_metadata(case,info)

def image_path(case):
    version,build=release_metadata(case)
    return case/'dmg'/f'Traverse-{version}-{build}-arm64.dmg'

def working_size_mib(payload_bytes):
    # APFS layout space is a packaging temporary, not the final download size.
    # Reserve64MiB beyond the bounded payload, rounded to32MiB, rather than
    # retaining192MiB for every small app. Refuse unexpected larger inputs.
    if type(payload_bytes)is not int or not 0 < payload_bytes <= 128 << 20:
        raise ValueError('Disk-image payload is outside its qualified bound')
    return max(96,((payload_bytes+(64<<20)+(32<<20)-1)//(32<<20))*32)

def detach_owned(case,image,mount,device):
    out,_=run(case,['hdiutil','info','-plist'],'dmg-attachment-check')
    images=plistlib.loads(out).get('images',[])
    matches=[i for i in images if Path(i.get('image-path','')).resolve()==image.resolve() and any(e.get('mount-point')==str(mount) and e.get('dev-entry')==device for e in i.get('system-entities',[]))]
    if len(matches)!=1:raise RuntimeError('Owned image identity uncertain; no detach attempted')
    run(case,['hdiutil','detach',device],'dmg-owned-detach')

def attached_owned(case,image):
    out,_=run(case,['hdiutil','info','-plist'],'dmg-mounted-image-identity')
    matches=[i for i in plistlib.loads(out).get('images',[]) if Path(i.get('image-path','')).resolve()==image.resolve() and i.get('owner-uid')==os.getuid()]
    if len(matches)!=1:raise RuntimeError('Expected one owned image attachment')
    mounted=[e for e in matches[0].get('system-entities',[]) if e.get('mount-point')]
    if len(mounted)!=1 or not mounted[0]['dev-entry'].startswith('/dev/disk'):raise RuntimeError('Unexpected image attachment')
    mount=Path(mounted[0]['mount-point'])
    if mount.parent!=Path('/Volumes') or mount.is_symlink():raise RuntimeError('Unexpected OS-managed image mountpoint')
    return mount,mounted[0]['dev-entry']

def mount_owned(case,image,readonly=False):
    # macOS 27 refuses nested mountpoints on this external development volume.
    # The OS chooses an unused /Volumes name; bind authority to the exact image,
    # returned mount and volume device, never to a guessed shared disk name.
    args=['hdiutil','attach','-nobrowse','-noautoopen','-plist']
    if readonly:args.append('-readonly')
    run(case,args+[str(image)],'dmg-owned-attach')
    return attached_owned(case,image)

def prepare(case):
    from ds_store import DSStore
    from mac_alias import Alias
    output=case/'dmg';output.mkdir(mode=0o700)
    source=output/'source';source.mkdir(mode=0o700)
    app=case/'notarized/Traverse.app'
    cdhash=app_facts(case,app)
    run(case,['ditto',str(app),str(source/'Traverse.app')],'dmg-copy-app')
    (source/'Applications').symlink_to('/Applications',target_is_directory=True)
    (source/'.background').mkdir(mode=0o755)
    run(case,['swift','-module-cache-path',str(directory(TOOLING/'dmg-swift')),str(REPO/'tools/distribution/DMGArtwork.swift'),str(source/'.background/background.png')],'dmg-artwork')
    writable=output/'layout-apfs.dmg'
    payload_bytes=sum(p.lstat().st_size for p in source.rglob('*') if p.is_file() and not p.is_symlink())
    size=working_size_mib(payload_bytes)
    put(output/'working-size.json',dict(payloadBytes=payload_bytes,workingMiB=size,extraReservedMiB=64))
    run(case,['hdiutil','create','-size',str(size)+'m','-srcfolder',str(source),'-volname','Traverse','-fs','APFS','-format','UDRW','-nospotlight',str(writable)],'dmg-create')
    complete_layout(case,writable,cdhash)

def complete_layout(case,writable,cdhash,already_mounted=False):
    from ds_store import DSStore
    from mac_alias import Alias
    output=case/'dmg'
    if (output/'prepared.json').exists() or image_path(case).exists():raise RuntimeError('Layout already completed')
    mount,device=attached_owned(case,writable) if already_mounted else mount_owned(case,writable)
    try:
        alias=Alias.for_file(str(mount/'.background/background.png'))
        # Keep only a portable volume hint, never the developer's mount/repo path.
        alias.volume.posix_path='/Volumes/Traverse'
        alias.target.posix_path='/.background/background.png'
        with DSStore.open(str(mount/'.DS_Store'),'w+') as ds:
            # WindowBounds includes title chrome; leave all 420 artwork points
            # visible instead of clipping the installation guidance at bottom.
            ds['.']['bwsp']={'ShowStatusBar':False,'ShowToolbar':False,'ShowTabView':False,'ShowPathbar':False,'ShowSidebar':False,'SidebarWidth':0,'WindowBounds':'{{200, 150}, {640, 452}}'}
            # Finder can reject the whole icon-view dictionary at 100. Keep
            # this value below that boundary, including with manual positions.
            # Finder rejects this dictionary when the fallback RGB fields are
            # absent, even with a picture background. A dark fallback also keeps
            # native icon labels readable over the violet artwork.
            ds['.']['icvp']={'viewOptionsVersion':1,'backgroundType':2,'backgroundImageAlias':alias.to_bytes(),'backgroundColorRed':0.055,'backgroundColorGreen':0.065,'backgroundColorBlue':0.12,'iconSize':96.0,'textSize':12.0,'gridOffsetX':0.0,'gridOffsetY':0.0,'gridSpacing':99.0,'arrangeBy':'none','labelOnBottom':True,'showItemInfo':False,'showIconPreview':True}
            ds['.']['vSrn']=('long',1)
            ds['.']['vstl']=('type',b'icnv')
            ds['.']['icvl']=('type',b'icnv')
            ds['Traverse.app']['Iloc']=(175,205)
            ds['Applications']['Iloc']=(465,205)
        data=(mount/'.DS_Store').read_bytes()
        if preflight.machine_path_in_metadata(data,allowed_volume_hint=b'/Volumes/Traverse'):
            raise RuntimeError('Developer path in presentation metadata')
        if os.readlink(mount/'Applications')!='/Applications' or app_facts(case,mount/'Traverse.app')!=cdhash:raise RuntimeError('Disk-image payload changed')
    finally:detach_owned(case,writable,mount,device)
    image=image_path(case)
    run(case,['hdiutil','convert',str(writable),'-format','UDZO','-imagekey','zlib-level=9','-o',str(image)],'dmg-compress')
    put(output/'prepared.json',{'image':str(image.relative_to(REPO)),'appCDHash':cdhash,'bytes':image.stat().st_size,'layout':'Drag Traverse onto Applications','mountedOnlyOwnedImage':True,'packageLibraries':{'ds-store':'1.3.1','mac-alias':'2.2.2'}})
    print('DMG prepared; signature and container notarization are separate gates.')

def sign(case,identity):
    output=case/'dmg';image=image_path(case)
    if (output/'signed.json').exists():raise RuntimeError('Already signed; do not repeat blindly')
    if not identity or len(identity)!=40 or any(c not in '0123456789ABCDEFabcdef' for c in identity):raise RuntimeError('Explicit signing identity required')
    run(case,['codesign','--sign',identity,'--timestamp','--identifier','com.respawnstudios.traverse.diskimage',str(image)],'dmg-sign',600)
    run(case,['codesign','--verify','--strict',str(image)],'dmg-container-verify')
    out,err=run(case,['codesign','-d','--verbose=4',str(image)],'dmg-container-signature')
    text=(out+err).decode()
    if 'TeamIdentifier=CDLNJRG82U' not in text or 'Authority=Developer ID Application:' not in text or 'Timestamp=' not in text:raise RuntimeError('Wrong container signature')
    put(output/'signed.json',{'passed':True,'team':'CDLNJRG82U','timestamped':True})
    print('DMG signed with Developer ID and secure timestamp.')

def submit(case):
    output=case/'dmg';image=image_path(case)
    if not (output/'signed.json').exists() or (output/'submission.json').exists():raise RuntimeError('Missing signing gate or submission already recorded')
    out,_=run(case,['xcrun','notarytool','submit',str(image),'--keychain-profile','Respawn-Traverse-Notary','--output-format','json','--no-wait'],'dmg-notary-submit',180)
    value=json.loads(out)
    if not value.get('id'):raise RuntimeError('Submission ID missing; retain outcome for explicit review')
    put(output/'submission.json',value)
    print('DMG submitted once; awaiting Apple result.')

def finish(case):
    from ds_store import DSStore
    output=case/'dmg';image=image_path(case)
    if (output/'manifest.json').exists():raise RuntimeError('Final receipt already exists')
    submission=json.loads((output/'submission.json').read_bytes())
    out,_=run(case,['xcrun','notarytool','info',submission['id'],'--keychain-profile','Respawn-Traverse-Notary','--output-format','json'],'dmg-notary-status')
    status=json.loads(out)
    if status.get('status')!='Accepted': print('Apple status: '+str(status.get('status')));return
    run(case,['xcrun','stapler','staple',str(image)],'dmg-staple')
    run(case,['xcrun','stapler','validate',str(image)],'dmg-ticket-verify')
    run(case,['codesign','--verify','--strict',str(image)],'dmg-final-signature')
    out,err=run(case,['spctl','--assess','--type','open','--context','context:primary-signature','--verbose=2',str(image)],'dmg-gatekeeper')
    if 'source=Notarized Developer ID' not in (out+err).decode():raise RuntimeError('Notarized container acceptance not established')
    mount,device=mount_owned(case,image,True)
    try:
        cdhash=app_facts(case,mount/'Traverse.app')
        with DSStore.open(str(mount/'.DS_Store'),'r') as ds:
            options=ds['.']['icvp']
            if (ds['Traverse.app']['Iloc']!=(175,205) or ds['Applications']['Iloc']!=(465,205)
                or options['backgroundType']!=2 or options['iconSize']!=96.0 or not 0<options['gridSpacing']<100
                or [options.get('backgroundColor'+c) for c in ('Red','Green','Blue')]!=[0.055,0.065,0.12]
                or ds['.']['icvl']!=(b'type',b'icnv') or ds['.']['bwsp']['WindowBounds']!='{{200, 150}, {640, 452}}'):
                raise RuntimeError('Layout readback failed')
        if os.readlink(mount/'Applications')!='/Applications':raise RuntimeError('Applications shortcut changed')
    finally:detach_owned(case,image,mount,device)
    digest=hashlib.sha256()
    with image.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):digest.update(block)
    version,build=release_metadata(case)
    manifest={'schema':1,'artifacts':[{'id':'traverse-'+version.replace('.','-')+'-'+build+'-arm64','filename':image.name,'bytes':image.stat().st_size,'sha256':digest.hexdigest(),'version':version,'build':build,'architecture':'arm64','minimumOS':'15.0','admission':{'schema':1,'team':'CDLNJRG82U','bundleID':'com.respawnstudios.traverse','version':version,'build':build,'channel':'Developer ID','gatekeeper':'accepted','stapled':True,'timestamped':True,'appCDHash':cdhash,'checkedAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'container':'dmg','containerGatekeeper':'accepted','containerStapled':True}}]}
    put(output/'manifest.json',manifest)
    print(json.dumps({'dmg':image.name,'bytes':image.stat().st_size,'sha256':digest.hexdigest(),'notarized':True,'mountedReadback':True}))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','resume-layout','sign','submit','finish']);parser.add_argument('--case',required=True);parser.add_argument('--identity');args=parser.parse_args();case=require_case(args.case)
    if args.action=='prepare':prepare(case)
    elif args.action=='resume-layout':complete_layout(case,case/'dmg/layout-apfs.dmg',app_facts(case,case/'notarized/Traverse.app'),True)
    elif args.action=='sign':sign(case,args.identity)
    elif args.action=='submit':submit(case)
    else:finish(case)
