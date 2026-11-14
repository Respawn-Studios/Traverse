import Foundation

/// One exact directory observation; it carries no caller-authored remote path.
@_spi(Qualification) public struct SMBFolderDownloadSelection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let request: UUID, connection: UUID
    public let snapshot: SMBDirectorySnapshot
    public let observation: SMBDirectoryObservation
    public var description: String { "<SMB folder selection>" }
    public var debugDescription: String { description }
    public var proposedLocalName: String? {
        guard let name = String(data: observation.name.wireUTF16, encoding: .utf16LittleEndian) else { return nil }
        return DownloadTreeManifest.localName(Data(name.utf8))
    }
    public init(connection: UUID, snapshot: SMBDirectorySnapshot, observation: SMBDirectoryObservation, request: UUID = UUID()) throws {
        let zero = "00000000-0000-0000-0000-000000000000"
        guard connection.uuidString != zero, request.uuidString != zero, snapshot.readID.uuidString != zero,
              snapshot.state == .complete, snapshot.revision > 0, snapshot.revision <= UInt64(Int64.max), snapshot.count > 0,
              observation.id > 0, observation.attributes & 0x450 == 0x10,
              observation.modifiedFileTime <= UInt64(Int64.max) else { throw SMBDirectoryFailure.invalidInput }
        self.connection = connection; self.request = request; self.snapshot = snapshot; self.observation = observation
    }
    func command(ordinal: UInt64, number: UInt64) -> String {
        "PREPARE_FOLDER \(request.uuidString) \(ordinal) \(number) \(snapshot.readID.uuidString) \(snapshot.revision) \(observation.id)\n"
    }
}

struct SMBFolderManifest: Sendable, Equatable {
    struct Node: Sendable, Equatable {
        let parent: Int?, wire: Data?
        let directory: Bool, attributes: UInt32
        let size: UInt64, allocated: UInt64, modified: UInt64, changed: UInt64, index: UInt64
        let volume: UInt32, links: UInt32
    }
    private struct Identity: Hashable { let volume: UInt32, index: UInt64 }
    let nodes: [Node]
    let local: DownloadTreeManifest
    init(nodes: [Node], selection: SMBFolderDownloadSelection) throws {
        guard !nodes.isEmpty, nodes.count <= 2_048 else { throw SMBDirectoryFailure.invalidOutput }
        var local: [DownloadTreeManifest.Node] = [], identities = Set<Identity>()
        for (ordinal, node) in nodes.enumerated() {
            guard node.attributes & 0x450 == (node.directory ? 0x10 : 0), node.index != 0, node.index != UInt64.max,
                  node.volume != 0, node.volume == nodes[0].volume, node.size <= UInt64(Int64.max),
                  node.allocated <= UInt64(Int64.max), node.modified <= UInt64(Int64.max), node.changed <= UInt64(Int64.max),
                  identities.insert(.init(volume: node.volume, index: node.index)).inserted,
                  node.links == (node.directory ? 0 : 1) else { throw SMBDirectoryFailure.invalidOutput }
            if ordinal == 0 {
                guard node.directory, node.parent == nil, node.wire == nil,
                      node.attributes == selection.observation.attributes, node.modified == selection.observation.modifiedFileTime else {
                    throw SMBDirectoryFailure.stale
                }
                local.append(.init(components: [], size: nil))
            } else {
                guard let parent = node.parent, parent >= 0, parent < ordinal, nodes[parent].directory, let wire = node.wire,
                      !wire.isEmpty, wire.count <= 510, wire.count % 2 == 0,
                      let text = String(data: wire, encoding: .utf16LittleEndian),
                      text.utf16.reduce(into: Data(), { $0.append(UInt8($1 & 255)); $0.append(UInt8($1 >> 8)) }) == wire,
                      DownloadTreeManifest.localName(Data(text.utf8)) != nil, !text.contains("\\"),
                      node.directory || node.size <= 256 << 20 else { throw SMBDirectoryFailure.invalidOutput }
                local.append(.init(components: local[parent].components + [Data(text.utf8)], size: node.directory ? nil : node.size))
            }
        }
        let manifest = try DownloadTreeManifest(nodes: local)
        guard manifest.logicalBytes <= 256 << 20 else { throw SMBDirectoryFailure.invalidOutput }
        self.nodes = nodes; self.local = manifest
    }
}

@_spi(Qualification) public struct SMBPreparedFolderDownload: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selection: SMBFolderDownloadSelection
    let manifest: SMBFolderManifest
    public var files: Int { manifest.local.files }
    public var folders: Int { manifest.local.folders }
    public var logicalBytes: UInt64 { manifest.local.logicalBytes }
    public var longestPathBytes: Int { manifest.local.longestPathBytes }
    public var description: String { "<SMB prepared folder>" }
    public var debugDescription: String { description }
}

enum SMBFolderDownloadEvent: Sendable {
    case prepared(SMBPreparedFolderDownload)
    case memberBegin(UUID, Int), bytes(UUID, Int, UInt64, Data), memberEnd(UUID, Int, UInt64)
    case complete(SMBPreparedFolderDownload), released(UUID)
}

/// The enclosing browser validates the global session/sequence. This closed
/// conversation validates all manifest, member, ACK and terminal ordering.
struct SMBFolderDownloadConversation: Sendable {
    static let binaryHeaderBytes = 101, maximumFrameBytes = 32768 + binaryHeaderBytes
    enum Phase: Sendable { case preparing, prepared, receiving, awaitingAppend, releasing, complete, failed }
    let selection: SMBFolderDownloadSelection, ordinal: UInt64
    private(set) var phase: Phase = .preparing
    private var nodes: [SMBFolderManifest.Node] = []
    private var prepared: SMBPreparedFolderDownload?
    private var current: Int?, next = 0, files = 0
    private var sequence: UInt64 = 0, offset: UInt64 = 0, received: UInt64 = 0
    private var pending: (sequence: UInt64, end: UInt64)?
    init(selection: SMBFolderDownloadSelection, ordinal: UInt64) throws {
        guard ordinal > 0 else { throw SMBDirectoryFailure.invalidInput }; self.selection = selection; self.ordinal = ordinal
    }
    mutating func begin() throws -> String {
        guard phase == .prepared else { throw SMBDirectoryFailure.busy }; phase = .receiving
        return "BEGIN_FOLDER \(selection.request.uuidString) \(ordinal)\n"
    }
    mutating func release() throws -> String {
        guard phase == .prepared else { throw SMBDirectoryFailure.busy }; phase = .releasing
        return "RELEASE_FOLDER \(selection.request.uuidString) \(ordinal)\n"
    }
    mutating func appended(request: UUID, member: Int, end: UInt64) throws -> String {
        guard phase == .awaitingAppend, request == selection.request, current == member, let pending,
              pending.end == end, pending.sequence == sequence, end > offset, sequence < UInt64.max,
              received <= (256 << 20) - (end - offset) else { throw SMBDirectoryFailure.invalidInput }
        received += end - offset; offset = end; self.pending = nil; sequence += 1; phase = .receiving
        return "ACK_FOLDER \(request.uuidString) \(ordinal) \(member) \(pending.sequence) \(end)\n"
    }
    mutating func text(_ fields: [String]) throws -> SMBFolderDownloadEvent? {
        do { return try consumeText(fields) } catch { phase = .failed; pending = nil; throw error }
    }
    private mutating func consumeText(_ p: [String]) throws -> SMBFolderDownloadEvent? {
        guard p.count >= 3, p[1] == selection.request.uuidString, try number(p[2], UInt64.self) == ordinal else { throw SMBDirectoryFailure.invalidOutput }
        switch p[0] {
        case "folderNode":
            guard phase == .preparing, p.count == 15, nodes.count < 2_048, try number(p[3], Int.self) == nodes.count,
                  p[5] == "d" || p[5] == "f" else { throw SMBDirectoryFailure.invalidOutput }
            let parent = p[4] == "-" ? nil : try number(p[4], Int.self)
            let wire = p[14] == "-" ? nil : try wireName(p[14])
            let value = SMBFolderManifest.Node(parent: parent, wire: wire, directory: p[5] == "d",
                attributes: try number(p[6], UInt32.self), size: try number(p[7], UInt64.self), allocated: try number(p[8], UInt64.self),
                modified: try number(p[9], UInt64.self), changed: try number(p[10], UInt64.self), index: try number(p[11], UInt64.self),
                volume: try number(p[12], UInt32.self), links: try number(p[13], UInt32.self))
            nodes.append(value); return nil
        case "folderPrepared":
            guard phase == .preparing, p.count == 7 else { throw SMBDirectoryFailure.invalidOutput }
            let manifest = try SMBFolderManifest(nodes: nodes, selection: selection), local = manifest.local
            guard try number(p[3], Int.self) == local.files, try number(p[4], Int.self) == local.folders,
                  try number(p[5], UInt64.self) == local.logicalBytes, try number(p[6], Int.self) == local.longestPathBytes else { throw SMBDirectoryFailure.invalidOutput }
            let result = SMBPreparedFolderDownload(selection: selection, manifest: manifest); prepared = result; nodes = []; phase = .prepared; return .prepared(result)
        case "folderMemberBegin":
            guard phase == .receiving, p.count == 5, current == nil, pending == nil, let prepared else { throw SMBDirectoryFailure.invalidOutput }
            while next < prepared.manifest.nodes.count, prepared.manifest.nodes[next].directory { next += 1 }
            guard next < prepared.manifest.nodes.count, try number(p[3], Int.self) == next,
                  try number(p[4], UInt64.self) == prepared.manifest.nodes[next].size else { throw SMBDirectoryFailure.invalidOutput }
            current = next; sequence = 0; offset = 0; return .memberBegin(selection.request, next)
        case "folderMemberEnd":
            guard phase == .receiving, p.count == 5, pending == nil, let current, let prepared,
                  try number(p[3], Int.self) == current, try number(p[4], UInt64.self) == offset,
                  prepared.manifest.nodes[current].size == offset else { throw SMBDirectoryFailure.invalidOutput }
            self.current = nil; next += 1; files += 1; return .memberEnd(selection.request, current, offset)
        case "folderComplete":
            guard phase == .receiving, p.count == 5, current == nil, pending == nil, let prepared,
                  try number(p[3], UInt64.self) == received, received == prepared.logicalBytes,
                  try number(p[4], Int.self) == files, files == prepared.files else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .complete(prepared)
        case "folderReleased":
            guard phase == .releasing, p.count == 3, received == 0, current == nil else { throw SMBDirectoryFailure.invalidOutput }
            phase = .complete; return .released(selection.request)
        default: throw SMBDirectoryFailure.invalidOutput
        }
    }
    mutating func binary(_ payload: Data, session: UUID, globalSequence: UInt64, magic: String = "MEXSMBF1") throws -> SMBFolderDownloadEvent {
        do { return try consumeBinary(payload, session: session, globalSequence: globalSequence, magic: magic) }
        catch { phase = .failed; pending = nil; throw error }
    }
    private mutating func consumeBinary(_ payload: Data, session: UUID, globalSequence: UInt64, magic: String) throws -> SMBFolderDownloadEvent {
        let b = [UInt8](payload)
        guard phase == .receiving, pending == nil, let current, let prepared,
              b.count >= Self.binaryHeaderBytes, b.count <= Self.maximumFrameBytes,
              Array(b[0..<9]) == [UInt8(1)] + Array(magic.utf8), Array(b[9..<45]) == Array(session.uuidString.utf8),
              integer(b, 45, 8) == globalSequence, Data(b[53..<69]) == withUnsafeBytes(of: selection.request.uuid, { Data($0) }),
              integer(b, 69, 8) == ordinal, integer(b, 77, 4) == UInt64(current), integer(b, 81, 8) == sequence,
              integer(b, 89, 8) == offset else { throw SMBDirectoryFailure.invalidOutput }
        let count = integer(b, 97, 4), size = prepared.manifest.nodes[current].size
        guard count > 0, count <= 32768, UInt64(b.count) == UInt64(Self.binaryHeaderBytes) + count,
              offset <= size, count <= size - offset else { throw SMBDirectoryFailure.invalidOutput }
        pending = (sequence, offset + count); phase = .awaitingAppend
        return .bytes(selection.request, current, offset, Data(b[Self.binaryHeaderBytes...]))
    }
    private func integer(_ bytes: [UInt8], _ at: Int, _ count: Int) -> UInt64 { bytes[at..<at+count].reduce(0) { ($0 << 8) | UInt64($1) } }
    private func number<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = T(text), String(value) == text else { throw SMBDirectoryFailure.invalidOutput }; return value
    }
    private func wireName(_ text: String) throws -> Data {
        let raw = Array(text.utf8)
        guard !raw.isEmpty, raw.count <= 1020, raw.count % 4 == 0,
              raw.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SMBDirectoryFailure.invalidOutput }
        var data = Data()
        for at in stride(from: 0, to: raw.count, by: 4) {
            guard let unit = UInt16(String(decoding: raw[at..<at+4], as: UTF8.self), radix: 16) else { throw SMBDirectoryFailure.invalidOutput }
            data.append(UInt8(unit & 255)); data.append(UInt8(unit >> 8))
        }; return data
    }
}
