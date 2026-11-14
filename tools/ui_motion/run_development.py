"""Existing development motion flows; runtime evidence, not an app build input.

The stable development CLI imports this module only for motion. Builders keep
using their original helpers and do not load capture/control code.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

import development
from development import (
    APP, ROOT, REPO, MIB, dev, reserve, audit, put, digest, loaded_object, measure,
    native_sources, generated_bodies, deep_generated_metadata, wait_generated,
)

def motion(surface,mode,large=False,light=False,source_case=None,ordinary_app=False):
 if surface not in ['controls','integration','deep','deep-navigation','failures']:
  dev.require_unlocked_console()
 app=dev.APP if ordinary_app else APP
 ordinary_receipt=None
 controller_sha=digest(Path(__file__))
 controller_inputs={'tools/development.py':digest(Path(development.__file__)),'tools/ui_motion/run_development.py':controller_sha}
 if ordinary_app:
  ordinary_receipt,ordinary=dev.compiled_debug_inputs(require_current_source=True)
 sources=native_sources();proof=None;native_case=None;loaded=None
 executable=digest(app/'Contents/MacOS/Mac Explorer')
 helpers={p.name:digest(p)for p in sorted((app/'Contents/Helpers').iterdir())if p.is_file()and not p.is_symlink()}
 if ordinary_app:
  proof={'sourceSHA256':ordinary['sourceSHA256']};native_case='ordinary-debug'
  loaded=loaded_object(app,'Debug')
 else:
  for candidate in sorted(ROOT.glob('*/evidence/source.json'),key=lambda p:p.stat().st_mtime_ns,reverse=True):
   item=json.loads(candidate.read_text());passed=candidate.with_name('build.json')
   if item.get('configuration')!='Debug'or item.get('executableSHA256')!=executable or item.get('helpersSHA256')!=helpers:continue
   object_path=loaded_object(app,'Debug',item.get('optimizedQualification',False))
   if item.get('loadedRelative')!=str(object_path.relative_to(app))or not object_path.is_file():continue
   if item.get('loadedSHA256')==digest(object_path)and passed.is_file()and json.loads(passed.read_text()).get('passed'):
    proof=item;native_case=candidate.parent.parent.name;loaded=object_path;break
 if proof is None or proof['sourceSHA256']!=sources:raise RuntimeError('Build changed native/module/scanner sources first')
 subprocess.run(['codesign','--verify','--strict','--deep',str(app)],capture_output=True,check=True,timeout=30)
 root=reserve('motion-audit');binary=app/'Contents/MacOS/Mac Explorer'
 if ordinary_receipt is not None:
  put(root/'evidence/ordinary-build-binding.json',{'receiptSHA256':hashlib.sha256(ordinary_receipt).hexdigest(),'application':str(app),'controllerSHA256':controller_sha,'controllerInputsSHA256':controller_inputs,'sourceUnchanged':True})
 if surface=='integration':
  for folder in ['Scan','Scan/Sources','Scan/target','Scan/node_modules']:(root/'source'/folder).mkdir(mode=0o700)
  for index in range(100):(root/'source/Scan'/('Generated '+str(index)+'.txt')).write_bytes(b'G'*16)
  for name,size in [('Cargo.toml',0),('Sources/main.rs',128),('target/build.o',256),('node_modules/dependency.js',64)]:(root/'source/Scan'/name).write_bytes(b'G'*size)
 if surface=='deep-navigation'and not source_case:raise RuntimeError('Reuse the marked deep fixture; no new deep entries')
 if surface=='deep':
  current=root/'source/DeepNative';current.mkdir(mode=0o700)
  (current/'Top.txt').write_bytes(b'G'*16);(current/'Cargo.toml').write_bytes(b'')
  for index in range(127):current=current/('d'+format(index,'03d'));current.mkdir(mode=0o700)
  (current/'Deep.rs').write_bytes(b'G'*4096)
 if surface=='failures':(root/'source/FailureScope').mkdir(mode=0o700)
 if surface=='tools':
  with(root/'source/Upload.txt').open('xb'):pass
 if surface=='workspace':(root/'source/Local').mkdir(mode=0o700)
 if surface=='filters':
  folder=root/'source/FilterFiles';folder.mkdir(mode=0o700)
  (folder/'Report Folder').mkdir(mode=0o700)
  for name,size in [('Report tiny.txt',511),('Report match.txt',1536),('Report large.txt',4096),('Report Other.pdf',1536),('Report empty.txt',0)]:
   (folder/name).write_bytes(b'G'*size)
 fixture=root
 deep_before=None
 if surface=='deep-navigation':
  if str(uuid.UUID(source_case)).upper()!=source_case:raise RuntimeError('Canonical source case required')
  fixture=ROOT/source_case
  if fixture.resolve()!=fixture or json.loads((fixture/'reservation.json').read_text()).get('action')!='motion-audit'or json.loads((fixture/'inputs.json').read_text()).get('surface')!='deep':raise RuntimeError('Only a marked retained deep source can be reused')
  deep_before=deep_generated_metadata(fixture/'source/DeepNative')
  put(root/'source/deep-metadata-before.json',deep_before)
 if surface=='workload':
  (root/'source/OperationDestination').mkdir(mode=0o700)
  if source_case:
   if str(uuid.UUID(source_case)).upper()!=source_case:raise RuntimeError('Canonical source case required')
   fixture=ROOT/source_case
   if fixture.resolve()!=fixture or json.loads((fixture/'reservation.json').read_text()).get('action')!='motion-audit'or json.loads((fixture/'inputs.json').read_text()).get('surface')!='workload':raise RuntimeError('Only a retained generated workload source can be reused')
   expected=json.loads((fixture/'source/expected-bodies.json').read_text())
   if generated_bodies(fixture/'source/OperationSource')!=expected:raise RuntimeError('Retained generated source changed')
  else:
   source=root/'source/OperationSource';source.mkdir(mode=0o700);expected={}
   for index in range(2048):
    name='Generated-'+format(index,'04d')+'.dat';body=(str(index).encode()+b'G'*4096)[:4096];path=source/name
    path.write_bytes(body);path.chmod(0o600);expected[name]=hashlib.sha256(body).hexdigest()
  put(root/'source/expected-bodies.json',expected)
 put(root/'inputs.json',{'surface':surface,'mode':mode,'sources':sources,'nativeBuildCase':native_case,'binarySHA256':digest(binary),'loadedSHA256':digest(loaded),'generatedOnly':True,'maximumRSSBytes':256*MIB,'maximumCaseBytes':64*MIB,'sourceFixtureCase':fixture.name})
 env=dev.environment(tooling=False);env.update(MAC_EXPLORER_TEST_ROOT=str(root),MAC_EXPLORER_STATE_ROOT=str(root/'state'),MAC_EXPLORER_CACHE_ROOT=str(root/'cache'))
 if surface=='workload':env['MAC_EXPLORER_WORKLOAD_SOURCE_CASE']=fixture.name
 if surface=='deep-navigation':env['MAC_EXPLORER_DEEP_SOURCE_CASE']=fixture.name
 with(root/'evidence/native.log').open('xb')as out:
  child=subprocess.Popen([str(binary),'--verify-ui','--check-development-motion','--motion-surface',surface,'--motion-mode',mode,*(['--offscreen']if surface in ['controls','integration','deep','deep-navigation','failures']else[]),*(['--motion-large']if large else[]),*(['--motion-light']if light else[])],cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  stats,failure,contained,forced=wait_generated(child,root/'evidence/native.log',root/'evidence',deadline=45)
 native=json.loads((root/'evidence/native.json').read_text())if(root/'evidence/native.json').is_file()else None
 unchanged=sources==native_sources()
 if ordinary_receipt is not None:
  final_receipt,_=dev.compiled_debug_inputs(require_current_source=True)
  if final_receipt!=ordinary_receipt:raise RuntimeError('Ordinary build receipt changed during native motion check')
  if {name:digest(REPO/name) for name in controller_inputs}!=controller_inputs:raise RuntimeError('Native motion controller changed during its check')
 passed=child.returncode==0 and not contained and native and native.get('passed')and unchanged and stats.ru_maxrss<=256*MIB and measure(root)['bytes']<=64*MIB
 if deep_before is not None:
  deep_after=deep_generated_metadata(fixture/'source/DeepNative');put(root/'evidence/deep-metadata-after.json',deep_after)
  stable=deep_before==deep_after;put(root/'evidence/deep-source-unchanged.json',{'passed':stable,'metadataEntries':len(deep_after),'fileBodyReads':0})
  passed &= stable
 if passed and surface=='workload':
  workload=native['additionalChecks']['concurrentWorkload'];area=root/'source/OperationDestination'/workload['retainedUndoArea']
  marker=area/'.mac-explorer-recovery-v1'
  wanted=json.loads((root/'source/expected-bodies.json').read_text())
  verified=area.parent==root/'source/OperationDestination'and not area.is_symlink()and marker.read_text()=='MacExplorer recovery v1\n'+workload['retainedUndoOperation']+'\nRetained until explicit cleanup.\n'and generated_bodies(area/'payload')==wanted and generated_bodies(fixture/'source/OperationSource')==wanted
  put(root/'evidence/copy-undo-independent.json',{'passed':verified,'sourceAndRetainedBodyCount':len(wanted),'copiedBytes':len(wanted)*4096,'personalBodyReads':0})
  passed &= verified
 report={'passed':bool(passed),'native':native,'actualExit':child.returncode,'peakRSSBytes':stats.ru_maxrss,'sourceUnchanged':unchanged,'failure':failure,'contained':contained,'forced':forced,'usage':audit()}
 put(root/'evidence/qualification.json',report);print(json.dumps({'case':root.name,'passed':bool(passed),'native':native}),flush=True)
 if not passed:raise SystemExit(1)
 return root
