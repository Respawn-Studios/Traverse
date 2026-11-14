#!/usr/bin/env python3
"""Finite source-bound TAR preview controls; no App/native graph fiction."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools/archive_opening'))
from packet import d, shared, MASTER, prepare
from admission_packet import OwnedMemory

ACTION = 'tar-explicit-preview'
RELEASE = 'DED1C41D-E952-42C3-B13D-D620EEA378E8'
MAXIMUM_CASES = 5  # Four retained failures plus the prospectively admitted completion.

def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json') if json.loads(p.read_bytes()).get('action') == ACTION]

def audit():
    prepare(); usage = d.audit(); roots = cases(); total = entries = bodies = 0
    if len(roots) > MAXIMUM_CASES: raise RuntimeError('Five TAR preview case reservations exceeded')
    for root in roots:
        value = d.measure(root); total += value['bytes']; entries += value['entries']
        if value['bytes'] > 64 << 20 or value['entries'] > 512: raise RuntimeError('TAR preview case bound')
        bodies += sum(p.stat().st_size for p in (root / 'source').glob('*.tar'))
    if total > 256 << 20 or entries > 2048 or bodies > 1 << 20: raise RuntimeError('TAR preview aggregate/input body bound')
    usage.update(tarPreviewCases=len(roots), compilerReservations=2*len(roots), runtimeReservations=2*len(roots), generatedSourceBytes=bodies)
    return usage

def graph(paths): return {str(p.relative_to(REPO)): d.digest(p) for p in paths}

def bind_core(root):
    release = d.ROOT / RELEASE
    build = json.loads((release / 'evidence/build.json').read_bytes())
    proof = json.loads((release / 'evidence/source.json').read_bytes())
    if build.get('passed') is not True or build.get('configuration') != 'Release' or build.get('optimizedQualification') is not False:
        raise RuntimeError('Exact passed ordinary Release required')
    core = sorted((REPO / 'Packages/ExplorerKit/Sources/ExplorerCore').glob('*.swift'))
    current = graph(core)
    if any(proof['sourceSHA256'].get(key) != digest for key, digest in current.items()): raise RuntimeError('Current Core differs from frozen Release Core')
    product = d.TOOLING / 'derived/Build/Products/Release'
    originals = [product / 'ExplorerCore.o'] + sorted((product / 'ExplorerCore.swiftmodule').iterdir())
    snapshots = root / 'source/Core'; snapshots.mkdir(mode=0o700)
    hashes = {}
    for path in originals:
        if path.resolve() != path or not path.is_file() or path.stat().st_mtime_ns > (release / 'evidence/source.json').stat().st_mtime_ns:
            raise RuntimeError('Core artifact provenance changed')
        relative = path.relative_to(product); target = snapshots / relative
        target.parent.mkdir(mode=0o700, exist_ok=True); shutil.copyfile(path, target)
        hashes[str(relative)] = d.digest(path)
        if d.digest(target) != hashes[str(relative)]: raise RuntimeError('Core snapshot copy changed')
    d.put(root / 'core-binding.json', dict(releaseCase=RELEASE, coreSourceSHA256=current, artifactsSHA256=hashes,
          releaseProofSHA256=graph([release / 'evidence/build.json', release / 'evidence/source.json', release / 'evidence/source-start.json']),
          unrelatedAppUnchangedRequired=False))
    return snapshots, core, hashes

def archive(rows, format=tarfile.USTAR_FORMAT):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w', format=format) as writer:
        for name, body, kind in rows:
            info = tarfile.TarInfo(name); info.mtime = info.uid = info.gid = 0; info.mode = 0o644
            info.type = kind; info.size = len(body) if kind == tarfile.REGTYPE else 0
            if format == tarfile.PAX_FORMAT: info.pax_headers = {'size': str(info.size)}
            if kind in [tarfile.SYMTYPE, tarfile.LNKTYPE]: info.linkname = 'Text.txt'
            writer.addfile(info, io.BytesIO(body) if info.size else None)
    return out.getvalue()

def fixtures(root):
    for prior in cases():
        manifest = prior / 'fixture.json'
        if manifest.exists():
            value = json.loads(manifest.read_bytes())
            if all(d.digest(prior / 'source' / name) == digest for name, digest in value['sha256'].items()): return prior, value
            raise RuntimeError('Preserved immutable fixture changed')
    rows = [('Text.txt', 'Hello café\n\t<html>plain</html>\r\n'.encode(), tarfile.REGTYPE), ('Empty', b'', tarfile.REGTYPE),
            ('Maximum', b'x' * (256 << 10), tarfile.REGTYPE), ('TooLarge', b'x' * ((256 << 10) + 1), tarfile.REGTYPE),
            ('Bytes', bytes(range(256)), tarfile.REGTYPE), ('._opaque', b'opaque', tarfile.REGTYPE),
            ('Folder', b'', tarfile.DIRTYPE), ('Sym', b'', tarfile.SYMTYPE), ('Hard', b'', tarfile.LNKTYPE), ('FIFO', b'', tarfile.FIFOTYPE)]
    for i, body in enumerate([b'\x00', b'\x01', b'\x7f', b'\xc2\x80', b'\xff', '\u202e'.encode(), '\u2066'.encode(), '\u061c'.encode()]): rows.append((f'Invalid{i}', body, tarfile.REGTYPE))
    values = {'Main.tar': archive(rows), 'Small.tar': archive([('Text.txt', b'abc', tarfile.REGTYPE)]),
              'PAX.tar': archive([('Long/' + 'p' * 110, b'pax', tarfile.REGTYPE)], tarfile.PAX_FORMAT),
              'GNU.tar': archive([('Long/' + 'g' * 110, b'gnu', tarfile.REGTYPE)], tarfile.GNU_FORMAT)}
    pax = bytearray(values['PAX.tar'])
    with tarfile.open(fileobj=io.BytesIO(pax), mode='r:') as reader: header = reader.getmembers()[0].offset_data - 512
    pax[header+124:header+136] = b'00000000000\0'
    pax[header+148:header+156] = b'        '
    pax[header+148:header+156] = ('%06o' % sum(pax[header:header+512])).encode() + b'\0 '
    values['PAX.tar'] = bytes(pax)
    for name, data in values.items(): (root / 'source' / name).write_bytes(data)
    def hex_digest(data):
        digest = hashlib.sha256()
        for offset in range(0, len(data), 16):
            chunk = data[offset:offset+16]
            line = f'{offset:08X}  ' + ' '.join(f'{byte:02X}' for byte in chunk).ljust(47) + '  |' + ''.join(chr(byte) if 32 <= byte <= 126 else '.' for byte in chunk).ljust(16) + '|\n'
            digest.update(line.encode('ascii'))
        return digest.hexdigest()
    value = dict(generatedOnly=True, sha256={name: hashlib.sha256(data).hexdigest() for name, data in values.items()}, files={},
                 hexSHA256={'Maximum':hex_digest(b'x' * (256 << 10)), 'Bytes':hex_digest(bytes(range(256)))})
    for name, data in values.items():
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as reader:
            value['files'][name] = [dict(path=e.name, offset=e.offset_data, bytes=e.size, file=e.isfile()) for e in reader]
    d.put(root / 'fixture.json', value); return root, value

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--label', default='explicit-selected-tar-preview'); args = parser.parse_args()
    audit()
    if len(cases()) >= MAXIMUM_CASES: raise RuntimeError('Five TAR preview cases consumed')
    own = Path(__file__).resolve(); local = REPO / 'Packages/ExplorerKit/Sources/LocalStorage'
    files = [local / name for name in ['TARMetadata.swift', 'TARCatalog.swift', 'TARSourceCatalog.swift', 'TARArchiveReader.swift', 'TARArchiveSession.swift', 'TARTextPreview.swift', 'ZIPSourceFile.swift']]
    enums = local / 'ZIPArchiveModels.swift'; control = own.with_name('controls.swift')
    helpers = [own, control, own.with_name('compile.py'), REPO / 'tools/archive_opening/packet.py', REPO / 'tools/archive_opening/admission_packet.py', REPO / 'tools/ssh_profiles/packet.py', REPO / 'tools/ssh_profiles/owned_observer.py', REPO / 'tools/native_build_processes.py', REPO / 'tools/development.py']
    paths = files + [enums] + helpers; source = graph(paths); root = d.reserve(ACTION)
    d.put(root / 'inputs.json', dict(master=MASTER, action=ACTION, label=args.label, sourceSHA256=source, compilerReservations=2,
          runtimeReservations=2, maximumCases=MAXIMUM_CASES, maximumCompilerInvocations=10, maximumRuntimeInvocations=10,
          maximumCaseBytes=64 << 20, maximumCaseEntries=512, maximumCompilerRSSBytes=512 << 20,
          maximumRuntimeRSSBytes=128 << 20, maximumSeconds=120, sourceSubgraphOnly=True, appLaunches=0, networkRequests=0))
    report = dict(passed=False, compilers=[], runtimes=[])
    core = []; core_hashes = None
    try:
        for path in paths:
            target = root / 'source/attempt' / str(path.relative_to(REPO)); target.parent.mkdir(mode=0o700, parents=True, exist_ok=True); shutil.copyfile(path, target)
        module, core, core_hashes = bind_core(root); core_source = graph(core)
        text = enums.read_text(); start = text.index('public enum ZIPArchiveFailure:'); end = text.index('\n}', start) + 2
        literal = text[start:end]; enum = root / 'source/ZIPArchiveFailure.swift'; enum.write_text('import Foundation\n' + literal + '\n')
        d.put(root / 'enum-binding.json', dict(productionSHA256=d.digest(enums), literalSHA256=hashlib.sha256(literal.encode()).hexdigest(), generatedSHA256=d.digest(enum)))
        binaries = []
        for label, opt in [('debug', '-Onone'), ('optimized', '-O')]:
            binary = root / 'source' / ('preview-' + label)
            config = root / ('compile-' + label + '.json')
            sdk = Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk').resolve(strict=True)
            d.put(config, dict(optimization=opt, sdk=str(sdk), sdkSettingsSHA256=d.digest(sdk / 'SDKSettings.json'), cache=str(d.TOOLING / 'swift'), module=str(module), files=[*map(str, files), str(enum), str(control)], coreObject=str(module / 'ExplorerCore.o'), output=str(binary)))
            command = [sys.executable, str(own.with_name('compile.py')), str(config)]
            memory = OwnedMemory(512 << 20)
            try: process, _, _ = shared.run(command, root, 'compile-' + label, timeout=120, observer=memory, independent_observer=True)
            finally: d.put(root / 'evidence' / ('compile-' + label + '-memory.json'), memory.report())
            report['compilers'].append(process); audit()
            if not process['passed'] or process['peakRSSBytes'] > 512 << 20: raise RuntimeError('Sharp TAR preview compiler failure')
            binaries.append((label, binary))
        fixture_root, fixture = fixtures(root)
        for label, binary in binaries:
            mutable = root / 'source' / ('Mutable-' + label + '.tar'); shutil.copyfile(fixture_root / 'source/Small.tar', mutable)
            before = graph([fixture_root / 'source' / name for name in fixture['sha256']]); mutable_hash = d.digest(mutable)
            memory = OwnedMemory(128 << 20)
            try: process, stdout, _ = shared.run([str(binary), str(root), str(fixture_root), str(mutable)], root, 'runtime-' + label, timeout=120, observer=memory, independent_observer=True)
            finally: d.put(root / 'evidence' / ('runtime-' + label + '-memory.json'), memory.report())
            value = json.loads(stdout.read_bytes()) if stdout.stat().st_size else {}
            report['runtimes'].append(dict(process=process, controls=value)); audit()
            if before != graph([fixture_root / 'source' / name for name in fixture['sha256']]) or d.digest(mutable) != mutable_hash: raise RuntimeError('Generated source not restored/unchanged')
            if not process['passed'] or process['peakRSSBytes'] > 128 << 20 or not value.get('passed'): raise RuntimeError('Sharp TAR preview runtime failure')
        if source != graph(paths) or core_source != graph(core): raise RuntimeError('Loaded dependency source changed')
        if core_hashes != {str(p.relative_to(module)): d.digest(p) for p in module.rglob('*') if p.is_file()}: raise RuntimeError('Frozen Core snapshot changed')
        report.update(passed=True, sourceUnchanged=True, coreUnchanged=True, fixtureCase=fixture_root.name)
        print(json.dumps(dict(case=root.name, passed=True, groups=[len(r['controls']['checks']) for r in report['runtimes']], compilerReservations=2, runtimeReservations=2)), flush=True)
    finally:
        report['sourceUnchanged'] = source == graph(paths); report['usage'] = audit(); d.put(root / 'evidence/result.json', report)

if __name__ == '__main__': main()
