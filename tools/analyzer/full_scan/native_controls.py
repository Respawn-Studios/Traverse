#!/usr/bin/env python3
"""One bounded current signed-app result/paging check; no new source fixture."""
import fcntl,hashlib,json,os,subprocess,sys,time,uuid,argparse
if __name__ == '__main__' and '--workspace' in sys.argv[1:]:
    raise SystemExit('Historical external-drive qualification is retired; use a generated analysis fixture.')
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[2]));import dev
sys.path.insert(0,str(Path(__file__).resolve().parents[1]));import refinement_budget as budget
from packet import BASE,REPO,put

def execute(a,app=None):
 if getattr(a,'workspace',False):raise ValueError('Historical external-drive qualification is retired; use a generated analysis fixture.')
 personal=getattr(a,'personal_app_data',False)
 if personal and (not a.startup or not a.contracts or a.stop or a.topology or a.classification_source or getattr(a,'workspace',False) or a.lane!='paged' or getattr(a,'app_data',False) or getattr(a,'policy_controls',False)):
  raise ValueError('personal app-data qualification admits the explicitly approved internal interface only')
 policy_controls=getattr(a,'policy_controls',False)
 if policy_controls and (a.lane!='paged' or a.contracts or a.classification_source or a.topology or a.startup or getattr(a,'workspace',False) or getattr(a,'app_data',False) or a.stop):
  raise ValueError('policy controls admit generated UI mode only')
 completion=getattr(a,'completion_controls',False)
 if completion and (a.lane!='paged' or a.contracts or a.classification_source or a.topology or a.startup
                    or getattr(a,'workspace',False) or getattr(a,'app_data',False) or personal or policy_controls or a.stop):
  raise ValueError('completion controls admit generated UI mode only')
 if getattr(a,'app_data',False) and (a.lane!='paged' or a.contracts or a.classification_source or a.topology or a.startup or getattr(a,'workspace',False)):
  raise ValueError('policy native qualification admits generated corpus mode only')
 app=Path(app or dev.APP)
 if app!=dev.APP:
  allowed=REPO/'.build/b06-consumer-profile-build'
  if allowed not in app.parents or app.is_symlink() or app.resolve()!=app:raise ValueError('isolated app path refused')
 workspace=getattr(a,'workspace',False)
 b=budget.inspect();reserve=(512<<20 if a.contracts or a.classification_source else 3*64<<20 if policy_controls else 64<<20) if a.lane=='paged' and not (a.topology or a.startup or workspace) else 0
 if not b['passed'] or b['sqlite_qualification']['remaining_bytes']<reserve or b['combined']['entries']+(32 if a.contracts else 16 if policy_controls else 5 if a.classification_source else 4)>b['limits']['entries'] or b['extra_evidence']['remaining_bytes']<(1<<20 if a.contracts or a.classification_source or policy_controls else 65536):raise ValueError('native admission')
 binary=app/'Contents/MacOS/Mac Explorer';worker=app/'Contents/Helpers/storage-scanner-worker'
 rec=dict(schema=1,passed=False,case=a.case,lane=a.lane,stop=a.stop,before=b,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),worker_sha256=hashlib.sha256(worker.read_bytes()).hexdigest())
 started=time.monotonic()
 try:
  command=[str(binary),'--verify-ui','--offscreen','--check-analysis-paged','--analysis-case',a.case,'--analysis-lane',a.lane]
  if a.stop:command+=['--analysis-stop']
  if getattr(a,'app_data',False):command+=['--analysis-app-data']
  if policy_controls:command+=['--analysis-policy-controls']
  if completion:command+=['--analysis-completion-controls']
  if a.topology:command+=['--analysis-topology']
  if a.contracts:command+=['--analysis-contracts']
  if a.startup:command+=['--analysis-startup']
  if personal:command+=['--analysis-personal-app-data']
  if a.diagnostic:command+=['--analysis-diagnostic']
  if a.classification_source:command+=['--analysis-classification','--analysis-source',a.classification_source]
  r=subprocess.run(command,env=dev.environment(tooling=False),capture_output=True,text=True,timeout=210 if a.startup or workspace else 60)
  rec.update(exit=r.returncode,stderr_bytes=len(r.stderr),stdout=r.stdout[-16384:],stderr=r.stderr[-8192:])
  lines=[s[len('MAC_EXPLORER_ANALYSIS_PAGED '):] for s in r.stdout.splitlines() if s.startswith('MAC_EXPLORER_ANALYSIS_PAGED ')]
  if len(lines)==1:rec['report']=json.loads(lines[0])
  rec['passed']=r.returncode==0 and rec.get('report',{}).get('passed',False)
 except Exception as error:rec['failure']=type(error).__name__
 try:rec['after']=budget.inspect();rec['passed'] &= rec['after']['passed']
 except Exception as error:rec['accounting_failure']=type(error).__name__;rec['passed']=False
 rec['seconds']=time.monotonic()-started
 return rec

def arguments():
 p=argparse.ArgumentParser();p.add_argument('--case',choices=['wide','mixed'],default='wide');p.add_argument('--lane',choices=['paged','memory'],default='paged');p.add_argument('--stop',action='store_true');p.add_argument('--app-data',action='store_true');p.add_argument('--personal-app-data',action='store_true');p.add_argument('--policy-controls',action='store_true');p.add_argument('--topology',action='store_true');p.add_argument('--contracts',action='store_true');p.add_argument('--startup',action='store_true');p.add_argument('--workspace',action='store_true');p.add_argument('--diagnostic',action='store_true');p.add_argument('--classification-source');p.add_argument('--application',type=Path)
 p.add_argument('--completion-controls',action='store_true');return p.parse_args()

def main():
 a=arguments()
 if a.workspace:raise SystemExit('Historical external-drive qualification is retired; use a generated analysis fixture.')
 lock=os.open(REPO/'.build/b06-consumer-profile-build/full-scope-controls.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 rec=execute(a,a.application)
 receipt=BASE/'evidence-extension-20261018'/('native-full-'+uuid.uuid4().hex+'.json');put(receipt,rec)
 print(json.dumps(dict(passed=rec['passed'],receipt=str(receipt.relative_to(REPO)),report=rec.get('report'),stdout=rec.get('stdout') if not rec['passed'] else None,stderr=rec.get('stderr'),failure=rec.get('failure')),indent=2))
 os.close(lock)
 if not rec['passed']:raise SystemExit(2)
if __name__=='__main__':main()
