#!/usr/bin/env python3
"""Refresh only the exact owned Preview; preserve old code and uncertain states."""
from __future__ import annotations
import argparse,errno,json,os,plistlib,stat,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
import install_preview as i
p=i.p;d=p.d
REFRESH_LINEAGE=('1B771CEE-CD71-46D7-BBA0-98E9E627EE98','57BCB8EB-7DE1-41BD-B3E7-179CF3C61211','ED196C79-6928-4E08-9E7B-167273165277','9F6FEEAB-0133-448F-9DC3-BFEFC45D24CC','768DE3FA-6FDE-447A-8765-56FAA81765D3','F10ED708-B4DB-4679-9E35-EF2974DF7CB9','454CECB9-1453-4CE8-BFF8-8FCF29A3EEC9','2DA553FA-E9BE-44C6-B2D4-8F44699B588C','A4F2E964-06A3-40DD-BC7B-9081DE915D59','E59096B8-E33A-48D4-BDCB-DDEAA9E2EA0E','C3EC5789-59C1-4929-81DC-37655863D8C0','EF75F40F-FAB9-4004-A807-0E990A53C98F')

def leaves(*names):
    if len(set(names))!=len(names)or any(not x or x in ['.','..']or '/'in x or '\0'in x for x in names):
        raise RuntimeError('Invalid Preview refresh names')

def identity(path):
    value=path.lstat()
    if not stat.S_ISDIR(value.st_mode)or value.st_uid!=os.getuid()or path.resolve()!=path:
        raise RuntimeError('Preview refresh root changed')
    return [value.st_dev,value.st_ino,value.st_mode,value.st_uid]

def occupied(path):return path.exists()or path.is_symlink()

def inspect(parent,stage,final,backup,old,new):
    leaves(stage,final,backup)
    def match(name,wanted):
        path=parent/name
        if not occupied(path):return False
        try:return p.inventory(path)==wanted and bool(identity(path))
        except (RuntimeError,OSError):return False
    if match(final,new)and match(backup,old)and not occupied(parent/stage):return 'published'
    if match(final,old)and match(stage,new)and not occupied(parent/backup):return 'prepared'
    if not occupied(parent/final)and match(stage,new)and match(backup,old):return 'retained'
    return 'uncertain'

def retain_and_publish(parent,stage,final,backup,old,new,checkpoint=lambda _:None):
    leaves(stage,final,backup);fd,parent_id=i.pinned_parent(parent)
    try:
        if occupied(parent/backup):raise FileExistsError(errno.EEXIST,'Preview backup occupied')
        if p.inventory(parent/stage)!=new or p.inventory(parent/final)!=old:raise RuntimeError('Preview refresh inventory changed')
        source_id=identity(parent/stage);old_id=identity(parent/final)
        i.flush_stage(parent/stage,new);checkpoint('prepared')
        i.fresh_parent(fd,parent,parent_id)
        if identity(parent/stage)!=source_id or identity(parent/final)!=old_id or p.inventory(parent/stage)!=new or p.inventory(parent/final)!=old:
            raise RuntimeError('Preview refresh changed before retention')
        i.publish_exclusive(fd,final,backup);os.fsync(fd)
        if identity(parent/backup)!=old_id or p.inventory(parent/backup)!=old:raise RuntimeError('Retained Preview differs from exact prior install')
        checkpoint('retained');i.fresh_parent(fd,parent,parent_id)
        if identity(parent/stage)!=source_id or p.inventory(parent/stage)!=new or identity(parent/backup)!=old_id or p.inventory(parent/backup)!=old:
            raise RuntimeError('Preview refresh changed before publication')
        i.publish_exclusive(fd,stage,final);os.fsync(fd)
        if identity(parent/final)!=source_id or p.inventory(parent/final)!=new or identity(parent/backup)!=old_id or p.inventory(parent/backup)!=old:
            raise RuntimeError('Published Preview identity/inventory mismatch')
        checkpoint('published');i.fresh_parent(fd,parent,parent_id)
    finally:os.close(fd)

def restore_old(parent,stage,final,backup,old,new):
    leaves(stage,final,backup);fd,parent_id=i.pinned_parent(parent)
    try:
        if inspect(parent,stage,final,backup,old,new)!='retained':raise RuntimeError('Only an exact interrupted retention may restore')
        old_id=identity(parent/backup);i.fresh_parent(fd,parent,parent_id)
        i.publish_exclusive(fd,backup,final);os.fsync(fd)
        if identity(parent/final)!=old_id or p.inventory(parent/final)!=old or p.inventory(parent/stage)!=new:
            raise RuntimeError('Restored Preview changed; preserve all inputs')
        i.fresh_parent(fd,parent,parent_id)
    finally:os.close(fd)

def has_preview_code(lines,roots):
    return any(line.strip().startswith(str(root)+'/Contents/')for line in lines for root in roots)

def no_running_preview(extra_roots=()):
    lines=subprocess.run(['/bin/ps','-axo','comm='],check=True,capture_output=True,text=True,timeout=10).stdout.splitlines()
    if has_preview_code(lines,(i.DESTINATION,*extra_roots)):
        raise RuntimeError('Quit the exact Preview and drain its workers before refresh or relaunch')

def checked_upgrade(tag):
    root=p.checked_case(tag,'local-review-upgrade');inputs=json.loads((root/'inputs.json').read_bytes())
    if inputs.get('format')!='preview-upgrade-v1'or inputs.get('destination')!=str(i.DESTINATION):raise RuntimeError('Wrong Preview upgrade receipt')
    leaves(inputs['stage'],i.DESTINATION.name,inputs['backup'])
    if inputs['profileCase']!='1C04223A-4025-4F1C-ABFE-001CBA2928BA':raise RuntimeError('Unapproved Preview profile')
    return root,inputs

def check_inherited(parent,leaf,inventory,expected_identity):
    leaves(leaf)
    if identity(parent/leaf)!=expected_identity or p.inventory(parent/leaf)!=inventory:
        raise RuntimeError('Earlier retained Preview code changed')

def inherited_backups(inputs):
    """Read old receipts unchanged; the exact Preview22 lineage admits seven ancestors."""
    if 'inheritedBackups'in inputs and 'inheritedBackup'in inputs:
        raise RuntimeError('Ambiguous inherited Preview code')
    if 'inheritedBackups'in inputs:
        values=inputs['inheritedBackups']
    else:
        legacy=inputs.get('inheritedBackup');values=[]if legacy is None else[legacy]
    if not isinstance(values,list)or len(values)>12:raise RuntimeError('Inherited Preview lineage bound')
    for value in values:
        if not isinstance(value,dict)or set(value)!={'leaf','inventory','identity'}or not isinstance(value['leaf'],str) \
            or not isinstance(value['inventory'],dict)or not isinstance(value['identity'],list)or len(value['identity'])!=4 \
            or not all(type(v)is int and v>=0 for v in value['identity']):raise RuntimeError('Invalid inherited Preview code')
    leaves(*(value['leaf']for value in values))
    return values

def check_ancestors(parent,inputs):
    values=inherited_backups(inputs)
    for value in values:check_inherited(parent,value['leaf'],value['inventory'],value['identity'])
    return values

def validate_retained_code(code):
    """Finite exact-version budget; inputs have already matched real inventories."""
    versions=len(code)
    if not 2<=versions<=14:raise RuntimeError('Fourteen retained Preview versions are the finite boundary')
    limit=(1280 if versions==14 else 1152 if versions==13 else 1024 if versions>=10 else 768 if versions==9 else 704 if versions>=7 else 576 if versions==6 else 512 if versions>=5 else 384)<<20
    if sum(v.get('bytes',0)for tree in code for v in tree.values())>limit or sum(len(tree)for tree in code)>2048:
        raise RuntimeError('Retained Preview code cap exceeded')
    return versions,limit

def upgrade(artifact_case,previous_case=None,previous_upgrade_case=None):
    inherited=[]
    if previous_upgrade_case:
        # This exact finite lineage admits Preview22; it is not a general updater.
        if previous_case or previous_upgrade_case not in REFRESH_LINEAGE:
            raise RuntimeError('Only the explicitly admitted Preview lineage may be refreshed')
        previous,prior=checked_upgrade(previous_upgrade_case)
        expected=REFRESH_LINEAGE.index(previous_upgrade_case)
        inherited=check_ancestors(i.DESTINATION.parent,prior)
        if len(inherited)!=expected or prior.get('previousUpgradeCase')!=(REFRESH_LINEAGE[expected-1]if expected else None):
            raise RuntimeError('Prior Preview lineage changed')
        prior_result=json.loads((previous/'evidence/result.json').read_bytes())
        if not prior_result.get('passed')or inspect(i.DESTINATION.parent,prior['stage'],i.DESTINATION.name,prior['backup'],prior['oldInventory'],prior['newInventory'])!='published':
            raise RuntimeError('Exact passed prior Preview revision required')
        old_proof=dict(inventory=prior['newInventory'],profileCase=prior['profileCase'])
        inherited=[*inherited,dict(leaf=prior['backup'],inventory=prior['oldInventory'],identity=identity(i.DESTINATION.parent/prior['backup']))]
        check_ancestors(i.DESTINATION.parent,dict(inheritedBackups=inherited))
    else:
        if not previous_case:raise RuntimeError('Exact prior installation required')
        i.launch_binding(previous_case)
        previous=p.checked_case(previous_case,'local-review-install');old_proof=json.loads((previous/'evidence/result.json').read_bytes())
    no_running_preview(tuple(i.DESTINATION.parent/value['leaf']for value in inherited))
    artifact=p.checked_case(artifact_case,'local-review-artifact');new_proof=json.loads((artifact/'evidence/result.json').read_bytes())
    source=artifact/'Traverse Preview.app';new=new_proof.get('inventory',{})
    if not new_proof['passed']or new_proof.get('inventoryVersion')!=2 or new_proof['storage']!='private-user'or new_proof['signing']!='development' \
        or new_proof['team']!='CDLNJRG82U'or new_proof['profileCase']!=old_proof['profileCase']or p.inventory(source)!=new:
        raise RuntimeError('Exact signed Preview artifact/profile required')
    fields=plistlib.loads((source/'Contents/Info.plist').read_bytes())
    if fields.get('CFBundleIdentifier')!=p.IDENTIFIER or fields.get('MacExplorerDistributionChannel')!=p.CHANNEL \
        or fields.get('MacExplorerReviewCase')!=new_proof['profileCase']or not p.preview_associations_valid(fields,folder_opening=new_proof.get('folderOpening')is True):
        raise RuntimeError('Preview refresh identity or association mismatch')
    p.command(['codesign','--verify','--strict','--deep',str(source)])
    old=old_proof['inventory']
    code=[old,new]+[value['inventory']for value in inherited]
    code_versions,code_limit=validate_retained_code(code)
    earlier=[]
    for prior in d.ROOT.glob('*/reservation.json'):
        if json.loads(prior.read_bytes()).get('action')=='local-review-upgrade':earlier.append(prior.parent.name)
    expected_lineage=REFRESH_LINEAGE[:REFRESH_LINEAGE.index(previous_upgrade_case)+1]if previous_upgrade_case else()
    if sorted(earlier)!=sorted(expected_lineage):raise RuntimeError('Finite Preview refresh allowance already reserved; preserve all earlier cases')
    root=d.reserve('local-review-upgrade');parent=i.DESTINATION.parent
    stage='.Traverse Preview-revision-'+root.name+'.app';backup='.Traverse Preview-previous-'+root.name+'.retained'
    production=i.production_snapshot()
    d.put(root/'inputs.json',dict(format='preview-upgrade-v1',artifactCase=artifact_case,previousInstallCase=previous_case,previousUpgradeCase=previous_upgrade_case,inheritedBackups=inherited,
        profileCase=new_proof['profileCase'],destination=str(i.DESTINATION),stage=stage,backup=backup,oldInventory=old,newInventory=new,
        productionBefore=production,maximumQualificationLaunches=2,maximumCodeVersions=code_versions,maximumCodeBytes=code_limit,maximumCodeEntries=2048,noCredentialImport=True,noBetaMigration=True))
    def checkpoint(phase):
        if production!=i.production_snapshot():raise RuntimeError('Protected production app changed')
        check_ancestors(parent,dict(inheritedBackups=inherited))
        d.put(root/'evidence'/('namespace-'+phase+'.json'),dict(phase=phase,stage=stage,backup=backup,
            state=inspect(parent,stage,i.DESTINATION.name,backup,old,new),productionUnchanged=True))
        for path in [root/'evidence'/('namespace-'+phase+'.json'),root/'evidence']:
            fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
            try:os.fsync(fd)
            finally:os.close(fd)
    report=dict(passed=False)
    try:
        if occupied(parent/stage)or occupied(parent/backup):raise RuntimeError('Fresh Preview revision names occupied')
        p.command(['/usr/bin/ditto','--rsrc','--extattr',str(source),str(parent/stage)])
        p.command(['codesign','--verify','--strict','--deep',str(parent/stage)])
        no_running_preview(tuple(parent/value['leaf']for value in inherited))
        retain_and_publish(parent,stage,i.DESTINATION.name,backup,old,new,checkpoint)
        p.command(['codesign','--verify','--strict','--deep',str(i.DESTINATION)])
        if p.inventory(source)!=new or production!=i.production_snapshot():raise RuntimeError('Protected source/app changed')
        check_ancestors(parent,dict(inheritedBackups=inherited))
        report.update(passed=True,app=str(i.DESTINATION),artifactCase=artifact_case,profileCase=new_proof['profileCase'],
            backup=str(parent/backup),oldCodeRetained=True,newInventory=new,signatureVerified=True,productionUnchanged=True,launched=False,usage=d.audit())
        if previous_upgrade_case:
            # Append the exact continuation; the first result remains immutable.
            note=previous/'evidence/superseded-by.json'
            d.put(note,dict(upgradeCase=root.name,artifactCase=artifact_case,priorCodeRetainedAt=str(parent/backup),earlierBackupUnchanged=True))
            fd=os.open(note,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
            try:os.fsync(fd)
            finally:os.close(fd)
            fd=os.open(note.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW)
            try:os.fsync(fd)
            finally:os.close(fd)
    except BaseException as error:
        report.update(passed=False,errorType=type(error).__name__,nativeCode=error.errno if isinstance(error,OSError)else None,
            observedState=inspect(parent,stage,i.DESTINATION.name,backup,old,new),productionUnchanged=production==i.production_snapshot(),allInputsRetained=True)
        raise
    finally:
        d.put(root/'evidence/result.json',report)
        print(json.dumps(dict(case=root.name,passed=report['passed'],app=str(i.DESTINATION))),flush=True)

def admit_launch(tag):
    root,inputs=checked_upgrade(tag);proof=json.loads((root/'evidence/result.json').read_bytes())
    inherited=check_ancestors(i.DESTINATION.parent,inputs)
    if not proof['passed']or inspect(i.DESTINATION.parent,inputs['stage'],i.DESTINATION.name,inputs['backup'],inputs['oldInventory'],inputs['newInventory'])!='published':
        raise RuntimeError('Exact passed Preview revision is required')
    p.command(['codesign','--verify','--strict','--deep',str(i.DESTINATION)])
    no_running_preview((i.DESTINATION.parent/inputs['stage'],i.DESTINATION.parent/inputs['backup'],*(i.DESTINATION.parent/value['leaf']for value in inherited)))
    for number in [1,2]:
        receipt=root/'evidence'/('qualification-launch-'+str(number)+'.json')
        if receipt.exists():continue
        d.put(receipt,dict(launch=number,upgradeCase=tag,artifactCase=inputs['artifactCase'],profileCase=inputs['profileCase'],
            profileUsage=p.audit_private_profile(inputs['profileCase']),originalAdmissionsUnchanged=True,newGrant=False,newCredential=False))
        for path in [receipt,receipt.parent]:
            fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)
            try:os.fsync(fd)
            finally:os.close(fd)
        print(json.dumps(dict(case=tag,launch=number,admitted=True)),flush=True);return
    raise RuntimeError('Both exact Preview revision launches are consumed')

def refresh_native(artifact_path,expected_build):
    """Refresh the current Preview with one rollback, independent of old lineages."""
    import uuid
    import dev
    root=Path(artifact_path).absolute()
    if root.resolve()!=root or root.parent!=dev.BUILD/'previews':raise RuntimeError('Use an exact repo-local Preview artifact')
    proof=json.loads((root/'result.json').read_bytes());source=root/'Traverse Preview.app'
    if proof.get('passed')is not True or proof.get('team')!='CDLNJRG82U' or p.inventory(source)!=proof.get('inventory'):
        raise RuntimeError('Signed Preview artifact changed')
    fields=plistlib.loads((i.DESTINATION/'Contents/Info.plist').read_bytes())
    next_fields=plistlib.loads((source/'Contents/Info.plist').read_bytes())
    for info in [fields,next_fields]:
        if info.get('CFBundleIdentifier')!=p.IDENTIFIER or info.get('MacExplorerDistributionChannel')!=p.CHANNEL:
            raise RuntimeError('Only the separate Preview identity may be refreshed')
    if not p.preview_associations_valid(fields,folder_opening=fields.get('MacExplorerPreviewFolderOpening')=='public-folder-v1') \
        or not p.preview_associations_valid(next_fields,folder_opening=proof.get('folderOpening')is True):
        raise RuntimeError('Preview folder or URL association policy mismatch')
    if fields.get('CFBundleVersion')!=expected_build or fields.get('MacExplorerReviewCase')!=proof['profileCase'] \
        or fields.get('MacExplorerReviewStorage')!=next_fields.get('MacExplorerReviewStorage'):
        raise RuntimeError('Preserve the exact existing Preview/profile; inspect a mismatched install')
    no_running_preview()
    p.command(['codesign','--verify','--strict','--deep',str(source)])
    p.command(['codesign','--verify','--strict','--deep',str(i.DESTINATION)])
    old=p.inventory(i.DESTINATION);new=proof['inventory'];production=i.production_snapshot()
    tag=str(uuid.uuid4()).upper();stage='.Traverse Preview-stage-'+tag+'.app';backup='.Traverse Preview-rollback-'+expected_build+'-'+tag+'.app'
    receipt=dict(passed=False,stage=stage,backup=backup,destination=str(i.DESTINATION),oldBuild=expected_build,
        newBuild=proof['build'],profileCase=proof['profileCase'],productionBefore=production,oldInventory=old,newInventory=new)
    report=root/'install.json'
    if report.exists():raise RuntimeError('Preserve the existing install result')
    try:
        p.command(['/usr/bin/ditto','--rsrc','--extattr',str(source),str(i.DESTINATION.parent/stage)])
        p.command(['codesign','--verify','--strict','--deep',str(i.DESTINATION.parent/stage)])
        no_running_preview()
        retain_and_publish(i.DESTINATION.parent,stage,i.DESTINATION.name,backup,old,new)
        receipt['passed']=i.production_snapshot()==production
        if not receipt['passed']:raise RuntimeError('Protected Traverse changed during Preview refresh')
    finally:
        receipt['observedState']=inspect(i.DESTINATION.parent,stage,i.DESTINATION.name,backup,old,new)
        report.write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps({k:receipt[k]for k in ['passed','oldBuild','newBuild','observedState','profileCase']}),flush=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--artifact-case');parser.add_argument('--previous-install-case');parser.add_argument('--previous-upgrade-case')
    parser.add_argument('--native-artifact')
    parser.add_argument('--expected-current-build','--expected-build',dest='expected_build',
        help='Exact currently installed Preview build to replace (for example73 when installing74).')
    parser.add_argument('--inspect-case');parser.add_argument('--restore-case');parser.add_argument('--admit-launch-case');args=parser.parse_args()
    if args.native_artifact:
        if not args.expected_build:parser.error('--expected-current-build is required for a native refresh')
        refresh_native(args.native_artifact,args.expected_build)
    elif args.admit_launch_case:admit_launch(args.admit_launch_case)
    elif args.inspect_case or args.restore_case:
        root,inputs=checked_upgrade(args.inspect_case or args.restore_case)
        inherited=check_ancestors(i.DESTINATION.parent,inputs)
        if args.restore_case:
            no_running_preview((i.DESTINATION.parent/inputs['stage'],i.DESTINATION.parent/inputs['backup'],*(i.DESTINATION.parent/value['leaf']for value in inherited)))
            if i.production_snapshot()!=inputs['productionBefore']:raise RuntimeError('Protected production snapshot changed before restore')
            restore_old(i.DESTINATION.parent,inputs['stage'],i.DESTINATION.name,inputs['backup'],inputs['oldInventory'],inputs['newInventory'])
            if i.production_snapshot()!=inputs['productionBefore']:raise RuntimeError('Protected production snapshot changed during restore')
        print(json.dumps(dict(case=root.name,state=inspect(i.DESTINATION.parent,inputs['stage'],i.DESTINATION.name,inputs['backup'],inputs['oldInventory'],inputs['newInventory']))),flush=True)
    elif args.artifact_case and(args.previous_install_case or args.previous_upgrade_case):upgrade(args.artifact_case,args.previous_install_case,args.previous_upgrade_case)
    else:parser.error('Choose one exact artifact/prior install, inspection, explicit restore or launch admission')

if __name__=='__main__':main()
