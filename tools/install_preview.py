#!/usr/bin/env python3
"""Install one explicitly separate review app without replacing any existing app."""
from __future__ import annotations
import argparse,ctypes,errno,json,os,plistlib,stat,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
import preview as p
d=p.d
DESTINATION=Path('/Applications/Traverse Preview.app')

def pinned_parent(path):
 if not path.is_absolute()or path.resolve()!=path or path.is_symlink():raise RuntimeError('Redirected install parent')
 fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|0x20000000)
 value=os.fstat(fd)
 if not stat.S_ISDIR(value.st_mode)or value.st_uid not in [0,os.getuid()]or value.st_mode&0o002:
  os.close(fd);raise RuntimeError('Untrusted install parent')
 return fd,value

def fresh_parent(fd,path,before):
 value=path.lstat();held=os.fstat(fd)
 if path.resolve()!=path or (value.st_dev,value.st_ino,value.st_mode,value.st_uid)!=(before.st_dev,before.st_ino,before.st_mode,before.st_uid) \
  or (held.st_dev,held.st_ino)!=(value.st_dev,value.st_ino):raise RuntimeError('Install parent changed')

def publish_exclusive(parent,source,destination):
 if any(not leaf or leaf in ['.','..']or '/'in leaf or '\0'in leaf for leaf in [source,destination])or source==destination:
  raise RuntimeError('Invalid publication leaf')
 rename=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True).renameatx_np
 rename.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint];rename.restype=ctypes.c_int
 # The selected SDK's sys/stdio.h declares RENAME_EXCL=0x00000004.
 if rename(parent,os.fsencode(source),parent,os.fsencode(destination),4)!=0:
  code=ctypes.get_errno();raise OSError(code,os.strerror(code))

def production_snapshot():
 app=Path('/Applications/Traverse.app')
 if not app.exists():return dict(present=False)
 if app.resolve()!=app or app.is_symlink():raise RuntimeError('Production app redirection refused')
 value=app.lstat();info=app/'Contents/Info.plist';fields=plistlib.loads(info.read_bytes());executable=fields.get('CFBundleExecutable')
 if not isinstance(executable,str)or '/'in executable or executable in ['', '.', '..']:raise RuntimeError('Unexpected production executable')
 return dict(present=True,device=value.st_dev,inode=value.st_ino,infoSHA256=d.digest(info),
  executableSHA256=d.digest(app/'Contents/MacOS'/executable),identifier=fields.get('CFBundleIdentifier'),
  version=fields.get('CFBundleShortVersionString'),build=fields.get('CFBundleVersion'))

def flush_stage(app,inventory):
 for name,item in inventory.items():
  if 'sha256'not in item:continue
  fd=os.open(app/name,os.O_RDONLY|os.O_CLOEXEC|0x20000000)
  try:
   before=os.fstat(fd)
   if not stat.S_ISREG(before.st_mode)or before.st_uid!=os.getuid()or before.st_nlink!=1 or before.st_size!=item['bytes']:
    raise RuntimeError('Staged file changed before synchronization')
   os.fsync(fd);after=os.fstat(fd)
   if(before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
    raise RuntimeError('Staged file changed during synchronization')
  finally:os.close(fd)
 # Persist each new namespace before publishing the bundle's root. File fsync
 # alone does not commit the directory entries that name those files.
 directories=[app/name for name,item in inventory.items()if item.get('directory')]+[app]
 for path in sorted(directories,key=lambda value:len(value.parts),reverse=True):
  if path.resolve()!=path or path.is_symlink():raise RuntimeError('Staged directory was redirected')
  fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|0x20000000)
  try:
   before=os.fstat(fd)
   if not stat.S_ISDIR(before.st_mode)or before.st_uid!=os.getuid():raise RuntimeError('Unowned staged directory')
   os.fsync(fd);after=os.fstat(fd);named=path.lstat()
   identity=lambda value:(value.st_dev,value.st_ino,value.st_mode,value.st_uid)
   if identity(before)!=identity(after)or identity(before)!=identity(named):raise RuntimeError('Staged directory changed during synchronization')
  finally:os.close(fd)

def install(artifact_case):
 source_root=p.checked_case(artifact_case,'local-review-artifact');proof=json.loads((source_root/'evidence/result.json').read_bytes())
 source=source_root/'Traverse Preview.app'
 if not proof['passed']or proof.get('inventoryVersion')!=2 or proof['storage']!='private-user'or proof['signing']!='development'or proof['team']!='CDLNJRG82U' \
  or proof['inventory']!=p.inventory(source):raise RuntimeError('Exact sealed, independent review artifact required')
 fields=plistlib.loads((source/'Contents/Info.plist').read_bytes())
 if fields.get('CFBundleIdentifier')!=p.IDENTIFIER or fields.get('MacExplorerDistributionChannel')!=p.CHANNEL \
  or fields.get('MacExplorerReviewCase')!=proof['profileCase']or not p.preview_associations_valid(fields,folder_opening=proof.get('folderOpening')is True):
  raise RuntimeError('Preview identity/profile/association policy mismatch')
 p.command(['codesign','--verify','--strict','--deep',str(source)])
 if DESTINATION.exists()or DESTINATION.is_symlink():raise RuntimeError('Preserve the existing Preview app; no replacement is admitted')
 before=production_snapshot();root=d.reserve('local-review-install');staging=DESTINATION.parent/('.Traverse Preview-install-'+root.name+'.app')
 d.put(root/'inputs.json',dict(artifactCase=artifact_case,profileCase=proof['profileCase'],destination=str(DESTINATION),
  staging=str(staging),productionBefore=before,sourceInventory=proof['inventory'],overwrite=False,publicUpdates=False))
 fd,facts=pinned_parent(DESTINATION.parent);report=dict(passed=False,published=False)
 try:
  if staging.exists()or staging.is_symlink():raise RuntimeError('Fresh Preview staging path is occupied')
  p.command(['/usr/bin/ditto','--rsrc','--extattr',str(source),str(staging)])
  if p.inventory(staging)!=proof['inventory']:raise RuntimeError('Installed-stage inventory mismatch')
  p.command(['codesign','--verify','--strict','--deep',str(staging)])
  flush_stage(staging,proof['inventory'])
  if p.inventory(staging)!=proof['inventory']:raise RuntimeError('Synchronized Preview stage changed')
  stage=staging.lstat();fresh_parent(fd,DESTINATION.parent,facts)
  held=os.stat(staging.name,dir_fd=fd,follow_symlinks=False)
  if(held.st_dev,held.st_ino)!=(stage.st_dev,stage.st_ino)or not stat.S_ISDIR(held.st_mode)or held.st_uid!=os.getuid():
   raise RuntimeError('Verified Preview stage changed')
  if before!=production_snapshot()or p.inventory(source)!=proof['inventory']:raise RuntimeError('Protected app/source changed before publication')
  publish_exclusive(fd,staging.name,DESTINATION.name);report['published']=True;os.fsync(fd)
  if p.inventory(DESTINATION)!=proof['inventory']:raise RuntimeError('Published Preview inventory mismatch')
  p.command(['codesign','--verify','--strict','--deep',str(DESTINATION)])
  unchanged=before==production_snapshot();fresh_parent(fd,DESTINATION.parent,facts)
  if not unchanged:raise RuntimeError('Production app changed during separate installation')
  report.update(passed=True,artifactCase=artifact_case,profileCase=proof['profileCase'],app=str(DESTINATION),
   signatureVerified=True,inventory=proof['inventory'],productionUnchanged=True,sourceUnchanged=True,
   version=fields['CFBundleShortVersionString'],build=fields['CFBundleVersion'],launched=False,usage=d.audit())
 except BaseException as error:
  report.update(errorType=type(error).__name__,nativeCode=error.errno if isinstance(error,OSError)else None,
   productionUnchanged=before==production_snapshot(),failedStagePreserved=True);raise
 finally:
  os.close(fd);d.put(root/'evidence/result.json',report)
  print(json.dumps(dict(case=root.name,passed=report['passed'],published=report['published'],app=str(DESTINATION))),flush=True)

def launch_binding(install_case):
 root=p.checked_case(install_case,'local-review-install');proof=json.loads((root/'evidence/result.json').read_bytes())
 artifact=p.checked_case(proof['artifactCase'],'local-review-artifact');original=json.loads((artifact/'evidence/result.json').read_bytes())
 if not proof['passed']or proof['app']!=str(DESTINATION)or proof['inventory']!=p.inventory(DESTINATION) \
  or proof['profileCase']!=original['profileCase']or proof['inventory']!=original['inventory']:raise RuntimeError('Installed Preview changed')
 p.command(['codesign','--verify','--strict','--deep',str(DESTINATION)])
 return proof['artifactCase'],str(DESTINATION)

def controls():
 root=d.reserve('preview-exclusive-install-controls');area=root/'source/Applications';area.mkdir(mode=0o700)
 fd,before=pinned_parent(area);checks=[]
 try:
  stage=area/'Stage.app';stage.mkdir(mode=0o700);(stage/'Marker').write_bytes(b'generated-stage')
  publish_exclusive(fd,'Stage.app','Preview.app');fresh_parent(fd,area,before)
  assert (area/'Preview.app/Marker').read_bytes()==b'generated-stage'and not stage.exists();checks.append('fresh exclusive publication')
  stage.mkdir(mode=0o700);(stage/'Marker').write_bytes(b'generated-new')
  try:publish_exclusive(fd,'Stage.app','Preview.app');raise RuntimeError('Existing app was replaced')
  except OSError as error:assert error.errno==errno.EEXIST
  assert(stage/'Marker').read_bytes()==b'generated-new'and(area/'Preview.app/Marker').read_bytes()==b'generated-stage';checks.append('existing app and stage preserved')
  (area/'Link.app').symlink_to(area/'Preview.app')
  try:publish_exclusive(fd,'Stage.app','Link.app');raise RuntimeError('Existing link was replaced')
  except OSError as error:assert error.errno==errno.EEXIST
  assert(area/'Link.app').is_symlink()and stage.is_dir();checks.append('occupied symlink refused')
  redirect=root/'source/Redirect';redirect.symlink_to(area,target_is_directory=True)
  try:
   escaped,_=pinned_parent(redirect);os.close(escaped);raise RuntimeError('Redirected parent was admitted')
  except RuntimeError as error:assert str(error)=='Redirected install parent'
  checks.append('redirected parent refused before mutation')
  for leaf in ['', '.', '..', 'Outside/App', 'nul\0tail']:
   try:publish_exclusive(fd,leaf,'New.app');raise RuntimeError('Invalid leaf admitted')
   except RuntimeError as error:assert str(error)=='Invalid publication leaf'
  checks.append('invalid namespace components refused');os.fsync(fd)
  flush_stage(area/'Preview.app',p.inventory(area/'Preview.app'))
  assert(area/'Preview.app/Marker').read_bytes()==b'generated-stage';checks.append('file and directory synchronization preserves inventory')
  invalid=stage/'Unowned Type';invalid.mkdir()
  try:flush_stage(stage,{'Unowned Type':dict(bytes=0,sha256='generated')});raise RuntimeError('Non-file admitted to file synchronization')
  except RuntimeError as error:assert str(error)=='Staged file changed before synchronization'
  checks.append('synchronization refuses changed file kind')
 finally:os.close(fd)
 d.put(root/'evidence/result.json',dict(passed=True,checks=checks,productionWrites=0,allGeneratedFixturesRetained=True,usage=d.audit()))
 print(json.dumps(dict(case=root.name,passed=True,checks=len(checks))),flush=True)

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--artifact-case');parser.add_argument('--controls',action='store_true');args=parser.parse_args()
 if args.controls:controls()
 elif args.artifact_case:install(args.artifact_case)
 else:parser.error('Choose explicit generated controls or one sealed artifact')

if __name__=='__main__':main()
