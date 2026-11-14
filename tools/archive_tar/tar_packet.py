"""New plain-TAR controls inside the unchanged current development pool."""
import json,sys
from pathlib import Path
sys.dont_write_bytecode=True
TOOLS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(TOOLS/'ssh_profiles'))
from packet import prepare,d,run,audit as shared_audit,directory,REPO
PREFIX='plain-tar-'
def cases():return[p.parent for p in d.ROOT.glob('*/reservation.json')if json.loads(p.read_bytes()).get('action','').startswith(PREFIX)]
def audit():
    value=shared_audit();roots=cases()
    if sum(d.measure(p)['bytes']for p in roots)>512<<20 or sum(d.measure(p)['entries']for p in roots)>2048:raise RuntimeError('Plain TAR packet bound')
    source=0
    for root in roots:
        declared=None
        if(root/'inputs.json').is_file():declared=json.loads((root/'inputs.json').read_bytes()).get('generatedArchiveInputs')
        if declared is not None:
            if not isinstance(declared,list)or len(declared)>8 or len(set(declared))!=len(declared):raise RuntimeError('Explicit generated TAR input list')
            for relative in declared:
                path=Path(relative)
                if not isinstance(relative,str)or path.is_absolute()or'..'in path.parts or len(path.parts)!=2 or path.parts[0]!='source':raise RuntimeError('Exact generated TAR input path')
                p=root/path
                if p.resolve()!=p or not p.is_file()or p.stat().st_nlink!=1:raise RuntimeError('Generated TAR input redirected')
                source+=p.stat().st_size
            continue
        folder=root/'source/archives'
        if not folder.exists():continue
        for p in folder.iterdir():
            if p.is_symlink()or not p.is_file()or p.stat().st_nlink!=1:raise RuntimeError('Generated TAR input authority changed')
            source+=p.stat().st_size
    if source>12<<20:raise RuntimeError('Generated TAR input bound')
    value.update(tarCases=len(roots),tarInputBytes=source);return value
def reserve(kind):
    if kind not in ['fixtures','parser-controls','reader-controls','extraction-controls','producer-crash','native','source','adoption']:raise RuntimeError('Unreviewed TAR action')
    prepare();audit();current=cases()
    if kind=='native':
        if sum(json.loads((p/'reservation.json').read_bytes())['action']==PREFIX+'native'for p in current)>=8:raise RuntimeError('Eight TAR native admissions consumed')
    elif kind not in ['source','adoption']:
        if sum(json.loads((p/'reservation.json').read_bytes())['action']not in[PREFIX+'native',PREFIX+'source',PREFIX+'adoption']for p in current)>=16:raise RuntimeError('Sixteen TAR control/driver admissions consumed')
    return d.reserve(PREFIX+kind)
