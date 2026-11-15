import CryptoKit
import Foundation

public enum TARArchiveFailure: String, Error, Equatable, Sendable {
    case malformed, unsupported, compressed, unsafeName, ambiguousNames
    case limited, unavailable, changed, stopped, busy, closed, invalidSelection
}
public enum TARMemberKind: String, Sendable { case file, directory, symbolicLink, hardLink, special }
internal struct TARReadLimits: Sendable {
    var sourceBytes: UInt64 = 2 << 30
    var records = 20_000, nodes = 20_000
    var metadataBytes = 32 << 20, nameBytes = 8 << 20, searchBytes = 16 << 20
    var extensionBytes = 64 << 10, pathBytes = 4096, componentBytes = 255, depth = 63
    var trailingBytes = 1 << 20
    var memberBytes: UInt64 = 256 << 20, logicalBytes: UInt64 = 1 << 30
    var seconds = 30.0
}
internal struct TARRecord: Sendable {
    let ordinal: Int, path: String, kind: TARMemberKind
    let headerOffset: UInt64, dataOffset: UInt64, bytes: UInt64
    var modification: ArchiveMemberModification? = nil
    /// A local PAX/GNU extension belongs to the following member. Writers keep
    /// that raw record rather than reconstructing metadata from display facts.
    var extensionOffset: UInt64? = nil
}
internal struct TARParsedDirectory: Sendable {
    let records: [TARRecord]
    let witness: Data
    let metadataBytes: Int
    let logicalBytes: UInt64
}

/// Plain-TAR structure only. The read closure is positioned and bounded: no
/// ordinary member body or its padding is read to discover the next header.
internal enum TARMetadataParser {
    private struct Override { var path: String?; var bytes: UInt64?; var modification: String? }
    static func parse(length: UInt64, limits: TARReadLimits = .init(),
                      check: () throws -> Void, read: (UInt64, Int) throws -> Data) throws -> TARParsedDirectory {
        guard [limits.records,limits.nodes,limits.metadataBytes,limits.nameBytes,limits.searchBytes,limits.extensionBytes,
            limits.pathBytes,limits.componentBytes,limits.depth,limits.trailingBytes].allSatisfy({ $0 >= 0 }) else { throw TARArchiveFailure.limited }
        guard length >= 1024, length % 512 == 0 else { throw TARArchiveFailure.malformed }
        guard length <= limits.sourceBytes else { throw TARArchiveFailure.limited }
        var cursor: UInt64 = 0, records = [TARRecord](), pending: Override?, physical = 0
        var extensionOffset: UInt64?
        var metadataBytes = 0, names = 0, logical: UInt64 = 0, rootSeen = false
        var witness = SHA256()
        func metadata(_ offset: UInt64, _ count: Int) throws -> Data {
            try check()
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw TARArchiveFailure.malformed }
            guard count <= limits.metadataBytes - metadataBytes else { throw TARArchiveFailure.limited }
            let data = try read(offset, count)
            guard data.count == count else { throw TARArchiveFailure.malformed }
            metadataBytes += count
            var position = offset.bigEndian, size = UInt64(count).bigEndian
            witness.update(data: withUnsafeBytes(of: &position) { Data($0) })
            witness.update(data: withUnsafeBytes(of: &size) { Data($0) })
            witness.update(data: data); return data
        }
        while cursor < length {
            let header = try metadata(cursor, 512)
            if header.allSatisfy({ $0 == 0 }) {
                guard pending == nil, length - cursor >= 1024,
                      try metadata(cursor + 512, 512).allSatisfy({ $0 == 0 }) else { throw TARArchiveFailure.malformed }
                var trailing = cursor + 1024
                guard length - trailing <= UInt64(limits.trailingBytes) else { throw TARArchiveFailure.limited }
                while trailing < length {
                    let count = Int(min(65_536, length - trailing))
                    guard try metadata(trailing, count).allSatisfy({ $0 == 0 }) else { throw TARArchiveFailure.malformed }
                    trailing += UInt64(count)
                }
                try check()
                return .init(records: records, witness: Data(witness.finalize()), metadataBytes: metadataBytes, logicalBytes: logical)
            }
            if cursor == 0, header.starts(with: [0x1f,0x8b]) { throw TARArchiveFailure.compressed }
            physical += 1
            guard physical <= limits.records else { throw TARArchiveFailure.limited }
            let expected = try octal(header, 148..<156)
            let actual = header.enumerated().reduce(UInt64(0)) { $0 + UInt64((148..<156).contains($1.offset) ? 32 : $1.element) }
            guard expected == actual else { throw TARArchiveFailure.malformed }
            let magic = Array(header[257..<263]), version = Array(header[263..<265])
            let ustar = magic == Array("ustar\0".utf8) && version == Array("00".utf8)
            let gnu = magic == Array("ustar ".utf8) && version == [32,0]
            guard ustar || gnu else { throw TARArchiveFailure.unsupported }
            let declared = try octal(header, 124..<136), type = header[156]
            let dataOffset = cursor + 512
            if type == 120 || type == 76 {
                guard pending == nil else { throw TARArchiveFailure.unsupported }
                guard declared > 0, declared <= UInt64(limits.extensionBytes) else { throw TARArchiveFailure.limited }
                let payload = try metadata(dataOffset, Int(declared))
                if type == 120 { pending = try pax(payload, limits: limits) }
                else {
                    guard payload.last == 0, !payload.dropLast().contains(0),
                          let path = String(data: payload.dropLast(), encoding: .utf8), !path.isEmpty else { throw TARArchiveFailure.malformed }
                    guard path.utf8.count <= limits.pathBytes else { throw TARArchiveFailure.limited }
                    pending = .init(path: path)
                }
                extensionOffset = cursor
                cursor = try next(dataOffset, declared, length: length); continue
            }
            let kind: TARMemberKind
            switch type {
            case 0, 48: kind = .file
            case 53: kind = .directory
            case 49: kind = .hardLink
            case 50: kind = .symbolicLink
            case 51,52,54: kind = .special
            default: throw TARArchiveFailure.unsupported
            }
            let bytes = pending?.bytes ?? declared
            guard kind == .file || bytes == 0 else { throw TARArchiveFailure.unsupported }
            guard bytes <= limits.memberBytes else { throw TARArchiveFailure.limited }
            var name = try text(header, 0..<100)
            if ustar {
                let prefix = try text(header, 345..<500)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            if let override = pending?.path { name = override }
            let modification = if let override = pending?.modification { paxModification(override) }
                else { headerModification(header) }
            pending = nil
            let memberExtension = extensionOffset; extensionOffset = nil
            let safe = try path(name, directory: kind == .directory, limits: limits)
            cursor = try next(dataOffset, bytes, length: length)
            if safe.isEmpty {
                guard kind == .directory, !rootSeen else { throw TARArchiveFailure.ambiguousNames }
                rootSeen = true; continue
            }
            let nameCount = safe.utf8.count
            guard nameCount <= limits.nameBytes - names else { throw TARArchiveFailure.limited }
            names += nameCount
            if kind == .file {
                guard bytes <= limits.logicalBytes - logical else { throw TARArchiveFailure.limited }
                logical += bytes
            }
            records.append(.init(ordinal: physical, path: safe, kind: kind, headerOffset: dataOffset - 512,
                dataOffset: dataOffset, bytes: bytes, modification: modification, extensionOffset: memberExtension))
        }
        throw TARArchiveFailure.malformed
    }
    private static func next(_ offset: UInt64, _ size: UInt64, length: UInt64) throws -> UInt64 {
        guard offset <= length, size <= length - offset, size <= UInt64.max - 511 else { throw TARArchiveFailure.malformed }
        let padded = ((size + 511) / 512) * 512
        guard padded <= length - offset else { throw TARArchiveFailure.malformed }; return offset + padded
    }
    private static func text(_ bytes: Data, _ range: Range<Int>) throws -> String {
        let field = bytes[range], end = field.firstIndex(of: 0) ?? range.upperBound
        guard bytes[end..<range.upperBound].allSatisfy({ $0 == 0 }),
              let value = String(data: bytes[range.lowerBound..<end], encoding: .utf8) else { throw TARArchiveFailure.malformed }
        return value
    }
    private static func octal(_ bytes: Data, _ range: Range<Int>) throws -> UInt64 {
        var values = Array(bytes[range])
        guard values.first.map({ $0 & 0x80 == 0 }) == true else { throw TARArchiveFailure.unsupported }
        while values.first == 32 { values.removeFirst() }
        while values.last == 0 || values.last == 32 { values.removeLast() }
        guard !values.isEmpty, values.allSatisfy({ (48...55).contains($0) }) else { throw TARArchiveFailure.malformed }
        return try values.reduce(UInt64(0)) { partial, byte in
            guard partial <= (UInt64.max - UInt64(byte - 48)) / 8 else { throw TARArchiveFailure.malformed }
            return partial * 8 + UInt64(byte - 48)
        }
    }

    private static func headerModification(_ header: Data) -> ArchiveMemberModification? {
        let first = header[136]
        if first & 0x80 == 0 {
            return (try? octal(header, 136..<148)).flatMap { .unix(TimeInterval($0)) }
        }
        // GNU base-256; sign extend the high bytes before decoding a bounded
        // Int64. Invalid timestamp fields don't hide an otherwise valid item.
        let negative = first & 0x40 != 0
        guard first == (negative ? 0xff : 0x80),
              header[137..<140].allSatisfy({ $0 == (negative ? 0xff : 0) }) else { return nil }
        let raw = header[140..<148].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let seconds = Int64(bitPattern: raw)
        return (seconds < 0) == negative ? .unix(TimeInterval(seconds)) : nil
    }

    private static func paxModification(_ value: String) -> ArchiveMemberModification? {
        guard (1...32).contains(value.utf8.count) else { return nil }
        let number = value.hasPrefix("-") ? value.dropFirst() : value[...]
        let components = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count), components.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }), let seconds = TimeInterval(value) else { return nil }
        return .unix(seconds)
    }
    private static func pax(_ bytes: Data, limits: TARReadLimits) throws -> Override {
        var cursor = 0, result = Override(), keys = Set<String>()
        while cursor < bytes.count {
            guard let space = bytes[cursor...].firstIndex(of: 32), space - cursor <= 6,
                  let lengthText = String(data: bytes[cursor..<space], encoding: .ascii), !lengthText.isEmpty,
                  lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText),
                  length > space - cursor + 3, length <= bytes.count - cursor, bytes[cursor + length - 1] == 10 else { throw TARArchiveFailure.malformed }
            let content = bytes[(space + 1)..<(cursor + length - 1)]
            guard let equals = content.firstIndex(of: 61), let key = String(data: content[..<equals], encoding: .utf8), !key.isEmpty,
                  let value = String(data: content[(equals + 1)...], encoding: .utf8), keys.insert(key).inserted else { throw TARArchiveFailure.malformed }
            switch key {
            case "path":
                guard !value.isEmpty, value.utf8.count <= limits.pathBytes else { throw TARArchiveFailure.limited }; result.path = value
            case "size":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let size = UInt64(value) else { throw TARArchiveFailure.malformed }; result.bytes = size
            case "mtime": result.modification = value
            case "uid","gid","uname","gname","atime","ctime": break
            default: throw TARArchiveFailure.unsupported
            }
            cursor += length
        }
        return result
    }
    internal static func path(_ raw: String, directory: Bool, limits: TARReadLimits) throws -> String {
        guard raw.utf8.count <= limits.pathBytes else { throw TARArchiveFailure.limited }
        if directory && [".","./"].contains(raw) { return "" }
        var name = raw
        if name.hasPrefix("./") { name.removeFirst(2) }
        if directory && name.hasSuffix("/") { name.removeLast() }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= limits.depth, parts.allSatisfy({ $0.utf8.count <= limits.componentBytes }) else { throw TARArchiveFailure.limited }
        guard !parts.isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || [0x061c,0x200e,0x200f].contains($0.value) || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value) }),
              !name.contains("\\"), !name.hasPrefix("/"),
              !(parts[0].utf8.count >= 2 && parts[0].utf8.dropFirst().first == 58),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw TARArchiveFailure.unsafeName }
        return name
    }
}
