#!/usr/bin/env python3
"""Package an explicitly separate local review app; never publish or migrate."""
from __future__ import annotations
import argparse,hashlib,json,os,plistlib,re,shutil,stat,subprocess,sys,uuid
import pwd
import tarfile
from pathlib import Path
sys.dont_write_bytecode=True
import development as d
import build_storage_worker as scanner
from folder_services import descriptor as folder_service_descriptor, valid as folder_services_valid

IDENTIFIER='local.macexplorer.preview'
CHANNEL='development-preview'
FOLDER_DOCUMENT_TYPES=[dict(CFBundleTypeName='Folder',CFBundleTypeRole='Viewer',
 LSHandlerRank='Alternate',LSItemContentTypes=['public.folder'])]
FOLDER_SERVICES=folder_service_descriptor('Traverse Preview')

def preview_folder_services_valid(fields):
 """Older packages may omit the service; a present service is exactly folder-only."""
 return folder_services_valid(fields,preview=True)

def preview_associations_valid(fields,*,folder_opening=False):
 """One explicit folder Viewer capability; no URL scheme or generic types."""
 if 'CFBundleURLTypes'in fields or not preview_folder_services_valid(fields):return False
 if not folder_opening:
  return 'CFBundleDocumentTypes'not in fields and 'MacExplorerPreviewFolderOpening'not in fields \
   and 'MacExplorerPreviewFolderServices'not in fields and 'NSServices'not in fields
 return fields.get('MacExplorerPreviewFolderOpening')=='public-folder-v1' \
  and fields.get('CFBundleDocumentTypes')==FOLDER_DOCUMENT_TYPES

VERSION='0.1.4'
# Local editor and connection review; separate from the public beta.
BUILD='27'
REVIEW_RUN='580E1F8D-6805-40B1-8173-8F8D7A4EA80F'
ROLE_IDS={'smb-browser-worker':'local.macexplorer.smb.browser',
 'smb-resolver-worker':'local.macexplorer.smb.resolver','sftp-metadata-worker':'local.macexplorer.sftp.metadata',
 'storage-scanner-worker':'local.macexplorer.storage.scanner'}
SCANNER_PROVENANCE='StorageScannerProvenance.json'
SCANNER_INFO_KEY='MacExplorerScannerProvenance'
SCANNER_FORMAT='preview-scanner-v1'

def scanner_input_digest(proof):
 return hashlib.sha256(json.dumps(proof['input'],sort_keys=True,separators=(',',':')).encode()).hexdigest()

def scanner_signing_input(signer,team):
 if not re.fullmatch(r'[0-9a-fA-F]{40}',signer)or team!='CDLNJRG82U':
  raise RuntimeError('Exact Preview scanner signer required')
 return dict(identity=signer.upper(),team=team,identifier=ROLE_IDS['storage-scanner-worker'],
  timestamp='none',runtime=False,entitlements=None,codesignSHA256=d.digest(Path('/usr/bin/codesign')))

def scanner_donor(installed,proof,profile_case,signing):
 """Only a parent-sealed previous Preview can donate exact signed scanner bytes."""
 for parent in [installed,installed/'Contents',installed/'Contents/Helpers',installed/'Contents/Resources']:
  if parent.is_symlink()or parent.resolve()!=parent or not parent.is_dir():
   raise RuntimeError('Redirected installed scanner container')
 command(['/usr/bin/codesign','--verify','--strict','--deep',str(installed)])
 status=command(['/usr/bin/codesign','-d','--verbose=4',str(installed)]).stderr.decode('utf-8','replace').splitlines()
 fields=dict(line.split('=',1)for line in status if'='in line)
 if fields.get('Identifier')!=IDENTIFIER or fields.get('TeamIdentifier')!=signing['team'] \
   or fields.get('Signature')=='adhoc' or not any(line.startswith('Authority=Apple Development: ')for line in status):
  raise RuntimeError('Installed scanner parent signing identity changed')
 info=plistlib.loads((installed/'Contents/Info.plist').read_bytes())
 if info.get('CFBundleIdentifier')!=IDENTIFIER or info.get('MacExplorerDistributionChannel')!=CHANNEL \
   or info.get('MacExplorerReviewCase')!=profile_case:
  raise RuntimeError('Installed scanner donor is not the exact Preview profile')
 manifest=installed/'Contents/Resources'/SCANNER_PROVENANCE
 if not manifest.exists()and not manifest.is_symlink():
  if SCANNER_INFO_KEY in info:raise RuntimeError('Installed scanner marker has no provenance')
  return None
 if info.get(SCANNER_INFO_KEY)!=SCANNER_FORMAT:
  raise RuntimeError('Installed scanner provenance marker changed')
 facts=manifest.lstat()
 if not stat.S_ISREG(facts.st_mode)or facts.st_uid!=os.getuid()or facts.st_nlink!=1 or facts.st_size>32768:
  raise RuntimeError('Unsafe installed scanner provenance')
 value=json.loads(manifest.read_bytes())
 if value.get('format')!=SCANNER_FORMAT or value.get('profileCase')!=profile_case \
   or value.get('version')!=info.get('CFBundleShortVersionString') or value.get('build')!=info.get('CFBundleVersion'):
  raise RuntimeError('Installed scanner provenance does not match its sealed app')
 helper=installed/'Contents/Helpers/storage-scanner-worker'
 scanner.regular(helper)
 if value.get('helperSHA256')!=d.digest(helper):
  raise RuntimeError('Installed scanner helper changed after provenance sealing')
 scanner.signed_facts(helper,identifier=signing['identifier'],team=signing['team'],adhoc=False,runtime=False)
 if value.get('inputSHA256')!=scanner_input_digest(proof)or value.get('binarySHA256')!=proof['binary_sha256'] \
   or value.get('signing')!=signing:
  return None
 return helper,value['helperSHA256']

def copy_scanner_donor(donor,target,expected_sha):
 """Copy only the pinned regular donor into this new package, with no path-following read."""
 before=scanner.regular(donor);destination=scanner.regular(target)
 source_fd=os.open(donor,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:
  opened=os.fstat(source_fd)
  if (opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns,opened.st_ctime_ns)!=(before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns):
   raise RuntimeError('Scanner donor changed before copy')
  target_fd=os.open(target,os.O_WRONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
  try:
   current=os.fstat(target_fd)
   if (current.st_dev,current.st_ino)!=(destination.st_dev,destination.st_ino):
    raise RuntimeError('Scanner package target changed before copy')
   os.ftruncate(target_fd,0);digest=hashlib.sha256();remaining=before.st_size
   while remaining:
    block=os.read(source_fd,min(65536,remaining))
    if not block:raise RuntimeError('Scanner donor ended during copy')
    digest.update(block);remaining-=len(block)
    view=memoryview(block)
    while view:
     written=os.write(target_fd,view)
     if written<=0:raise RuntimeError('Scanner package write stopped')
     view=view[written:]
   if os.read(source_fd,1)or digest.hexdigest()!=expected_sha:
    raise RuntimeError('Scanner donor content changed during copy')
   os.fsync(target_fd)
  finally:os.close(target_fd)
  after=os.fstat(source_fd);named=scanner.regular(donor)
  if (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)!=(before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) \
    or (named.st_dev,named.st_ino)!=(before.st_dev,before.st_ino)or d.digest(target)!=expected_sha:
   raise RuntimeError('Scanner donor/package changed during copy')
 finally:os.close(source_fd)

def seal_scanner(app,signer,team,proof,donor,profile_case,version,build):
 for parent in [app,app/'Contents',app/'Contents/Helpers',app/'Contents/Resources']:
  if parent.is_symlink()or parent.resolve()!=parent or not parent.is_dir():
   raise RuntimeError('Redirected scanner package container')
 helper=app/'Contents/Helpers/storage-scanner-worker'
 if not helper.is_file()or helper.is_symlink()or helper.stat().st_nlink!=1:
  raise RuntimeError('Review scanner helper missing or shared')
 signing=scanner_signing_input(signer,team)
 if donor is None:
  command(['/usr/bin/codesign','--force','--sign',signer,'--timestamp=none','--identifier',signing['identifier'],str(helper)])
 else:
  copy_scanner_donor(donor[0],helper,donor[1])
 scanner.signed_facts(helper,identifier=signing['identifier'],team=team,adhoc=False,runtime=False)
 manifest=app/'Contents/Resources'/SCANNER_PROVENANCE
 if manifest.exists()or manifest.is_symlink():raise RuntimeError('Scanner provenance already occupies new package')
 manifest.write_text(json.dumps(dict(format=SCANNER_FORMAT,profileCase=profile_case,
  version=version,build=build,inputSHA256=scanner_input_digest(proof),binarySHA256=proof['binary_sha256'],
  signing=signing,helperSHA256=d.digest(helper)),sort_keys=True,indent=2)+'\n')
 return donor is not None

def checked_case(tag,action=None):
 if str(uuid.UUID(tag)).upper()!=tag:raise RuntimeError('Canonical review case required')
 root=d.ROOT/tag
 if root.resolve()!=root or root.is_symlink():raise RuntimeError('Redirected review case')
 marker=root/'reservation.json'
 if marker.is_symlink()or not marker.is_file()or marker.stat().st_size>4096:raise RuntimeError('Missing review reservation')
 value=json.loads(marker.read_bytes())
 if value.get('packet')!='traverse-development-v1'or action and value.get('action')!=action:raise RuntimeError('Wrong review reservation')
 return root

def inventory(root):
 if root.resolve()!=root or root.is_symlink():raise RuntimeError('Redirected review app')
 result={}
 for parent,children,files in os.walk(root,followlinks=False):
  for name in children+files:
   p=Path(parent)/name;v=p.lstat();relative=str(p.relative_to(root))
   if v.st_uid!=os.getuid():raise RuntimeError('Unowned review artifact')
   if stat.S_ISLNK(v.st_mode):
    if not p.resolve().is_relative_to(root):raise RuntimeError('Review link escapes its bundle')
    result[relative]=dict(link=os.readlink(p))
   elif stat.S_ISREG(v.st_mode):
    if v.st_nlink!=1:raise RuntimeError('Shared review executable or resource')
    if v.st_mode&0o6000:raise RuntimeError('Privileged review executable/resource refused')
    result[relative]=dict(bytes=v.st_size,sha256=d.digest(p),mode=stat.S_IMODE(v.st_mode))
   elif stat.S_ISDIR(v.st_mode):result[relative]=dict(directory=True,mode=stat.S_IMODE(v.st_mode))
   else:raise RuntimeError('Unsupported review artifact type')
 if sum(v.get('bytes',0)for v in result.values())>192<<20 or len(result)>1024:raise RuntimeError('Local review artifact bound')
 return result

def command(args):
 return subprocess.run(args,check=True,capture_output=True,timeout=30)

def retain_native_symbols(source,app,root,configuration):
 """Keep the exact main-app dSYM compressed beside an ordinary Preview."""
 from distribution import helper_symbols
 bundle=source.with_name(source.name+'.dSYM')
 if not bundle.exists():
  if configuration=='Release':raise RuntimeError('Release Preview requires its matching main-app symbols')
  return dict(retained=False,scope='main executable only',reason='debug build did not produce a dSYM')
 binary=source/'Contents/MacOS/Mac Explorer'
 proof=helper_symbols.validate(binary,bundle)
 if helper_symbols.uuids(app/'Contents/MacOS/Mac Explorer')!=proof['UUIDs']:
  raise RuntimeError('Packaged Preview and main-app symbols differ')
 before=inventory(bundle);archive=root/'main-app-symbols.tar.gz'
 if archive.exists()or archive.is_symlink():raise RuntimeError('Preserve existing Preview symbols')
 with archive.open('xb')as stream:
  os.chmod(archive,0o600)
  with tarfile.open(fileobj=stream,mode='w:gz',compresslevel=6)as output:
   output.add(bundle,arcname=bundle.name,recursive=True)
 # Verify the compressed member bodies without another loose extraction.
 expected={bundle.name+'/'+name:item for name,item in before.items()}
 with tarfile.open(archive,'r:gz')as saved:
  members=saved.getmembers()
  if len({m.name for m in members})!=len(members)or set(m.name for m in members)!={bundle.name,*expected}:
   raise RuntimeError('Preview symbols archive names differ')
  for member in members:
   if member.name==bundle.name:
    if not member.isdir():raise RuntimeError('Preview symbols root differs')
    continue
   item=expected[member.name]
   if item.get('directory'):
    if not member.isdir():raise RuntimeError('Preview symbols directory differs')
   else:
    if not member.isfile()or member.size!=item['bytes']:raise RuntimeError('Preview symbols member differs')
    digest=hashlib.sha256()
    with saved.extractfile(member)as body:
     while chunk:=body.read(1<<20):digest.update(chunk)
    if digest.hexdigest()!=item['sha256']:raise RuntimeError('Preview symbols body differs')
 if before!=inventory(bundle)or helper_symbols.uuids(binary)!=proof['UUIDs']:
  raise RuntimeError('Preview symbol source changed')
 result=dict(retained=True,scope='main executable only',UUIDs=proof['UUIDs'],archive=archive.name,
  archiveSHA256=d.digest(archive),compressedBytes=archive.stat().st_size,files=before,hasCompileUnits=True)
 (root/'main-app-symbols.json').write_text(json.dumps(result,indent=2)+'\n')
 return {key:value for key,value in result.items()if key!='files'}

def private_paths(tag):
 home=Path(pwd.getpwuid(os.getuid()).pw_dir)
 namespace=IDENTIFIER+'.'+tag.lower()
 return [home/'Library/Application Support'/namespace,home/'Library/Caches'/namespace]

def admit_private_profile(profile):
 admission=d.ROOT/REVIEW_RUN/'evidence/private-preview-storage-admission.json'
 if admission.exists():
  if admission.is_symlink()or json.loads(admission.read_bytes()).get('profileCase')!=profile.name:
   raise RuntimeError('The single approved private Preview profile is already reserved')
  return
 if any(p.exists()or p.is_symlink()for p in private_paths(profile.name)):
  raise RuntimeError('New private Preview namespace already exists; preserve it')
 d.put(admission,dict(profileCase=profile.name,approval='owner explicitly approved isolated Preview storage comparison on25October2026',
  maximumCombinedBytes=64<<20,maximumEntries=2048,maximumQualificationLaunches=3,
  migration=False,personalCatalog=False,credentialReads=False,osContainer=False))
 for p in [admission,admission.parent]:
  fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
  try:os.fsync(fd)
  finally:os.close(fd)

def audit_private_profile(tag):
 profile=checked_case(tag,'local-review-profile')
 admission=d.ROOT/REVIEW_RUN/'evidence/private-preview-storage-admission.json'
 if json.loads(admission.read_bytes()).get('profileCase')!=tag:raise RuntimeError('Private profile is not the approved namespace')
 total=dict(bytes=0,entries=0,allocatedBytes=0)
 for p in private_paths(tag):
  if not p.exists():continue
  if p.resolve()!=p or p.is_symlink()or p.stat().st_uid!=os.getuid():raise RuntimeError('Private profile path changed')
  measured=d.measure(p)
  for key in total:total[key]+=measured[key]
 if total['bytes']>64<<20 or total['entries']>2048:raise RuntimeError('Approved private Preview storage bound exceeded')
 return total

def admit_launch(artifact_case,install_case=None):
 root=checked_case(artifact_case,'local-review-artifact');proof=json.loads((root/'evidence/result.json').read_bytes())
 profile=checked_case(proof['profileCase'],'local-review-profile')
 if proof.get('storage')!='private-user':raise RuntimeError('This counter covers only the approved private profile')
 installed=None
 if install_case:
  from install_preview import launch_binding
  bound,path=launch_binding(install_case)
  if bound!=artifact_case:raise RuntimeError('Installed app belongs to another artifact')
  installed=path
 for index in range(1,4):
  target=profile/'evidence'/('qualification-launch-'+str(index)+'.json')
  if target.exists():continue
  d.put(target,dict(artifactCase=artifact_case,launch=index,profileUsage=audit_private_profile(profile.name),installedCase=install_case,installedApp=installed,
   noPersonalGrant=True,noCredentials=True,normalLaunchServices=True))
  fd=os.open(target,os.O_RDONLY|os.O_NOFOLLOW)
  try:os.fsync(fd)
  finally:os.close(fd)
  print(json.dumps(dict(profileCase=profile.name,launch=index,admitted=True)),flush=True);return
 raise RuntimeError('Three private qualification launches already admitted; do not reset the counter')

def admit_cold_launch(artifact_case,install_case,acceptance_case):
 if not install_case or not acceptance_case:raise RuntimeError('Exact installed and ordinary acceptance cases are required')
 artifact=checked_case(artifact_case,'local-review-artifact');proof=json.loads((artifact/'evidence/result.json').read_bytes())
 acceptance=checked_case(acceptance_case,'installed-preview-ordinary-acceptance')
 ordinary=json.loads((acceptance/'evidence/result.json').read_bytes());inputs=json.loads((acceptance/'inputs.json').read_bytes())
 if not proof['passed']or proof['storage']!='private-user'or not ordinary['passed']or inputs['installedCase']!=install_case or inputs['artifactCase']!=artifact_case:
  raise RuntimeError('Passed exact ordinary Preview acceptance is required')
 from install_preview import launch_binding
 bound,path=launch_binding(install_case)
 if bound!=artifact_case:raise RuntimeError('Cold-launch installed artifact changed')
 profile=checked_case(proof['profileCase'],'local-review-profile')
 if profile.name!='1C04223A-4025-4F1C-ABFE-001CBA2928BA':raise RuntimeError('Only the approved isolated profile may cold launch')
 for index in [1,2,3]:
  old=json.loads((profile/'evidence'/('qualification-launch-'+str(index)+'.json')).read_bytes())
  if old['launch']!=index:raise RuntimeError('Legacy qualification admission changed')
 command=subprocess.run(['/bin/ps','-axo','command='],check=True,capture_output=True,text=True,timeout=10)
 if any(line.strip()==path+'/Contents/MacOS/Mac Explorer'for line in command.stdout.splitlines()):raise RuntimeError('Quit the existing Preview before its one cold launch')
 target=profile/'evidence/cold-start-launch-1.json'
 if target.exists():raise RuntimeError('The additional cold-start launch is already admitted')
 d.put(target,dict(format='preview-cold-start-admission-v1',artifactCase=artifact_case,installedCase=install_case,
  ordinaryAcceptanceCase=acceptance_case,launch=1,maximumAdditionalLaunches=1,legacyAdmissionsUnchanged=True,
  authority='separate engineering checkpoint under owner extended12-hour implementation authorization',
  maximumCombinedBytes=64<<20,maximumEntries=2048,profileUsage=audit_private_profile(profile.name),
  sameInstalledInventory=True,newPersonalGrant=False,newCredentials=False,migration=False,normalLaunchServices=True))
 for item in [target,target.parent]:
  fd=os.open(item,os.O_RDONLY|os.O_NOFOLLOW)
  try:os.fsync(fd)
  finally:os.close(fd)
 print(json.dumps(dict(profileCase=profile.name,coldStartLaunch=1,admitted=True,legacyAdmissionsUnchanged=True)),flush=True)

def seal_bundle(app,profile_case,build_reference,version,build,signer,team,storage,*,folder_opening=False,
                scanner_proof=None,scanner_previous=None):
 # Older ordinary projects may still copy a newly added directory guide.
 # Match the shipping generator's exclusions without changing the source app.
 from generate_project import source_membership_exceptions
 resources=app/'Contents/Resources'
 for name in sorted({Path(value).name for value in source_membership_exceptions()if value.endswith('.md')}):
  guide=resources/name
  if not guide.exists()and not guide.is_symlink():continue
  value=guide.lstat()
  if guide.resolve()!=guide or not stat.S_ISREG(value.st_mode)or value.st_uid!=os.getuid()or value.st_nlink!=1:
   raise RuntimeError('Redirected or shared engineering guide in staged Preview')
  guide.unlink()
 info_path=app/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes())
 info.update(CFBundleIdentifier=IDENTIFIER,CFBundleName='Traverse Preview',CFBundleDisplayName='Traverse Preview',
  CFBundleShortVersionString=version,CFBundleVersion=build,MacExplorerDistributionChannel=CHANNEL,MacExplorerReviewCase=profile_case,MacExplorerReviewBuildCase=build_reference,
  MacExplorerReviewStorage='private-user-v1'if storage=='private-user'else'repository-v1')
 for key in list(info):
  if key in ['CFBundleDocumentTypes','CFBundleURLTypes','NSServices','MacExplorerPreviewFolderServices','MacExplorerPreviewFolderOpening','MacExplorerDevelopmentStateRoot','MacExplorerDevelopmentCacheRoot','MacExplorerStorageMode',SCANNER_INFO_KEY]or key.startswith('MacExplorerCopyPreview'):
   del info[key]
 if folder_opening:
  info['CFBundleDocumentTypes']=FOLDER_DOCUMENT_TYPES
  info['MacExplorerPreviewFolderOpening']='public-folder-v1'
  info['NSServices']=FOLDER_SERVICES
  info['MacExplorerPreviewFolderServices']='public-folders-service-v1'
 if scanner_proof is not None:info[SCANNER_INFO_KEY]=SCANNER_FORMAT
 info_path.write_bytes(plistlib.dumps(info,sort_keys=False))
 # Reuse the already selected development signer for normal local reviews.
 # Ad-hoc remains an explicit comparison, never an authentication fallback.
 # Every concrete nested code object is sealed before the enclosing app.
 for p in sorted((app/'Contents/MacOS').glob('*.dylib')):
  command(['codesign','--force','--sign',signer,'--timestamp=none',str(p)])
 scanner_reused=False
 for name,identifier in ROLE_IDS.items():
  p=app/'Contents/Helpers'/name
  if not p.is_file()or p.is_symlink():raise RuntimeError('Review helper missing')
  if name=='storage-scanner-worker'and scanner_proof is not None:
   scanner_reused=seal_scanner(app,signer,team,scanner_proof,scanner_previous,profile_case,version,build)
  else:
   command(['codesign','--force','--sign',signer,'--timestamp=none','--identifier',identifier,str(p)])
 # Reuse the composition owner; Preview keeps its exact v1 manifest and rights.
 from build_drive_health_worker import embed as embed_drive_health
 embed_drive_health(app,preview=(signer,team,profile_case))
 for name in ['SMBHelperManifest.plist','SFTPHelperManifest.plist']:
  p=app/'Contents/Resources'/name;value=plistlib.loads(p.read_bytes())
  if value.get('version')!=1 or value.get('channel')!='development'or value.get('parentIdentifier')!='local.macexplorer.development':
   raise RuntimeError('Unexpected original local helper policy')
  value['parentIdentifier']=IDENTIFIER;value['teamIdentifier']=team
  for role,entry in value['roles'].items():
   leaf={'browser':'smb-browser-worker','resolver':'smb-resolver-worker','sftp':'sftp-metadata-worker'}.get(role)
   if leaf is None or entry.get('identifier')!=ROLE_IDS[leaf]:raise RuntimeError('Unexpected helper role')
   entry['sha256']=d.digest(app/'Contents/Helpers'/leaf)
  p.write_bytes(plistlib.dumps(value,sort_keys=False))
 command(['codesign','--force','--sign',signer,'--timestamp=none','--identifier',IDENTIFIER,str(app)])
 command(['codesign','--verify','--strict','--deep',str(app)])
 return scanner_reused

def package(build_case,profile_case=None,signing='development',storage='repository',signer_from_case=None):
 source_case=checked_case(build_case)
 proof=json.loads((source_case/'evidence/source.json').read_bytes())
 result=json.loads((source_case/'evidence/build.json').read_bytes())
 configuration=proof.get('configuration');sources=d.native_sources()
 if configuration not in ['Debug','Release']or not result.get('passed')or proof['sourceSHA256']!=sources:
  raise RuntimeError('A current source-bound native build is required')
 if signer_from_case is not None and(signing!='development'or configuration!='Release'):
  raise RuntimeError('An explicit signer donor requires development signing of a Release copy')
 if signer_from_case is not None and(not proof.get('executableSHA256')or result.get('configuration')!='Release'):
  raise RuntimeError('The Release signer-donor path requires an exact executable/build proof')
 source=d.TOOLING/'derived/Build/Products'/configuration/'Mac Explorer.app'
 loaded=d.loaded_object(source,configuration,proof.get('optimizedQualification',False))
 if d.digest(loaded)!=proof['loadedSHA256']:raise RuntimeError('Native binary no longer matches its build')
 if proof.get('executableSHA256')is not None and proof['executableSHA256']!=d.digest(source/'Contents/MacOS/Mac Explorer'):
  raise RuntimeError('Native launcher/executable no longer matches its build')
 command(['codesign','--verify','--strict','--deep',str(source)])
 before=inventory(source)
 signer='-';team='adhoc';donor_fields={};donor=None;donor_before=None;donor_receipts={}
 if signing=='development':
  signing_source=source
  if signer_from_case is not None:
   release_status=command(['codesign','-d','--verbose=4',str(source)]).stderr.decode()
   release_lines=release_status.splitlines()
   if [line for line in release_lines if line.startswith('Signature=')]!=['Signature=adhoc']or any(line.startswith('Authority=')for line in release_lines):
    raise RuntimeError('The explicit signer-donor path accepts only an intact ad-hoc Release source')
   donor_case=checked_case(signer_from_case)
   donor_source_receipt=donor_case/'evidence/source.json';donor_build_receipt=donor_case/'evidence/build.json'
   if any(path.is_symlink()or path.resolve()!=path or not path.is_file()or path.stat().st_size>1<<20 for path in [donor_source_receipt,donor_build_receipt]):
    raise RuntimeError('Exact local Debug signer-donor receipts are required')
   donor_proof=json.loads(donor_source_receipt.read_bytes());donor_result=json.loads(donor_build_receipt.read_bytes())
   if donor_proof.get('configuration')!='Debug'or donor_result.get('configuration')!='Debug'or donor_result.get('passed')is not True \
      or donor_proof.get('sourceSHA256')!=sources or not donor_proof.get('loadedSHA256')or not donor_proof.get('executableSHA256'):
    raise RuntimeError('The explicit signer donor must be an exact current passed Debug build')
   donor=d.TOOLING/'derived/Build/Products/Debug/Mac Explorer.app'
   donor_loaded=d.loaded_object(donor,'Debug',donor_proof.get('optimizedQualification',False))
   if d.digest(donor_loaded)!=donor_proof['loadedSHA256']or d.digest(donor/'Contents/MacOS/Mac Explorer')!=donor_proof['executableSHA256']:
    raise RuntimeError('The Debug signer donor no longer matches its exact loaded/executable proof')
   command(['codesign','--verify','--strict','--deep',str(donor)])
   donor_before=inventory(donor);signing_source=donor
   donor_receipts={str(path):d.digest(path)for path in [donor_source_receipt,donor_build_receipt,donor_case/'reservation.json']}
  status=command(['codesign','-d','--verbose=4',str(signing_source)]).stderr.decode()
  authorities=[line.split('=',1)[1]for line in status.splitlines()if line.startswith('Authority=Apple Development: ')]
  teams=[line.split('=',1)[1]for line in status.splitlines()if line.startswith('TeamIdentifier=')]
  if len(authorities)!=1 or teams!=['CDLNJRG82U']:raise RuntimeError('The source must retain the existing approved development team; no signer fallback')
  signer=authorities[0];team=teams[0]
  if signer_from_case is not None:
   if any(line=='Signature=adhoc'for line in status.splitlines()):raise RuntimeError('An ad-hoc Debug signer donor is refused')
   donor_fields=dict(signerDonor=dict(format='preview-development-signer-donor-v1',case=signer_from_case,
    configuration='Debug',receiptSHA256=donor_receipts,loadedSHA256=donor_proof['loadedSHA256'],executableSHA256=donor_proof['executableSHA256'],
    inventorySHA256=hashlib.sha256(json.dumps(donor_before,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
    signatureDisplaySHA256=hashlib.sha256(status.encode()).hexdigest(),team=team,sameCurrentNativeSources=True))
 elif signing!='adhoc':raise RuntimeError('Unknown local review signing policy')
 profile=checked_case(profile_case,'local-review-profile')if profile_case else d.reserve('local-review-profile')
 if storage not in ['repository','private-user']:raise RuntimeError('Exact local review storage policy required')
 if not profile_case:
  d.put(profile/'inputs.json',dict(channel=CHANNEL,identifier=IDENTIFIER,sourceRun='580E1F8D-6805-40B1-8173-8F8D7A4EA80F',
   storage=storage,maximumProfileBytes=64<<20,maximumEntries=2048,noProductionState=True,noCredentialImport=True))
 elif json.loads((profile/'inputs.json').read_bytes()).get('storage','repository')!=storage:
  raise RuntimeError('Do not change an existing profile storage policy')
 if storage=='private-user':admit_private_profile(profile)
 root=d.reserve('local-review-artifact');app=root/'Traverse Preview.app'
 d.put(root/'inputs.json',dict(buildCase=build_case,profileCase=profile.name,configuration=configuration,
  version=VERSION,build=BUILD,sourceSHA256=sources,originalInventory=before,maximumCaseBytes=256<<20,
  signing=signing,team=team,storage=storage,optimizedQualification=proof.get('optimizedQualification',False),productionIdentityChanged=False,publicUpdates=False,folderAssociation=False,**donor_fields))
 shutil.copytree(source,app,symlinks=True)
 if signer_from_case is not None:
  if inventory(app)!=before:raise RuntimeError('The ad-hoc Release copy differs before Preview sealing')
  command(['codesign','--verify','--strict','--deep',str(app)])
  if inventory(donor)!=donor_before or donor_receipts!={path:d.digest(Path(path))for path in donor_receipts}or sources!=d.native_sources():
   raise RuntimeError('The Debug signer donor or current sources changed before Preview sealing')
 seal_bundle(app,profile.name,build_case,VERSION,BUILD,signer,team,storage)
 after=inventory(app)
 if before!=inventory(source)or sources!=d.native_sources():raise RuntimeError('Original source/build changed during local packaging')
 if signer_from_case is not None:
  if inventory(donor)!=donor_before or donor_receipts!={path:d.digest(Path(path))for path in donor_receipts}:
   raise RuntimeError('The exact Debug signer donor or its receipts changed during packaging')
  command(['codesign','--verify','--strict','--deep',str(donor)])
 if d.measure(root)['bytes']>256<<20:raise RuntimeError('Composed review artifact cap exceeded')
 d.put(root/'evidence/result.json',dict(passed=True,app=str(app),profileCase=profile.name,
  configuration=configuration,buildCase=build_case,version=VERSION,build=BUILD,signing=signing,team=team,storage=storage,optimizedQualification=proof.get('optimizedQualification',False),inventoryVersion=2,inventory=after,sourceUnchanged=True,
  originalAppUnchanged=True,productionUntouched=True,usage=d.audit(),**donor_fields))
 print(json.dumps(dict(case=root.name,profileCase=profile.name,app=str(app),packaged=True)),flush=True)
 return root

def package_native(configuration,version,build,profile_case,repository_profile=False):
 """Use the ordinary incremental product, without another project/source graph."""
 import dev
 if configuration not in ['Debug','Release']or not version or not build.isdecimal():
  raise ValueError('An explicit native configuration/version/build is required')
 if str(uuid.UUID(profile_case)).upper()!=profile_case:raise ValueError('Canonical existing profile required')
 if repository_profile:
  checked_case(profile_case,'ordinary-release-review')
  storage='repository'
 else:
  installed=Path('/Applications/Traverse Preview.app')
  command(['codesign','--verify','--strict','--deep',str(installed)])
  current=plistlib.loads((installed/'Contents/Info.plist').read_bytes())
  if current.get('CFBundleIdentifier')!=IDENTIFIER or current.get('MacExplorerReviewCase')!=profile_case \
      or current.get('MacExplorerDistributionChannel')!=CHANNEL:
   raise RuntimeError('Use the signed installed Preview profile; no migration or new private namespace')
  storage='private-user'if current.get('MacExplorerReviewStorage')=='private-user-v1'else'repository'
 if storage not in ['repository','private-user']:raise RuntimeError('Unknown existing profile storage')
 source=dev.BUILD/('xcode'if configuration=='Debug'else'xcode-release')/'Build/Products'/configuration/'Mac Explorer.app'
 command(['codesign','--verify','--strict','--deep',str(source)])
 before=inventory(source);sources=d.native_sources()
 scanner_proof=scanner.embedded_provenance(source/'Contents/Helpers/storage-scanner-worker',current=True)
 if scanner_proof is None:
  raise RuntimeError('Current scanner provenance required before native packaging')
 executable=source/'Contents/MacOS/Mac Explorer'
 if max((d.REPO/name).stat().st_mtime_ns for name in sources)>executable.stat().st_mtime_ns:
  raise RuntimeError('Build the current native source before packaging')
 # The already-approved development identity is reused, never selected by fallback.
 signer='3FAFAC05E68A576A7D23B1DF71A939955375ECAD';team='CDLNJRG82U'
 scanner_previous=scanner_donor(installed,scanner_proof,profile_case,scanner_signing_input(signer,team)) \
  if not repository_profile else None
 root=dev.local_directory('previews/'+version+'-'+build)
 app=root/'Traverse Preview.app'
 if app.exists()or app.is_symlink():raise RuntimeError('Preserve the existing Preview artifact; choose a new build number')
 (root/'inputs.json').write_text(json.dumps(dict(configuration=configuration,version=version,build=build,
  packagerSHA256=d.digest(Path(__file__)),
  sourceInventory=before,sourceSHA256=sources,profileCase=profile_case,storage=storage),indent=2)+'\n')
 shutil.copytree(source,app,symlinks=True)
 scanner_reused=seal_bundle(app,profile_case,'ordinary-'+configuration.lower(),version,build,signer,team,storage,
  folder_opening=True,scanner_proof=scanner_proof,scanner_previous=scanner_previous)
 after=inventory(app)
 symbols=retain_native_symbols(source,app,root,configuration)
 if before!=inventory(source)or sources!=d.native_sources():raise RuntimeError('Current source/product changed during packaging')
 if scanner.embedded_provenance(source/'Contents/Helpers/storage-scanner-worker',current=True)!=scanner_proof:
  raise RuntimeError('Ordinary scanner provenance changed during packaging')
 if scanner_previous is not None:
  if scanner_donor(installed,scanner_proof,profile_case,scanner_signing_input(signer,team))!=scanner_previous:
   raise RuntimeError('Installed scanner donor changed during packaging')
 fields=plistlib.loads((app/'Contents/Info.plist').read_bytes())
 if not preview_associations_valid(fields,folder_opening=True)or fields.get('NSServices')!=FOLDER_SERVICES \
  or fields.get('MacExplorerPreviewFolderServices')!='public-folders-service-v1':
  raise RuntimeError('Preview must declare only the exact folder Viewer and restricted folder Service, with no URL handlers')
 result=dict(passed=True,app=str(app),version=version,build=build,configuration=configuration,
  profileCase=profile_case,storage=storage,team=team,inventory=after,sourceUnchanged=True,
  publicReleaseActions=0,sandboxed=False,folderOpening=True,folderServices=True,mainAppSymbols=symbols,
  scannerProvenance=scanner_proof is not None,scannerSignedBytesReused=scanner_reused)
 (root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({k:result[k]for k in ['passed','app','version','build','profileCase','sandboxed']}),flush=True)
 return root

def main():
 p=argparse.ArgumentParser();p.add_argument('--build-case');p.add_argument('--profile-case')
 p.add_argument('--native-configuration',choices=['Debug','Release']);p.add_argument('--version');p.add_argument('--build-number')
 p.add_argument('--repository-profile',action='store_true',help='Use an owned ordinary-release-review case; never install or touch the existing private profile')
 p.add_argument('--signing',choices=['development','adhoc'],default='development')
 p.add_argument('--signer-from-case')
 p.add_argument('--storage',choices=['repository','private-user'],default='repository')
 p.add_argument('--admit-launch-case');p.add_argument('--admit-cold-launch-case');p.add_argument('--ordinary-acceptance-case')
 p.add_argument('--installed-case');p.add_argument('--audit-profile-case');a=p.parse_args()
 if a.native_configuration:
  if not a.profile_case or not a.version or not a.build_number:p.error('Native packaging requires existing --profile-case, --version and --build-number')
  package_native(a.native_configuration,a.version,a.build_number,a.profile_case,a.repository_profile);return
 if a.signer_from_case is not None and(not a.build_case or a.signing!='development'or a.admit_cold_launch_case or a.admit_launch_case or a.audit_profile_case):
  p.error('--signer-from-case is only for explicit development packaging from a Release build')
 if a.admit_cold_launch_case:admit_cold_launch(a.admit_cold_launch_case,a.installed_case,a.ordinary_acceptance_case);return
 if a.admit_launch_case:admit_launch(a.admit_launch_case,a.installed_case);return
 if a.audit_profile_case:print(json.dumps(audit_private_profile(a.audit_profile_case)));return
 if not a.build_case:p.error('--build-case is required for packaging')
 package(a.build_case,a.profile_case,a.signing,a.storage,a.signer_from_case)

if __name__=='__main__':main()
