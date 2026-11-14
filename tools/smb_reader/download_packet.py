"""New finite offline SMB Download channel scope; no old allowance is reused."""
import importlib.util,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('smb_download_resources',HERE/'packet.py')
smb=importlib.util.module_from_spec(spec);spec.loader.exec_module(smb)
spec=importlib.util.spec_from_file_location('smb_download_child_owner',HERE.parent/'ssh_profiles/packet.py')
child=importlib.util.module_from_spec(spec);spec.loader.exec_module(child)
d=child.d
PREFIX='smb-selected-download-channel-'
def cases():
    return [m.parent for m in d.ROOT.glob('*/reservation.json')if json.loads(m.read_bytes()).get('action','').startswith(PREFIX)]
def audit():
    value=child.audit();current=cases()
    if sum(d.measure(r)['bytes']for r in current)>256<<20 or sum(d.measure(r)['entries']for r in current)>4096:raise RuntimeError('SMB Download channel subpacket ceiling')
    value['smbDownloadChannelCases']=len(current);value['smbTooling']=smb.usage(smb.TOOLING,smb.TOOLING_LIMIT);return value
def reserve(kind):
    child.prepare();audit()
    if kind not in ['swift-codec','rust-codec','worker-build','worker-controls','storage-controls']:raise RuntimeError('Unreviewed offline Download action')
    current=cases();builds=sum(json.loads((r/'inputs.json').read_bytes()).get('compilerAttempt',False)for r in current if(r/'inputs.json').exists())
    tests=sum((lambda v:v.get('reservedTestLaunches',v.get('actualTestLaunches',0)))(json.loads((r/'inputs.json').read_bytes()))for r in current if(r/'inputs.json').exists())
    if builds>=6 or tests>=4:raise RuntimeError('Six compiler attempts/four test launches already consumed')
    return d.reserve(PREFIX+kind)
def environment(root):
    value=child.environment(root)
    for area in ['swift-module-cache','tmp']:smb.directory(smb.TOOLING/area)
    value.update(CLANG_MODULE_CACHE_PATH=str(smb.TOOLING/'swift-module-cache'),SWIFTPM_MODULECACHE_OVERRIDE=str(smb.TOOLING/'swift-module-cache'),
        TMPDIR=str(smb.TOOLING/'tmp'),TRAVERSE_SMB_DOWNLOAD_CODEC_ROOT=str(root/'source'))
    return value
def observe(_):audit()
