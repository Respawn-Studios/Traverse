#!/usr/bin/env python3
"""SDK-typed generated health interfaces; never acquires a real device."""
from __future__ import annotations
import argparse, importlib.util, json, os, shutil, subprocess, sys
from pathlib import Path
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / 'tools'))
import development as d
spec = importlib.util.spec_from_file_location('health_process', REPO / 'tools/ssh_profiles/packet.py')
own = importlib.util.module_from_spec(spec)
spec.loader.exec_module(own)
ACTION = 'typed-device-health-generated'
MAX_CASES = 7

def audit_compiler_cache(action, cache):
    """Retry only a vanished compiler-owned PCM temporary, at most twice.

    Nothing is subtracted or skipped. Each retry repeats the whole measurement;
    quiescent final audit stays strict and never calls this helper.
    """
    if cache.resolve() != cache or cache.is_symlink() or not cache.is_dir() \
        or cache.stat().st_uid != os.getuid():
        raise RuntimeError('Owned typed-health compiler cache changed')
    for attempt in range(3):
        try:
            return action()
        except FileNotFoundError as error:
            missing = Path(error.filename) if error.filename else None
            if missing is None or not missing.is_absolute() or '..' in missing.parts \
                or not missing.is_relative_to(cache) or missing.suffixes[-2:] != ['.pcm', '.tmp'] \
                or missing.parent.resolve() != missing.parent or attempt == 2:
                raise
    raise AssertionError('Bounded cache audit returned without a result')

def audit_controls(cache):
    marker = cache/'Generated.pcm.tmp'
    calls = 0
    def volatile():
        nonlocal calls
        calls += 1
        if calls < 3:
            raise FileNotFoundError(2, 'generated compiler rename', str(marker))
        return dict(measured=True)
    assert audit_compiler_cache(volatile, cache) == dict(measured=True) and calls == 3
    for path in [cache/'stable.pcm', cache.parent/'Outside.pcm.tmp', cache/'..'/'Outside.pcm.tmp']:
        attempts = [0]
        def refused():
            attempts[0] += 1
            raise FileNotFoundError(2, 'generated unsafe path', str(path))
        try:
            audit_compiler_cache(refused, cache)
        except FileNotFoundError:
            assert attempts == [1]
        else:
            raise AssertionError('Non-temporary or escaping measurement error was retried')
    attempts = [0]
    def persistent():
        attempts[0] += 1
        raise FileNotFoundError(2, 'generated persistent failure', str(marker))
    try:
        audit_compiler_cache(persistent, cache)
    except FileNotFoundError:
        assert attempts == [3]
    else:
        raise AssertionError('Persistent compiler-cache failure was hidden')
    return 5

def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json')
            if json.loads(p.read_bytes()).get('action') == ACTION]

def admission(root, kind, label):
    if kind not in ['compiler', 'runtime']:
        raise RuntimeError('Known generated command kind required')
    used = sum(len(list((p/'evidence').glob(kind + '-admission-*.json'))) for p in cases())
    maximum = 17 if kind == 'compiler' else 12
    if used >= maximum:
        raise RuntimeError('Finite typed-health command allowance consumed; retain all attempts')
    d.put(root/'evidence'/(kind+'-admission-'+str(used+1)+'.json'), dict(kind=kind, label=label, ordinal=used+1))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=['c', 'swift'], required=True)
    parser.add_argument('--optimization', choices=['debug', 'optimized'], default='debug')
    args = parser.parse_args()
    if len(cases()) >= MAX_CASES:
        raise RuntimeError('Six typed-health cases consumed, including failures')
    root = d.reserve(ACTION)
    graph = root/'source/health'
    graph.mkdir(mode=0o700)
    canonical = REPO / 'Packages/ExplorerKit/Sources/DriveHealthNative'
    def source_path(name):
        if name in ['THSMART.c', 'THAssociation.c']:
            return canonical / name
        if name in ['THSMART.h', 'THAssociation.h']:
            return canonical / 'include' / name
        return HERE / name
    source = {p.name: d.digest(source_path(p.name)) for p in HERE.iterdir()
              if p.suffix in ['.c', '.h', '.swift', '.modulemap']}
    sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True, timeout=10).strip())
    sdk_headers = sdk/'System/Library/Frameworks/IOKit.framework/Headers'
    header_names = ['storage/ata/ATASMARTLib.h', 'storage/nvme/NVMeSMARTLibExternal.h', 'IOCFPlugIn.h']
    headers = {name: d.digest(sdk_headers/name) for name in header_names}
    inputs = dict(stage=args.stage, optimization=args.optimization, sourceSHA256=source,
                  driverSHA256=d.digest(Path(__file__)), sdkHeaders=headers,
                  maximumCaseBytes=128<<20, maximumEntries=256, maximumCompilerRSSBytes=512<<20,
                  maximumRuntimeRSSBytes=256<<20, realDeviceOpens=0, networkRequests=0,
                  nativeAcquisitionBackend=False, ordinaryActivation=False)
    d.put(root/'inputs.json', inputs)
    report = dict(passed=False, stage=args.stage, hardwareQualified=False, realDeviceOpens=0,
                  commands=[], nativeAcquisitionBackend=False, ordinaryActivation=False)
    def audit():
        value = d.audit()
        usage = d.measure(root)
        if usage['bytes'] > 128<<20 or usage['entries'] > 256:
            raise RuntimeError('Generated typed-health case bound')
        return value
    def environment(case):
        value = d.dev.environment(tooling=False)
        value.update(CFFIXED_USER_HOME=str(case/'cache/user'), TMPDIR=str(case/'cache/tmp')+'/',
                     CLANG_MODULE_CACHE_PATH=str(case/'cache/modules'),
                     SWIFTPM_MODULECACHE_OVERRIDE=str(case/'cache/modules'))
        return value
    def run(command, kind, label):
        audit(); admission(root, kind, label)
        def observe(_):
            return audit_compiler_cache(audit, root/'cache/modules') if kind=='compiler' else audit()
        value, out, err = own.run(command, root, label, timeout=120 if kind=='compiler' else 60,
                                  native=True, observer=observe)
        limit = (512 if kind=='compiler' else 256)<<20
        if not value['passed'] or value['peakRSSBytes'] > limit:
            raise RuntimeError('Typed-health '+label+' gate failed; preserve '+str(err))
        report['commands'].append(dict(kind=kind, label=label, **value))
        return out
    own.environment = environment
    try:
        shutil.copyfile(Path(__file__), root/'source/qualify.py')
        for name in source:
            shutil.copyfile(source_path(name), graph/name)
        for name in ['user', 'tmp', 'modules']:
            (root/'cache'/name).mkdir(mode=0o700)
        report['cacheAuditControls'] = audit_controls(root/'cache/modules')
        flags = ['-O2'] if args.optimization=='optimized' else ['-O0', '-g']
        clang = ['/usr/bin/clang', '-std=c17', '-target', 'arm64-apple-macos15.0', '-isysroot', str(sdk),
                 '-Wall', '-Wextra', '-Werror', '-Wpedantic', *flags, '-I', str(graph)]
        if args.stage=='c':
            binary = graph/'typed-health-controls'
            run(clang+[str(graph/'THSMART.c'), str(graph/'THSMARTFake.c'), str(graph/'smart_controls.c'),
                       '-framework', 'CoreFoundation', '-o', str(binary)], 'compiler', 'typed-c-compile')
            out = run([str(binary)], 'runtime', 'typed-c-controls')
            result = json.loads(out.read_bytes())
            if not result.get('passed') or result.get('warningValues')!=256 or result.get('heldNativeStages')!=14 \
                or result.get('forbiddenCalls')!=0 or result.get('realDeviceOpens')!=0 or result.get('hardwareQualified') is not False:
                raise RuntimeError('Typed C result contract')
            report['controls'] = result
        else:
            # Each object and the Swift image retain their own finite admission.
            objects = []
            for name in ['THSMART', 'THSMARTFake']:
                obj = graph/(name+'.o')
                run(clang+['-c', str(graph/(name+'.c')), '-o', str(obj)], 'compiler', name+'-compile')
                objects.append(str(obj))
            binary = graph/'health-session-controls'
            swift = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                     '-target', 'arm64-apple-macos15.0', '-sdk', str(sdk),
                     '-module-cache-path', str(root/'cache/modules'), '-I', str(graph),
                     '-O' if args.optimization=='optimized' else '-Onone', '-parse-as-library',
                     str(graph/'DeviceHealthSession.swift'), str(graph/'session_controls.swift'),
                     *objects, '-framework', 'CoreFoundation', '-o', str(binary)]
            run(swift, 'compiler', 'health-session-compile')
            out = run([str(binary)], 'runtime', 'health-session-controls')
            result = json.loads(out.read_bytes())
            if not result.get('passed') or result.get('realDeviceOpens')!=0 or result.get('hardwareQualified') is not False:
                raise RuntimeError('Health-session result contract')
            report['controls'] = result
        symbols = subprocess.check_output(['/usr/bin/nm', '-u', str(binary)], text=True, timeout=10)
        forbidden = ['_IOService', '_IOConnect', '_IORegistry', '_DADisk',
                     '_IOCreatePlugInInterfaceForService', '_IODestroyPlugInInterface']
        if any(value in symbols for value in forbidden):
            raise RuntimeError('Generated executable contains a callable native-acquisition route')
        d.put(root/'evidence/undefined-symbols.json', dict(symbols=symbols.splitlines(),
              rejectedPrefixes=forbidden, realIOKitAcquisitionSymbols=0))
        if {name:d.digest(source_path(name)) for name in source}!=source \
            or any(d.digest(graph/name)!=digest for name,digest in source.items()) \
            or d.digest(Path(__file__))!=inputs['driverSHA256'] \
            or any(d.digest(sdk_headers/name)!=digest for name,digest in headers.items()):
            raise RuntimeError('Typed-health source/SDK graph changed')
        report.update(passed=True, copiedSourcesMatch=True, sdkHeadersUnchanged=True,
                      binarySHA256=d.digest(binary), realIOKitAcquisitionSymbols=0)
    except BaseException as error:
        report['failure'] = type(error).__name__
        raise
    finally:
        report['usage'] = audit()
        d.put(root/'evidence/result.json', report)
        print(json.dumps(dict(case=root.name, passed=report['passed'], stage=args.stage)), flush=True)
if __name__=='__main__':
    main()
