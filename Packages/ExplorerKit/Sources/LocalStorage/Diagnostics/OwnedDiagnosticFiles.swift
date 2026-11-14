import Darwin
import Foundation

/// Confined to DiagnosticRecorder's serial queue. This store is never authority
/// to change user files or operation history; malformed/foreign state is refused.
final class OwnedDiagnosticFiles {
    struct Header: Codable { let schema: Int; let owner: UUID; let segment: UInt64; let began: Int64 }
    struct Marker: Codable { let schema: Int; let owner: UUID }
    struct Segment {
        let number: UInt64
        let name: String
        let header: Header
        let identity: Identity
        var bytes: Int
    }
    struct Identity: Equatable {
        let device: dev_t; let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private let limits: DiagnosticHistoryLimits
    private let parent: Int32
    private let directory: Int32
    private let lockFD: Int32
    private let leaf: String
    private let directoryIdentity: Identity
    private let markerIdentity: Identity
    private let lockIdentity: Identity
    private let descriptors: DiagnosticDescriptors
    let owner: UUID
    private var segments: [Segment] = []
    private var current: (fd: Int32, number: UInt64, identity: Identity, bytes: Int)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let probe: (@Sendable (DiagnosticStorageStage) throws -> Void)?
    private var total = 8192 // Reserve the marker/lock/allocation rounding too.
    private var nextNumber: UInt64 = 1

    init(directory url: URL, limits: DiagnosticHistoryLimits,
         probe: (@Sendable (DiagnosticStorageStage) throws -> Void)? = nil) throws {
        self.limits = limits; self.probe = probe
        leaf = url.lastPathComponent
        guard url.isFileURL, !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
            throw DiagnosticHistoryFailure.invalidInput
        }
        let p = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard p >= 0 else { throw DiagnosticHistoryFailure.io(errno) }
        var parentStat = stat()
        guard fstat(p, &parentStat) == 0, parentStat.st_uid == geteuid(), parentStat.st_mode & 0o022 == 0 else {
            close(p); throw DiagnosticHistoryFailure.changed
        }
        if mkdirat(p, leaf, 0o700) != 0 && errno != EEXIST { let code = errno; close(p); throw DiagnosticHistoryFailure.io(code) }
        let d = openat(p, leaf, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard d >= 0 else { let code = errno; close(p); throw DiagnosticHistoryFailure.io(code) }
        var ds = stat()
        guard fstat(d, &ds) == 0, ds.st_uid == geteuid(), ds.st_mode & 0o777 == 0o700 else {
            close(d); close(p); throw DiagnosticHistoryFailure.changed
        }
        do {
            let existing = try Self.names(d)
            guard existing.isEmpty || (existing.contains("owner.json") && existing.contains("writer.lock")
                && existing.allSatisfy({ $0 == "owner.json" || $0 == "writer.lock" || Self.number($0) != nil })) else {
                throw DiagnosticHistoryFailure.changed
            }
        } catch { close(d); close(p); throw error }
        let l = openat(d, "writer.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard l >= 0 else { let code = errno; close(d); close(p); throw DiagnosticHistoryFailure.io(code) }
        var ls = stat()
        guard fstat(l, &ls) == 0, Self.privateFile(ls), ls.st_size == 0 else {
            close(l); close(d); close(p); throw DiagnosticHistoryFailure.changed
        }
        guard flock(l, LOCK_EX | LOCK_NB) == 0 else {
            close(l); close(d); close(p); throw DiagnosticHistoryFailure.busy
        }
        var accepted = false
        defer { if !accepted { close(l); close(d); close(p) } }
        let names = try Self.names(d)
        let marker: Marker
        if names.contains("owner.json") {
            marker = try JSONDecoder().decode(Marker.self, from: Self.read(d, "owner.json", maximum: 512).0)
            guard marker.schema == 1 else { throw DiagnosticHistoryFailure.incompatible }
        } else {
            guard names == ["writer.lock"] else { throw DiagnosticHistoryFailure.changed }
            marker = Marker(schema: 1, owner: UUID())
            let m = openat(d, "owner.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard m >= 0 else { throw DiagnosticHistoryFailure.io(errno) }
            do {
                try Self.write(m, JSONEncoder().encode(marker)); try Self.sync(m); try Self.sync(d); close(m)
            } catch { close(m); throw error }
        }
        parent = p; directory = d; lockFD = l; directoryIdentity = Identity(ds); owner = marker.owner
        markerIdentity = try Self.read(d, "owner.json", maximum: 512).1; lockIdentity = Identity(ls)
        descriptors = DiagnosticDescriptors([p,d,l])
        encoder.outputFormatting = [.sortedKeys]
        accepted = true
        do { try loadSegments() }
        catch { throw error }
    }

    deinit { if let current { close(current.fd) } }

    func append(_ events: [DiagnosticEvent], now: Date) throws {
        try validate()
        for event in events {
            guard event.isValid else { throw DiagnosticHistoryFailure.invalidInput }
            var bytes = try encoder.encode(event); bytes.append(10)
            guard bytes.count <= 2048 else { throw DiagnosticHistoryFailure.capacity }
            let expired = current.flatMap { active in segments.first { $0.number == active.number } }
                .map { $0.header.began < DiagnosticEvent.milliseconds(now) - Int64(limits.retentionSeconds * 1000) } ?? false
            if current == nil || current!.bytes + bytes.count > limits.segmentBytes || expired {
                try finishSegment(); try startSegment(now: now)
            }
            try makeRoom(additional: bytes.count, now: now)
            guard var active = current else { throw DiagnosticHistoryFailure.unavailable }
            try validateFile(active.fd, name: Self.name(active.number), identity: active.identity, bytes: active.bytes)
            try probe?(.beforeAppend)
            try validateFile(active.fd, name: Self.name(active.number), identity: active.identity, bytes: active.bytes)
            do { try Self.write(active.fd, bytes) }
            catch {
                var partial = stat()
                if fstat(active.fd, &partial) == 0, Identity(partial) == active.identity,
                   partial.st_size >= active.bytes, partial.st_size <= limits.segmentBytes,
                   let index = segments.firstIndex(where: { $0.number == active.number }) {
                    total += Int(partial.st_size) - active.bytes; segments[index].bytes = Int(partial.st_size)
                }
                current = nil; close(active.fd); throw error
            }
            active.bytes += bytes.count; current = active
            if let i = segments.firstIndex(where: { $0.number == active.number }) { segments[i].bytes = active.bytes }
            total += bytes.count
        }
        if let current { try probe?(.beforeSync); try Self.sync(current.fd) }
        try validate()
    }

    func page(before cursor: DiagnosticHistoryCursor?, limit: Int, errorsOnly: Bool,
              traces: Set<UUID>? = nil) throws -> DiagnosticHistoryPage {
        guard (1...256).contains(limit), cursor == nil || cursor?.owner == owner else {
            throw DiagnosticHistoryFailure.invalidInput
        }
        try validate()
        if let cursor, !segments.contains(where: { $0.number == cursor.segment }) {
            return .init(events: [], next: nil, incomplete: true)
        }
        var events: [DiagnosticEvent] = [], incomplete = false, next: DiagnosticHistoryCursor?
        var examined = 0
        let candidates = segments.reversed().filter { cursor == nil || $0.number <= cursor!.segment }
        for segment in candidates {
            let (data, identity) = try Self.read(directory, segment.name, maximum: limits.segmentBytes)
            guard identity == segment.identity else { throw DiagnosticHistoryFailure.changed }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            guard let headerLine = lines.first,
                  let header = try? decoder.decode(Header.self, from: Data(headerLine)),
                  header.schema == 1, header.owner == owner, header.segment == segment.number else {
                throw DiagnosticHistoryFailure.changed
            }
            let completeLines = lines.count - 1 // Never decode an interrupted trailing record.
            if data.last != 10 { incomplete = true }
            let upper = cursor?.segment == segment.number ? min(cursor!.before, completeLines) : completeLines
            if upper > 1 {
                for index in stride(from: upper - 1, through: 1, by: -1) {
                    let value = Data(lines[index])
                    if value.count > 2048 { incomplete = true }
                    else if let event = try? decoder.decode(DiagnosticEvent.self, from: value), event.isValid {
                        if (!errorsOnly || event.level != .information),
                           traces?.contains(event.trace) ?? true { events.append(event) }
                    } else { incomplete = true }
                    next = DiagnosticHistoryCursor(owner: owner, segment: segment.number, before: index)
                    if events.count == limit {
                        return .init(events: events, next: next, incomplete: incomplete)
                    }
                }
            }
            examined += 1
            if examined >= 2, let index = segments.firstIndex(where: { $0.number == segment.number }), index > 0 {
                return .init(events: events, next: .init(owner: owner, segment: segments[index-1].number, before: Int.max), incomplete: incomplete)
            }
        }
        return .init(events: events, next: nil, incomplete: incomplete)
    }

    func clear() throws {
        try validate(); try finishSegment()
        while let segment = segments.first {
            try remove(segment); segments.removeFirst(); total -= segment.bytes + 4096
        }
        try Self.sync(directory)
    }

    func expire(now: Date) throws {
        if let current, let active = segments.first(where: { $0.number == current.number }),
           active.header.began < DiagnosticEvent.milliseconds(now) - Int64(limits.retentionSeconds * 1000) {
            try finishSegment()
        }
        try makeRoom(additional: 0, now: now)
    }

    func synchronize() throws { if let current { try Self.sync(current.fd) }; try validate() }

    private func loadSegments() throws {
        let names = try Self.names(directory)
        for name in names where name != "owner.json" && name != "writer.lock" {
            guard let number = Self.number(name), number > 0 else { throw DiagnosticHistoryFailure.changed }
            let (data, identity) = try Self.read(directory, name, maximum: limits.segmentBytes)
            guard let first = data.split(separator: 10).first else { throw DiagnosticHistoryFailure.changed }
            let header = try decoder.decode(Header.self, from: Data(first))
            guard header.schema == 1, header.owner == owner, header.segment == number else { throw DiagnosticHistoryFailure.changed }
            segments.append(.init(number: number, name: name, header: header, identity: identity, bytes: data.count))
            total += data.count + 4096
        }
        segments.sort { $0.number < $1.number }
        guard segments.count <= 64, total <= limits.bytes else { throw DiagnosticHistoryFailure.capacity }
        if let last = segments.last { guard last.number < UInt64.max else { throw DiagnosticHistoryFailure.capacity }; nextNumber = last.number + 1 }
    }

    private func startSegment(now: Date) throws {
        try makeRoom(additional: 512 + 4096, now: now, starting: true)
        let number = nextNumber
        guard number < UInt64.max else { throw DiagnosticHistoryFailure.capacity }
        nextNumber += 1
        let header = Header(schema: 1, owner: owner, segment: number, began: DiagnosticEvent.milliseconds(now))
        var bytes = try encoder.encode(header); bytes.append(10)
        let name = Self.name(number)
        let fd = openat(directory, name, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DiagnosticHistoryFailure.io(errno) }
        do {
            try Self.write(fd, bytes); try Self.sync(fd); try Self.sync(directory)
            var st = stat(); guard fstat(fd, &st) == 0, Self.privateFile(st) else { throw DiagnosticHistoryFailure.changed }
            let identity = Identity(st)
            current = (fd, number, identity, bytes.count)
            segments.append(.init(number: number, name: name, header: header, identity: identity, bytes: bytes.count))
            total += bytes.count + 4096
        } catch { close(fd); throw error }
    }

    private func makeRoom(additional: Int, now: Date, starting: Bool = false) throws {
        let cutoff = DiagnosticEvent.milliseconds(now) - Int64(limits.retentionSeconds * 1000)
        while let oldest = segments.first,
              oldest.number != current?.number,
              oldest.header.began < cutoff || total + additional > limits.bytes || (starting && segments.count >= 64) {
            try remove(oldest); segments.removeFirst(); total -= oldest.bytes + 4096
        }
        guard total + additional <= limits.bytes else { throw DiagnosticHistoryFailure.capacity }
    }
    private func remove(_ segment: Segment) throws {
        try validate()
        let fd = openat(directory, segment.name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw DiagnosticHistoryFailure.changed }
        defer { close(fd) }
        try validateFile(fd, name: segment.name, identity: segment.identity, bytes: segment.bytes)
        try probe?(.beforeRemove)
        try validateFile(fd, name: segment.name, identity: segment.identity, bytes: segment.bytes)
        // Only an already-validated name in this private owned directory.
        guard unlinkat(directory, segment.name, 0) == 0 else { throw DiagnosticHistoryFailure.io(errno) }
    }
    private func finishSegment() throws {
        guard let active = current else { return }
        try Self.sync(active.fd); close(active.fd); current = nil
    }
    private func validate() throws {
        var a = stat(), b = stat()
        guard fstat(directory, &a) == 0, fstatat(parent, leaf, &b, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(a) == directoryIdentity, Identity(b) == directoryIdentity,
              a.st_uid == geteuid(), b.st_mode & S_IFMT == S_IFDIR, a.st_mode & 0o777 == 0o700 else {
            throw DiagnosticHistoryFailure.changed
        }
        try validateFile(lockFD, name: "writer.lock", identity: lockIdentity, bytes: 0)
        let (bytes, identity) = try Self.read(directory, "owner.json", maximum: 512)
        let marker = try decoder.decode(Marker.self, from: bytes)
        guard identity == markerIdentity, marker.schema == 1, marker.owner == owner else { throw DiagnosticHistoryFailure.changed }
    }
    private func validateFile(_ fd: Int32, name: String, identity: Identity, bytes: Int) throws {
        var a = stat(), b = stat()
        guard fstat(fd, &a) == 0, fstatat(directory, name, &b, AT_SYMLINK_NOFOLLOW) == 0,
              Self.privateFile(a), Self.privateFile(b), Identity(a) == identity, Identity(b) == identity,
              a.st_size == bytes, b.st_size == bytes else { throw DiagnosticHistoryFailure.changed }
    }
    private static func privateFile(_ st: stat) -> Bool {
        st.st_mode & S_IFMT == S_IFREG && st.st_mode & 0o777 == 0o600 && st.st_uid == geteuid() && st.st_nlink == 1
    }
    private static func name(_ number: UInt64) -> String { "events-" + String(format: "%016llx", number) + ".jsonl" }
    private static func number(_ name: String) -> UInt64? {
        guard name.utf8.count == 29, name.hasPrefix("events-"), name.hasSuffix(".jsonl") else { return nil }
        let digits = name.dropFirst(7).dropLast(6)
        guard digits.count == 16, digits.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return UInt64(digits, radix: 16)
    }
    private static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let directory = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw DiagnosticHistoryFailure.io(errno) }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= 66 else { throw DiagnosticHistoryFailure.capacity }
        }
        return names.sorted()
    }
    private static func read(_ directory: Int32, _ name: String, maximum: Int) throws -> (Data, Identity) {
        let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw DiagnosticHistoryFailure.changed }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, privateFile(st), st.st_size >= 0, st.st_size <= maximum else { throw DiagnosticHistoryFailure.changed }
        var data = Data(count: Int(st.st_size))
        let count = data.count
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let got = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { throw DiagnosticHistoryFailure.io(errno) }; offset += got
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Identity(after) == Identity(st), after.st_size == st.st_size else { throw DiagnosticHistoryFailure.changed }
        return (data, Identity(st))
    }
    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let got = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { throw DiagnosticHistoryFailure.io(errno) }; offset += got
            }
        }
    }
    private static func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw DiagnosticHistoryFailure.io(errno) }
    }
}

enum DiagnosticStorageStage: Sendable { case beforeAppend, beforeSync, beforeRemove }

private final class DiagnosticDescriptors {
    let values: [Int32]
    init(_ values: [Int32]) { self.values = values }
    deinit { for value in values { close(value) } }
}
