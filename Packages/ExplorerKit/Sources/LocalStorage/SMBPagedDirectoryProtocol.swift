import Foundation

@_spi(Qualification) public enum SMBDirectoryReadState: String, Sendable { case loading, complete, partial, stopped }
@_spi(Qualification) public enum SMBDirectorySort: String, Sendable { case name, size, modified }
@_spi(Qualification) public struct SMBDirectorySnapshot: Sendable, Equatable {
    public let readID: UUID
    public let revision: UInt64
    public let count: Int64
    public let folders: Int64
    public let state: SMBDirectoryReadState
}
struct SMBDirectoryFindRequest: Sendable, Equatable {
    let query: RemoteDirectoryFindQuery
    let snapshot: SMBDirectorySnapshot
    var token: UUID { query.id }
    var fields: String {
        let state: Int
        switch snapshot.state { case .loading: state = 0; case .complete: state = 1; case .partial: state = 2; case .stopped: state = 3 }
        let hex = query.text.utf8.map { String(format: "%02x", $0) }.joined()
        return "\(snapshot.readID.uuidString) \(snapshot.revision) \(snapshot.count) \(snapshot.folders) \(state) \(hex)"
    }
    var command: String { "FIND \(token.uuidString) \(fields)\n" }
}
@_spi(Qualification) public struct SMBDirectoryPageRequest: Sendable, Equatable {
    public let token: UUID
    public let snapshot: SMBDirectorySnapshot
    public let offset: Int64
    public let sort: SMBDirectorySort
    public let descending: Bool
    public let find: SMBDirectoryFindResult?
    public init(snapshot: SMBDirectorySnapshot, offset: Int64, sort: SMBDirectorySort = .name, descending: Bool = false,
                find: SMBDirectoryFindResult? = nil) throws {
        guard offset >= 0 else { throw SMBDirectoryFailure.invalidInput }
        guard find == nil || find?.snapshot == snapshot else { throw RemoteDirectoryFindFailure.stale }
        token = UUID(); self.snapshot = snapshot; self.offset = offset; self.sort = sort; self.descending = descending
        self.find = find
    }
    var command: String {
        "PAGE \(token.uuidString) \(snapshot.readID.uuidString) \(snapshot.revision) \(offset) \(sort.rawValue) \(descending ? 1 : 0)\(find.map { " " + $0.query.id.uuidString } ?? "")\n"
    }
}
@_spi(Qualification) public struct SMBDirectoryObservation: Sendable, Equatable {
    public let id: Int64
    public let name: SMBRemoteName
    public let attributes: UInt32
    public let logicalBytes: UInt64
    public let modifiedFileTime: UInt64
    /// Same-session class-37 filesystem IDs. These are never SMB open handles
    /// and cannot authorize a mutation without fresh server revalidation.
    public let objectID: UInt64?
    public let parentID: UInt64?
    public init(id: Int64, name: SMBRemoteName, attributes: UInt32, logicalBytes: UInt64,
                modifiedFileTime: UInt64, objectID: UInt64? = nil, parentID: UInt64? = nil) {
        self.id = id; self.name = name; self.attributes = attributes
        self.logicalBytes = logicalBytes; self.modifiedFileTime = modifiedFileTime
        self.objectID = objectID; self.parentID = parentID
    }
    public var isDirectory: Bool { attributes & 16 != 0 }
    public var isReparsePoint: Bool { attributes & 0x400 != 0 }
}
@_spi(Qualification) public struct SMBDirectoryPage: Sendable {
    public let request: SMBDirectoryPageRequest
    public let entries: [SMBDirectoryObservation]
}
@_spi(Qualification) public enum SMBDirectoryFailure: Error, Sendable, Equatable {
    case invalidInput, invalidOutput, stale, busy, stopped, unavailable, storage, quota, containment
}
enum SMBDirectoryCatalogEvent: Sendable {
    case snapshot(SMBDirectorySnapshot), page(SMBDirectoryPage), stale(UUID), closed(String)
    case found(SMBDirectoryFindResult), findStale(UUID), queryUnavailable(UUID)
}

/// A bounded local metadata protocol, separate from authenticated network framing.
/// Pages become visible only after their exact terminal. A revision change closes
/// publication for any older page; the caller may explicitly request a fresh one.
struct SMBDirectoryCatalogDecoder {
    let session: UUID
    let read: UUID
    private var sequence: UInt64 = 0
    private(set) var snapshot: SMBDirectorySnapshot?
    private(set) var pending: SMBDirectoryPageRequest?
    private var pendingFind: SMBDirectoryFindRequest?
    private var activeFind: SMBDirectoryFindResult?
    private(set) var closed = false
    private var entries: [SMBDirectoryObservation] = []
    private var ids = Set<Int64>()
    private var names = Set<Data>()
    init(session: UUID, read: UUID) { self.session = session; self.read = read }
    mutating func request(_ value: SMBDirectoryPageRequest) throws {
        guard !closed, pending == nil, pendingFind == nil else { throw SMBDirectoryFailure.busy }
        guard value.snapshot == snapshot, value.offset >= 0 else { throw SMBDirectoryFailure.stale }
        guard value.find == nil || value.find == activeFind else { throw RemoteDirectoryFindFailure.stale }
        pending = value; entries = []; ids = []; names = []
    }
    mutating func request(_ value: SMBDirectoryFindRequest) throws {
        guard !closed, pending == nil, pendingFind == nil else { throw SMBDirectoryFailure.busy }
        guard value.snapshot == snapshot else { throw RemoteDirectoryFindFailure.stale }
        pendingFind = value; activeFind = nil
    }
    mutating func consume(_ line: Data) throws -> SMBDirectoryCatalogEvent? {
        guard !closed, !line.isEmpty, line.count <= 16512, line.allSatisfy({ (32...126).contains($0) }),
              let text = String(data: line, encoding: .ascii) else { throw SMBDirectoryFailure.invalidOutput }
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0] == "MEXSMBC1", parts[1] == session.uuidString,
              try number(parts[2], UInt64.self) == sequence, sequence < UInt64.max else { throw SMBDirectoryFailure.invalidOutput }
        sequence += 1
        switch parts[3] {
        case "snapshot":
            guard parts.count == 9, parts[4] == read.uuidString,
                  let state = SMBDirectoryReadState(rawValue: parts[8]) else { throw SMBDirectoryFailure.invalidOutput }
            let revision = try number(parts[5], UInt64.self), count = try number(parts[6], Int64.self), folders = try number(parts[7], Int64.self)
            // Even the minimum row cannot fit more observations than this in
            // the approved 512 MiB store. Refuse impossible native row counts.
            guard folders <= count, count <= (512 << 20) / 16 else { throw SMBDirectoryFailure.invalidOutput }
            if let previous = snapshot {
                guard previous.state == .loading, revision > previous.revision, count >= previous.count,
                      folders >= previous.folders else { throw SMBDirectoryFailure.invalidOutput }
            }
            let value = SMBDirectorySnapshot(readID: read, revision: revision, count: count, folders: folders, state: state)
            if snapshot != value { activeFind = nil }
            snapshot = value; return .snapshot(value)
        case "find":
            guard parts.count == 12, let pendingFind, parts[4] == pendingFind.token.uuidString,
                  parts[5] == pendingFind.snapshot.readID.uuidString else { throw SMBDirectoryFailure.invalidOutput }
            let expected = pendingFind.snapshot
            let state: SMBDirectoryReadState
            switch parts[9] { case "0": state = .loading; case "1": state = .complete; case "2": state = .partial; case "3": state = .stopped; default: throw SMBDirectoryFailure.invalidOutput }
            let count = try number(parts[10], Int64.self), folders = try number(parts[11], Int64.self)
            guard try number(parts[6], UInt64.self) == expected.revision,
                  try number(parts[7], Int64.self) == expected.count, try number(parts[8], Int64.self) == expected.folders,
                  state == expected.state, folders <= count, folders <= expected.folders, count <= expected.count else { throw SMBDirectoryFailure.invalidOutput }
            let result = try SMBDirectoryFindResult(query: pendingFind.query, snapshot: expected, count: count, folders: folders)
            self.pendingFind = nil
            guard snapshot == expected else { return .findStale(pendingFind.token) }
            activeFind = result; return .found(result)
        case "findStale", "findUnavailable":
            guard parts.count == 6, let pendingFind, parts[4] == pendingFind.token.uuidString,
                  parts[3] == "findStale" ? parts[5] == pendingFind.snapshot.readID.uuidString : parts[5] == "deadline" else {
                throw SMBDirectoryFailure.invalidOutput
            }
            self.pendingFind = nil
            return parts[3] == "findStale" ? .findStale(pendingFind.token) : .queryUnavailable(pendingFind.token)
        case "row", "findRow":
            if parts[3] == "findRow" {
                guard parts.count == 13, let find = pending?.find, parts[5] == find.query.id.uuidString else { throw SMBDirectoryFailure.invalidOutput }
                parts.remove(at: 5)
            } else { guard pending?.find == nil else { throw SMBDirectoryFailure.invalidOutput } }
            guard [10,12].contains(parts.count), let pending, parts[4] == pending.token.uuidString,
                  entries.count < 256 else { throw SMBDirectoryFailure.invalidOutput }
            let id = try number(parts[5], Int64.self), attributes = try number(parts[6], UInt32.self), size = try number(parts[7], UInt64.self), modified = try number(parts[8], UInt64.self)
            let object: UInt64?, parent: UInt64?
            if parts.count == 12 {
                let a = try number(parts[9], UInt64.self), b = try number(parts[10], UInt64.self)
                guard a != UInt64.max, b != UInt64.max, a == 0 || b == 0 || a != b else { throw SMBDirectoryFailure.invalidOutput }
                object = a == 0 ? nil : a; parent = b == 0 ? nil : b
            } else { object = nil; parent = nil }
            let raw = Array(parts.last!.utf8)
            guard id > 0, size <= UInt64(Int64.max), modified <= UInt64(Int64.max), !raw.isEmpty, raw.count <= 8192, raw.count % 4 == 0,
                  raw.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SMBDirectoryFailure.invalidOutput }
            var wire = Data()
            for start in stride(from: 0, to: raw.count, by: 4) {
                guard let unit = UInt16(String(decoding: raw[start..<start+4], as: UTF8.self), radix: 16) else { throw SMBDirectoryFailure.invalidOutput }
                wire.append(UInt8(unit & 255)); wire.append(UInt8(unit >> 8))
            }
            let name: SMBRemoteName
            do { name = try SMBRemoteName(wireUTF16: wire) } catch { throw SMBDirectoryFailure.invalidOutput }
            guard ids.insert(id).inserted, names.insert(wire).inserted else { throw SMBDirectoryFailure.invalidOutput }
            entries.append(SMBDirectoryObservation(id: id, name: name, attributes: attributes, logicalBytes: size,
                                                   modifiedFileTime: modified, objectID: object, parentID: parent))
            return nil
        case "page", "findPage":
            if parts[3] == "findPage" {
                guard parts.count == 12, let find = pending?.find, parts[5] == find.query.id.uuidString,
                      try number(parts[9], Int64.self) == find.count, try number(parts[10], Int64.self) == find.folders else { throw SMBDirectoryFailure.invalidOutput }
                parts.remove(at: 10); parts.remove(at: 9); parts.remove(at: 5)
            } else { guard pending?.find == nil else { throw SMBDirectoryFailure.invalidOutput } }
            guard parts.count == 9, let pending, parts[4] == pending.token.uuidString, parts[5] == read.uuidString,
                  try number(parts[6], UInt64.self) == pending.snapshot.revision,
                  try number(parts[7], Int64.self) == pending.offset,
                  try number(parts[8], Int.self) == entries.count,
                  entries.count == Int(min(256, max(0, (pending.find?.count ?? pending.snapshot.count) - min(pending.offset, pending.find?.count ?? pending.snapshot.count)))) else {
                throw SMBDirectoryFailure.invalidOutput
            }
            let value = SMBDirectoryPage(request: pending, entries: entries)
            clearPending()
            // A correctly delimited old response may have raced a new committed
            // snapshot; drain it, but never publish it into the newer display.
            return pending.snapshot == snapshot ? .page(value) : .stale(pending.token)
        case "stale", "findPageStale", "findPageUnavailable":
            let unavailable = parts[3] == "findPageUnavailable"
            if parts[3] != "stale" {
                guard parts.count == (unavailable ? 7 : 6), let find = pending?.find,
                      parts[5] == find.query.id.uuidString, !unavailable || parts[6] == "deadline" else { throw SMBDirectoryFailure.invalidOutput }
                if unavailable { parts.removeLast() }; parts.remove(at: 5)
            } else { guard pending?.find == nil else { throw SMBDirectoryFailure.invalidOutput } }
            guard parts.count == 5, let pending, parts[4] == pending.token.uuidString, entries.isEmpty else { throw SMBDirectoryFailure.invalidOutput }
            clearPending(); return unavailable ? .queryUnavailable(pending.token) : .stale(pending.token)
        case "closed":
            guard parts.count == 5, ["stopped", "complete", "storage", "quota", "invalid", "ipc"].contains(parts[4]) else { throw SMBDirectoryFailure.invalidOutput }
            clearPending(); pendingFind = nil; activeFind = nil; closed = true; return .closed(parts[4])
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }
    private mutating func clearPending() { pending = nil; entries = []; ids = []; names = [] }
    private func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = T(text), String(value) == text else { throw SMBDirectoryFailure.invalidOutput }
        return value
    }
}

/// At most two native pages. An item never changes identity just because a row
/// offset moved; snapshots and exact observation IDs belong to the result.
@_spi(Qualification) public struct SMBDirectoryPageCache: Sendable {
    public private(set) var snapshot: SMBDirectorySnapshot?
    public private(set) var find: SMBDirectoryFindResult?
    private var pages: [SMBDirectoryPage] = []
    public init() {}
    public var retainedCount: Int { pages.reduce(0) { $0 + $1.entries.count } }
    public var displayCount: Int64 { find?.count ?? snapshot?.count ?? 0 }
    public var loadedEntries: [(offset: Int64, row: SMBDirectoryObservation)] {
        let offsets = Set(pages.flatMap { page in page.entries.indices.map { page.request.offset + Int64($0) } })
        return offsets.sorted().compactMap { offset in entry(at: offset).map { (offset: offset, row: $0) } }
    }
    public mutating func observe(_ snapshot: SMBDirectorySnapshot) {
        if self.snapshot != snapshot { pages = []; find = nil }; self.snapshot = snapshot
    }
    public mutating func setFindResult(_ result: SMBDirectoryFindResult?) throws {
        if let result, result.snapshot != snapshot { throw RemoteDirectoryFindFailure.stale }
        if find != result { pages = [] }; find = result
    }
    public mutating func accept(_ page: SMBDirectoryPage) throws {
        guard page.request.snapshot == snapshot, page.entries.count <= 256,
              page.request.find == find, page.request.offset >= 0, page.request.offset <= displayCount,
              Int64(page.entries.count) <= displayCount - page.request.offset else { throw SMBDirectoryFailure.stale }
        var known: [Int64: SMBDirectoryObservation] = [:]
        for other in pages { for row in other.entries { known[row.id] = row } }
        for row in page.entries {
            if let existing = known[row.id], existing != row { throw SMBDirectoryFailure.invalidOutput }
        }
        pages.removeAll { $0.request.offset == page.request.offset || $0.request.sort != page.request.sort || $0.request.descending != page.request.descending }
        pages.append(page); if pages.count > 2 { pages.removeFirst() }
    }
    public func entry(at offset: Int64) -> SMBDirectoryObservation? {
        guard offset >= 0 else { return nil }
        for page in pages {
            let index = offset - page.request.offset
            if index >= 0, index < page.entries.count { return page.entries[Int(index)] }
        }
        return nil
    }
    public mutating func clear() { snapshot = nil; find = nil; pages = [] }
}
