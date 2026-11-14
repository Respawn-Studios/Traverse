"""New server/native completion scope; never spends earlier SMB counters."""
import json,sys
sys.dont_write_bytecode=True
from download_worker_packet import HERE,d,child,smb
PREFIX='smb-selected-download-live-'
def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action','').startswith(PREFIX)]
def audit(building=False):
    value=child.audit();current=cases()
    if sum(d.measure(r)['bytes']for r in current)>896<<20 or sum(d.measure(r)['entries']for r in current)>5120:raise RuntimeError('SMB live Download packet ceiling')
    value['smbDownloadLiveCases']=len(current);value['smbTooling']=smb.usage(smb.TOOLING,smb.TOOLING_LIMIT,building=building,compiler_locks=building);return value
def reserve(kind):
    allowed=['controller-controls','session','native-preparation','native-preflight','native','offline-worker','repair-controls']
    if kind not in allowed:raise RuntimeError('Unreviewed live Download action')
    child.prepare();audit();current=cases()
    values=[json.loads((r/'reservation.json').read_bytes())['action']for r in current]
    if kind=='session'and values.count(PREFIX+'session')>=5:raise RuntimeError('Four closed plus one native-repair start consumed')
    if kind=='native'and values.count(PREFIX+'native')>=4:raise RuntimeError('Four native launch admissions consumed')
    if kind not in ['native','session']and sum(v not in [PREFIX+'native',PREFIX+'session']for v in values)>=22:raise RuntimeError('Nineteen closed plus three exact registration-repair admissions consumed')
    return d.reserve(PREFIX+kind)
def observe(_):audit(building=True)
