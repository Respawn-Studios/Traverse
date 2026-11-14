#!/usr/bin/env python3
"""Bounded regular-development tests; separate from preserved release evidence."""
import argparse,fcntl,hashlib,json,os,signal,stat,subprocess,sys,time,uuid
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parent))
import dev
from native_build_inputs import source_inputs as native_sources
from qualify_foundation import wait_generated
from distribution.traverse_packet import TOOLING,CLANG_CACHE,SWIFT_CACHE,charged_tooling,measure
REPO=Path(__file__).resolve().parents[1]
ROOT=REPO/'.build/traverse-development'
MASTER=ROOT/'887B77DA-8583-42B1-9055-32B91A60641F'
APP=TOOLING/'derived/Build/Products/Debug/Mac Explorer.app'
MIB=1<<20
# Historical finite packet limits include all earlier reservations and failures.
# They are not ordinary build defaults and must never be reset by source cleanup.
# Daily builds use tools/dev.py; exact scope history remains in Git and receipts.
DEVELOPMENT_ENTRY_LIMIT=157952
DEVELOPMENT_BYTE_LIMIT=(14<<30)+(272<<20)
DEVELOPMENT_TOOLING_LIMIT=5<<30

def put(path,value):
 with path.open('x')as f:os.fchmod(f.fileno(),0o600);json.dump(value,f,indent=2);f.write('\n')
def audit():
 value=measure(ROOT);charged=charged_tooling()
 if value['bytes']>DEVELOPMENT_BYTE_LIMIT or value['entries']>DEVELOPMENT_ENTRY_LIMIT or charged['chargedToolingAllocatedBytes']>DEVELOPMENT_TOOLING_LIMIT:raise RuntimeError('Development or isolated tooling limit reached')
 return {'development':value,**charged}
def reserve(action):
 if ROOT.resolve()!=ROOT or MASTER.resolve()!=MASTER or not(MASTER/'reservation.json').is_file():raise RuntimeError('Development scope unavailable')
 audit();root=ROOT/str(uuid.uuid4()).upper();root.mkdir(mode=0o700)
 for name in ['source','evidence','state','cache']:(root/name).mkdir(mode=0o700)
 put(root/'reservation.json',{'packet':'traverse-development-v1','action':action,'master':MASTER.name})
 return root
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def loaded_object(product,configuration='Debug',optimized_qualification=False):
 return product/'Contents/MacOS'/('Mac Explorer.debug.dylib'if configuration=='Debug'and not optimized_qualification else'Mac Explorer')
def generated_bodies(folder):
 anchor=os.open(folder,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|0x20000000)
 try:
  names=os.listdir(anchor)
  if set(names)!={'Generated-'+format(i,'04d')+'.dat'for i in range(2048)}:raise RuntimeError('Unexpected generated Copy names')
  actual={}
  for name in names:
   fd=os.open(name,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=anchor)
   try:
    before=os.fstat(fd)
    if not stat.S_ISREG(before.st_mode)or before.st_nlink!=1 or before.st_uid!=os.geteuid()or before.st_size!=4096:raise RuntimeError('Unexpected generated Copy body')
    data=os.read(fd,4097);after=os.fstat(fd)
    if len(data)!=4096 or os.read(fd,1)or(before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):raise RuntimeError('Generated Copy body changed')
    actual[name]=hashlib.sha256(data).hexdigest()
   finally:os.close(fd)
  return actual
 finally:os.close(anchor)
def deep_generated_metadata(folder):
 """Exact retained deep fixture, descriptor-relative metadata only."""
 if folder.resolve()!=folder:raise RuntimeError('Deep fixture symlink refused')
 result={}
 def visit(anchor,level,prefix):
  expected={'Top.txt','Cargo.toml','d000'}if level==0 else {'Deep.rs'}if level==127 else {'d'+format(level,'03d')}
  if set(os.listdir(anchor))!=expected:raise RuntimeError('Retained deep fixture names changed')
  for name in sorted(expected):
   facts=os.stat(name,dir_fd=anchor,follow_symlinks=False);key=prefix+name
   directory=name.startswith('d')and len(name)==4
   if facts.st_uid!=os.geteuid()or (not stat.S_ISDIR(facts.st_mode)if directory else not stat.S_ISREG(facts.st_mode)):raise RuntimeError('Retained deep fixture kind/owner changed')
   result[key]={'device':facts.st_dev,'inode':facts.st_ino,'directory':directory,'size':None if directory else facts.st_size,'mtimeNS':None if directory else facts.st_mtime_ns}
   if not directory:
    if facts.st_size!={'Top.txt':16,'Cargo.toml':0,'Deep.rs':4096}[name]:raise RuntimeError('Retained deep fixture size changed')
   else:
    fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=anchor)
    try:
     fresh=os.fstat(fd)
     if(fresh.st_dev,fresh.st_ino)!=(facts.st_dev,facts.st_ino):raise RuntimeError('Retained deep fixture changed during open')
     visit(fd,level+1,key+'/')
    finally:os.close(fd)
 anchor=os.open(folder,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
 try:visit(anchor,0,'')
 finally:os.close(anchor)
 if len(result)!=130:raise RuntimeError('Retained deep fixture count changed')
 return result
def build(label,configuration='Debug',optimized_qualification=False,bounded_optimization=False,app_compiler_headroom=False,focused_network=False):
 if configuration not in ['Debug','Release']:raise ValueError('Known development configuration required')
 if optimized_qualification and configuration!='Debug':raise ValueError('Optimized qualification retains the explicit Debug controls')
 if bounded_optimization and not(optimized_qualification or configuration=='Release'):raise ValueError('Bounded optimizer requires an explicit optimized build')
 if focused_network and not(configuration=='Debug'and optimized_qualification and bounded_optimization and app_compiler_headroom):raise ValueError('Focused network controls require their explicit optimized native profile')
 if app_compiler_headroom:
  if not bounded_optimization:raise ValueError('Native compiler headroom requires actual descendant measurement')
  used=sum(json.loads(p.read_bytes()).get('appCompilerHeadroom')is True for p in ROOT.glob('*/inputs.json'))
  # Root prospectively admits four completion invocations after all53 earlier
  # slots were consumed; preserve failures and unchanged process/tooling caps.
  # Twelve new-run invocations; every earlier attempt stays charged.
  if used>=107:raise RuntimeError('One hundred seven finite native app-compiler headroom admissions consumed, including retained compiler failures')
 compiler_limit=(2<<30)if app_compiler_headroom else(512<<20)
 aggregate_limit=(3<<30)if app_compiler_headroom else(2<<30)
 root=reserve(configuration.lower()+'-build')
 product=TOOLING/'derived/Build/Products'/configuration/'Mac Explorer.app'
 source_proof=native_sources()
 # Generate a separate project with an explicit repository source root.
 from generate_project import generate
 project=MASTER/'MacExplorer.xcodeproj';generate(destination=project)
 pbx=project/'project.pbxproj';text=pbx.read_text();assert 'projectDirPath = "";'in text
 pbx.write_text(text.replace('projectDirPath = "";','projectDirPath = "'+str(REPO)+'";',1))
 scheme=project/'xcshareddata/xcschemes/MacExplorer.xcscheme';scheme.write_text(scheme.read_text().replace('container:MacExplorer.xcodeproj','container:'+str(project)))
 clang=dev.local_directory('compiler-cache/xcode');swift=dev.local_directory('compiler-cache/xcode-swift')
 assert clang==CLANG_CACHE and swift==SWIFT_CACHE
 command=['xcodebuild','-project',str(project),'-scheme','MacExplorer','-configuration',configuration,'-destination','platform=macOS,arch=arm64','-derivedDataPath',str(TOOLING/'derived'),'-clonedSourcePackagesDirPath',str(TOOLING/'packages'),'-skipPackageUpdates','-disableAutomaticPackageResolution','-disablePackageRepositoryCache','-packageCachePath',str(TOOLING/'package-cache'),'-packageAuthorizationProvider','netrc','-resultBundlePath',str(root/'evidence/build.xcresult'),'-jobs','4','CODE_SIGN_STYLE=Manual','SWIFT_TREAT_WARNINGS_AS_ERRORS=YES','ONLY_ACTIVE_ARCH=YES','OTHER_SWIFT_FLAGS=$(inherited) -j4 -driver-batch-count 4','COMPILER_INDEX_STORE_ENABLE=NO','CLANG_MODULE_CACHE_PATH='+str(clang),'SWIFT_MODULE_CACHE_PATH='+str(swift)]
 # Keep normal Release optimization/whole-module compilation, without creating
 # a distribution dSYM in the bounded development cache. No archive or install.
 if configuration=='Release':command+=['DEBUG_INFORMATION_FORMAT=dwarf']
 if optimized_qualification:
  command+=['SWIFT_OPTIMIZATION_LEVEL=-O','SWIFT_COMPILATION_MODE=wholemodule','DEBUG_INFORMATION_FORMAT=dwarf','ENABLE_DEBUG_DYLIB=NO']
 if bounded_optimization:
  command[command.index('-jobs')+1]='1'
  command+=['SWIFT_COMPILATION_MODE=incremental','SWIFT_ENABLE_BATCH_MODE=NO','OTHER_SWIFT_FLAGS=$(inherited) -j1 -disable-batch-mode']
 frontend_profile=None
 if focused_network:
  command+=['SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG TRAVERSE_NETWORK_QUALIFICATION']
 if optimized_qualification and bounded_optimization and not focused_network:
  compiler=Path(subprocess.check_output(['xcrun','--find','swift-frontend'],text=True,timeout=10).strip()).resolve();info=compiler.stat()
  wrapper=REPO/'tools/native_swift_frontend.py'
  profile_proof=ROOT/'3EB34718-291E-4953-8069-4D31D1987E21/evidence/result.json'
  qualified=json.loads(profile_proof.read_bytes())
  if not qualified.get('passed')or qualified.get('wrapperSHA256')!=digest(wrapper):raise RuntimeError('Current real frontend qualification required')
  frontend_profile={'compiler':str(compiler),'compilerIdentity':[info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns],'wrapperSHA256':digest(wrapper)}
  command[-1]='OTHER_SWIFT_FLAGS=$(inherited) -j1 -disable-batch-mode -driver-use-frontend-path '+str(wrapper)+' -resource-dir '+str(compiler.parents[1]/'lib/swift')+' -tools-directory '+str(compiler.parent)
  command+=['COMPILATION_CACHE_ENABLE_CACHING=NO','SWIFT_ENABLE_EXPLICIT_MODULES=NO']
 command+=['build']
 put(root/'inputs.json',{'configuration':configuration,'command':command,'distribution':False,'optimizedQualification':optimized_qualification,'boundedOptimization':bounded_optimization,'appCompilerHeadroom':app_compiler_headroom,'focusedNetworkQualification':focused_network,'maximumCompilerRSSBytes':compiler_limit,'maximumAggregateCompilerRSSBytes':aggregate_limit,'frontendProfile':frontend_profile})
 owner=digest(REPO/'MacExplorer.xcodeproj/project.pbxproj');began=time.monotonic();build_deadline=1200 if app_compiler_headroom else 600
 child=None;native_owner=None
 put(root/'evidence/source-start.json',{'sourceSHA256':source_proof,'ownerProjectSHA256':owner,'configuration':configuration,'optimizedQualification':optimized_qualification})
 try:
  with(root/'evidence/build.log').open('xb')as out:
   build_environment=dev.environment(tooling=False)
   build_environment.update(CLANG_MODULE_CACHE_PATH=str(clang),
    SWIFTPM_MODULECACHE_OVERRIDE=str(swift))
   if frontend_profile:build_environment['TRAVERSE_NATIVE_BUILD_ROOT']=str(root)
   child=subprocess.Popen(command,cwd=REPO,env=build_environment,stdout=out,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
   if bounded_optimization:
    from native_build_processes import NativeBuildOwner
    native_owner=NativeBuildOwner(child.pid)
   try:
    while child.poll()is None:
     if time.monotonic()-began>build_deadline:raise RuntimeError('Owned build deadline')
     if bounded_optimization:
      native_owner.observe()
      if native_owner.peak>compiler_limit or native_owner.total_peak>aggregate_limit:raise RuntimeError('Bounded native compiler RSS ceiling')
     audit();time.sleep(1)
    if child.returncode:raise RuntimeError('Native build failed; retained '+str(root/'evidence/build.log'))
    if bounded_optimization and native_owner.samples==0:raise RuntimeError('Native compiler memory was not observed')
   finally:
    if native_owner:native_owner.stop()
    if child.poll()is None:
     os.killpg(child.pid,signal.SIGTERM)
     try:child.wait(timeout=5)
     except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=5)
    if native_owner:put(root/'evidence/compiler-memory.json',dict(**native_owner.report(),maximumCompilerRSSBytes=compiler_limit,maximumAggregateCompilerRSSBytes=aggregate_limit,actualExit=child.returncode))
 except BaseException as error:
  put(root/'evidence/build-stop.json',{'passed':False,'errorType':type(error).__name__,'actualExit':child.returncode if child else None,'seconds':time.monotonic()-began,'sourceUnchanged':source_proof==native_sources(),'ownerProjectUnchanged':digest(REPO/'MacExplorer.xcodeproj/project.pbxproj')==owner,'buildAcceptance':False})
  raise
 assert digest(REPO/'MacExplorer.xcodeproj/project.pbxproj')==owner
 if source_proof!=native_sources():raise RuntimeError('Native sources changed during build')
 subprocess.run(['codesign','--verify','--strict','--deep',str(product)],capture_output=True,check=True,timeout=30)
 loaded=loaded_object(product,configuration,optimized_qualification)
 put(root/'evidence/source.json',{'sourceSHA256':source_proof,'loadedSHA256':digest(loaded),'loadedRelative':str(loaded.relative_to(product)),
  'executableSHA256':digest(product/'Contents/MacOS/Mac Explorer'),
  'helpersSHA256':{p.name:digest(p)for p in sorted((product/'Contents/Helpers').iterdir())if p.is_file()and not p.is_symlink()},
  'configuration':configuration,'optimizedQualification':optimized_qualification})
 put(root/'evidence/build.json',{'passed':True,'label':label,'configuration':configuration,'optimizedQualification':optimized_qualification,'seconds':time.monotonic()-began,'ownerProjectUnchanged':True,'sourceUnchanged':True,'signatureVerified':True,'usage':audit()})
 print(json.dumps({'case':root.name,'built':True}),flush=True)
 return root

def motion(surface,mode,large=False,light=False,source_case=None,ordinary_app=False):
 from ui_motion.run_development import motion as run_motion
 return run_motion(surface,mode,large,light,source_case,ordinary_app)

def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['build','motion','audit']);p.add_argument('--label',default='development');p.add_argument('--configuration',choices=['Debug','Release'],default='Debug');p.add_argument('--surface',choices=['settings','help','analysis','properties','connection','ssh','ssh-prompts','ssh-jump','workspace','tools','filters','controls','integration','deep','deep-navigation','progress','stop','failures','workload'],default='settings');p.add_argument('--mode',choices=['full','reduced','off'],default='full');p.add_argument('--large',action='store_true');p.add_argument('--light',action='store_true');p.add_argument('--source-case');p.add_argument('--optimized-qualification',action='store_true');p.add_argument('--bounded-optimization',action='store_true');p.add_argument('--app-compiler-headroom',action='store_true');p.add_argument('--focused-network',action='store_true');p.add_argument('--ordinary-app',action='store_true',help='Reuse the current verified ordinary Debug app for motion; no second build graph.');a=p.parse_args()
 if a.ordinary_app and a.action!='motion':p.error('--ordinary-app applies only to motion')
 if a.action=='build':build(a.label,a.configuration,a.optimized_qualification,a.bounded_optimization,a.app_compiler_headroom,a.focused_network)
 elif a.action=='motion':motion(a.surface,a.mode,a.large,a.light,a.source_case,a.ordinary_app)
 else:print(json.dumps(audit()))
if __name__=='__main__':main()
