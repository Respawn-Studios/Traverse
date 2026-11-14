#!/usr/bin/env python3
"""Two finite metadata-gate cases; every reservation survives failed launch."""
import argparse
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from packet import d, shared, REPO, MASTER, prepare
from native_build_processes import observation, identity, descendants

ACTION = 'archive-metadata-admission'
CASE_BYTES, CASE_ENTRIES = 128 << 20, 512


def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json')
            if json.loads(p.read_bytes()).get('action') == ACTION]


def audit():
    prepare(); value = d.audit(); roots = cases()
    if len(roots) > 2: raise RuntimeError('Two metadata-admission cases exceeded')
    for root in roots:
        usage = d.measure(root)
        if usage['bytes'] > CASE_BYTES or usage['entries'] > CASE_ENTRIES:
            raise RuntimeError('Metadata-admission case bound')
    value.update(metadataAdmissionCases=len(roots), compilerReservations=2 * len(roots), runtimeReservations=2 * len(roots))
    return value


class OwnedMemory:
    """Observe only one directly owned process and its identity-bound children."""
    def __init__(self, limit):
        self.limit, self.root, self.known = limit, None, {}
        self.peak = self.aggregate = self.samples = 0

    def __call__(self, pid):
        rows = observation()
        if self.root is None:
            row = rows.get(pid)
            if row is None: return  # A reaped fast child is checked by wait4.
            if row['parent'] != os.getpid(): raise RuntimeError('Exact metadata-control child required')
            self.root = pid; self.known[pid] = identity(row)
        elif self.root != pid: raise RuntimeError('Metadata-control child changed')
        active = descendants(rows, pid, self.known)
        if len(active) > 16: raise RuntimeError('Metadata-control descendant bound')
        total = 0
        for current in active:
            row = rows[current]; stamp = identity(row)
            if current in self.known and self.known[current] != stamp: raise RuntimeError('Metadata-control identity changed')
            self.known[current] = stamp; total += row['rss']; self.peak = max(self.peak, row['rss']); self.samples += 1
        self.aggregate = max(self.aggregate, total)
        if self.peak > self.limit or self.aggregate > self.limit: raise RuntimeError('Metadata-control live RSS ceiling')

    def report(self):
        rows = observation()
        live = [pid for pid, stamp in self.known.items() if pid in rows and identity(rows[pid]) == stamp]
        return dict(peakObservedRSSBytes=self.peak, peakObservedAggregateRSSBytes=self.aggregate,
                    samples=self.samples, trackedProcesses=len(self.known), liveObservedPIDs=live)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--label', default='metadata-admission'); args = parser.parse_args()
    audit()
    if len(cases()) >= 2: raise RuntimeError('Two metadata-admission cases consumed')
    own = Path(__file__).resolve(); controls = own.with_name('admission_controls.swift')
    gate = REPO / 'App/MacExplorer/Features/Archives/ArchiveMetadataAdmission.swift'
    paths = [own, controls, gate, REPO / 'App/MacExplorer/Features/Archives/ArchiveBrowser.swift', REPO / 'App/MacExplorer/Features/Archives/TARBrowserModel.swift']
    sources = {str(p.relative_to(REPO)): d.digest(p) for p in paths}
    root = d.reserve(ACTION)
    d.put(root / 'day-build-admission.json', dict(master=MASTER, action=ACTION, compilerReservations=2, runtimeReservations=2,
          maximumCases=2, maximumCompilerInvocations=4, maximumRuntimeInvocations=4,
          maximumCompilerRSSBytes=512 << 20, maximumRuntimeRSSBytes=128 << 20,
          maximumCaseBytes=CASE_BYTES, maximumCaseEntries=CASE_ENTRIES))
    d.put(root / 'inputs.json', dict(label=args.label, sources=sources, generatedOnly=True, appLaunches=0,
          archiveBodyReads=0, networkRequests=0, compilerReservations=2, runtimeReservations=2))
    for path in paths:
        with (root / 'source' / path.name).open('xb') as output: output.write(path.read_bytes())
    report = dict(passed=False, compilers=[], runtimes=[])
    try:
        binaries = []
        for label, optimization in [('debug', '-Onone'), ('optimized', '-O')]:
            binary = root / 'source' / ('admission-' + label)
            command = ['xcrun', 'swiftc', optimization, '-whole-module-optimization', '-j1', '-parse-as-library',
                       '-warnings-as-errors', '-swift-version', '6', '-strict-concurrency=complete',
                       '-module-cache-path', str(d.TOOLING / 'swift'), str(root / 'source' / gate.name), str(root / 'source' / controls.name), '-o', str(binary)]
            memory = OwnedMemory(512 << 20)
            try:
                process, _, _ = shared.run(command, root, 'compile-' + label, timeout=180, observer=memory, independent_observer=True)
            finally:
                d.put(root / 'evidence' / ('compile-' + label + '-memory.json'), memory.report())
            report['compilers'].append(process); audit()
            if not process['passed'] or process['peakRSSBytes'] > 512 << 20: raise RuntimeError('Metadata-control compiler gate')
            binaries.append((label, binary))
        for label, binary in binaries:
            memory = OwnedMemory(128 << 20)
            try:
                process, stdout, _ = shared.run([str(binary)], root, 'runtime-' + label, timeout=30, observer=memory, independent_observer=True)
            finally:
                d.put(root / 'evidence' / ('runtime-' + label + '-memory.json'), memory.report())
            controls_value = json.loads(stdout.read_bytes()) if stdout.stat().st_size else {}
            report['runtimes'].append(dict(process=process, controls=controls_value)); audit()
            if not process['passed'] or process['peakRSSBytes'] > 128 << 20 or not controls_value.get('passed'):
                raise RuntimeError('Metadata-admission runtime control failed')
        unchanged = sources == {str(p.relative_to(REPO)): d.digest(p) for p in paths}
        if not unchanged: raise RuntimeError('Metadata-admission source graph changed')
        report.update(passed=True, sourceUnchanged=True, usage=audit())
        print(json.dumps(dict(case=root.name, passed=True, checks=sum(len(v['controls']['checks']) for v in report['runtimes']),
                              compilerReservations=2, runtimeReservations=2)), flush=True)
    finally:
        d.put(root / 'evidence/result.json', report)


if __name__ == '__main__': main()
