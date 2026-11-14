"""Separate J composition budget; old H/I routes and counters stay preserved."""
import json,sys
sys.dont_write_bytecode=True
from packet import d,audit as shared_audit,prepare,directory
PREFIX='routed-folder-upload-'
def cases():return [p.parent for p in d.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action','').startswith(PREFIX)]
def audit():
    value=shared_audit();current=cases()
    if sum(d.measure(r)['bytes']for r in current)>512<<20 or sum(d.measure(r)['entries']for r in current)>6144:raise RuntimeError('J composition packet ceiling')
    value['routedFolderCases']=len(current);return value
def reserve(kind,repair=False,fixture_completion=False):
    if kind not in ['source','worker-controls','local-contracts','local-test-completion','observer-controls','builder-observer-controls','loopback','controller-contracts','wire','native','review-profile','session','adoption']:raise RuntimeError('Unreviewed J action')
    if type(repair)is not bool or repair and kind!='local-contracts':raise RuntimeError('Typed local completion repair required')
    if type(fixture_completion)is not bool or fixture_completion and(kind!='worker-controls'or repair):raise RuntimeError('Typed fixture completion required')
    prepare();audit();current=cases()
    if kind in ['worker-controls','local-contracts','local-test-completion']:
        test_drivers=sum(json.loads((r/'inputs.json').read_bytes()).get('testDriverLaunches',0)for r in current if(r/'inputs.json').exists())
        if test_drivers>=7:raise RuntimeError('Seven J test-driver admissions consumed, including unlaunched reservations')
    builds=[r for r in current if json.loads((r/'reservation.json').read_bytes())['action']in[PREFIX+'worker-controls',PREFIX+'local-contracts']]
    maximum,per_kind=4,2
    if repair:
        for name in ['8866C74E-0379-4C2B-B14E-9DA3CB883B9C','B6FF735D-01B0-4428-A5DD-72EB2FA733A0']:
            old=d.ROOT/name
            if json.loads((old/'reservation.json').read_bytes())['action']!=PREFIX+'local-contracts'or json.loads((old/'evidence/result.json').read_bytes()).get('passed')is not False:raise RuntimeError('Exact preserved local failures required')
        preserved=[p.parent for p in d.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action')=='preserve-j-inactive-sdk']
        if len(preserved)!=1 or not json.loads((preserved[0]/'evidence/result.json').read_bytes()).get('passed'):raise RuntimeError('Completed lossless cache proof required')
        maximum,per_kind=5,3
    if fixture_completion:
        proof=json.loads((d.ROOT/'D7D37273-59A7-4AC0-9B19-FE322B919B73/evidence/result.json').read_bytes())
        if not proof.get('passed'):raise RuntimeError('Existing optimized J proof required')
        maximum,per_kind=6,3
    if kind in ['worker-controls','local-contracts']and(len(builds)>=maximum or sum(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in current)>=per_kind):raise RuntimeError('Finite J control-build admissions consumed')
    if kind=='native'and sum(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in current)>=9:raise RuntimeError('Nine J native admissions consumed, including preserved responsiveness failures')
    if kind=='review-profile'and sum(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in current)>=4:raise RuntimeError('Four zero-network sheet profile launches consumed')
    if kind in ['local-test-completion','observer-controls']and any(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in current):raise RuntimeError('One diagnosed observer completion per J packet')
    if kind=='builder-observer-controls'and sum(json.loads((r/'reservation.json').read_bytes())['action']==PREFIX+kind for r in current)>=2:raise RuntimeError('Two exact builder observer versions consumed')
    return d.reserve(PREFIX+kind)
