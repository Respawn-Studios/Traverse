#!/usr/bin/env python3
"""Explicit, resumable Developer ID notarization; never converts local cases."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import time

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from distribution import release_candidate
from distribution.preflight import inspect,signing
from distribution.direct_dmg import run
from distribution.traverse_packet import REPO,require_case,put,audit

PROFILE='Respawn-Traverse-Notary'


def code_hash(case,app):
    stdout,stderr=run(case,['codesign','-d','--verbose=4',str(app)],'notary-code-identity')
    facts=dict(line.split('=',1) for line in (stdout+stderr).decode().splitlines() if '=' in line)
    digest=facts.get('CDHash','')
    if len(digest)!=40 or any(c not in '0123456789abcdef' for c in digest):raise RuntimeError('Actual code identity missing')
    return digest


def admit(case,app):
    if app.is_symlink() or app.resolve()!=app or not app.is_relative_to(case) or app.name!='Traverse.app':
        raise RuntimeError('Exact case-owned app required')
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    config=json.loads((case/'configuration.json').read_bytes())
    version,build=release_candidate.shipping_metadata(config,info)
    report=inspect(app,'com.respawnstudios.traverse','CDLNJRG82U','developer-id')
    bad=[v['id'] for v in report['checks'] if not v['passed']]
    if bad:raise RuntimeError('Technical artifact admission failed: '+','.join(bad))
    return version,build,report


def prepare(case):
    config=release_candidate.configuration(json.loads((case/'configuration.json').read_bytes()))
    release_candidate.admit_action(config,'notarize')
    if config.get('shippingCandidate') is not True:raise RuntimeError('New shipping case required')
    exported=json.loads((case/'export.json').read_bytes())
    if exported.get('passed') is not True:raise RuntimeError('Successful explicit local export required')
    parent=REPO/exported['output']
    if parent.is_symlink() or parent.resolve()!=parent or parent.parent!=case:raise RuntimeError('Export path differs')
    original=parent/'Traverse.app'
    version,build,report=admit(case,original)
    output=case/'notarized'
    if output.exists() or output.is_symlink():raise RuntimeError('Preserve existing notarization output')
    output.mkdir(mode=0o700)
    put(output/'source-admission.json',dict(version=version,build=build,sourceApp=str(original.relative_to(REPO)),
        sourceCodeHash=code_hash(case,original),technicalPreflight=report,
        encryptionAnswer='App Store/TestFlight answers and export review remain separate; no exemption invented'))
    run(case,['ditto',str(original),str(output/'Traverse.app')],'notary-app-copy')
    admit(case,output/'Traverse.app')
    run(case,['ditto','-c','-k','--sequesterRsrc','--keepParent',str(output/'Traverse.app'),str(output/'Traverse.notary.zip')],'notary-app-envelope')
    path=output/'Traverse.notary.zip'
    put(output/'prepared.json',dict(passed=True,bytes=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        internalNotarizationEnvelopeOnly=True,friendInstaller='DMG'))
    print(json.dumps(dict(case=case.name,prepared=True,version=version,build=build)),flush=True)


def submit(case):
    output=case/'notarized';admit(case,output/'Traverse.app')
    prepared=json.loads((output/'prepared.json').read_bytes());archive=output/'Traverse.notary.zip'
    if prepared.get('passed') is not True or archive.stat().st_size!=prepared['bytes'] \
            or hashlib.sha256(archive.read_bytes()).hexdigest()!=prepared['sha256']:
        raise RuntimeError('Notarization envelope changed')
    if (output/'submission-attempt.json').exists() or (output/'submission.json').exists():
        raise RuntimeError('Submission attempted already; reconcile its outcome before any further request')
    put(output/'submission-attempt.json',dict(profile=PROFILE,envelopeSHA256=prepared['sha256'],attemptedUTC=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())))
    stdout,_=run(case,['xcrun','notarytool','submit',str(archive),'--keychain-profile',PROFILE,'--output-format','json','--no-wait'],'notary-app-submit',180)
    response=json.loads(stdout)
    if not isinstance(response.get('id'),str):raise RuntimeError('Submission outcome requires explicit reconciliation')
    put(output/'submission.json',response)
    print(json.dumps(dict(case=case.name,submitted=True,id=response['id'])),flush=True)


def finish(case):
    output=case/'notarized';app=output/'Traverse.app'
    if (output/'accepted.json').exists():raise RuntimeError('Notarization completion already recorded')
    admit(case,app)
    submission=json.loads((output/'submission.json').read_bytes())
    stdout,_=run(case,['xcrun','notarytool','info',submission['id'],'--keychain-profile',PROFILE,'--output-format','json'],'notary-app-status')
    status=json.loads(stdout)
    put(output/('status-'+str(time.time_ns())+'.json'),status)
    if status.get('status')!='Accepted':
        print(json.dumps(dict(case=case.name,status=status.get('status'),accepted=False)),flush=True);return
    run(case,['xcrun','stapler','staple',str(app)],'notary-app-staple')
    run(case,['xcrun','stapler','validate',str(app)],'notary-app-ticket')
    run(case,['codesign','--verify','--deep','--strict',str(app)],'notary-app-seal')
    stdout,stderr=run(case,['spctl','--assess','--type','execute','--verbose=2',str(app)],'notary-app-gatekeeper')
    if 'source=Notarized Developer ID' not in (stdout+stderr).decode():raise RuntimeError('Gatekeeper notarized acceptance missing')
    version,build,report=admit(case,app)
    original=json.loads((output/'source-admission.json').read_bytes())
    if code_hash(case,app)!=original['sourceCodeHash']:raise RuntimeError('Notarized program differs from exported program')
    put(output/'accepted.json',dict(passed=True,version=version,build=build,submission=submission['id'],
        codeHash=original['sourceCodeHash'],stapled=True,gatekeeper='accepted',technicalPreflight=report,packet=audit()))
    print(json.dumps(dict(case=case.name,accepted=True,stapled=True,version=version,build=build)),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','submit','finish']);parser.add_argument('--case',required=True)
    args=parser.parse_args();case=require_case(args.case)
    {'prepare':prepare,'submit':submit,'finish':finish}[args.action](case)
