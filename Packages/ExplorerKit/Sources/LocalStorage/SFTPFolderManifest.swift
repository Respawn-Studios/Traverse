import Foundation

/// A complete directory observation, never a caller-supplied remote path.
@_spi(Qualification) public struct SFTPFolderDownloadSelection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let request: UUID, generation: UUID
    public let read: UInt64, revision: UInt64, observation: UInt64
    let entry: SFTPWorkerEntry
    public var description: String { "<SFTP folder selection>" }
    public var debugDescription: String { description }
    public init(generation: UUID, snapshot: SFTPStoredSnapshot, row: SFTPStoredRow) throws {
        guard SFTPWire.validToken(generation), snapshot.state == .complete, snapshot.read > 0, snapshot.revision > 0,
              snapshot.read <= UInt64(Int64.max), snapshot.revision <= UInt64(Int64.max),
              row.observation > 0, row.observation <= UInt64(Int64.max),
              row.entry.isDirectory == true, row.entry.modifiedSeconds != nil else { throw SFTPProtocolFailure.invalidInput }
        request = UUID(); self.generation = generation; read = snapshot.read; revision = snapshot.revision
        observation = row.observation; entry = row.entry
    }
    public var proposedLocalName: String? { SFTPFolderManifest.localName(entry.name.wireUTF8) }
    public var row: SFTPStoredRow { .init(observation: observation, entry: entry) }
    public static func validLocalName(_ name: String) -> Bool { SFTPFolderManifest.localName(Data(name.utf8)) != nil }
}

/// This bounded metadata value is shared by the wire validator and sealed tree
/// producer. Its relative components are byte-exact, never display-escaped.
struct SFTPFolderManifest: Sendable, Equatable {
    static let maximumFiles = 1_024, maximumNodes = 2_048, maximumDepth = 32
    static let maximumComponentBytes = 4 << 20, maximumEncodedBytes = 8 << 20
    struct Node: Sendable, Equatable, Codable {
        let components: [Data]
        let size: UInt64?, modified: UInt32, permissions: UInt32
        var directory: Bool { permissions & 0o170000 == 0o040000 }
        var relative: String { components.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/") }
    }
    struct SealedNode: Sendable, Codable {
        let node: Node, offset: UInt64, sha256: Data?
    }
    struct Sealed: Sendable, Codable { let version: Int, nodes: [SealedNode] }
    let nodes: [Node]
    let files: Int, folders: Int, logicalBytes: UInt64, longestPathBytes: Int

    init(nodes: [Node]) throws {
        guard !nodes.isEmpty, nodes.count <= Self.maximumNodes else { throw SFTPProtocolFailure.invalidOutput }
        var parents = Set<Data>(), paths = Set<Data>(), folded = Set<Data>()
        var files = 0, folders = 0, bytes: UInt64 = 0, componentBytes = 0, longest = 0
        for (index, node) in nodes.enumerated() {
            let kind = node.permissions & 0o170000
            guard [UInt32(0o040000), UInt32(0o100000)].contains(kind), node.components.count <= Self.maximumDepth,
                  (index == 0) == node.components.isEmpty, index != 0 || node.directory,
                  node.components.allSatisfy({ Self.localName($0) != nil }) else { throw SFTPProtocolFailure.invalidOutput }
            let raw = Self.pathKey(node.components)
            guard paths.insert(raw).inserted, index == 0 || parents.contains(Self.pathKey(Array(node.components.dropLast()))) else {
                throw SFTPProtocolFailure.invalidOutput
            }
            let normalized = node.components.map { Data(String(decoding: $0, as: UTF8.self)
                .precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).utf8) }
            guard folded.insert(Self.pathKey(normalized)).inserted else { throw SFTPProtocolFailure.invalidOutput }
            for part in node.components {
                guard componentBytes <= Self.maximumComponentBytes - part.count else { throw SFTPProtocolFailure.invalidOutput }
                componentBytes += part.count
            }
            longest = max(longest, node.components.reduce(0, { $0 + $1.count }) + max(0, node.components.count - 1))
            if node.directory { parents.insert(raw); if index != 0 { folders += 1 } }
            else {
                guard let size = node.size, size <= 1 << 30, bytes <= (1 << 30) - size,
                      files < Self.maximumFiles else { throw SFTPProtocolFailure.invalidOutput }
                bytes += size; files += 1
            }
        }
        self.nodes = nodes; self.files = files; self.folders = folders; logicalBytes = bytes; longestPathBytes = longest
    }
    static func pathKey(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1); $0.append(0) } }
    static func localName(_ bytes: Data) -> String? {
        guard !bytes.isEmpty, bytes.count <= 255, let name = String(data: bytes, encoding: .utf8), Data(name.utf8) == bytes,
              name != ".", name != "..", !bytes.contains(47), !bytes.contains(58),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                && ![0x061c, 0x200e, 0x200f].contains($0.value)
                && !(0x202a...0x202e).contains($0.value) && !(0x2066...0x2069).contains($0.value) }) else { return nil }
        return name
    }
    func sealed(hashes: [Data?]) throws -> (Sealed, Data) {
        guard hashes.count == nodes.count else { throw RemoteDownloadStorageFailure.incomplete }
        var offset: UInt64 = 0, result: [SealedNode] = []
        for (node, hash) in zip(nodes, hashes) {
            guard node.directory ? hash == nil : hash?.count == 32 else { throw RemoteDownloadStorageFailure.incomplete }
            result.append(.init(node: node, offset: offset, sha256: hash))
            if !node.directory { offset += node.size! }
        }
        guard offset == logicalBytes else { throw RemoteDownloadStorageFailure.incomplete }
        let value = Sealed(version: 1, nodes: result), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumEncodedBytes else { throw RemoteDownloadStorageFailure.capacity }
        return (value, data)
    }
}

@_spi(Qualification) public struct SFTPPreparedFolderDownload: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let selection: SFTPFolderDownloadSelection
    public let files: Int, folders: Int, logicalBytes: UInt64, longestPathBytes: Int
    let manifest: SFTPFolderManifest
    public var description: String { "<SFTP prepared folder>" }
    public var debugDescription: String { description }
    init(selection: SFTPFolderDownloadSelection, manifest: SFTPFolderManifest) throws {
        let root = manifest.nodes[0]
        guard root.permissions == selection.entry.permissions, root.modified == selection.entry.modifiedSeconds,
              root.size == selection.entry.logicalBytes else { throw SFTPProtocolFailure.stale }
        self.selection = selection; self.manifest = manifest
        files = manifest.files; folders = manifest.folders; logicalBytes = manifest.logicalBytes; longestPathBytes = manifest.longestPathBytes
    }
}
