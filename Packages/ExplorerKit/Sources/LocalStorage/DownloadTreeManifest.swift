import Foundation

/// Local publication metadata only. Remote source authority stays in the
/// concrete prepared SFTP/SMB value, never in these relative components.
struct DownloadTreeManifest: Sendable, Equatable {
    struct Node: Sendable, Equatable, Codable {
        let components: [Data]
        let size: UInt64?
        var directory: Bool { size == nil }
        var relative: String { components.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/") }
    }
    struct SealedNode: Sendable, Codable { let node: Node, offset: UInt64, sha256: Data? }
    struct Sealed: Sendable, Codable { let version: Int, nodes: [SealedNode] }
    let nodes: [Node]
    let files: Int, folders: Int, logicalBytes: UInt64, longestPathBytes: Int

    init(nodes: [Node]) throws {
        guard !nodes.isEmpty, nodes.count <= 2_048 else { throw RemoteDownloadStorageFailure.changed }
        var parents = Set<Data>(), paths = Set<Data>(), folded = Set<Data>()
        var files = 0, folders = 0, total: UInt64 = 0, components = 0, longest = 0
        for (index, node) in nodes.enumerated() {
            guard node.components.count <= 32, (index == 0) == node.components.isEmpty,
                  index != 0 || node.directory, node.components.allSatisfy({ Self.localName($0) != nil }) else {
                throw RemoteDownloadStorageFailure.changed
            }
            let key = Self.pathKey(node.components)
            let normalized = node.components.map { Data(String(decoding: $0, as: UTF8.self)
                .precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).utf8) }
            guard paths.insert(key).inserted, folded.insert(Self.pathKey(normalized)).inserted,
                  index == 0 || parents.contains(Self.pathKey(Array(node.components.dropLast()))) else {
                throw RemoteDownloadStorageFailure.changed
            }
            for part in node.components {
                guard components <= (4 << 20) - part.count else { throw RemoteDownloadStorageFailure.capacity }
                components += part.count
            }
            longest = max(longest, node.components.reduce(0) { $0 + $1.count } + max(0, node.components.count - 1))
            if node.directory { parents.insert(key); if index != 0 { folders += 1 } }
            else {
                guard let size = node.size, size <= 1 << 30, total <= (1 << 30) - size, files < 1_024 else {
                    throw RemoteDownloadStorageFailure.capacity
                }
                total += size; files += 1
            }
        }
        self.nodes = nodes; self.files = files; self.folders = folders; logicalBytes = total; longestPathBytes = longest
    }
    init(_ value: SFTPFolderManifest) throws {
        try self.init(nodes: value.nodes.map { .init(components: $0.components, size: $0.directory ? nil : $0.size) })
        guard files == value.files, folders == value.folders, logicalBytes == value.logicalBytes,
              longestPathBytes == value.longestPathBytes else { throw RemoteDownloadStorageFailure.changed }
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
            if let size = node.size { offset += size }
        }
        guard offset == logicalBytes else { throw RemoteDownloadStorageFailure.incomplete }
        let sealed = Sealed(version: 2, nodes: result), encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sealed)
        guard data.count <= 8 << 20 else { throw RemoteDownloadStorageFailure.capacity }
        return (sealed, data)
    }
}

/// Closed source association; no provider abstraction or caller path authority.
enum DownloadTreeSource: Sendable {
    case sftp(SFTPPreparedFolderDownload)
    case smb(SMBPreparedFolderDownload)
    var request: UUID { switch self { case .sftp(let p): p.selection.request; case .smb(let p): p.selection.request } }
    func matches(_ value: SFTPPreparedFolderDownload) -> Bool {
        guard case .sftp(let original) = self else { return false }
        return value.selection == original.selection && value.manifest == original.manifest
    }
    func matches(_ value: SMBPreparedFolderDownload) -> Bool {
        guard case .smb(let original) = self else { return false }
        return value.selection == original.selection && value.manifest == original.manifest
    }
    func localManifest() throws -> DownloadTreeManifest {
        switch self { case .sftp(let p): try .init(p.manifest); case .smb(let p): p.manifest.local }
    }
}
