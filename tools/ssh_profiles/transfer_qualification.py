#!/usr/bin/env python3
"""New bounded direct-auth/body composition, generated loopback peers only."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import uuid
sys.dont_write_bytecode = True
from packet import prepare, d, audit, TOOLING, directory
from process import Child, Channel, Fields, field, line
from network_ledger import record
from worker_build import sources
from worker_qualification import duplicate, public, snapshot, terminal


def generated(offset, count):
    return bytes((index * 31 + 7) % 251 for index in range(offset, offset + count))


def authenticate(channel, keys, method):
    key = method != 'prompts'
    if key:
        channel.send(12 if method == 'key' else 15, field(b'generated') + field((keys/'encrypted-0').read_bytes())
                     + field(b'generated-only-not-a-secret') + field(b''))
    else:
        channel.send(13, field(b'generated'))
    rounds = 0; identity = False
    while True:
        tag, payload = channel.next_event()
        if tag == 136:
            value = Fields(payload); rounds += 1
            assert value.number('>B') == rounds and rounds <= 2 and 1 <= value.number('>H') <= 120
            value.field(); value.field(); count = value.number('>B'); assert count == (2 if rounds == 1 else 1)
            echoes = []
            for _ in range(count):
                echoes.append(value.number('>B')); value.field()
            value.end(); assert echoes == ([1, 0] if rounds == 1 else [0])
            answers = [b'generated', b'123456'] if rounds == 1 else [b'654321']
            channel.send(14, bytes([rounds, count]) + b''.join(field(answer) for answer in answers))
        elif tag == 135:
            value = Fields(payload); assert key and not identity and value.field() == public(keys/'key-0.pub'); value.end(); identity = True
        elif tag == 102:
            assert payload == b'' and identity == key and rounds == (0 if method == 'key' else 2)
            assert channel.event(109) == b''; return rounds
        else:
            raise RuntimeError('Authentication did not finish before a body operation')


def listing(channel, count=2, path=b'/generated'):
    generation = uuid.uuid4().bytes; channel.send(4, generation + field(path))
    value = Fields(channel.event(110)); assert value.take(16) == generation and value.field() == path
    state = snapshot(value); value.end()
    for _ in range(4):
        if state['state'] != 0: break
        channel.send(5, generation); value = Fields(channel.event(111)); assert value.take(16) == generation
        state = snapshot(value); value.end()
    assert state['state'] == 1 and state['count'] == count
    query = uuid.uuid4().bytes; channel.send(7, query + generation + struct.pack('>QQHBB', state['revision'], 0, 256, 0, 0))
    value = Fields(channel.event(114)); assert value.take(16) == query and value.take(16) == generation and snapshot(value) == state and value.number('>Q') == 0; value.end()
    rows = []
    for _ in range(count):
        value = Fields(channel.event(115)); assert value.take(16) == query
        row = dict(observation=value.number('>Q'), flags=value.number('>B'), size=value.number('>Q'), modified=value.number('>I'), mode=value.number('>I'), name=value.field())
        value.end(); assert row['flags'] == 7 and row['observation'] > 0; rows.append(row)
    value = Fields(channel.event(116)); assert value.take(16) == query and value.number('>I') == count; value.end()
    return generation, state, rows


def download(channel, root, fixture_output, generation, row, scenario):
    request = uuid.uuid4().bytes; channel.send(8, request + generation + struct.pack('>Q', row['observation']))
    value = Fields(channel.event(120)); assert value.take(16) == request and value.take(16) == generation and value.number('>Q') == row['observation']
    assert (value.number('>Q'), value.number('>I'), value.number('>I'), value.field()) == (row['size'], row['modified'], row['mode'], row['name']); value.end()
    received = 0; digest = hashlib.sha256(); began = None
    if scenario == 'transfer-stop':
        assert line(fixture_output, root, 'generated-read-pending')['generatedBodyPending'] == 'read'
        began = time.monotonic(); channel.send(6)
    while True:
        tag, payload = channel.next_event(); value = Fields(payload)
        if tag == 121:
            assert value.take(16) == request and value.number('>Q') == received
            data = value.field(); value.end()
            assert 0 < len(data) <= 32768 and received + len(data) <= row['size'] and data == generated(received, len(data))
            digest.update(data); received += len(data)
            if scenario == 'transfer-lost-close' and received == row['size']:
                assert line(fixture_output, root, 'generated-close-pending')['generatedBodyPending'] == 'close'
                began = time.monotonic(); channel.send(6)
        elif tag == 122:
            assert scenario.startswith('composed-') and value.take(16) == request and value.number('>Q') == received == row['size'] and value.take(2) == b'\1\1'
            value.end(); return dict(completed=True, bytes=received, sha256=digest.hexdigest()), None
        elif tag == 107:
            expected = {'transfer-denied': 8, 'transfer-changed': 10, 'transfer-stop': 0, 'transfer-lost-close': 0}[scenario]
            ended = terminal(channel, payload); assert ended['outcome'] == expected
            if began is not None: assert time.monotonic() - began < 3
            return dict(completed=False, bytes=received, sha256=digest.hexdigest(), stopSeconds=None if began is None else time.monotonic()-began), ended
        else:
            raise RuntimeError('Unexpected direct download phase')


def upload(channel, root, fixture_output, generation, state, scenario):
    body = generated(0, 65553); digest = hashlib.sha256(body).digest(); request = uuid.uuid4().bytes
    channel.send(9, request + generation + struct.pack('>Q', state['revision']) + field(b'Draft-Notes.bin') + struct.pack('>Q', len(body)))
    value = Fields(channel.event(130)); assert value.take(16) == request and value.take(16) == generation and value.number('>Q') == len(body)
    assert value.field() == b'/generated/.mac-explorer-upload-' + request.hex().upper().encode() + b'.part' and value.field() == b'/generated/Draft-Notes.bin'; value.end()
    sent = 0; stopped = False; began = None
    while True:
        tag, payload = channel.next_event(); value = Fields(payload)
        if tag == 131:
            assert not stopped and value.take(16) == request and value.number('>Q') == sent
            count = value.number('>I'); value.end(); assert count == min(32768, len(body) - sent)
            channel.send(10, request + struct.pack('>Q', sent) + field(body[sent:sent+count])); sent += count
            if scenario == 'composed-stop-write':
                assert line(fixture_output, root, 'generated-write-pending')['generatedBodyPending'] == 'write'
                stopped = True; began = time.monotonic(); channel.send(6)
        elif tag == 132:
            assert value.take(16) == request and value.number('>Q') == sent == len(body) and value.take(32) == digest; value.end()
            channel.send(11, request + digest)
        elif tag == 133:
            assert scenario == 'composed-success' and value.take(16) == request and value.number('>Q') == len(body) and value.take(32) == digest and value.take(4) == b'\1\1\1\1'; value.end()
            return dict(completed=True, bytes=len(body), sha256=digest.hex()), None
        elif tag == 134:
            assert value.take(16) == request
            cause, phase, temporary, published = (value.number('>B') for _ in range(4)); status = value.number('>I'); value.end()
            expected = {'composed-sync-failure': (6, 7, 1, 0, 4), 'composed-lost-rename': (4, 11, 1, 1, 0), 'composed-stop-write': (3, 4, 1, 0, 0)}[scenario]
            assert (cause, phase, temporary, published, status) == expected
            ended = terminal(channel); assert ended['outcome'] == (0 if stopped else 4)
            if began is not None: assert time.monotonic()-began < 3
            return dict(completed=False, bytes=sent, sha256=digest.hex(), cause=cause, phase=phase,
                        temporaryMayExist=bool(temporary), publicationMayHaveHappened=bool(published), status=status), ended
        else:
            raise RuntimeError('Unexpected direct upload phase')


def live(root, binary, fixture, keys, label, method, scenario):
    record('transfer-loopback', root, label); children = []; fds = []; parent = remote = None
    stage = 'fixture'
    try:
        read, write = map(duplicate, os.pipe()); ir, iw = map(duplicate, os.pipe()); fds += [read, write, ir, iw]
        os.write(iw, public(keys/'key-0.pub')); os.close(iw); fds.remove(iw)
        prefix = {'key': 'key-auth-', 'mfa': 'mfa-key-auth-', 'prompts': 'interactive-auth-'}[method]
        peer = Child([fixture, prefix+scenario], root, label+'-fixture', stdin=ir, stdout=write); children.append(peer)
        os.close(ir); fds.remove(ir); os.close(write); fds.remove(write)
        ready = line(read, root, label+'-ready'); host = bytes.fromhex(ready['generatedPublicKey'])
        store = directory(root/'state'/label)
        descriptors = [duplicate(os.open(store, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC))]
        for name in ['catalog.sqlite', 'owner.lock']:
            descriptors.append(duplicate(os.open(store/name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)))
        fds += descriptors; fcntl.flock(descriptors[2], fcntl.LOCK_EX | fcntl.LOCK_NB)
        parent, remote = socket.socketpair(); parent.settimeout(12)
        wire = fcntl.fcntl(remote.fileno(), fcntl.F_DUPFD_CLOEXEC, 10); fds.append(wire)
        body = scenario.startswith('composed-'); mode = ('key-' if method == 'key' else 'interactive-') + ('upload' if body else 'transfer')
        magic = (b'MEXSFTP7' if body else b'MEXSFTP6') if method == 'key' else (b'MEXSFTPA' if body else b'MEXSFTP9')
        worker = Child([binary, '--'+mode+'-paged-worker'], root, label+'-worker', descriptors=dict(zip([3,4,5,6], [wire, *descriptors]))); children.append(worker)
        remote.close(); remote = None; os.close(wire); fds.remove(wire)
        channel = Channel(parent, magic)
        channel.send(1, field(b'generated.example') + field(b'127.0.0.1') + struct.pack('>HI', ready['port'], 0) + field(b'')
                     + field(str(store/'catalog.sqlite').encode()) + struct.pack('>Q', 8 << 20))
        value = Fields(channel.event(100)); assert value.number('>B') == 1 and value.field() == b'generated.example' and value.number('>H') == ready['port'] and value.field() == host and value.field() == b''; value.end()
        channel.send(2, b'\1' + field(host)); assert channel.event(101) == b''
        stage = 'authentication'; rounds = authenticate(channel, keys, method)
        stage = 'metadata'; generation, state, rows = listing(channel)
        selected = next(row for row in rows if row['name'] == b'Requested.bin')
        stage = 'download'; received, ended = download(channel, root, read, generation, selected, scenario)
        sent = None
        if ended is None:
            stage = 'upload'; sent, ended = upload(channel, root, read, generation, state, scenario)
            if ended is None:
                stage = 'refreshed-metadata'; _, _, rows = listing(channel, count=3)
                assert any(row['name'] == b'Draft-Notes.bin' and row['size'] == sent['bytes'] for row in rows)
                channel.send(6); ended = terminal(channel)
        stage = 'drain'; assert ended['tasksAfter'] == 0 and ended['writerEnd'] == 1 and ended['sshEnded'] == 1
        assert worker.wait() == 0 and parent.recv(1) == b'' and worker.log.stat().st_size == 0
        observed = line(read, root, label+'-fixture-ended')
        assert observed['ended'] and observed['runtimeTasksAfter'] == 0 and observed['fixtureTasksAborted'] == 0
        assert observed['authCalls'] == (0 if method == 'prompts' else 1) and observed['interactiveCalls'] == (0 if method == 'key' else 3)
        assert peer.wait() == 0 and peer.log.stat().st_size == 0
        if sent:
            published = sent['completed'] or sent.get('publicationMayHaveHappened', False)
            assert observed['uploadPublishedLengthPlusOne'] == (65554 if published else 0)
            if published: assert observed['uploadFinalSHA256'] == sent['sha256']
        assert worker.stats.ru_maxrss <= 256 << 20 and peer.stats.ru_maxrss <= 256 << 20
        result = dict(passed=True, method=method, scenario=scenario, authenticationRounds=rounds, received=received, sent=sent,
                      fixture=observed, terminal=ended, actualWorkerExit=worker.status, actualFixtureExit=peer.status, ipcEOF=True)
        d.put(root/'evidence'/(label+'-result.json'), result); return result
    except BaseException as error:
        d.put(root/'evidence'/(label+'-failure.json'), dict(passed=False, stage=stage, error=type(error).__name__)); raise
    finally:
        try:
            for child in reversed(children): child.contain()
        finally:
            if parent: parent.close()
            if remote: remote.close()
            for fd in fds: os.close(fd)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--build-case', required=True); parser.add_argument('--only'); parser.add_argument('--skip', action='append', default=[])
    args = parser.parse_args(); prepare()
    proof = json.loads((d.ROOT/args.build_case/'evidence/result.json').read_bytes())
    mode = 'release' if proof['release'] else 'debug'; binary = TOOLING/'target'/mode/'catalog_worker'; fixture = binary.with_name('key_fixture')
    if not proof['passed'] or proof['sources'] != sources() or any(d.digest(TOOLING/'target'/mode/name) != value for name,value in proof['binaries'].items()):
        raise RuntimeError('Current source-bound worker/fixture controls required')
    keys_case = d.ROOT/'C4D28241-2E4A-4F4D-AF4B-688E164885EE'
    if not json.loads((keys_case/'evidence/result.json').read_bytes())['passed']: raise RuntimeError('Passed generated key matrix required')
    cases = [(method+'-complete', method, 'composed-success') for method in ['key','prompts','mfa']]
    cases += [('mfa-'+name, 'mfa', name) for name in ['transfer-denied','transfer-changed','transfer-stop','transfer-lost-close',
                                                    'composed-sync-failure','composed-lost-rename','composed-stop-write']]
    if args.only: cases = [case for case in cases if case[0] == args.only]
    cases = [case for case in cases if case[0] not in args.skip]
    if not cases: raise RuntimeError('Known generated composition case required')
    root = d.reserve('sftp-auth-transfer-wire'); results = []
    d.put(root/'inputs.json', dict(workerCase=args.build_case, workerSources=proof['sources'], toolSHA256=d.digest(Path(__file__)),
          generatedOnly=True, cases=[case[0] for case in cases], privateSources=0, keychainCalls=0, ordinaryRoutingChanged=False))
    try:
        for label, method, scenario in cases:
            results.append(live(root, binary, fixture, keys_case/'state', label, method, scenario))
            print(json.dumps(dict(case=root.name, label=label, passed=True)), flush=True)
        if proof['sources'] != sources(): raise RuntimeError('Worker source fence changed')
        d.put(root/'evidence/result.json', dict(passed=True, cases=results, usage=audit()))
    except BaseException as error:
        d.put(root/'evidence/result.json', dict(passed=False, error=type(error).__name__, completed=results, usage=audit())); raise


if __name__ == '__main__': main()
