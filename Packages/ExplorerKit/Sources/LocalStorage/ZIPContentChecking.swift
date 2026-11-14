import Foundation
import zlib

public enum ZIPContentFailure: Error, Equatable, Sendable {
    case unsupported, metadataMismatch, contentMismatch, limitReached, codecUnavailable
}
public struct ZIPContentProblem: Error, Sendable {
    public let member: String?
    public let reason: ZIPContentFailure
}
public struct ZIPContentProgress: Sendable {
    public let completedEntries: Int
    public let totalEntries: Int
    public let decodedBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let member: String
}
public struct ZIPContentReport: Sendable {
    public let files: Int
    public let folders: Int
    public let decodedBytes: UInt64
    public let packedBytes: UInt64
    public let seconds: Double
    public let codecVersion: String
}
internal struct ZIPContentLimits: Sendable {
    var files = 10_000
    var nodes = 20_000
    var memberBytes: UInt64 = 256 * 1_024 * 1_024
    var jobBytes: UInt64 = 1_024 * 1_024 * 1_024
    var packedBytes: UInt64 = 1_024 * 1_024 * 1_024
    var expansionRatio: UInt64 = 2_000
    var seconds: Double = 300
}
internal struct ZIPPayloadRecord: Sendable, Equatable {
    let name: String
    let rawName: Data
    let kind: ZIPMemberKind
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let logical: UInt64
    let packed: UInt64
    let localOffset: UInt64
    let centralOffset: UInt64
    let usesZIP64: Bool
}
internal struct ZIPPayloadExtent: Sendable {
    let record: ZIPPayloadRecord
    let payload: UInt64
    let end: UInt64
}

/// One synchronous stream owner. The checker has no sink; only the separately
/// admitted producer consumes a scratch buffer before the next codec call.
internal enum ZIPContentDecoder {
    static let chunk = 65_536
    static func check(method: UInt16, packed: UInt64, logical: UInt64, expectedCRC: UInt32,
                      check: () throws -> Void, read: (UInt64, Int) throws -> Data,
                      decoded: (UInt64) throws -> Void,
                      consume: (UnsafeRawBufferPointer) throws -> Void = { _ in }) throws {
        try check()
        var checksum = zlib.crc32(0, nil, 0), produced: UInt64 = 0
        if method == 0 {
            guard packed == logical else { throw ZIPContentFailure.contentMismatch }
            var offset: UInt64 = 0
            while offset < packed {
                try check()
                let count = Int(min(UInt64(chunk), packed - offset)), bytes = try read(offset, count)
                guard bytes.count == count else { throw ZIPContentFailure.contentMismatch }
                try check()
                checksum = bytes.withUnsafeBytes { zlib.crc32(checksum, $0.bindMemory(to: UInt8.self).baseAddress, uInt(count)) }
                try bytes.withUnsafeBytes { try consume($0) }
                offset += UInt64(count); produced += UInt64(count)
                try decoded(UInt64(count))
            }
        } else if method == 8 {
            var state = z_stream()
            try withUnsafeMutablePointer(to: &state) { stream in
                guard inflateInit2_(stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPContentFailure.codecUnavailable }
                defer { _ = inflateEnd(stream) }
                let output = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: chunk)
                defer { output.deallocate() }
                var input = Data(), inputIndex = 0, supplied: UInt64 = 0, consumed: UInt64 = 0
                while true {
                    try check()
                    if inputIndex == input.count, supplied < packed {
                        let count = Int(min(UInt64(chunk), packed - supplied))
                        input = try read(supplied, count); inputIndex = 0
                        guard input.count == count else { throw ZIPContentFailure.contentMismatch }
                        supplied += UInt64(count)
                    }
                    let available = input.count - inputIndex
                    try check()
                    var used = 0, emitted = 0
                    let status = input.withUnsafeBytes { bytes in
                        stream.pointee.next_in = available == 0 ? nil : UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: inputIndex))
                        stream.pointee.avail_in = uInt(available)
                        stream.pointee.next_out = output.baseAddress; stream.pointee.avail_out = uInt(chunk)
                        defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                        let value = inflate(stream, Z_NO_FLUSH)
                        used = available - Int(stream.pointee.avail_in); emitted = chunk - Int(stream.pointee.avail_out)
                        return value
                    }
                    inputIndex += used; consumed += UInt64(used)
                    guard UInt64(emitted) <= logical - produced else { throw ZIPContentFailure.contentMismatch }
                    if emitted > 0 {
                        checksum = zlib.crc32(checksum, output.baseAddress, uInt(emitted))
                        try consume(UnsafeRawBufferPointer(start: output.baseAddress, count: emitted))
                        produced += UInt64(emitted); try decoded(UInt64(emitted))
                    }
                    if status == Z_STREAM_END {
                        guard consumed == packed else { throw ZIPContentFailure.contentMismatch }
                        break
                    }
                    if status == Z_MEM_ERROR || status == Z_STREAM_ERROR || status == Z_VERSION_ERROR { throw ZIPContentFailure.codecUnavailable }
                    guard status == Z_OK || status == Z_BUF_ERROR else { throw ZIPContentFailure.contentMismatch }
                    // Fresh output is always available. An unchanged state has
                    // no additional input/buffer transition left to justify retry.
                    guard used > 0 || emitted > 0 else { throw ZIPContentFailure.contentMismatch }
                }
            }
        } else { throw ZIPContentFailure.unsupported }
        try check()
        guard produced == logical, UInt32(truncatingIfNeeded: checksum) == expectedCRC else { throw ZIPContentFailure.contentMismatch }
    }
}

internal enum ZIPContentVerifier {
    static func verify(_ records: [ZIPPayloadRecord], limits: ZIPContentLimits, check: () throws -> Void,
                       read: (UInt64, Int) throws -> Data,
                       progress: (@Sendable (ZIPContentProgress) -> Void)?) throws -> ZIPContentReport {
        let started = ProcessInfo.processInfo.systemUptime
        let layout = try prepare(records, limits: limits, check: check, read: read)
        let extents = layout.extents, logical = layout.logical, packed = layout.packed
        let files = layout.files, folders = layout.folders
        var done: UInt64 = 0, completed = 0, lastProgress = -Double.infinity
        for extent in extents {
            try check()
            do {
                try ZIPContentDecoder.check(method: extent.record.method, packed: extent.record.packed, logical: extent.record.logical, expectedCRC: extent.record.crc,
                    check: check, read: { offset, count in try read(extent.payload + offset, count) }, decoded: { amount in
                        guard amount <= limits.jobBytes - done else { throw ZIPContentFailure.limitReached }
                        done += amount
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastProgress >= 0.1 {
                            progress?(.init(completedEntries: completed, totalEntries: extents.count, decodedBytes: done, totalLogicalBytes: logical, member: extent.record.name))
                            lastProgress = now
                        }
                    })
            } catch let reason as ZIPContentFailure { throw ZIPContentProblem(member: extent.record.name, reason: reason) }
            completed += 1
        }
        try check()
        progress?(.init(completedEntries: completed, totalEntries: extents.count, decodedBytes: done, totalLogicalBytes: logical, member: ""))
        return .init(files: files, folders: folders, decodedBytes: done, packedBytes: packed,
            seconds: ProcessInfo.processInfo.systemUptime - started, codecVersion: String(cString: zlibVersion()))
    }
    struct Layout: Sendable {
        let extents: [ZIPPayloadExtent]
        let logical: UInt64, packed: UInt64
        let files: Int, folders: Int
    }
    static func prepare(_ records: [ZIPPayloadRecord], limits: ZIPContentLimits, check: () throws -> Void,
                        read: (UInt64, Int) throws -> Data) throws -> Layout {
        var logical: UInt64 = 0, packed: UInt64 = 0, files = 0, folders = 0
        var extents: [ZIPPayloadExtent] = []
        for record in records {
            try check()
            do {
                guard record.kind == .file || record.kind == .directory, [0, 8].contains(record.method),
                      record.flags & ~UInt16(0x080e) == 0,
                      record.method == 8 || record.flags & 0x0006 == 0 else { throw ZIPContentFailure.unsupported }
                let (expanded, ratioOverflow) = max(record.packed, 1).multipliedReportingOverflow(by: limits.expansionRatio)
                guard !ratioOverflow, record.logical <= limits.memberBytes, record.logical <= expanded else { throw ZIPContentFailure.limitReached }
                let (total, a) = logical.addingReportingOverflow(record.logical), (input, b) = packed.addingReportingOverflow(record.packed)
                guard !a && !b, total <= limits.jobBytes, input <= limits.packedBytes else { throw ZIPContentFailure.limitReached }
                logical = total; packed = input
                if record.kind == .file { files += 1 } else { folders += 1 }
                guard files <= limits.files, files + folders <= limits.nodes else { throw ZIPContentFailure.limitReached }
                extents.append(try extent(record, read: read))
            } catch let reason as ZIPContentFailure { throw ZIPContentProblem(member: record.name, reason: reason) }
        }
        extents.sort { $0.record.localOffset < $1.record.localOffset }
        for pair in zip(extents, extents.dropFirst()) where pair.0.end > pair.1.record.localOffset {
            throw ZIPContentProblem(member: pair.1.record.name, reason: .metadataMismatch)
        }
        return .init(extents: extents, logical: logical, packed: packed, files: files, folders: folders)
    }
    private static func extent(_ record: ZIPPayloadRecord, read: (UInt64, Int) throws -> Data) throws -> ZIPPayloadExtent {
        let header = try read(record.localOffset, 30)
        guard header.count == 30, ZIPMetadataParser.u32(header, 0) == 0x04034b50,
              ZIPMetadataParser.u16(header, 6) == record.flags, ZIPMetadataParser.u16(header, 8) == record.method,
              Int(ZIPMetadataParser.u16(header, 26)) == record.rawName.count else { throw ZIPContentFailure.metadataMismatch }
        let extraBytes = Int(ZIPMetadataParser.u16(header, 28)), variableBytes = record.rawName.count + extraBytes
        guard ZIPMetadataParser.fits(record.localOffset, UInt64(30 + variableBytes), before: record.centralOffset) else { throw ZIPContentFailure.metadataMismatch }
        let fields = try read(record.localOffset + 30, variableBytes)
        guard fields.count == variableBytes, fields.prefix(record.rawName.count).elementsEqual(record.rawName) else { throw ZIPContentFailure.metadataMismatch }
        let streamed = record.flags & 8 != 0
        let crc = ZIPMetadataParser.u32(header, 14)
        var logical = UInt64(ZIPMetadataParser.u32(header, 22)), packed = UInt64(ZIPMetadataParser.u32(header, 18))
        let extra = try ZIPMetadataParser.extras(Data(fields.dropFirst(record.rawName.count)))
        if streamed {
            guard crc == 0 || crc == record.crc else { throw ZIPContentFailure.metadataMismatch }
            if logical == UInt32.max || packed == UInt32.max {
                guard logical == UInt32.max, packed == UInt32.max, extra[1] != nil else { throw ZIPContentFailure.metadataMismatch }
            } else {
                guard (logical == 0 || logical == record.logical), (packed == 0 || packed == record.packed) else { throw ZIPContentFailure.metadataMismatch }
            }
            if let values = extra[1] {
                guard values.count == 16 else { throw ZIPContentFailure.metadataMismatch }
                let expanded = ZIPMetadataParser.u64(values, 0), compressed = ZIPMetadataParser.u64(values, 8)
                guard (expanded == 0 || expanded == record.logical), (compressed == 0 || compressed == record.packed) else { throw ZIPContentFailure.metadataMismatch }
            }
        } else if logical == UInt32.max || packed == UInt32.max {
            guard let values = extra[1] else { throw ZIPContentFailure.metadataMismatch }
            var cursor = 0
            if logical == UInt32.max { logical = try ZIPMetadataParser.take64(values, &cursor) }
            if packed == UInt32.max { packed = try ZIPMetadataParser.take64(values, &cursor) }
            guard cursor == values.count else { throw ZIPContentFailure.metadataMismatch }
        }
        if !streamed {
            guard crc == record.crc, logical == record.logical, packed == record.packed else { throw ZIPContentFailure.metadataMismatch }
        }
        let payload = record.localOffset + UInt64(30 + variableBytes)
        guard ZIPMetadataParser.fits(payload, record.packed, before: record.centralOffset) else { throw ZIPContentFailure.metadataMismatch }
        var end = payload + record.packed
        if streamed {
            let count = try ZIPDataDescriptor.length(at: end, before: record.centralOffset,
                crc: record.crc, packed: record.packed, logical: record.logical,
                wide: record.usesZIP64 || extra[1] != nil, read: read)
            end += UInt64(count)
        }
        return .init(record: record, payload: payload, end: end)
    }
}

/// Exact known offset, one declared width, no signature search. A CRC equal to
/// the optional signature is evaluated as both forms; ambiguity is a refusal.
internal enum ZIPDataDescriptor {
    static func length(at offset: UInt64, before boundary: UInt64, crc: UInt32,
                       packed: UInt64, logical: UInt64, wide: Bool,
                       read: (UInt64, Int) throws -> Data) throws -> Int {
        let body = wide ? 20 : 12
        guard offset <= boundary, UInt64(body) <= boundary - offset,
              wide || (packed <= UInt32.max && logical <= UInt32.max) else { throw ZIPContentFailure.metadataMismatch }
        let count = Int(min(UInt64(body + 4), boundary - offset)), bytes = try read(offset, count)
        guard bytes.count == count else { throw ZIPContentFailure.metadataMismatch }
        func matches(_ start: Int) -> Bool {
            guard start + body <= bytes.count, ZIPMetadataParser.u32(bytes, start) == crc else { return false }
            let input = wide ? ZIPMetadataParser.u64(bytes, start + 4) : UInt64(ZIPMetadataParser.u32(bytes, start + 4))
            let output = wide ? ZIPMetadataParser.u64(bytes, start + 12) : UInt64(ZIPMetadataParser.u32(bytes, start + 8))
            return input == packed && output == logical
        }
        var candidates: [Int] = []
        if matches(0) { candidates.append(body) }
        if ZIPMetadataParser.u32(bytes, 0) == 0x08074b50, matches(4) { candidates.append(body + 4) }
        guard candidates.count == 1 else { throw ZIPContentFailure.metadataMismatch }
        return candidates[0]
    }
}
