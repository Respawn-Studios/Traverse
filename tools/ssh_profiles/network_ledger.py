"""New durable attempt allowance; never resets prior B11/remote ledgers."""
import fcntl
import hashlib
import json
import os
import stat
import uuid
from packet import TOOLING, directory

SFTP_DIRECTORY_ACTION_RESERVATION='sftp-directory-action-release21'
SFTP_DIRECTORY_RENAME_RESERVATION='sftp-directory-rename-qualification-20261104'
SFTP_MOVE_ACTION_RESERVATION='sftp-file-folder-move-qualification-20261107'
SFTP_CUT_ACTION_RESERVATION='sftp-file-folder-cut-qualification-20261108'
SFTP_PERMISSION_COMPLETION_RESERVATION='sftp-exclusive-permission-completion-20261108'
SFTP_PERMISSION_REPAIR_RESERVATION='sftp-exclusive-permission-final-inventory-repair-20261108'
PERMISSION_COMPLETION_CASE='A4C6E55A-5943-4E36-B48B-6507883824F6'
PERMISSION_COMPLETION_SCOPE_SHA256='9fbcdce0ca5ee232f639662939f97747023414a9d7f7fb594328c0e255cc6b8f'
PERMISSION_REPAIR_CASE='1F30E8F0-105C-4DD0-8266-151CC462518B'
PERMISSION_REPAIR_SCOPE_SHA256='1ab872eb39b626e1fb4a896fa409e813781060a22cf988c70b4783f3150ccc5c'
PERMISSION_FIRST_RESULT_SHA256='a060ac439b14df41c301170ccc73be677d8f8e82290f9f8250a79626f3ed0c27'
PERMISSION_FIRST_STOP_SHA256='4bf0ad8776043d4d18e654f0f823166fef5115b52b9fe817aa71a2109e92fd39'
PERMISSION_FIRST_NATIVE_SHA256='fb9cfecc76da84cdce283895ca1653294750faf490280c9f3ffcb4b7df898778'
PERMISSION_FIRST_BASELINE_SHA256='f77ff042ffeac25b41ccf9e1317c673d616365bcc08782992f09e2445d060df2'
PERMISSION_FIRST_LEDGER_SHA256={
    'sftp-permission-completion-openssh-session-001.json':'1c761d326561abcf18ac91319623a3f6dbd2e5e84be077de581aaecf0abe4212',
    'sftp-permission-completion-openssh-attempt-001.json':'f0d888cab5af3a55c8f615cc64902189af2846c97185cd51882c6b29ce6251a9',
}
PERMISSION_DENIAL_LEDGER_SHA256={
    'exclusive-denial-openssh-session-001.json':'ecff784f2aadcb1c9ae49d1ede92f18aae898903866cafb6e18c41ab0abe0f64',
    'exclusive-denial-openssh-session-002.json':'b7e0bc48318cb6e78b30d7aedbe5ff3143bddc97855897676b746811276d9845',
    'exclusive-denial-openssh-attempt-001.json':'6ce6b1437f920ae9b5a2fec7a6b52f1bcb0564a967be08ede4ec3cd16a1ba6dd',
    'exclusive-denial-openssh-attempt-002.json':'6a78472b943dcd181fb6429b38dddb5d2c1abfab3e9ad082ffbea1276d8fc109',
    'exclusive-denial-openssh-attempt-003.json':'4a78ddcfad878a13cbcbce5045222de22fe16fc47344d8580c58a98b8fe427fd',
    'exclusive-denial-openssh-attempt-004.json':'089ec64bf41cb54f48af3d2f396a4bb7603edc93216d4f26af2fb8a585bc7ed5',
}
PERMISSION_DENIAL_VERDICTS_SHA256={
    '0FD4EF7F-3581-470C-90AE-0742D898D2B9':{
        'result.json':'f66dd9916b596f28e14b303416ee91fb06fd6c0fd059581dc08eaa3527357b2e',
        'cleanup.json':'9ba6d31c78231677f4848bfe65f731d0e1dbd5d8b8ee5406fafe5302a6d68f00',
        'live-result.json':'e32616516d6d03eaf651abc8a592969bd79d0ff89f267d4fb743bbea8f494a3e',
        'live-cleanup.json':'90eedc7b7fc27e792e147bffe43ff1fd0f9e03a1f0b75b84b26aded8290a54df',
    },
    '661C88F6-AC89-4AD6-9CDB-43D68702CED7':{
        'result.json':'15fc012bd017528c7765f86d0001a47e481bbb151e3566176b07b6efbf50de2a',
        'cleanup.json':'90eedc7b7fc27e792e147bffe43ff1fd0f9e03a1f0b75b84b26aded8290a54df',
    },
}
CUT_OWNER_SCOPE_SHA256='8377a343fca2f2409a331a1a4fcfa9fc3e4ae6febaa56b87f316a9b480db3eb2'
CUT_FIRST_CASE='75A27CC3-F985-4A65-B15A-C1B1AD003224'
CUT_REPAIR_CASE='D9F8C3E5-CF3B-43EC-B6A2-ED7A06CFA50E'
MOVE_FIRST_CASE='2E392C64-EF36-40F2-AE58-EB8C32005435'
MOVE_REPAIR_CASE='ABF05E41-7FDA-46BB-B549-1E4F94F89D81'
MOVE_CONTINUATION_CASE='0CBAD8DA-23D0-48AE-8ACD-BD90D10FE056'
MOVE_FIRST_STOP_SHA256='ab7f9abffd5ea54aa78db2885d90834b6336b01fda8c9aaf844497eebd61c756'
MOVE_SECOND_STOP_SHA256='3e427157c3e7793df9f891824393f9cdac629c1f9628a6923647767b07819edd'
MOVE_REPAIR_OFFLINE_SHA256='37aa65c7ab68a501250f15d7b7fe26f2861f425757c4fdc9c6c136d2a9799f89'
MOVE_SECOND_RESULT_SHA256='5bb2c09459ad595d164e7a6cafc46293b8560dc577324bf0a5ae5b70bf90cbba'
MOVE_SECOND_BASELINE_SHA256='5977b8324474d9baebc54c6b22f18af54fcbcc0bbae08afaf9bd68ac6d2ed18d'
MOVE_SECOND_NATIVE_AUTH_SHA256='d9c58cb82e4b7fdcb7172202d3ab021820b64081cd6585647c5a7f6fae6eaae5'
MOVE_THIRD_STOP_SHA256='1df30c953388cb707fbd522494618e28a685cdec1ee14ae17a075b27fd7ad5f7'
MOVE_THIRD_EXPORT_SHA256='f6a773e658354c61156497fa03af583a15eceb4097ef53f4b6fe5f46ce220fd5'
MOVE_THIRD_RESULT_SHA256='4d5f019e01251201f0d449397469a781fdd3528ba6cd295ad2729f951ff85ee8'
MOVE_THIRD_LEDGER_SHA256={
    'sftp-move-action-openssh-session-003.json':'7ae8b6b0d825eaa1bf59c3bc8c7260c1bc6771fa96e178201b4598100f3bd815',
    'sftp-move-action-openssh-attempt-005.json':'86511504bc19e1db4ab7a815b4fbdb72ad4d1a6ef6d8ad29adcc5b430a57e937',
}
# A second Cut lifetime requires a separately reviewed first-failure packet.
CUT_FIRST_RESULT_SHA256=None
CUT_REPAIR_PROOF_SHA256=None
MOVE_FIRST_LEDGER_SHA256={
    'sftp-move-action-openssh-session-001.json':'6bae1a66c3410e608625c48c07e077480b00450946d7150d45a9b74d6ca33bdf',
    'sftp-move-action-openssh-attempt-001.json':'08c500c411726474b4496749ee65b2739d55602c9f456d04953b3cfc888f0ff9',
    'sftp-move-action-openssh-attempt-002.json':'3c1e10290180cf615a84c78c90bfc222c104473ff3ead98108d18bd75e464096',
}
MOVE_SECOND_LEDGER_SHA256={
    'sftp-move-action-openssh-session-002.json':'f0cfc2f290b2299da0670993b2058445d87425c3ed52c9d219879debdf97cb05',
    'sftp-move-action-openssh-attempt-003.json':'e6c1433af26789fd376b13c1fb2d9c07b60c507d65a4e08b9b840fd3d6012215',
    'sftp-move-action-openssh-attempt-004.json':'c78eace0ee77e170f71caf8c75fb8c203213fe7720f32b4006424d31e58a0868',
}
SHIPPING_EDITOR_CASE='BBF7A983-07B4-4258-BE32-868B094BE3EB'
SHIPPING_EDITOR_ACTION='sftp-installed69-editor-smoke-20261108'
SHIPPING_EDITOR_SCOPE_SHA256='53e0ab6cdd9ccc1a3a94a8de4f1e4e284f1d395e293a3a78d1737faf105fbbbc'
SHIPPING_EDITOR_PREFLIGHT_SHA256='b8b8a19537cfd6cc45c58bb7bc647e09dcba8d3571b0699d4a46501b25665a6d'
SHIPPING_EDITOR_KINDS=['sftp-installed69-editor-openssh-session','sftp-installed69-editor-openssh-attempt']
PREVIEW_METADATA_CASE='48C9C525-687A-4498-8A1D-175CB87A343C'
PREVIEW_METADATA_ACTION='preview73-metadata-ui'
PREVIEW_METADATA_SCOPE_SHA256='be6cf82fee02c0c01f9c4b96545d36b9a36f121ddbbb2c5b7dbf1f51faeb06d6'
PREVIEW_METADATA_KINDS=['sftp-preview73-metadata-openssh-session','sftp-preview73-metadata-openssh-attempt']
PREVIEW_METADATA_SCOPE='maintenance/2026-11-09/preview73-metadata-acceptance/delegated-run-scope.md'


def move_owned_evidence(path):
    if path.resolve()!=path:raise RuntimeError('First Move evidence path redirected')
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    with os.fdopen(descriptor,'rb')as source:
        facts=os.fstat(source.fileno())
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() or facts.st_nlink!=1 or facts.st_size>65536:
            raise RuntimeError('Unsafe first Move stop evidence')
        raw=source.read(65537)
    if len(raw)>65536:raise RuntimeError('First Move evidence exceeds bound')
    return raw


def move_first_stop_evidence():
    evidence=TOOLING.parent/'traverse-development'/MOVE_FIRST_CASE/'evidence'
    envelope=json.loads(move_owned_evidence(evidence/'folder-controller-05-stop.stdout'));value=envelope.get('record')
    canonical=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
    if envelope.get('ok')is not True or type(value)is not dict or hashlib.sha256(canonical).hexdigest()!=MOVE_FIRST_STOP_SHA256 \
            or value.get('case')!=MOVE_FIRST_CASE or value.get('stage')!='stopped' or value.get('normalCleanup')is not True \
            or value.get('markedBridgeRetained')is not True or value.get('remoteActions')is not True \
            or value.get('directoryActions')is not True or value.get('moveActions')is not True \
            or value.get('sourceSHA256')!='1c59b8670027384143781a8a8bff2f3b44bd8818d0f53b13b064c2375a1afe38':
        raise RuntimeError('First Move source or cleanup evidence differs')
    proof_raw=move_owned_evidence(evidence/'runner-repair-offline.json')
    proof=json.loads(proof_raw)
    if hashlib.sha256(proof_raw).hexdigest()!=MOVE_REPAIR_OFFLINE_SHA256 or proof.get('passed')is not True \
            or proof.get('firstRuntimeCase')!=MOVE_FIRST_CASE or proof.get('firstStopRecordCanonicalSHA256')!=MOVE_FIRST_STOP_SHA256 \
            or proof.get('networkRequests')!=0 or proof.get('newServerStarts')!=0:
        raise RuntimeError('Source-only Move runner repair proof differs')
    return MOVE_FIRST_STOP_SHA256


def move_second_stop_evidence():
    move_first_stop_evidence()
    evidence=TOOLING.parent/'traverse-development'/MOVE_REPAIR_CASE/'evidence'
    envelope=json.loads(move_owned_evidence(evidence/'folder-controller-04-stop.stdout'));value=envelope.get('record')
    canonical=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
    if envelope.get('ok')is not True or type(value)is not dict or hashlib.sha256(canonical).hexdigest()!=MOVE_SECOND_STOP_SHA256 \
            or value.get('case')!=MOVE_REPAIR_CASE or value.get('stage')!='stopped' or value.get('normalCleanup')is not True \
            or value.get('markedBridgeRetained')is not True or value.get('remoteActions')is not True \
            or value.get('directoryActions')is not True or value.get('moveActions')is not True or value.get('moveRepair')is not True \
            or value.get('firstMoveStopSHA256')!=MOVE_FIRST_STOP_SHA256 \
            or value.get('sourceSHA256')!='1c59b8670027384143781a8a8bff2f3b44bd8818d0f53b13b064c2375a1afe38' \
            or value.get('runtimeScriptSHA256')!='071b441fcd84b6fb00be829748365b193f9e964f631ecfc90e1fe1e8109b5be0':
        raise RuntimeError('Second Move source or cleanup evidence differs')
    baseline_raw=move_owned_evidence(evidence/'independent-baseline.json')
    baseline=json.loads(baseline_raw)
    expected=dict(moveStage='baseline',fileMoved=False,folderMoved=False,entries=14,bytes=1048774,allBodiesVerified=True)
    if hashlib.sha256(baseline_raw).hexdigest()!=MOVE_SECOND_BASELINE_SHA256 or baseline.get('verified')!=expected:
        raise RuntimeError('Second Move baseline evidence differs')
    result_raw=move_owned_evidence(evidence/'result.json');result=json.loads(result_raw)
    if hashlib.sha256(result_raw).hexdigest()!=MOVE_SECOND_RESULT_SHA256 or result.get('passed')is not False \
            or result.get('actualSignIns')!=0 or result.get('prospectiveSignIns')!=2 \
            or result.get('independentFailureState')!=expected or result.get('cleanupVerified')is not True:
        raise RuntimeError('Second Move failure and cleanup result differs')
    native=TOOLING.parent/'traverse-development'/'284184C0-EE51-425D-8C16-E6D1A0CAF32E'/'evidence/native-auth-transfer.json'
    native_raw=move_owned_evidence(native);native_result=json.loads(native_raw)
    if hashlib.sha256(native_raw).hexdigest()!=MOVE_SECOND_NATIVE_AUTH_SHA256 or native_result.get('passed')is not False \
            or native_result.get('checkpoint')!='native-authentication' or native_result.get('line')!=176 \
            or native_result.get('keychainCalls')!=0 or native_result.get('localStorageFailure')!='none':
        raise RuntimeError('Second Move authentication failure evidence differs')
    return MOVE_SECOND_STOP_SHA256


def move_third_stop_evidence():
    move_second_stop_evidence()
    evidence=TOOLING.parent/'traverse-development'/MOVE_CONTINUATION_CASE/'evidence'
    envelope=json.loads(move_owned_evidence(evidence/'folder-controller-04-stop.stdout'));value=envelope.get('record')
    canonical=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
    if envelope.get('ok')is not True or type(value)is not dict or hashlib.sha256(canonical).hexdigest()!=MOVE_THIRD_STOP_SHA256 \
            or value.get('case')!=MOVE_CONTINUATION_CASE or value.get('stage')!='stopped' \
            or value.get('normalCleanup')is not True or value.get('markedBridgeRetained')is not True \
            or value.get('moveActions')is not True or value.get('moveContinuation')is not True \
            or value.get('secondMoveStopSHA256')!=MOVE_SECOND_STOP_SHA256:
        raise RuntimeError('Third Move source or cleanup evidence differs')
    exported=json.loads(move_owned_evidence(evidence/'folder-controller-03-export.stdout')).get('record',{}).get('generatedExport')
    if type(exported)is not dict or hashlib.sha256(json.dumps(exported,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=MOVE_THIRD_EXPORT_SHA256 \
            or exported.get('bytes')!=1048774:
        raise RuntimeError('Third Move final inventory differs')
    raw=move_owned_evidence(evidence/'result.json');result=json.loads(raw)
    if hashlib.sha256(raw).hexdigest()!=MOVE_THIRD_RESULT_SHA256 or result.get('passed')is not True \
            or result.get('cleanupVerified')is not True or result.get('actualSignIns')!=1 \
            or result.get('prospectiveSignIns')!=1 or result.get('cumulativeRuntimeOrdinal')!=3:
        raise RuntimeError('Third Move result or cleanup differs')
    return MOVE_THIRD_STOP_SHA256


def cut_first_failure_evidence():
    if type(CUT_FIRST_RESULT_SHA256)is not str or type(CUT_REPAIR_PROOF_SHA256)is not str \
            or any(len(value)!=64 or any(ch not in '0123456789abcdef'for ch in value)
                   for value in (CUT_FIRST_RESULT_SHA256,CUT_REPAIR_PROOF_SHA256)):
        raise RuntimeError('First Cut failure and repair proof not yet bound')
    evidence=TOOLING.parent/'traverse-development'/CUT_FIRST_CASE/'evidence'
    raw=move_owned_evidence(evidence/'result.json');result=json.loads(raw)
    proof_raw=move_owned_evidence(evidence/'cut-repair-offline.json');proof=json.loads(proof_raw)
    if hashlib.sha256(raw).hexdigest()!=CUT_FIRST_RESULT_SHA256 or result.get('passed')is not False \
            or result.get('cleanupVerified')is not True or result.get('parentCase')!=CUT_FIRST_CASE \
            or hashlib.sha256(proof_raw).hexdigest()!=CUT_REPAIR_PROOF_SHA256 \
            or proof.get('passed')is not True or proof.get('firstRuntimeCase')!=CUT_FIRST_CASE \
            or proof.get('networkRequests')!=0 or proof.get('newServerStarts')!=0:
        raise RuntimeError('First Cut failure or offline repair proof differs')
    return CUT_REPAIR_PROOF_SHA256


def permission_denial_history(folder):
    for name,expected in PERMISSION_DENIAL_LEDGER_SHA256.items():
        if hashlib.sha256(move_owned_evidence(folder/name)).hexdigest()!=expected:
            raise RuntimeError('Spent permission-denial ledger receipt differs')
    for case,items in PERMISSION_DENIAL_VERDICTS_SHA256.items():
        evidence=TOOLING.parent/'traverse-development'/case/'evidence'
        for name,expected in items.items():
            if hashlib.sha256(move_owned_evidence(evidence/name)).hexdigest()!=expected:
                raise RuntimeError('Earlier permission-denial verdict was changed')


def permission_first_failure_evidence(folder):
    for name,expected in PERMISSION_FIRST_LEDGER_SHA256.items():
        if hashlib.sha256(move_owned_evidence(folder/name)).hexdigest()!=expected:
            raise RuntimeError('First permission completion admission changed')
    evidence=TOOLING.parent/'traverse-development'/PERMISSION_COMPLETION_CASE/'evidence'
    raw=move_owned_evidence(evidence/'result.json');result=json.loads(raw)
    if hashlib.sha256(raw).hexdigest()!=PERMISSION_FIRST_RESULT_SHA256 \
            or result.get('passed')is not False or result.get('errorType')!='FileExistsError' \
            or result.get('prospectiveSignIns')!=1 or result.get('cleanupVerified')is not True:
        raise RuntimeError('First permission completion failure verdict changed')
    raw=move_owned_evidence(evidence/'independent-exclusive-upload-export.stdout')
    baseline=json.loads(raw).get('record',{}).get('generatedExport')
    if hashlib.sha256(raw).hexdigest()!=PERMISSION_FIRST_BASELINE_SHA256 \
            or type(baseline)is not dict or baseline.get('authenticationCount')!=0 \
            or baseline.get('deniedPathAbsent')is not True \
            or [row.get('name')for row in baseline.get('files',[])]!=['Requested.bin']:
        raise RuntimeError('First permission baseline, not final export, changed')
    raw=move_owned_evidence(evidence/'independent-exclusive-upload-stop.stdout')
    stopped=json.loads(raw).get('record')
    if type(stopped)is not dict \
            or hashlib.sha256(json.dumps(stopped,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=PERMISSION_FIRST_STOP_SHA256 \
            or stopped.get('stage')!='stopped' or stopped.get('normalCleanup')is not True:
        raise RuntimeError('First permission completion stop changed')
    native=TOOLING.parent/'traverse-development'/'A2DE059E-5D69-48E8-810A-F26232CA3B44'/'evidence/native-auth-transfer.json'
    raw=move_owned_evidence(native);value=json.loads(raw)
    continuation=value.get('permissionContinuation')
    if hashlib.sha256(raw).hexdigest()!=PERMISSION_FIRST_NATIVE_SHA256 \
            or value.get('passed')is not True or value.get('actualConnections')!=1 \
            or value.get('actualExit')is not True or value.get('catalogRemoved')is not True \
            or type(continuation)is not dict or continuation.get('coldOutcomes')!=3 \
            or continuation.get('definiteCreateDenial')is not True \
            or continuation.get('uploadVerified')is not True \
            or continuation.get('newFileAndNativeEditor')is not True:
        raise RuntimeError('First permission native continuation evidence changed')
    return PERMISSION_FIRST_STOP_SHA256


def record(kind, case, label, *, repair=False, continuation=False):
    routed_file_kinds=['routed-upload-loopback','routed-upload-native-loopback','routed-upload-openssh-session','routed-upload-openssh-attempt','routed-upload-f-compat-session','routed-upload-f-compat-attempt']
    routed_folder_kinds=['routed-folder-loopback','routed-folder-native-loopback','routed-folder-openssh-session','routed-folder-openssh-attempt']
    routed_action_kinds=['routed-action-openssh-session','routed-action-openssh-attempt']
    routed_repair_action_kinds=['routed-repair-action-openssh-session','routed-repair-action-openssh-attempt']
    directory_action_kinds=['sftp-directory-action-openssh-session','sftp-directory-action-openssh-attempt']
    directory_rename_kinds=['sftp-directory-rename-openssh-session','sftp-directory-rename-openssh-attempt']
    move_action_kinds=['sftp-move-action-openssh-session','sftp-move-action-openssh-attempt']
    cut_action_kinds=['sftp-cut-action-openssh-session','sftp-cut-action-openssh-attempt']
    exclusive_denial_kinds=['exclusive-denial-openssh-session','exclusive-denial-openssh-attempt']
    permission_completion_kinds=['sftp-permission-completion-openssh-session','sftp-permission-completion-openssh-attempt']
    if kind in PREVIEW_METADATA_KINDS:
        expected=TOOLING.parent/'traverse-development'/PREVIEW_METADATA_CASE
        if case!=expected or case.resolve()!=case or repair or continuation:
            raise RuntimeError('Exact one-runtime Preview metadata case required')
        marker=json.loads(move_owned_evidence(case/'reservation.json'))
        if marker!={'packet':'traverse-development-v1','action':PREVIEW_METADATA_ACTION,
                    'master':'887B77DA-8583-42B1-9055-32B91A60641F'} \
                or hashlib.sha256(move_owned_evidence(TOOLING.parent/PREVIEW_METADATA_SCOPE)).hexdigest()!=PREVIEW_METADATA_SCOPE_SHA256:
            raise RuntimeError('Exact delegated Preview metadata scope changed')
    if kind in SHIPPING_EDITOR_KINDS:
        expected=TOOLING.parent/'traverse-development'/SHIPPING_EDITOR_CASE
        if case!=expected or case.resolve()!=case:
            raise RuntimeError('Exact installed69 editor case required')
        marker=json.loads(move_owned_evidence(case/'reservation.json'))
        if marker!={'packet':'traverse-development-v1','action':SHIPPING_EDITOR_ACTION,
                    'master':'887B77DA-8583-42B1-9055-32B91A60641F'}:
            raise RuntimeError('Exact installed69 editor reservation required')
        scope=TOOLING.parent/'maintenance/2026-11-08/installed69-sftp-editor-scope.md'
        preflight=case/'evidence/shipping-editor-preflight.json'
        if hashlib.sha256(move_owned_evidence(scope)).hexdigest()!=SHIPPING_EDITOR_SCOPE_SHA256 \
                or hashlib.sha256(move_owned_evidence(preflight)).hexdigest()!=SHIPPING_EDITOR_PREFLIGHT_SHA256:
            raise RuntimeError('Installed69 editor scope or read-only preflight differs')
    if kind in routed_folder_kinds:
        marker=json.loads((case/'reservation.json').read_bytes())
        if not marker.get('action','').startswith('routed-folder-upload-'):raise RuntimeError('J packet reservation required')
    if kind in routed_action_kinds:
        marker=json.loads((case/'reservation.json').read_bytes())
        if not marker.get('action','').startswith('sftp-routed-action-'):raise RuntimeError('P action reservation required')
    if kind in routed_repair_action_kinds:
        marker=json.loads((case/'reservation.json').read_bytes())
        if not marker.get('action','').startswith('sftp-routed-repair-action-'):
            raise RuntimeError('routed action repair reservation required')
    if kind in directory_action_kinds+directory_rename_kinds+move_action_kinds+cut_action_kinds+permission_completion_kinds:
        if not case.is_relative_to(TOOLING.parent) or case.resolve()!=case:
            raise RuntimeError('Directory-action case must be an owned repository fixture')
        reservation=case/'reservation.json';facts=reservation.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=1 or facts.st_uid!=os.getuid() or facts.st_size>4096:
            raise RuntimeError('Unsafe directory-action reservation marker')
        marker=json.loads(reservation.read_bytes())
        expected=SFTP_DIRECTORY_ACTION_RESERVATION if kind in directory_action_kinds else SFTP_DIRECTORY_RENAME_RESERVATION if kind in directory_rename_kinds else SFTP_MOVE_ACTION_RESERVATION if kind in move_action_kinds else SFTP_CUT_ACTION_RESERVATION if kind in cut_action_kinds else SFTP_PERMISSION_REPAIR_RESERVATION if case.name==PERMISSION_REPAIR_CASE else SFTP_PERMISSION_COMPLETION_RESERVATION
        if type(marker)is not dict or marker.get('action')!=expected:
            raise RuntimeError('Exact directory-action reservation required')
        if kind in cut_action_kinds:
            owner=TOOLING.parent/'maintenance/2026-11-08/remote-cut-owner-approval.md'
            if hashlib.sha256(move_owned_evidence(owner)).hexdigest()!=CUT_OWNER_SCOPE_SHA256:
                raise RuntimeError('Cut owner-scope record changed')
        if kind in permission_completion_kinds:
            permission_repair=case.name==PERMISSION_REPAIR_CASE
            owner=TOOLING.parent/'maintenance/2026-11-08'/('sftp-permission-repair-owner-scope.md'if permission_repair else'sftp-permission-owner-approval.md')
            expected=PERMISSION_REPAIR_SCOPE_SHA256 if permission_repair else PERMISSION_COMPLETION_SCOPE_SHA256
            if case.name not in (PERMISSION_COMPLETION_CASE,PERMISSION_REPAIR_CASE) \
                    or repair is not permission_repair \
                    or hashlib.sha256(move_owned_evidence(owner)).hexdigest()!=expected:
                raise RuntimeError('Exact permission completion owner scope changed')
    if type(repair)is not bool or repair and kind not in routed_file_kinds+routed_folder_kinds+routed_repair_action_kinds+exclusive_denial_kinds+move_action_kinds+cut_action_kinds+permission_completion_kinds \
       or kind in routed_repair_action_kinds and not repair:
        raise RuntimeError('Typed routed repair scope required')
    if type(continuation)is not bool or continuation and(kind not in move_action_kinds or repair):
        raise RuntimeError('Typed final Move continuation scope required')
    if kind not in routed_file_kinds+routed_folder_kinds+routed_action_kinds+routed_repair_action_kinds+directory_action_kinds+directory_rename_kinds+move_action_kinds+cut_action_kinds+exclusive_denial_kinds+permission_completion_kinds+SHIPPING_EDITOR_KINDS+PREVIEW_METADATA_KINDS+['loopback', 'route-loopback', 'transfer-loopback', 'workspace-loopback', 'workspace-smb-session', 'workspace-smb-attempt', 'transfer-openssh-session', 'transfer-openssh-attempt', 'folder-loopback', 'folder-openssh-session', 'folder-openssh-attempt', 'routed-download-loopback', 'routed-download-openssh-session', 'routed-download-openssh-attempt', 'exclusive-upload-loopback', 'exclusive-upload-openssh-session', 'exclusive-upload-openssh-attempt', 'folder-upload-openssh-session', 'folder-upload-openssh-attempt', 'sftp-action-openssh-session', 'sftp-action-openssh-attempt', 'openssh-session', 'openssh-attempt', 'directory-recovery-loopback', 'drop-batch-openssh-session', 'drop-batch-openssh-attempt', 'drop-batch-completion-session', 'drop-batch-completion-attempt', 'drop-gate-shell-session', 'drop-gate-shell-attempt', 'drop-disconnect-completion-session', 'drop-disconnect-completion-attempt'] or str(uuid.UUID(case.name)).upper() != case.name:
        raise RuntimeError('Generated SSH attempt identity')
    folder = directory(TOOLING / 'network-accounting')
    lock = os.open(folder / 'owner.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # One additional, offline-diagnosed PAM-fixture repair runtime under
        # the extended owner's engineering delegation. Byte/attempt caps stay.
        # B11 saved-route storage/native packet has its own new peer allowance;
        # prior profile/authentication attempts remain consumed, never reset.
        limits = {'loopback': 96, 'route-loopback': 32, 'openssh-session': 4, 'openssh-attempt': 24,
                  'transfer-loopback': 16, 'transfer-openssh-session': 2, 'transfer-openssh-attempt': 8,
                  'workspace-loopback': 16, 'workspace-smb-session': 1, 'workspace-smb-attempt': 4,
                  # Separate24October folder packet under delegated authority;
                  # no previous attempt/runtime counter is reset or borrowed.
                  # Four finite source-proven native completion/repair attempts
                  # added at13:31UTC; original receipts remain consumed.
                  'folder-loopback': 28, 'folder-openssh-session': 2, 'folder-openssh-attempt': 8,
                  # Separate one-hop Download composition; every connection
                  # leg is admitted before the generated fixture starts.
                  # Eight supplemental prospective peer slots for native Stop,
                  # activation and two source-proven fixture repairs. Earlier
                  # failed native admissions remain consumed and preserved.
                  'routed-download-loopback': 32, 'routed-download-openssh-session': 2, 'routed-download-openssh-attempt': 6,
                  # Exclusive-final publication is a new capability packet;
                  # the second runtime is only for an offline-proven repair.
                  'exclusive-upload-loopback': 16, 'exclusive-upload-openssh-session': 2, 'exclusive-upload-openssh-attempt': 4,
                  # Separate first-OPEN denial continuation: the old exclusive
                  # receipts stay spent. Two new sessions/four sign-ins maximum;
                  # only an offline-proven repair may consume the second.
                  'exclusive-denial-openssh-session': 2, 'exclusive-denial-openssh-attempt': 4,
                  # First completion stays spent. One exact final-inventory
                  # repair server adds one prospective sign-in, no old credit.
                  'sftp-permission-completion-openssh-session': 2,
                  'sftp-permission-completion-openssh-attempt': 3,
                  # H has separate prospective admission; no prior counter resets.
                  'folder-upload-openssh-session': 4, 'folder-upload-openssh-attempt': 24,
                  # Prospectively authorized SFTP O/P action qualification.
                  # New marked sessions and authentication attempts only.
                  'sftp-action-openssh-session': 2, 'sftp-action-openssh-attempt': 4,
                  # Release21 empty-directory Delete uses one fresh generated
                  # action runtime and at most two sign-ins. Earlier action
                  # receipts remain spent and are never borrowed or reset.
                  'sftp-directory-action-openssh-session': 1, 'sftp-directory-action-openssh-attempt': 2,
                  # Prospective separate directory-Rename case. Release21
                  # kinds stay capped at 1/2; this case has one new runtime
                  # and two new sign-ins after the old receipts are present.
                  'sftp-directory-rename-openssh-session': 1, 'sftp-directory-rename-openssh-attempt': 2,
                  # First and second Move lifetimes and four sign-ins stay
                  # consumed. One final source-bound session/sign-in is separate.
                  'sftp-move-action-openssh-session': 3, 'sftp-move-action-openssh-attempt': 5,
                  # Owner-scoped Cut/Paste uses two fresh retained-bridge
                  # lifetimes and at most two prospective sign-ins each.
                  'sftp-cut-action-openssh-session': 2, 'sftp-cut-action-openssh-attempt': 4,
                  # One distinct guarded-in-place P action runtime, with two
                  # two-peer route admissions at most. No old route credit moves.
                  'routed-action-openssh-session': 1, 'routed-action-openssh-attempt': 4,
                  # One separately proved P repair lifetime; both route peers
                  # are charged prospectively and old P/J counters stay spent.
                  'routed-repair-action-openssh-session': 1, 'routed-repair-action-openssh-attempt': 2,
                  # New25October request-scoped directory failure regression.
                  # Generated in-process Rust peers; not an OpenSSH runtime.
                  'directory-recovery-loopback': 16,
                  'drop-batch-openssh-session': 5, 'drop-batch-openssh-attempt': 8,
                  # Fixed-prefix completion after the read-only capacity audit.
                  # One new runtime/four attempts; no old ledger is reset.
                  'drop-batch-completion-session': 1, 'drop-batch-completion-attempt': 4,
                  'drop-gate-shell-session': 2, 'drop-gate-shell-attempt': 4,
                  'drop-disconnect-completion-session': 1, 'drop-disconnect-completion-attempt': 2,
                  # Exact installed69 editor case: one new lifetime and one
                  # prospective sign-in. All earlier receipts stay consumed.
                  SHIPPING_EDITOR_KINDS[0]: 1, SHIPPING_EDITOR_KINDS[1]: 1,
                  # Preview73 metadata uses the retained image/bridge in one
                  # distinct read-only runtime. No earlier allowance moves.
                  PREVIEW_METADATA_KINDS[0]: 1, PREVIEW_METADATA_KINDS[1]: 2,
                  # New15-hour packet: count both peers before connection;
                  # earlier exhausted routes/downloads/uploads stay consumed.
                  'routed-upload-loopback':24,'routed-upload-native-loopback':6,'routed-upload-openssh-session':2,'routed-upload-openssh-attempt':8,'routed-upload-f-compat-session':1,'routed-upload-f-compat-attempt':2,
                  # Distinct J folder-through-route packet, prospectively reviewed.
                  'routed-folder-loopback':20,'routed-folder-native-loopback':14,'routed-folder-openssh-session':2,'routed-folder-openssh-attempt':10}
        existing = sorted(folder.glob('*.json')); counts = {k: 0 for k in limits}; rename_session_case=None; move_sessions={}; cut_sessions={};cut_attempts={};denial_sessions={};permission_sessions={}
        for path in existing:
            facts = path.lstat()
            if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or facts.st_uid != os.getuid() or facts.st_size > 4096:
                raise RuntimeError('Unsafe SSH attempt receipt')
            value = json.loads(path.read_bytes())
            if value.get('packet') != 'ssh-profiles-network-v1' or value.get('kind') not in limits:
                raise RuntimeError('SSH attempt receipt mismatch')
            if value['kind'] in SHIPPING_EDITOR_KINDS:
                expected_kind=value['kind']
                expected_label='one-installed69-connect-open-save' if expected_kind==SHIPPING_EDITOR_KINDS[0] else 'native-server-prompts'
                if path.name!=expected_kind+'-001.json' or value.get('ordinal')!=1 \
                        or value.get('case')!=SHIPPING_EDITOR_CASE or value.get('label')!=expected_label \
                        or value.get('ownerScopeSHA256')!=SHIPPING_EDITOR_SCOPE_SHA256 \
                        or value.get('preflightSHA256')!=SHIPPING_EDITOR_PREFLIGHT_SHA256 \
                        or value.get('reservationAction')!=SHIPPING_EDITOR_ACTION:
                    raise RuntimeError('Installed69 editor receipt differs')
            if value['kind'] in PREVIEW_METADATA_KINDS:
                session_kind=value['kind']==PREVIEW_METADATA_KINDS[0]
                ordinal=value.get('ordinal')
                expected_label='one-read-only-metadata-runtime' if session_kind else 'native-server-prompts'
                if type(ordinal)is not int or ordinal not in ((1,)if session_kind else(1,2)) \
                        or path.name!=value['kind']+'-'+str(ordinal).zfill(3)+'.json' \
                        or set(value)!={'packet','kind','ordinal','case','label','admittedBeforeConnection',
                                        'limits','ownerScopeSHA256','reservationAction','priorMoveStopSHA256',
                                        'metadataOnly'} \
                        or value.get('case')!=PREVIEW_METADATA_CASE or value.get('label')!=expected_label \
                        or value.get('admittedBeforeConnection')is not True \
                        or value.get('limits')!=limits or value.get('metadataOnly')is not True \
                        or value.get('ownerScopeSHA256')!=PREVIEW_METADATA_SCOPE_SHA256 \
                        or value.get('reservationAction')!=PREVIEW_METADATA_ACTION \
                        or value.get('priorMoveStopSHA256')!=MOVE_THIRD_STOP_SHA256:
                    raise RuntimeError('Preview metadata receipt identity differs')
            counts[value['kind']] += 1
            if value['kind'] in move_action_kinds:
                ordinal=value.get('ordinal')
                allowed_ordinals=(1,2,3)if value['kind']==move_action_kinds[0]else(1,2,3,4,5)
                if type(ordinal)is not int or ordinal not in allowed_ordinals:
                    raise RuntimeError('Move ledger ordinal differs')
                expected_name=value['kind']+'-'+str(ordinal).zfill(3)+'.json'
                first=ordinal==1 if value['kind']==move_action_kinds[0] else ordinal<=2
                second=ordinal==2 if value['kind']==move_action_kinds[0]else ordinal in (3,4)
                expected_case=MOVE_FIRST_CASE if first else MOVE_REPAIR_CASE if second else MOVE_CONTINUATION_CASE
                if path.name!=expected_name or value.get('case')!=expected_case \
                        or value.get('offlineProvenRepairScope',False)is not second \
                        or value.get('offlineProvenContinuationScope',False)is not(not first and not second):
                    raise RuntimeError('Move lifetime identity or scope differs')
                if first:
                    if hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=MOVE_FIRST_LEDGER_SHA256[path.name]:
                        raise RuntimeError('First Move ledger evidence differs')
                elif second:
                    if hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=MOVE_SECOND_LEDGER_SHA256[path.name] \
                            or value.get('firstMoveStopSHA256')!=MOVE_FIRST_STOP_SHA256:
                        raise RuntimeError('Second Move ledger evidence differs')
                elif value.get('firstMoveStopSHA256')!=MOVE_FIRST_STOP_SHA256 or value.get('secondMoveStopSHA256')!=MOVE_SECOND_STOP_SHA256 \
                        or hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()!=MOVE_THIRD_LEDGER_SHA256[path.name]:
                    raise RuntimeError('Final Move source seals or receipt differ')
            if value['kind'] in cut_action_kinds:
                ordinal=value.get('ordinal');session_kind=value['kind']==cut_action_kinds[0]
                if type(ordinal)is not int or ordinal not in ((1,2)if session_kind else(1,2,3,4)) \
                        or path.name!=value['kind']+'-'+str(ordinal).zfill(3)+'.json' \
                        or value.get('case')not in (CUT_FIRST_CASE,CUT_REPAIR_CASE) \
                        or value.get('offlineProvenRepairScope')is not(value['case']==CUT_REPAIR_CASE) \
                        or value.get('cutOwnerScopeSHA256')!=CUT_OWNER_SCOPE_SHA256 \
                        or value.get('priorMoveStopSHA256')!=MOVE_THIRD_STOP_SHA256 \
                        or value.get('priorMoveUsage')!={'sessions':3,'attempts':5}:
                    raise RuntimeError('Cut receipt identity or old Move lineage differs')
                if session_kind:
                    if value['case']!=(CUT_FIRST_CASE if ordinal==1 else CUT_REPAIR_CASE) \
                            or type(value.get('cutAttemptBase'))is not int \
                            or ordinal==1 and value['cutAttemptBase']!=0 \
                            or ordinal==2 and not 0<=value['cutAttemptBase']<=2:
                        raise RuntimeError('Cut runtime or attempt base differs')
                    cut_sessions[ordinal]=value
                else:cut_attempts[ordinal]=value
            if value['kind']==directory_rename_kinds[0]:
                if path.name!=directory_rename_kinds[0]+'-001.json' or value.get('ordinal')!=1:
                    raise RuntimeError('Directory-Rename session receipt differs')
                rename_session_case=value.get('case')
            if value['kind']==move_action_kinds[0]:
                move_sessions[value['ordinal']]=value
            if value['kind']==exclusive_denial_kinds[0]:
                ordinal=value.get('ordinal')
                if ordinal not in (1,2) or path.name!=exclusive_denial_kinds[0]+'-'+str(ordinal).zfill(3)+'.json' \
                   or type(value.get('denialAttemptBase')) is not int or value['denialAttemptBase']<0:
                    raise RuntimeError('First-OPEN denial session receipt differs')
                denial_sessions[ordinal]=value
            if value['kind'] in permission_completion_kinds:
                ordinal=value.get('ordinal');session_kind=value['kind']==permission_completion_kinds[0]
                if type(ordinal)is not int or ordinal not in ((1,2)if session_kind else(1,2,3)) \
                        or path.name!=value['kind']+'-'+str(ordinal).zfill(3)+'.json' \
                        or value.get('case')!=(PERMISSION_COMPLETION_CASE if ordinal==1 else PERMISSION_REPAIR_CASE) \
                        or value.get('permissionOwnerScopeSHA256')!=(PERMISSION_COMPLETION_SCOPE_SHA256 if ordinal==1 else PERMISSION_REPAIR_SCOPE_SHA256) \
                        or value.get('priorDenialUsage')!={'sessions':2,'attempts':4} \
                        or value.get('offlineProvenRepairScope',False)is not(ordinal!=1):
                    raise RuntimeError('Permission completion receipt or spent denial usage differs')
                if session_kind:
                    if value.get('permissionAttemptBase')!=(0 if ordinal==1 else 1):raise RuntimeError('Permission session attempt base differs')
                    permission_sessions[ordinal]=value
                if ordinal!=1 and (value.get('firstPermissionResultSHA256')!=PERMISSION_FIRST_RESULT_SHA256 \
                        or value.get('firstPermissionStopSHA256')!=PERMISSION_FIRST_STOP_SHA256 \
                        or value.get('firstPermissionNativeSHA256')!=PERMISSION_FIRST_NATIVE_SHA256):
                    raise RuntimeError('Permission repair predecessor seal differs')
        if set(cut_sessions)!=set(range(1,counts[cut_action_kinds[0]]+1)) \
                or set(cut_attempts)!=set(range(1,counts[cut_action_kinds[1]]+1)) \
                or cut_attempts and 1 not in cut_sessions:
            raise RuntimeError('Cut receipt ordinal sequence differs')
        split=cut_sessions[2]['cutAttemptBase']if 2 in cut_sessions else counts[cut_action_kinds[1]]
        if split>2 or counts[cut_action_kinds[1]]-split>2 \
                or any(value.get('case')!=(CUT_FIRST_CASE if ordinal<=split else CUT_REPAIR_CASE)
                       for ordinal,value in cut_attempts.items()):
            raise RuntimeError('Cut per-runtime prospective sign-in bound differs')
        if kind in directory_rename_kinds:
            if counts[directory_action_kinds[0]]!=1 or counts[directory_action_kinds[1]]!=2:
                raise RuntimeError('Release21 directory-action receipts must remain consumed')
            if (kind==directory_rename_kinds[0] and counts[directory_rename_kinds[1]]!=0) or (kind==directory_rename_kinds[1] and rename_session_case!=case.name):
                raise RuntimeError('One exact directory-Rename case must own the sign-ins')
        if kind in move_action_kinds:
            # Release21 used both sign-ins; the accepted directory-Rename
            # run used one and left its second finite slot unused.
            if counts[directory_action_kinds[0]]!=1 or counts[directory_action_kinds[1]]!=2 or counts[directory_rename_kinds[0]]!=1 or counts[directory_rename_kinds[1]]!=1:
                raise RuntimeError('Exact prior directory-action ledger history required')
            if continuation:
                if repair or case.name!=MOVE_CONTINUATION_CASE or counts[move_action_kinds[0]]!=(2 if kind==move_action_kinds[0]else 3) \
                        or counts[move_action_kinds[1]]!=4 or 1 not in move_sessions or 2 not in move_sessions \
                        or kind==move_action_kinds[1]and 3 not in move_sessions:
                    raise RuntimeError('One exact final Move lifetime and sign-in required')
                move_second_stop_evidence()
            else:
                if not repair or case.name!=MOVE_REPAIR_CASE or counts[move_action_kinds[0]]!=(1 if kind==move_action_kinds[0]else 2) \
                        or kind==move_action_kinds[0]and counts[move_action_kinds[1]]!=2 \
                        or kind==move_action_kinds[1]and counts[move_action_kinds[1]] not in (2,3) \
                        or 1 not in move_sessions or kind==move_action_kinds[1]and 2 not in move_sessions:
                    raise RuntimeError('Exact second Move lifetime and two sign-ins required')
                move_first_stop_evidence()
        if kind in cut_action_kinds:
            if counts[move_action_kinds[0]]!=3 or counts[move_action_kinds[1]]!=5:
                raise RuntimeError('Old Move receipts must remain fully consumed')
            move_third_stop_evidence()
            sessions=counts[cut_action_kinds[0]]
            if kind==cut_action_kinds[0]:
                if repair!=(sessions==1) or sessions==0 and counts[cut_action_kinds[1]]!=0 \
                        or sessions==1 and not 0<=counts[cut_action_kinds[1]]<=2 \
                        or case.name!=(CUT_REPAIR_CASE if repair else CUT_FIRST_CASE):
                    raise RuntimeError('Exact first Cut or offline-proven repair lifetime required')
                if repair:cut_first_failure_evidence()
            elif sessions not in (1,2) or case.name!=cut_sessions[sessions]['case'] \
                    or repair!=(sessions==2) \
                    or counts[kind]-cut_sessions[sessions]['cutAttemptBase']>=2:
                raise RuntimeError('Cut prospective sign-in outside its owned lifetime')
        if kind in exclusive_denial_kinds:
            sessions=counts[exclusive_denial_kinds[0]]
            if counts['exclusive-upload-openssh-session']<1 or counts['exclusive-upload-openssh-attempt']<2:
                raise RuntimeError('Consumed exclusive-upload history must remain recorded')
            if repair!=(sessions==1 if kind==exclusive_denial_kinds[0] else sessions==2):
                raise RuntimeError('First-OPEN denial second lifetime requires offline repair')
            if kind==exclusive_denial_kinds[1] and sessions not in (1,2):
                raise RuntimeError('First-OPEN denial sign-in requires its recorded runtime')
            if kind==exclusive_denial_kinds[1]:
                base=denial_sessions[sessions]['denialAttemptBase']
                if counts[kind]<base or counts[kind]-base>=2:
                    raise RuntimeError('First-OPEN denial lifetime sign-in cap')
        if kind in permission_completion_kinds:
            if continuation or counts['exclusive-upload-openssh-session']!=1 \
                    or counts['exclusive-upload-openssh-attempt']!=2 \
                    or counts[exclusive_denial_kinds[0]]!=2 or counts[exclusive_denial_kinds[1]]!=4:
                raise RuntimeError('Exact spent exclusive and denial histories required')
            permission_denial_history(folder)
            if kind==permission_completion_kinds[0]:
                if repair:
                    if counts[kind]!=1 or counts[permission_completion_kinds[1]]!=1 \
                            or 1 not in permission_sessions or case.name!=PERMISSION_REPAIR_CASE:
                        raise RuntimeError('Exactly one failed completion before one repair')
                    permission_first_failure_evidence(folder)
                elif counts[kind]!=0 or counts[permission_completion_kinds[1]]!=0 \
                        or case.name!=PERMISSION_COMPLETION_CASE:
                    raise RuntimeError('Exact first permission completion server only')
            else:
                sessions=counts[permission_completion_kinds[0]]
                if sessions not in (1,2) or sessions not in permission_sessions \
                        or repair is not(sessions==2) or case.name!=permission_sessions[sessions]['case'] \
                        or counts[kind]-permission_sessions[sessions]['permissionAttemptBase']>=(1 if repair else 2):
                    raise RuntimeError('Permission sign-in outside its owned server')
                if repair:permission_first_failure_evidence(folder)
        if kind in SHIPPING_EDITOR_KINDS:
            expected_label='one-installed69-connect-open-save' if kind==SHIPPING_EDITOR_KINDS[0] else 'native-server-prompts'
            if label!=expected_label or (kind==SHIPPING_EDITOR_KINDS[0] and counts[SHIPPING_EDITOR_KINDS[1]]!=0) \
                    or (kind==SHIPPING_EDITOR_KINDS[1] and counts[SHIPPING_EDITOR_KINDS[0]]!=1):
                raise RuntimeError('One exact installed69 editor lifetime and sign-in required')
        if kind in PREVIEW_METADATA_KINDS:
            if continuation or repair or counts[move_action_kinds[0]]!=3 or counts[move_action_kinds[1]]!=5 \
                    or counts[cut_action_kinds[0]]!=1 or counts[cut_action_kinds[1]]!=1 \
                    or counts[permission_completion_kinds[0]]!=2 or counts[permission_completion_kinds[1]]!=2 \
                    or counts[SHIPPING_EDITOR_KINDS[0]]!=1 or counts[SHIPPING_EDITOR_KINDS[1]]!=1:
                raise RuntimeError('Spent Move, Cut, permission and editor history required')
            if kind==PREVIEW_METADATA_KINDS[0]:
                if label!='one-read-only-metadata-runtime' or counts[kind]!=0 \
                        or counts[PREVIEW_METADATA_KINDS[1]]!=0:
                    raise RuntimeError('One new Preview metadata runtime only')
            else:
                if label!='native-server-prompts' or counts[PREVIEW_METADATA_KINDS[0]]!=1 \
                        or counts[kind]>=2:
                    raise RuntimeError('Preview metadata sign-in outside its runtime')
                if counts[kind]==1:
                    first=folder/(kind+'-001.json')
                    session=folder/(PREVIEW_METADATA_KINDS[0]+'-001.json')
                    try:
                        diagnosis=json.loads(move_owned_evidence(
                            case/'evidence/preview73-metadata-definite-input-failure.json'))
                    except (OSError,ValueError,RuntimeError):
                        raise RuntimeError('Second metadata sign-in needs reviewed definite input failure') from None
                    expected={'packet':'preview73-metadata-definite-input-failure-v1',
                              'case':PREVIEW_METADATA_CASE,'ownerScopeSHA256':PREVIEW_METADATA_SCOPE_SHA256,
                              'firstAttemptReceiptSHA256':hashlib.sha256(first.read_bytes()).hexdigest(),
                              'sessionReceiptSHA256':hashlib.sha256(session.read_bytes()).hexdigest(),
                              'definiteInputFailure':True,'uncertainState':False,'sameRuntime':True}
                    if diagnosis!=expected:
                        raise RuntimeError('Second metadata sign-in needs definite same-runtime input failure')
        reserved={'routed-upload-loopback':4,'routed-upload-native-loopback':2,'routed-upload-openssh-attempt':2,'routed-folder-loopback':2}.get(kind,0)
        if reserved and not repair and counts[kind]>=limits[kind]-reserved:
            raise RuntimeError('Final routed-file slots reserved for an offline-proven repair')
        if counts[kind] >= limits[kind]:
            raise RuntimeError('New SSH profile allowance exhausted; old allowances stay consumed')
        ordinal = counts[kind] + 1; destination = folder / (kind + '-' + str(ordinal).zfill(3) + '.json')
        value = {'packet': 'ssh-profiles-network-v1', 'kind': kind, 'ordinal': ordinal, 'case': case.name, 'label': label,
                 'admittedBeforeConnection': True, 'limits': limits}
        if kind in routed_file_kinds+routed_folder_kinds+routed_repair_action_kinds+exclusive_denial_kinds+move_action_kinds+cut_action_kinds:value['offlineProvenRepairScope']=repair
        if kind in move_action_kinds:value['offlineProvenContinuationScope']=continuation
        if kind in exclusive_denial_kinds:value['priorExclusiveUsage']={'sessions':counts['exclusive-upload-openssh-session'],'attempts':counts['exclusive-upload-openssh-attempt']}
        if kind in move_action_kinds:value['priorDirectoryUsage']={'actionSessions':counts[directory_action_kinds[0]],'actionAttempts':counts[directory_action_kinds[1]],'renameSessions':counts[directory_rename_kinds[0]],'renameAttempts':counts[directory_rename_kinds[1]]}
        if kind in move_action_kinds:value['firstMoveStopSHA256']=MOVE_FIRST_STOP_SHA256;value['priorMoveUsage']={'sessions':counts[move_action_kinds[0]],'attempts':counts[move_action_kinds[1]]}
        if kind in move_action_kinds and continuation:value['secondMoveStopSHA256']=MOVE_SECOND_STOP_SHA256
        if kind in SHIPPING_EDITOR_KINDS:
            value['ownerScopeSHA256']=SHIPPING_EDITOR_SCOPE_SHA256
            value['preflightSHA256']=SHIPPING_EDITOR_PREFLIGHT_SHA256
            value['reservationAction']=SHIPPING_EDITOR_ACTION
        if kind in PREVIEW_METADATA_KINDS:
            value['ownerScopeSHA256']=PREVIEW_METADATA_SCOPE_SHA256
            value['reservationAction']=PREVIEW_METADATA_ACTION
            value['priorMoveStopSHA256']=MOVE_THIRD_STOP_SHA256
            value['metadataOnly']=True
        if kind in cut_action_kinds:
            value['cutOwnerScopeSHA256']=CUT_OWNER_SCOPE_SHA256
            value['priorMoveStopSHA256']=MOVE_THIRD_STOP_SHA256
            value['priorMoveUsage']={'sessions':counts[move_action_kinds[0]],'attempts':counts[move_action_kinds[1]]}
        if kind in permission_completion_kinds:
            value['permissionOwnerScopeSHA256']=PERMISSION_REPAIR_SCOPE_SHA256 if repair else PERMISSION_COMPLETION_SCOPE_SHA256
            value['priorDenialUsage']={'sessions':counts[exclusive_denial_kinds[0]],'attempts':counts[exclusive_denial_kinds[1]]}
            value['offlineProvenRepairScope']=repair
            if repair:
                value['firstPermissionResultSHA256']=PERMISSION_FIRST_RESULT_SHA256
                value['firstPermissionStopSHA256']=PERMISSION_FIRST_STOP_SHA256
                value['firstPermissionNativeSHA256']=PERMISSION_FIRST_NATIVE_SHA256
        if kind==permission_completion_kinds[0]:value['permissionAttemptBase']=counts[permission_completion_kinds[1]]
        if kind==cut_action_kinds[0]:value['cutAttemptBase']=counts[cut_action_kinds[1]]
        if kind==cut_action_kinds[0] and repair:value['firstCutResultSHA256']=CUT_FIRST_RESULT_SHA256;value['cutRepairProofSHA256']=CUT_REPAIR_PROOF_SHA256
        if kind==exclusive_denial_kinds[0]:value['denialAttemptBase']=counts[exclusive_denial_kinds[1]]
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, sort_keys=True); output.write('\n'); output.flush(); os.fsync(output.fileno())
        parent = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(parent)
        finally: os.close(parent)
        return value
    finally:
        os.close(lock)
