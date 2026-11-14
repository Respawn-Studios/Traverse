import CryptoKit
import Foundation

/// Canonical, bounded metadata for one explicit new-folder copy. Components
/// are exact UTF-8 bytes, never display strings or normalized search keys.
struct SFTPFolderUploadManifest: Sendable, Equatable, CustomDebugStringConvertible {
    static let maximumFiles = 1_024, maximumNodes = 2_048, maximumDepth = 32
    static let maximumEncodedBytes = 512 << 10
    static let maximumLogicalBytes: UInt64 = 1 << 30
    private static let magic = Data("TRVFUP01".utf8)
    enum Kind: UInt8, Sendable, Codable { case directory = 1, file = 2 }
    struct Node: Sendable, Equatable, Codable {
        let kind: Kind, components: [Data], size: UInt64
        var directory: Bool { kind == .directory }
    }
    let nodes: [Node], files: Int, folders: Int, logicalBytes: UInt64
    let encoded: Data, digest: Data
    var debugDescription: String { "<SFTP explicit folder manifest>" }

    init(nodes: [Node]) throws {
        guard !nodes.isEmpty, nodes.count <= Self.maximumNodes else { throw SFTPUploadSourceFailure.unsupported }
        var parents = Set<Data>(), files = 0, folders = 0, bytes: UInt64 = 0
        var encoded = Self.magic; encoded.append(contentsOf: Self.bigEndian(UInt32(nodes.count)))
        var previous: [Data]?
        for (index, node) in nodes.enumerated() {
            guard node.components.count <= Self.maximumDepth,
                  (index == 0) == node.components.isEmpty, index != 0 || node.directory,
                  node.components.allSatisfy(Self.validComponent),
                  index == 0 || parents.contains(Self.key(Array(node.components.dropLast()))),
                  previous.map({ Self.precedes($0, node.components) }) ?? true else { throw SFTPUploadSourceFailure.unsupported }
            if node.directory {
                guard node.size == 0 else { throw SFTPUploadSourceFailure.unsupported }
                parents.insert(Self.key(node.components)); if index != 0 { folders += 1 }
            } else {
                guard files < Self.maximumFiles, node.size <= Self.maximumLogicalBytes,
                      bytes <= Self.maximumLogicalBytes - node.size else { throw SFTPUploadSourceFailure.unsupported }
                files += 1; bytes += node.size
            }
            let added = 10 + node.components.reduce(0, { $0 + 2 + $1.count })
            guard added <= Self.maximumEncodedBytes - encoded.count else { throw SFTPUploadSourceFailure.unsupported }
            encoded.append(node.kind.rawValue); encoded.append(UInt8(node.components.count))
            encoded.append(contentsOf: Self.bigEndian(node.size))
            for part in node.components { encoded.append(contentsOf: Self.bigEndian(UInt16(part.count))); encoded.append(part) }
            previous = node.components
        }
        self.nodes = nodes; self.files = files; self.folders = folders; logicalBytes = bytes
        self.encoded = encoded; digest = Data(SHA256.hash(data: encoded))
    }

    init(encoded: Data) throws {
        guard (22...Self.maximumEncodedBytes).contains(encoded.count), encoded.prefix(8) == Self.magic else { throw SFTPUploadSourceFailure.unsupported }
        var cursor = 8
        func number<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard cursor <= encoded.count - size else { throw SFTPUploadSourceFailure.unsupported }
            var value: T = 0; for byte in encoded[cursor..<(cursor + size)] { value = (value << 8) | T(byte) }
            cursor += size; return value
        }
        let count = Int(try number(UInt32.self))
        guard (1...Self.maximumNodes).contains(count) else { throw SFTPUploadSourceFailure.unsupported }
        var nodes: [Node] = []; nodes.reserveCapacity(count)
        for _ in 0..<count {
            guard let kind = Kind(rawValue: try number(UInt8.self)) else { throw SFTPUploadSourceFailure.unsupported }
            let depth = Int(try number(UInt8.self)), size = try number(UInt64.self)
            guard depth <= Self.maximumDepth else { throw SFTPUploadSourceFailure.unsupported }
            var parts: [Data] = []
            for _ in 0..<depth {
                let length = Int(try number(UInt16.self))
                guard (1...255).contains(length), length <= encoded.count - cursor else { throw SFTPUploadSourceFailure.unsupported }
                parts.append(encoded.subdata(in: cursor..<(cursor + length))); cursor += length
            }
            nodes.append(.init(kind: kind, components: parts, size: size))
        }
        guard cursor == encoded.count else { throw SFTPUploadSourceFailure.unsupported }
        try self.init(nodes: nodes)
        guard self.encoded == encoded else { throw SFTPUploadSourceFailure.unsupported }
    }

    static func validComponent(_ bytes: Data) -> Bool {
        guard (1...255).contains(bytes.count), !bytes.contains(0), !bytes.contains(47),
              bytes != Data([46]), bytes != Data([46, 46]),
              let value = String(data: bytes, encoding: .utf8), Data(value.utf8) == bytes else { return false }
        return true
    }
    static func key(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1); $0.append(0) } }
    static func precedes(_ a: [Data], _ b: [Data]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x.lexicographicallyPrecedes(y) }
        return a.count < b.count
    }
    private static func bigEndian<T: FixedWidthInteger>(_ number: T) -> [UInt8] {
        withUnsafeBytes(of: number.bigEndian) { Array($0) }
    }
}
