#!/usr/bin/env python3
"""Exact upstream binary artifact, direct-only composition and nested signing.

The checksum is the tagged upstream SPM checksum. No download happens during a
build; prepared bytes and every unpacked member are rechecked before use.
"""
import argparse,base64,hashlib,json,os,plistlib,posixpath,shutil,stat,subprocess,sys,urllib.request,zipfile
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from distribution.traverse_packet import REPO,TOOLING,directory,audit
from distribution import release_candidate
from folder_services import descriptor as folder_service_descriptor

ROOT=TOOLING/'sparkle-2.10.0'
ARCHIVE=ROOT/'Sparkle-for-Swift-Package-Manager.zip'
UNPACKED=ROOT/'unpacked'
FRAMEWORK=UNPACKED/'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'

def inputs():
    value=json.loads((REPO/'Distribution/Sparkle.lock.json').read_bytes())
    if value.get('schema')!=1 or value.get('version')!='2.10.0' \
        or value.get('sha256')!='17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959':
        raise RuntimeError('Unreviewed updater dependency')
    return value

def verify():
    wanted=inputs()
    if ARCHIVE.resolve()!=ARCHIVE or ARCHIVE.stat().st_size>128<<20 \
        or hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()!=wanted['sha256']:
        raise RuntimeError('Updater dependency bytes do not match the reviewed pin')
    count=0;size=0
    with zipfile.ZipFile(ARCHIVE)as z:
        for member in z.infolist():
            count+=1;size+=member.file_size
            path=Path(member.filename)
            if count>512 or size>128<<20 or path.is_absolute() or '..'in path.parts:
                raise RuntimeError('Unsafe updater artifact member')
            target=UNPACKED/path
            mode=member.external_attr>>16
            if stat.S_ISLNK(mode):
                link=z.read(member).decode('utf-8')
                resolved=posixpath.normpath(posixpath.join(str(path.parent),link))
                if link.startswith('/') or resolved=='..' or resolved.startswith('../') \
                    or not target.is_symlink() or os.readlink(target)!=link:
                    raise RuntimeError('Updater artifact link mismatch')
            elif not member.is_dir():
                if target.is_symlink() or not target.is_file() or target.read_bytes()!=z.read(member):
                    raise RuntimeError('Updater artifact content mismatch')
    if hashlib.sha256((UNPACKED/'LICENSE').read_bytes()).hexdigest()!=wanted['licenseSHA256']:
        raise RuntimeError('Updater license mismatch')
    return wanted

def metadata(public=False, local_user=False, direct_shipping=False):
    """Build exact updater Info metadata without fetching or unpacking code."""
    if local_user and not public:
        raise RuntimeError('Local-user updates require the separate public composition')
    if direct_shipping and not (public and local_user):
        raise RuntimeError('Direct shipping requires its own public composition')
    wanted=inputs()
    if public:
        config=json.loads((REPO/('Distribution/DirectPublicUpdates.json' if local_user
            else 'Distribution/PublicUpdates.json')).read_bytes())
        if not isinstance(config,dict) \
            or set(config)!={'schema','origin','feedPath','publicEDKey','intervalSeconds'} \
            or type(config.get('schema')) is not int or config['schema']!=1 \
            or config.get('origin')!='https://respawn-studios.com' \
            or config.get('feedPath')!=('/products/traverse/direct-updates/appcast.xml' if local_user
                else '/products/traverse/public-updates/appcast.xml') \
            or len(base64.b64decode(config.get('publicEDKey',''),validate=True))!=32 \
            or type(config.get('intervalSeconds')) is not int or config['intervalSeconds']!=21600:
            raise RuntimeError('Invalid public update configuration')
    else:
        config=json.loads((REPO/'Distribution/PrivateUpdates.json').read_bytes())
        if config.get('schema')!=1 or config.get('origin')!='https://respawn-studios.com' \
            or config.get('feedPath')!='/products/traverse/updates/appcast.xml' \
            or len(base64.b64decode(config.get('publicEDKey',''),validate=True))!=32 \
            or config.get('intervalSeconds')!=21600:
            raise RuntimeError('Invalid private update configuration')
    info=plistlib.loads((REPO/'Distribution/TraverseInfo.plist').read_bytes())
    if release_candidate.RELEASE_PURPOSE_KEY in info:
        raise RuntimeError('Base Info template cannot assign a release purpose')
    if direct_shipping:
        info[release_candidate.RELEASE_PURPOSE_KEY]=release_candidate.DIRECT_SHIPPING_PURPOSE
    info.update(SUFeedURL=config['origin']+config['feedPath'],SUPublicEDKey=config['publicEDKey'],
        SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0,
        SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False,SUAllowsAutomaticUpdates=False,
        SUScheduledCheckInterval=21600,SUEnableSystemProfiling=False,SUEnableJavaScript=False)
    if not local_user:
        info.update(SUEnableInstallerLauncherService=True,SUEnableDownloaderService=False)
    if public:
        if any(key in info for key in ('NSServices','MacExplorerFolderServices','TraversePrivateUpdaterVersion',
                                      'TraversePublicUpdaterVersion','TraverseDirectPublicUpdaterVersion')):
            raise RuntimeError('Public update metadata inherited a private declaration')
        if local_user:
            info.update(TraverseDirectPublicUpdaterVersion=wanted['version'],
                TraverseDirectStorageNamespace='com.respawnstudios.traverse.direct')
        else:
            info.update(TraversePublicUpdaterVersion=wanted['version'])
        info.update(MacExplorerFolderServices='public-folders-service-v1',
                    NSServices=folder_service_descriptor('Traverse'))
    else:
        info.update(TraversePrivateUpdaterVersion=wanted['version'],
            MacExplorerFolderServices='public-folders-service-v1',
            NSServices=folder_service_descriptor('Traverse'))
    return info

def prepare(fetch=False, public=False, local_user=False, direct_shipping=False):
    if local_user and not public:
        raise RuntimeError('Local-user updates require the separate public composition')
    if direct_shipping and not (public and local_user):
        raise RuntimeError('Direct shipping requires its own public composition')
    wanted=inputs();directory(ROOT)
    if fetch and not ARCHIVE.exists():
        if wanted['url']!='https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip':
            raise RuntimeError('Unknown upstream artifact URL')
        with urllib.request.urlopen(wanted['url'],timeout=45)as response,ARCHIVE.open('xb')as output:
            size=0
            while chunk:=response.read(65536):
                size+=len(chunk)
                if size>128<<20:raise RuntimeError('Updater dependency download bound')
                output.write(chunk)
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()!=wanted['sha256']:raise RuntimeError('Updater artifact checksum mismatch')
    if not UNPACKED.exists():
        # Inspect archive paths/links before native extraction preserves them.
        with zipfile.ZipFile(ARCHIVE)as z:
            for i in z.infolist():
                p=Path(i.filename)
                if p.is_absolute()or'..'in p.parts:raise RuntimeError('Unsafe updater artifact path')
                if stat.S_ISLNK(i.external_attr>>16):
                    t=z.read(i).decode();r=posixpath.normpath(posixpath.join(str(p.parent),t))
                    if t.startswith('/')or r=='..'or r.startswith('../'):raise RuntimeError('Unsafe updater artifact link')
        directory(UNPACKED)
        subprocess.run(['/usr/bin/ditto','-x','-k',str(ARCHIVE),str(UNPACKED)],check=True,timeout=30)
    verify()
    info=metadata(public=public,local_user=local_user,direct_shipping=direct_shipping)
    generated=directory(TOOLING/('direct-public-shipping' if direct_shipping else
        'direct-public-updater' if local_user else
        'public-updater' if public else 'private-updater'))/'TraverseInfo.plist'
    generated.write_bytes(plistlib.dumps(info))
    audit();return generated

def embed():
    verify()
    from distribution import store_helpers
    tag=os.environ.get('MAC_EXPLORER_TRAVERSE_BUILD')
    policy=store_helpers.access_policy(os.environ)
    local_user=tag in ('developer-id-local-user-public-qualification-v1',
        'developer-id-local-user-public-shipping-v1')
    if policy==store_helpers.LOCAL and not local_user:
        raise RuntimeError('Unselected local-user updater composition')
    target=Path(os.environ['TARGET_BUILD_DIR'])/os.environ['CONTENTS_FOLDER_PATH']
    if target.resolve()!=target or not target.is_relative_to(REPO/'.build')or not target.is_dir():
        raise RuntimeError('Updater embedding requires the exact isolated build bundle')
    info=plistlib.loads((target/'Info.plist').read_bytes())
    if tag=='developer-id-local-user-public-shipping-v1':
        if info.get(release_candidate.RELEASE_PURPOSE_KEY)!=release_candidate.DIRECT_SHIPPING_PURPOSE:
            raise RuntimeError('Direct shipping updater requires signed-purpose metadata')
    elif release_candidate.RELEASE_PURPOSE_KEY in info:
        raise RuntimeError('Updater composition cannot borrow direct shipping purpose')
    identity=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity or identity=='-':raise RuntimeError('Updater nesting needs the selected real signing identity')
    frameworks=target/'Frameworks';frameworks.mkdir(exist_ok=True)
    if frameworks.is_symlink():raise RuntimeError('Redirected framework output')
    dest=frameworks/'Sparkle.framework'
    if dest.is_symlink():raise RuntimeError('Redirected updater output')
    if dest.exists():shutil.rmtree(dest)
    subprocess.run(['/usr/bin/ditto',str(FRAMEWORK),str(dest)],check=True,timeout=30)
    root=dest/'Versions/B'
    # The unsandboxed composition uses no sandbox XPC installer/downloader.
    shutil.rmtree(root/'XPCServices/Downloader.xpc')
    if local_user:shutil.rmtree(root/'XPCServices/Installer.xpc')
    roles=[root/'Autoupdate',root/'Updater.app']
    if not local_user:roles.append(root/'XPCServices/Installer.xpc')
    for path in [*roles,dest]:
        role=['--identifier','org.sparkle-project.Sparkle.Autoupdate']if path.name=='Autoupdate'else['--preserve-metadata=identifier']
        subprocess.run(['/usr/bin/codesign','--force','--sign',identity,'--options','runtime',
            *role,str(path)],check=True,timeout=45)
    resources=target/'Resources'
    notices=resources/'ThirdPartyNotices.txt';manifest=resources/'ThirdPartyManifest.json'
    text=notices.read_bytes()+b'\n\nSparkle 2.10.0 (direct updates only)\n'+(UNPACKED/'LICENSE').read_bytes()
    metadata=json.loads(manifest.read_bytes())
    metadata['components'].append(dict(name='Sparkle',version='2.10.0',declaredLicense='Upstream BSD/MIT notices',
        artifactSHA256=inputs()['sha256'],noticeSHA256=inputs()['licenseSHA256']))
    metadata['noticeSHA256']=hashlib.sha256(text).hexdigest()
    notices.write_bytes(text);manifest.write_text(json.dumps(metadata,indent=2,sort_keys=True)+'\n')
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(dest)],check=True,timeout=30)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','prepare-public','prepare-direct-public','fetch','verify','embed']);args=parser.parse_args()
    if args.action=='embed':embed()
    elif args.action=='verify':verify()
    else:prepare(fetch=args.action=='fetch',public=args.action in ('prepare-public','prepare-direct-public'),
        local_user=args.action=='prepare-direct-public')
    print(json.dumps(dict(passed=True,version='2.10.0',action=args.action)),flush=True)
