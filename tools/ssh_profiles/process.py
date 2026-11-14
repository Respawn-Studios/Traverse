"""Exact generated children and bounded versioned worker channel."""
import hashlib
import json
import os
import select
import signal
import struct
import time
import uuid
from packet import audit, d, TOOLING


class Child:
    def __init__(self, command, root, label, stdin=None, stdout=None, descriptors=None):
        self.root = root; self.label = label; self.status = None; self.stats = None; self.contained = False; self.began = time.monotonic()
        if not str(command[0]).startswith(str(TOOLING / 'target') + '/'):
            raise RuntimeError('Only generated Rust binaries in this process owner')
        self.log = root / 'evidence' / (label + '.stderr')
        with self.log.open('xb') as log, open('/dev/null', 'rb') as null:
            actions = [(os.POSIX_SPAWN_DUP2, null.fileno(), 0), (os.POSIX_SPAWN_DUP2, log.fileno(), 1), (os.POSIX_SPAWN_DUP2, log.fileno(), 2)]
            if stdin is not None: actions.append((os.POSIX_SPAWN_DUP2, stdin, 0))
            if stdout is not None: actions.append((os.POSIX_SPAWN_DUP2, stdout, 1))
            for target, source in (descriptors or {}).items():
                if target not in [3, 4, 5, 6] or source < 10: raise RuntimeError('Owned descriptor mapping')
                actions.append((os.POSIX_SPAWN_DUP2, source, target))
            self.pid = os.posix_spawn(str(command[0]), list(map(str, command)), {'LANG': 'C', 'LC_ALL': 'C'}, file_actions=actions, setpgroup=0)
        try:
            d.put(root / 'evidence' / (label + '.started.json'), {'pid': self.pid, 'ownedGroup': self.pid, 'binarySHA256': d.digest(command[0])})
        except BaseException:
            self.contain()
            raise
    def poll(self):
        if self.status is None:
            found, status, stats = os.wait4(self.pid, os.WNOHANG)
            if found: self.status = os.waitstatus_to_exitcode(status); self.stats = stats
        return self.status
    def wait(self, timeout=8):
        began = time.monotonic()
        while self.poll() is None:
            if time.monotonic() - began > timeout or self.log.stat().st_size > 65536:
                raise RuntimeError('Owned generated child deadline/output')
            audit(); time.sleep(.02)
        value = {'actualExit': self.status, 'contained': self.contained, 'seconds': time.monotonic() - self.began,
                 'peakRSSBytes': self.stats.ru_maxrss, 'stderrSHA256': d.digest(self.log)}
        path = self.root / 'evidence' / (self.label + '.exit.json')
        if not path.exists(): d.put(path, value)
        return self.status
    def contain(self):
        if self.poll() is None:
            self.contained = True
            for sig in [signal.SIGTERM, signal.SIGKILL]:
                try: os.killpg(self.pid, sig)
                except ProcessLookupError: pass
                except PermissionError:
                    # macOS may reject a signal during an already exiting
                    # signed child's final teardown. Require actual wait4;
                    # a living/inaccessible child remains an explicit error.
                    until = time.monotonic() + .5
                    while self.poll() is None and time.monotonic() < until:
                        time.sleep(.01)
                    if self.status is None: raise
                    self.wait(); return
                try: self.wait(timeout=3); return
                except RuntimeError: pass
            raise RuntimeError('Exact generated child is still live')
        self.wait()


def line(descriptor, root, label, timeout=10):
    began = time.monotonic(); value = bytearray()
    while True:
        remaining = timeout - (time.monotonic() - began)
        if remaining <= 0 or not select.select([descriptor], [], [], min(.2, remaining))[0]:
            if remaining <= 0: raise RuntimeError('Generated fixture response deadline')
            audit(); continue
        part = os.read(descriptor, 1)
        if part == b'\n': break
        if not part or len(value) >= 65536: raise RuntimeError('Generated fixture response bound/EOF')
        value.extend(part)
    result = json.loads(value)
    d.put(root / 'evidence' / (label + '.json'), result)
    return result


def field(data): return struct.pack('>I', len(data)) + data


class Fields:
    def __init__(self, data): self.data = data; self.offset = 0
    def take(self, size):
        if size < 0 or self.offset + size > len(self.data): raise RuntimeError('Generated field truncated')
        value = self.data[self.offset:self.offset+size]; self.offset += size; return value
    def number(self, form): return struct.unpack(form, self.take(struct.calcsize(form)))[0]
    def field(self):
        count = self.number('>I')
        if count > 32768: raise RuntimeError('Generated field cap')
        return self.take(count)
    def end(self):
        if self.offset != len(self.data): raise RuntimeError('Generated trailing response data')


class Channel:
    def __init__(self, sock, magic=b'MEXSFTP5'):
        self.sock = sock; self.magic = magic; self.session = uuid.uuid4().bytes; self.sending = 0; self.receiving = 0
    def send(self, kind, body=b''):
        message = self.magic + self.session + struct.pack('>Q', self.sending) + bytes([kind]) + body
        if len(message) > 65536: raise RuntimeError('Generated worker frame cap')
        self.sock.sendall(struct.pack('>I', len(message)) + message); self.sending += 1
    def read(self, size):
        data = bytearray()
        while len(data) < size:
            part = self.sock.recv(size-len(data))
            if not part: raise RuntimeError('Generated worker unexpected EOF')
            data.extend(part)
        return bytes(data)
    def event(self, kind):
        actual, body = self.next_event()
        if actual != kind: raise RuntimeError('Generated response kind mismatch')
        return body
    def next_event(self):
        size = struct.unpack('>I', self.read(4))[0]
        if not 33 <= size <= 65536: raise RuntimeError('Generated response frame cap')
        value = self.read(size)
        if value[:8] != self.magic or value[8:24] != self.session or struct.unpack('>Q', value[24:32])[0] != self.receiving:
            raise RuntimeError('Generated response version/session/sequence mismatch')
        self.receiving += 1; return value[32], value[33:]
