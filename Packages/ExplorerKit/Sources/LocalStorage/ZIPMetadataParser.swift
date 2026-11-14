import CoreFoundation
import CryptoKit
import Foundation

/// The caller supplies one anchored, length-bounded positioned reader. This
/// parser never decompresses, creates files or turns a member into a local URL.
internal enum ZIPMetadataParser {
    private struct Trailer { let offset: UInt64; let bytes: UInt64; let count: UInt64; let zip64: Bool }
    private struct CentralRecord {
        let member: ZIPPayloadRecord
        let end: Int
        let modification: ArchiveMemberModification?
    }
    static func parse(length: UInt64, limits: ZIPReadLimits = .init(), capture: ((ZIPPayloadRecord) throws -> Void)? = nil, cancelled: () -> Bool,
                      read: (UInt64, Int) throws -> Data) throws -> ZIPCatalogStorage {
        guard length >= 22 else { throw ZIPArchiveFailure.malformed }
        let tailCount = Int(min(length, 65_557)), tailStart = length - UInt64(tailCount)
        let tail = try read(tailStart, tailCount)
        guard tail.count == tailCount else { throw ZIPArchiveFailure.malformed }
        var candidates: [Int] = []
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, offset) == 0x06054b50, offset + 22 + Int(u16(tail, offset + 20)) == tail.count {
                candidates.append(offset)
                guard candidates.count < 2 else { throw ZIPArchiveFailure.malformed }
            }
        }
        guard let end = candidates.first else { throw ZIPArchiveFailure.malformed }
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == u16(tail, end + 10) else { throw ZIPArchiveFailure.unsupported }
        let endPosition = tailStart + UInt64(end)
        let trailer: Trailer
        let suffix: Data
        if u16(tail, end + 10) == .max || u32(tail, end + 12) == .max || u32(tail, end + 16) == .max {
            guard endPosition >= 20 else { throw ZIPArchiveFailure.malformed }
            let locator = try read(endPosition - 20, 20)
            guard locator.count == 20, u32(locator, 0) == 0x07064b50, u32(locator, 4) == 0,
                  u32(locator, 16) == 1 else { throw ZIPArchiveFailure.unsupported }
            let position = u64(locator, 8)
            guard position < endPosition - 20, fits(position, 56, before: endPosition - 20) else { throw ZIPArchiveFailure.malformed }
            let record = try read(position, 56)
            guard record.count == 56, u32(record, 0) == 0x06064b50 else { throw ZIPArchiveFailure.malformed }
            let recordBytes = u64(record, 4)
            guard recordBytes >= 44, recordBytes <= 4_096 else { throw ZIPArchiveFailure.limited }
            guard recordBytes == 44 else { throw ZIPArchiveFailure.unsupported }
            guard fits(position, recordBytes + 12, before: endPosition - 20), position + recordBytes + 12 == endPosition - 20,
                  u32(record, 16) == 0, u32(record, 20) == 0, u64(record, 24) == u64(record, 32) else { throw ZIPArchiveFailure.unsupported }
            trailer = Trailer(offset: u64(record, 48), bytes: u64(record, 40), count: u64(record, 32), zip64: true)
            suffix = record + locator + Data(tail[end...])
            guard (u16(tail, end + 10) == .max || UInt64(u16(tail, end + 10)) == trailer.count),
                  (u32(tail, end + 12) == .max || UInt64(u32(tail, end + 12)) == trailer.bytes),
                  (u32(tail, end + 16) == .max || UInt64(u32(tail, end + 16)) == trailer.offset) else { throw ZIPArchiveFailure.malformed }
            guard fits(trailer.offset, trailer.bytes, before: position), trailer.offset + trailer.bytes == position else { throw ZIPArchiveFailure.malformed }
        } else {
            trailer = Trailer(offset: UInt64(u32(tail, end + 16)), bytes: UInt64(u32(tail, end + 12)), count: UInt64(u16(tail, end + 10)), zip64: false)
            suffix = Data(tail[end...])
            guard fits(trailer.offset, trailer.bytes, before: endPosition), trailer.offset + trailer.bytes == endPosition else { throw ZIPArchiveFailure.malformed }
        }
        guard trailer.count <= limits.members, trailer.bytes <= limits.centralBytes else { throw ZIPArchiveFailure.limited }
        if trailer.count == 0 {
            guard trailer.bytes == 0, trailer.offset == 0 else { throw ZIPArchiveFailure.malformed }
        } else {
            let first = try read(0, 4)
            guard first.count == 4, u32(first, 0) == 0x04034b50 else { throw ZIPArchiveFailure.unsupported }
        }
        guard !cancelled() else { throw ZIPArchiveFailure.stopped }
        let directory = try read(trailer.offset, Int(trailer.bytes))
        guard directory.count == Int(trailer.bytes) else { throw ZIPArchiveFailure.malformed }
        var builder = ZIPCatalogBuilder(limits: limits), offset = 0, localMinimum = UInt64.max
        for _ in 0..<Int(trailer.count) {
            guard !cancelled() else { throw ZIPArchiveFailure.stopped }
            let parsed = try record(directory, at: offset, centralOffset: trailer.offset, limits: limits)
            let member = parsed.member
            localMinimum = min(localMinimum, member.localOffset)
            try builder.add(name: member.name, kind: member.kind, logical: member.logical, packed: member.packed,
                method: member.method, encrypted: member.flags & 0x2041 != 0,
                centralEntryOffset: trailer.offset + UInt64(offset), modification: parsed.modification)
            try capture?(member)
            offset = parsed.end
        }
        guard offset == directory.count, trailer.count == 0 || localMinimum == 0 else { throw ZIPArchiveFailure.unsupported }
        guard !cancelled() else { throw ZIPArchiveFailure.stopped }
        var hash = SHA256(); hash.update(data: directory); hash.update(data: suffix)
        let witness = ZIPDirectoryWitness(offset: trailer.offset, bytes: trailer.bytes + UInt64(suffix.count),
            digest: Data(hash.finalize()))
        guard !cancelled() else { throw ZIPArchiveFailure.stopped }
        return try builder.finish(records: Int(trailer.count), centralBytes: Int(trailer.bytes), zip64: trailer.zip64,
            centralOffset: trailer.offset, directoryWitness: witness, cancelled: cancelled)
    }

    /// Shared record decoding for initial directory validation and a later
    /// exact, source-bound selected lookup. It never opens or decodes a payload.
    private static func record(_ directory: Data, at offset: Int, centralOffset: UInt64,
                               limits: ZIPReadLimits) throws -> CentralRecord {
        guard offset >= 0, offset <= directory.count - 46, u32(directory, offset) == 0x02014b50 else { throw ZIPArchiveFailure.malformed }
        let nameCount = Int(u16(directory, offset + 28)), extraCount = Int(u16(directory, offset + 30)), commentCount = Int(u16(directory, offset + 32))
        let end = offset + 46 + nameCount + extraCount + commentCount
        guard nameCount > 0, end <= directory.count else { throw ZIPArchiveFailure.malformed }
        guard nameCount <= limits.pathBytes else { throw ZIPArchiveFailure.limited }
        let rawName = Data(directory[(offset + 46)..<(offset + 46 + nameCount)])
        let extra = Data(directory[(offset + 46 + nameCount)..<(offset + 46 + nameCount + extraCount)])
        let fields = try extras(extra, includesModification: true)
        let flags = u16(directory, offset + 8), method = u16(directory, offset + 10)
        var logical = UInt64(u32(directory, offset + 24)), packed = UInt64(u32(directory, offset + 20))
        var local = UInt64(u32(directory, offset + 42)), disk = UInt64(u16(directory, offset + 34))
        if logical == UInt32.max || packed == UInt32.max || local == UInt32.max || disk == UInt16.max {
            guard let value = fields[1] else { throw ZIPArchiveFailure.malformed }
            var cursor = 0
            if logical == UInt32.max { logical = try take64(value, &cursor) }
            if packed == UInt32.max { packed = try take64(value, &cursor) }
            if local == UInt32.max { local = try take64(value, &cursor) }
            if disk == UInt16.max {
                guard cursor + 4 <= value.count else { throw ZIPArchiveFailure.malformed }
                disk = UInt64(u32(value, cursor)); cursor += 4
            }
            guard cursor == value.count else { throw ZIPArchiveFailure.malformed }
        }
        guard disk == 0 else { throw ZIPArchiveFailure.unsupported }
        guard fits(local, 30, before: centralOffset) else { throw ZIPArchiveFailure.malformed }
        let name = try decode(rawName, flags: flags, unicode: fields[0x7075])
        let creator = UInt8(u16(directory, offset + 4) >> 8), attributes = u32(directory, offset + 38)
        let mode = creator == 3 || creator == 19 ? UInt16(attributes >> 16) & 0xf000 : 0
        let isDirectory = name.hasSuffix("/") || attributes & 0x10 != 0 || mode == 0x4000
        let kind: ZIPMemberKind = mode == 0xa000 ? .symbolicLink : isDirectory ? .directory : (mode == 0 || mode == 0x8000 ? .file : .special)
        guard !(isDirectory && (mode == 0xa000 || mode == 0x8000)), !isDirectory || logical == 0 else { throw ZIPArchiveFailure.malformed }
        let member = ZIPPayloadRecord(name: name, rawName: rawName, kind: kind, flags: flags, method: method,
            crc: u32(directory, offset + 16), logical: logical, packed: packed, localOffset: local,
            centralOffset: centralOffset, usesZIP64: fields[1] != nil)
        return .init(member: member, end: end, modification: modification(fields,
            date: u16(directory, offset + 14), time: u16(directory, offset + 12)))
    }

    static func selectedRecord(at position: UInt64, centralOffset: UInt64, centralEnd: UInt64,
        sourceLength: UInt64, limits: ZIPReadLimits, read: (UInt64, Int) throws -> Data) throws -> ZIPPayloadRecord {
        guard position >= centralOffset, centralEnd <= sourceLength, fits(position, 46, before: centralEnd) else {
            throw ZIPArchiveFailure.malformed
        }
        let header = try read(position, 46)
        guard header.count == 46, u32(header, 0) == 0x02014b50 else { throw ZIPArchiveFailure.malformed }
        let count = 46 + Int(u16(header, 28)) + Int(u16(header, 30)) + Int(u16(header, 32))
        guard count <= limits.centralBytes, fits(position, UInt64(count), before: centralEnd) else {
            throw ZIPArchiveFailure.limited
        }
        let bytes = try read(position, count)
        guard bytes.count == count else { throw ZIPArchiveFailure.malformed }
        let parsed = try record(bytes, at: 0, centralOffset: centralOffset, limits: limits)
        guard parsed.end == bytes.count else { throw ZIPArchiveFailure.malformed }
        return parsed.member
    }

    static func extras(_ data: Data, includesModification: Bool = false) throws -> [UInt16: Data] {
        var offset = 0, result: [UInt16: Data] = [:]
        var duplicateModification = Set<UInt16>()
        while offset < data.count {
            guard offset + 4 <= data.count else { throw ZIPArchiveFailure.malformed }
            let tag = u16(data, offset), size = Int(u16(data, offset + 2)); offset += 4
            guard offset + size <= data.count else { throw ZIPArchiveFailure.malformed }
            if tag == 1 || tag == 0x7075 {
                guard result[tag] == nil else { throw ZIPArchiveFailure.malformed }
                result[tag] = Data(data[offset..<(offset + size)])
            } else if includesModification, (tag == 0x5455 || tag == 0x000a), !duplicateModification.contains(tag) {
                if result[tag] != nil { result[tag] = nil; duplicateModification.insert(tag) }
                else { result[tag] = Data(data[offset..<(offset + size)]) }
            }
            offset += size
        }
        return result
    }

    private static func modification(_ fields: [UInt16: Data], date: UInt16, time: UInt16) -> ArchiveMemberModification? {
        // NTFS stores fractional absolute time. The Info-ZIP extended field
        // carries signed Unix seconds when its modification bit is present.
        if let ntfs = fields[0x000a], let value = ntfsModification(ntfs) { return value }
        if let unix = fields[0x5455], unix.count >= 5, unix[0] & 1 == 1 {
            return .unix(TimeInterval(Int32(bitPattern: u32(unix, 1))))
        }
        return .dos(date: date, time: time)
    }

    private static func ntfsModification(_ data: Data) -> ArchiveMemberModification? {
        var offset = 4, result: ArchiveMemberModification?, seen = false
        while offset + 4 <= data.count {
            let tag = u16(data, offset), size = Int(u16(data, offset + 2)); offset += 4
            guard size <= data.count - offset else { return nil }
            if tag == 1 {
                guard size == 24, !seen else { return nil }
                seen = true
                let ticks = u64(data, offset)
                if ticks != 0 { result = .unix(TimeInterval(ticks) / 10_000_000 - 11_644_473_600) }
            }
            offset += size
        }
        return offset == data.count ? result : nil
    }
    private static func decode(_ raw: Data, flags: UInt16, unicode: Data?) throws -> String {
        if flags & 0x0800 != 0 {
            guard let value = String(data: raw, encoding: .utf8) else { throw ZIPArchiveFailure.unsupportedEncoding }; return value
        }
        if let unicode, unicode.count >= 5, unicode[0] == 1, u32(unicode, 1) == crc32(raw) {
            guard let value = String(data: unicode.dropFirst(5), encoding: .utf8) else { throw ZIPArchiveFailure.unsupportedEncoding }; return value
        }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        guard let value = String(data: raw, encoding: encoding) else { throw ZIPArchiveFailure.unsupportedEncoding }; return value
    }
    internal static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) } }
        return value ^ .max
    }
    static func take64(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        guard offset + 8 <= data.count else { throw ZIPArchiveFailure.malformed }
        defer { offset += 8 }; return u64(data, offset)
    }
    static func fits(_ start: UInt64, _ count: UInt64, before end: UInt64) -> Bool { start <= end && count <= end - start }
    static func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16 }
    static func u64(_ data: Data, _ offset: Int) -> UInt64 { UInt64(u32(data, offset)) | UInt64(u32(data, offset + 4)) << 32 }
}
