"""Finite generated archive-Open checks for the 26 October day build."""
import importlib.util
import json
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
sys.path.append(str(REPO / 'tools/ssh_profiles'))
spec = importlib.util.spec_from_file_location('archive_opening_shared_packet', REPO / 'tools/ssh_profiles/packet.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
d, directory, TOOLING = shared.d, shared.directory, shared.TOOLING
TOOLCHAIN = shared.TOOLCHAIN
MASTER = '7B4FE5D0-444E-4676-A91F-25E69FDDAF8D'
ACTION = 'archive-open-routing-native'
MAXIMUM_BYTES, MAXIMUM_ENTRIES = 64 << 20, 256


def prepare():
    marker = d.ROOT / MASTER / 'reservation.json'
    if marker.resolve() != marker or not marker.is_file():
        raise RuntimeError('Day-build master unavailable')
    value = json.loads(marker.read_bytes())
    if value.get('packet') != 'traverse-development-v1' or value.get('action') != 'day-build-20261026':
        raise RuntimeError('Day-build master mismatch')


def cases():
    return [p.parent for p in d.ROOT.glob('*/reservation.json')
            if json.loads(p.read_bytes()).get('action') == ACTION]


def audit():
    prepare()
    value = d.audit()
    roots = cases()
    if len(roots) > 6:
        raise RuntimeError('Six archive Open runtime admissions exceeded')
    for root in roots:
        usage = d.measure(root)
        if usage['bytes'] > MAXIMUM_BYTES or usage['entries'] > MAXIMUM_ENTRIES:
            raise RuntimeError('Archive Open case bound exceeded')
    value['archiveOpeningRuntimeReservations'] = len(roots)
    return value


def reserve():
    audit()
    if len(cases()) >= 6:
        raise RuntimeError('Six archive Open runtime admissions consumed')
    root = d.reserve(ACTION)
    d.put(root / 'day-build-admission.json', dict(master=MASTER, action=ACTION,
          maximumCaseBytes=MAXIMUM_BYTES, maximumCaseEntries=MAXIMUM_ENTRIES,
          maximumNativeRSSBytes=256 << 20, maximumSeconds=90, maximumRuntimeReservations=6))
    return root


def run(command, root, label, timeout=90, native=True):
    """Reuse the exact owned-child containment; enforce this packet's own cap."""
    audit()
    last = 0.0

    def observe(_pid):
        nonlocal last
        now = time.monotonic()
        if now - last >= .25:
            usage = d.measure(root)
            if usage['bytes'] > MAXIMUM_BYTES or usage['entries'] > MAXIMUM_ENTRIES:
                raise RuntimeError('Archive Open live case bound exceeded')
            last = now

    result = shared.run(command, root, label, timeout=min(timeout, 90), native=native, observer=observe)
    audit()
    return result
