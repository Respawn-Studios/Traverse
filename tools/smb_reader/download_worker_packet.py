"""Separate finite whole-worker packet; old codec/core reservations stay closed."""
import json,sys
from pathlib import Path
sys.dont_write_bytecode=True
from download_packet import HERE,d,child,smb
PREFIX='smb-selected-download-integration-'
def cases():
    return [m.parent for m in d.ROOT.glob('*/reservation.json')if json.loads(m.read_bytes()).get('action','').startswith(PREFIX)]
def audit(building=False):
    value=child.audit();current=cases()
    if sum(d.measure(r)['bytes']for r in current)>512<<20 or sum(d.measure(r)['entries']for r in current)>6144:raise RuntimeError('Whole-worker Download subpacket ceiling')
    value['smbDownloadIntegrationCases']=len(current);value['smbTooling']=smb.usage(smb.TOOLING,smb.TOOLING_LIMIT,building=building,compiler_locks=building);return value
def reserve(kind,launches=0):
    if kind not in ['build','controls','swift-storage','swift-session','offline-worker']:raise RuntimeError('Unreviewed Download integration action')
    child.prepare();audit();current=cases()
    if len(current)>=10:raise RuntimeError('Ten whole-worker integration attempts consumed')
    used=sum(json.loads((r/('admission.json'if(r/'admission.json').exists()else'inputs.json')).read_bytes()).get('reservedTestLaunches',0)for r in current if(r/'admission.json').exists()or(r/'inputs.json').exists())
    if used+launches>8:raise RuntimeError('Eight whole-worker test launches consumed')
    root=d.reserve(PREFIX+kind)
    d.put(root/'admission.json',dict(reservedTestLaunches=launches,maximumCaseBytes=(128 if kind=='build'else 64)<<20,networkSockets=0))
    return root
def environment(root):
    value=smb.environment();value['SDKROOT']=__import__('subprocess').check_output(['xcrun','--show-sdk-path'],text=True).strip()
    value['MEX_SMB_DOWNLOAD_FIXTURES']=str(root/'source/fixtures')
    return value
def observe(_):audit(building=True)
