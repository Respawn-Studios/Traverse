import CryptoKit
import Foundation

/// Treat the index as an opaque native Git document except for the fields
/// needed to check what a private edit would replace or preserve.
struct GitIndexFormat {
    struct Key: Hashable {
        let path: GitSnapshotPath
        let stage: UInt16
    }

    struct Entry: Equatable {
        /// Includes cached file facts and all flags. Name compression is
        /// deliberately outside the entry because Git may repack it.
        let fields: Data
        let mode: UInt32
        let object: GitObjectID
        let hasSpecialFlags: Bool

        func member(at path: GitSnapshotPath) throws -> GitSnapshotMember {
            let spelling: String
            switch mode {
            case 0o100644: spelling = "100644"
            case 0o100755: spelling = "100755"
            default: throw GitIndexEditFailure.unsupportedPath
            }
            guard let value = try GitSnapshotMember.read(mode: Data(spelling.utf8), path: path, id: object) else {
                throw GitIndexEditFailure.unsupportedIndex
            }
            return value
        }
    }

    let entries: [Key: Entry]

    init(_ data: Data?, hashLength: Int, check: () throws -> Void) throws {
        guard let data else { entries = [:]; return }
        let digestLength = hashLength / 2
        guard [20, 32].contains(digestLength), data.count >= 12 + digestLength else {
            throw GitIndexEditFailure.unsupportedIndex
        }
        let body = data.dropLast(digestLength)
        let digest = digestLength == 32 ? Array(SHA256.hash(data: body)) : Array(Insecure.SHA1.hash(data: body))
        guard data.suffix(digestLength).elementsEqual(digest) else { throw GitIndexEditFailure.unsupportedIndex }

        var reader = Reader(bytes: Array(body))
        guard try reader.take(4).elementsEqual("DIRC".utf8) else { throw GitIndexEditFailure.unsupportedIndex }
        let version = try reader.integer(4)
        let count = try reader.integer(4)
        guard (2...4).contains(version), count <= 65_536 else { throw GitIndexEditFailure.unsupportedIndex }
        var parsed: [Key: Entry] = [:]
        var previous = Data()
        for _ in 0..<count {
            try check()
            let start = reader.offset
            _ = try reader.take(24)
            let mode = try reader.integer(4)
            _ = try reader.take(12)
            let object = try reader.take(digestLength)
            let flags = UInt16(try reader.integer(2))
            if flags & 0x4000 != 0 {
                guard version >= 3 else { throw GitIndexEditFailure.unsupportedIndex }
                _ = try reader.take(2)
            }
            let fields = Data(reader.bytes[start..<reader.offset])
            let strip = version == 4 ? try reader.stripCount(maximum: previous.count) : previous.count
            let name = previous.dropLast(strip) + (try reader.terminatedPathSuffix())
            if version != 4 {
                let padding = (8 - (reader.offset - start) % 8) % 8
                guard try reader.take(padding).allSatisfy({ $0 == 0 }) else { throw GitIndexEditFailure.unsupportedIndex }
            }
            guard min(name.count, 0x0fff) == Int(flags & 0x0fff),
                  let path = GitSnapshotPath(name), mode != 0o040000 else { throw GitIndexEditFailure.unsupportedIndex }
            let key = Key(path: path, stage: (flags & 0x3000) >> 12)
            let oid = GitObjectID(digest: object)
            guard parsed.updateValue(.init(fields: fields, mode: mode, object: oid,
                hasSpecialFlags: flags & 0xc000 != 0), forKey: key) == nil else {
                throw GitIndexEditFailure.unsupportedIndex
            }
            previous = name
        }
        var extensions = Set<String>()
        while reader.offset < reader.bytes.count {
            try check()
            let name = String(decoding: try reader.take(4), as: UTF8.self)
            // Native Git may regenerate these caches. Sparse, split, untracked
            // and resolve-undo state need a separate preservation contract.
            guard ["TREE", "EOIE", "IEOT"].contains(name), extensions.insert(name).inserted else {
                throw GitIndexEditFailure.unsupportedIndex
            }
            _ = try reader.take(Int(reader.integer(4)))
        }
        entries = parsed
    }

    func entry(at path: GitSnapshotPath) throws -> Entry? {
        guard (1...3).allSatisfy({ entries[.init(path: path, stage: $0)] == nil }) else {
            throw GitInspectionFailure.indexConflict
        }
        let value = entries[.init(path: path, stage: 0)]
        guard value?.hasSpecialFlags != true else { throw GitIndexEditFailure.unsupportedPath }
        return value
    }

    func verifiesEdit(from prior: Self, path: GitSnapshotPath, to member: GitSnapshotMember?) throws {
        let key = Key(path: path, stage: 0)
        guard try entry(at: path)?.member(at: path) == member,
              entries.count - (entries[key] == nil ? 0 : 1) == prior.entries.count - (prior.entries[key] == nil ? 0 : 1),
              prior.entries.allSatisfy({ $0.key == key || entries[$0.key] == $0.value }) else {
            throw GitIndexEditFailure.unsupportedIndex
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count <= bytes.count - offset else { throw GitIndexEditFailure.unsupportedIndex }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }

        mutating func integer(_ count: Int) throws -> UInt32 {
            try take(count).reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func stripCount(maximum: Int) throws -> Int {
            var byte = try integer(1)
            var value = Int(byte & 0x7f)
            while byte & 0x80 != 0 {
                guard value <= maximum else { throw GitIndexEditFailure.unsupportedIndex }
                byte = try integer(1)
                value = ((value + 1) << 7) | Int(byte & 0x7f)
            }
            guard value <= maximum else { throw GitIndexEditFailure.unsupportedIndex }
            return value
        }

        mutating func terminatedPathSuffix() throws -> Data {
            let end = offset + min(4_097, bytes.count - offset)
            guard let terminator = bytes[offset..<end].firstIndex(of: 0) else {
                throw GitIndexEditFailure.unsupportedIndex
            }
            let name = Data(bytes[offset..<terminator])
            offset = terminator + 1
            return name
        }
    }
}
