#!/usr/bin/env python3
"""New generated key-auth worker sessions; counted BEFORE any connection."""
import argparse
import base64
import fcntl
import json
import os
import socket
import struct
import sys
import time
import uuid
sys.dont_write_bytecode = True
from packet import prepare, d, audit, REPO, TOOLING, directory
from process import Child, Channel, Fields, field, line
from network_ledger import record
from worker_build import sources


def duplicate(fd):
    copy = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 10); os.close(fd); return copy


def public(path): return base64.b64decode(path.read_bytes().split()[1], validate=True)


def snapshot(fields):
    result = {name: fields.number('>Q') for name in ['read', 'revision', 'count', 'folders']}
    result['state'] = fields.number('>B'); return result


def terminal(channel, body=None):
    value = Fields(channel.event(107) if body is None else body)
    result = {'outcome': value.number('>B'), 'directoryAck': value.number('>B'), 'sshEnded': value.number('>B'),
              'tasksBefore': value.number('>Q'), 'tasksAfter': value.number('>Q'), 'writerEnd': value.number('>B')}
    value.end(); return result


def session(root, binary, fixture, keys, label, scenario, kind):
    admission = record('loopback', root, label); children = []; fds = []; parent = child = None
    try:
        read, write = map(duplicate, os.pipe()); fds += [read, write]
        in_read, in_write = map(duplicate, os.pipe()); fds += [in_read, in_write]
        key_file = keys / ('encrypted-' + str(kind) if scenario == 'wrong-passphrase' or label.endswith('encrypted') else 'key-' + str(kind))
        authorized = public(keys / ('key-' + str(kind) + '.pub'))
        os.write(in_write, authorized); os.close(in_write); fds.remove(in_write)
        peer = Child([fixture, scenario], root, label + '-fixture', stdin=in_read, stdout=write); children.append(peer)
        os.close(in_read); fds.remove(in_read); os.close(write); fds.remove(write)
        ready = line(read, root, label + '-ready'); host_key = bytes.fromhex(ready['generatedPublicKey'])
        assert ready['ready'] and 0 < ready['port'] < 65536
        store = directory(root / 'state' / label)
        descriptors = [duplicate(os.open(store, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC))]
        for name in ['catalog.sqlite', 'owner.lock']:
            descriptors.append(duplicate(os.open(store / name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)))
        fds += descriptors; fcntl.flock(descriptors[2], fcntl.LOCK_EX | fcntl.LOCK_NB)
        parent, child = socket.socketpair(); parent.settimeout(10)
        worker_fd = fcntl.fcntl(child.fileno(), fcntl.F_DUPFD_CLOEXEC, 10); fds.append(worker_fd)
        worker = Child([binary, '--key-paged-worker'], root, label + '-worker', descriptors=dict(zip([3, 4, 5, 6], [worker_fd, *descriptors]))); children.append(worker)
        child.close(); child = None; os.close(worker_fd); fds.remove(worker_fd)
        channel = Channel(parent)
        channel.send(1, field(b'generated.example') + field(b'127.0.0.1') + struct.pack('>HI', ready['port'], 0) + field(b'')
            + field(str(store / 'catalog.sqlite').encode()) + struct.pack('>Q', 8 << 20))
        challenge = Fields(channel.event(100)); assert challenge.number('>B') == 1 and challenge.field() == b'generated.example'
        assert challenge.number('>H') == ready['port'] and challenge.field() == host_key and challenge.field() == b''; challenge.end()
        expected = 0; successful = False; checked_rows = 0; stop_seconds = None
        if scenario == 'cancel-host': channel.send(6)
        else:
            channel.send(2, b'\1' + field(host_key)); assert channel.event(101) == b''
            if scenario == 'before-auth-stop': channel.send(6)
            else:
                key = key_file.read_bytes()
                phrase = b'generated-only-not-a-secret' if key_file.name.startswith('encrypted-') else b''
                wanted = b''
                if scenario == 'wrong-passphrase': phrase = b'generated-wrong-phrase'; expected = 12
                if scenario == 'bad-key': key = (keys / ('key-' + str((kind + 1) % 7))).read_bytes(); expected = 5
                if scenario == 'key-denied': expected = 5
                if scenario == 'key-changed': wanted = public(keys / 'key-1.pub'); expected = 14
                channel.send(12, field(b'generated') + field(key) + field(phrase) + field(wanted)); key = b''; phrase = b''
                if expected == 0:
                    identity = Fields(channel.event(135)); assert identity.field() == authorized; identity.end()
                    assert channel.event(102) == b'' and channel.event(109) == b''; successful = True
                    generation = uuid.uuid4().bytes; channel.send(4, generation + field(b'.'))
                    opened = Fields(channel.event(110)); assert opened.take(16) == generation and opened.field() == b'/generated'
                    state = snapshot(opened); opened.end(); assert state['count'] == 0
                    if scenario == 'read-stop':
                        channel.send(5, generation); time.sleep(.05); began = time.monotonic(); channel.send(6)
                    else:
                        for _ in range(4):
                            channel.send(5, generation); progress = Fields(channel.event(111)); assert progress.take(16) == generation
                            state = snapshot(progress); progress.end()
                            if state['state'] == 1: break
                        assert state['state'] == 1 and state['count'] == 2
                        query = uuid.uuid4().bytes; channel.send(7, query + generation + struct.pack('>QQHBB', state['revision'], 0, 256, 0, 0))
                        head = Fields(channel.event(114)); assert head.take(16) == query and head.take(16) == generation and snapshot(head) == state and head.number('>Q') == 0; head.end()
                        names = []
                        for _ in range(2):
                            row = Fields(channel.event(115)); assert row.take(16) == query and row.number('>Q') > 0
                            flags = row.number('>B'); size = row.number('>Q'); row.number('>I'); row.number('>I'); names.append(row.field()); row.end()
                            assert flags <= 7 and size in [123, 456]
                        tail = Fields(channel.event(116)); assert tail.take(16) == query and tail.number('>I') == 2; tail.end()
                        assert set(names) == {b'Generated first.txt', b'Generated second.txt'}; checked_rows = 2; channel.send(6)
        ended = terminal(channel)
        if scenario == 'read-stop': stop_seconds = time.monotonic() - began
        assert ended['outcome'] == expected and ended['tasksAfter'] == 0 and ended['writerEnd'] == 1
        assert worker.wait() == 0 and parent.recv(1) == b'' and worker.log.stat().st_size == 0
        observed = line(read, root, label + '-fixture-ended'); assert observed['ended'] and observed['runtimeTasksAfter'] == 0 and observed['fixtureTasksAborted'] == 0
        assert peer.wait() == 0 and peer.log.stat().st_size == 0
        if scenario in ['cancel-host', 'before-auth-stop', 'wrong-passphrase', 'key-changed']:
            assert observed['authCalls'] == 0 and observed['keyOffers'] == 0
        elif successful or scenario == 'key-denied': assert observed['authCalls'] == 1 and observed['keyOffers'] >= 1
        elif scenario == 'bad-key': assert observed['authCalls'] == 0 and observed['keyOffers'] >= 1
        value = {'passed': True, 'label': label, 'scenario': scenario, 'admission': admission, 'terminal': ended, 'fixture': observed,
                 'checkedRows': checked_rows, 'stopSeconds': stop_seconds, 'workerActualExit': worker.status, 'fixtureActualExit': peer.status,
                 'workerPeakRSSBytes': worker.stats.ru_maxrss, 'fixturePeakRSSBytes': peer.stats.ru_maxrss, 'ipcEOF': True}
        d.put(root / 'evidence' / (label + '.result.json'), value); return value
    finally:
        try:
            for owned in reversed(children): owned.contain()
        finally:
            if parent: parent.close()
            if child: child.close()
            for fd in fds: os.close(fd)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--build-case', required=True); parser.add_argument('--keys-case', default='C4D28241-2E4A-4F4D-AF4B-688E164885EE')
    parser.add_argument('--only', default='all'); args = parser.parse_args(); prepare()
    for value in [args.build_case, args.keys_case]:
        if str(uuid.UUID(value)).upper() != value: raise RuntimeError('Canonical owned case required')
    prior = d.ROOT / args.build_case; proof = json.loads((prior / 'evidence/result.json').read_bytes())
    mode = 'release' if proof['release'] else 'debug'; binary = TOOLING / 'target' / mode / 'catalog_worker'; fixture = binary.with_name('key_fixture')
    if not proof['passed'] or proof['sources'] != sources() or any(d.digest(TOOLING / 'target' / mode / n) != h for n, h in proof['binaries'].items()):
        raise RuntimeError('Build current exact auth worker first')
    keys_case = d.ROOT / args.keys_case
    if not json.loads((keys_case / 'evidence/result.json').read_bytes())['passed'] or json.loads((keys_case / 'reservation.json').read_bytes())['action'] != 'ssh-key-independent-interoperability':
        raise RuntimeError('Only the passed generated-key matrix may be used')
    root = d.reserve('ssh-key-worker-loopback'); results = []
    cases = [('ed-first', 'first', 0), ('ed-encrypted', 'first', 0), ('ec-first', 'first', 1), ('rsa-2048', 'first', 4),
             ('rsa-3072', 'first', 5), ('rsa-4096-encrypted', 'first', 6), ('wrong-passphrase', 'wrong-passphrase', 0),
             ('bad-key', 'bad-key', 0), ('key-denied', 'key-denied', 0), ('key-changed', 'key-changed', 0),
             ('cancel-host', 'cancel-host', 0), ('before-auth-stop', 'before-auth-stop', 0), ('read-stop', 'read-stop', 0),
             ('ecdsa-host', 'ecdsa-host', 0), ('fips-host', 'fips', 0)]
    if args.only != 'all': cases = [item for item in cases if item[0] == args.only]
    if not cases: raise RuntimeError('Known source-owned scenario required')
    d.put(root / 'inputs.json', {'build': args.build_case, 'sources': proof['sources'], 'keys': args.keys_case,
        'scenarios': [c[0] for c in cases], 'personalSSH': False, 'personalCredentials': False, 'bodyRequests': 0})
    try:
        for label, scenario, kind in cases: results.append(session(root, binary, fixture, keys_case / 'state', label, scenario, kind))
        d.put(root / 'evidence/result.json', {'passed': True, 'scenarios': results, 'usage': audit()})
        print(json.dumps({'case': root.name, 'passed': True, 'controls': len(results)}))
    except BaseException as error:
        d.put(root / 'evidence/result.json', {'passed': False, 'error': type(error).__name__, 'completed': results, 'usage': audit()}); raise


if __name__ == '__main__': main()
