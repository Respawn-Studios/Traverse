import CryptoKit
import Darwin
import Foundation
import zlib

/// One canonical streamed record. Both portable creation and copy-Add use this
/// encoder; the copy producer never creates another intermediate archive.
internal struct ZIPEncodedNode {
    let name: String, directory: Bool, size: UInt64, crc: UInt32, digest: Data
    let method: UInt16, packed: UInt64, localOffset: UInt64
    let localHeader: Data, centralEntry: Data, dataDescriptor: Data

    func matches(_ record: ZIPPayloadRecord) -> Bool {
        record.rawName.elementsEqual(name.utf8) && record.name.utf8.elementsEqual(name.utf8)
            && (record.kind == .directory) == directory && record.logical == size
            && record.crc == crc && record.method == method && record.packed == packed
            && record.localOffset == localOffset && record.flags == 0x0808
    }
}

internal enum ZIPNodeEncoder {
    /// Empty authored members share the ordinary streamed record format. No
    /// temporary local file is needed to create a file or folder inside a ZIP.
    static func appendEmptyMember(name: String, modifiedSeconds: Int, mode: mode_t,
        writer: ZIPFileEncoder, check: () throws -> Void) throws -> ZIPEncodedNode {
        try check()
        let nameBytes = Data(name.utf8), local = writer.count
        let directory = mode & S_IFMT == S_IFDIR
        guard !name.isEmpty, name.hasSuffix("/") == directory,
              nameBytes.count <= UInt16.max, local <= UInt32.max,
              directory || mode & S_IFMT == S_IFREG else { throw ZIPCreationFailure.limitOrPrivacy }
        let dates = ZIPFileEncoder.dates(modifiedSeconds)
        let extra = ZIPFileEncoder.timestamp(modifiedSeconds)
        var header = Data()
        for (value, width): (UInt64, Int) in [(0x04034b50, 4), (20, 2), (0x0808, 2), (0, 2),
            (UInt64(dates.time), 2), (UInt64(dates.date), 2), (0, 4), (0, 4), (0, 4),
            (UInt64(nameBytes.count), 2), (UInt64(extra.count), 2)] {
            header += ZIPFileEncoder.le(value, width)
        }
        try writer.write(header, check: check)
        try writer.write(nameBytes, check: check)
        try writer.write(extra, check: check)
        let descriptor = ZIPFileEncoder.le(0x08074b50, 4) + ZIPFileEncoder.le(0, 4)
            + ZIPFileEncoder.le(0, 4) + ZIPFileEncoder.le(0, 4)
        try writer.write(descriptor, check: check)
        var entry = Data()
        for (value, width): (UInt64, Int) in [(0x02014b50, 4), (0x0314, 2), (20, 2), (0x0808, 2), (0, 2),
            (UInt64(dates.time), 2), (UInt64(dates.date), 2), (0, 4), (0, 4), (0, 4),
            (UInt64(nameBytes.count), 2), (UInt64(extra.count), 2), (0, 2), (0, 2), (0, 2),
            (UInt64(mode & (S_IFMT | 0o777)) << 16 | (directory ? 0x10 : 0), 4), (local, 4)] {
            entry += ZIPFileEncoder.le(value, width)
        }
        let digest = SHA256()
        return .init(name: name, directory: directory, size: 0, crc: 0,
            digest: Data(digest.finalize()), method: 0, packed: 0, localOffset: local,
            localHeader: header + nameBytes + extra, centralEntry: entry + nameBytes + extra,
            dataDescriptor: descriptor)
    }

    static func append(_ inventory: ZIPCreationInventory, compression: ZIPCompression,
        writer: ZIPFileEncoder, hooks: ZIPCreationHooks, check: () throws -> Void,
        progress: (UInt64, Int) -> Void) throws -> [ZIPEncodedNode] {
        var result: [ZIPEncodedNode] = [], centralBytes = 0
        func checkpoint() throws { try check() }
        for node in inventory.nodes {
            try checkpoint()
            let fd = try inventory.open(node, forReading: !node.stamp.directory, check: checkpoint); defer { close(fd) }
            if node.stamp.directory {
                let encoded = try appendEmptyMember(name: node.name,
                    modifiedSeconds: node.stamp.modifiedSeconds, mode: node.stamp.mode,
                    writer: writer, check: checkpoint)
                guard try ZIPInputStamp(fd) == node.stamp else { throw ZIPCreationFailure.sourceChanged }
                guard centralBytes <= 16 * 1_024 * 1_024 - encoded.centralEntry.count else {
                    throw ZIPCreationFailure.limitOrPrivacy
                }
                result.append(encoded); centralBytes += encoded.centralEntry.count
                progress(0, 1)
                continue
            }
            let name = Data(node.name.utf8), local = writer.count, method = node.stamp.directory ? 0 : compression.method
            let dates = ZIPFileEncoder.dates(node.stamp.modifiedSeconds)
            let extra = ZIPFileEncoder.timestamp(node.stamp.modifiedSeconds)
            var header = Data()
            for (value, width): (UInt64, Int) in [(0x04034b50, 4), (20, 2), (0x0808, 2), (UInt64(method), 2),
                (UInt64(dates.time), 2), (UInt64(dates.date), 2), (0, 4), (0, 4), (0, 4), (UInt64(name.count), 2), (UInt64(extra.count), 2)] {
                header += ZIPFileEncoder.le(value, width)
            }
            try writer.write(header, check: checkpoint); try writer.write(name, check: checkpoint); try writer.write(extra, check: checkpoint)
            let payload = writer.count
            var crc = zlib.crc32(0, nil, 0), content = SHA256(), offset: UInt64 = 0
            if !node.stamp.directory {
                func read() throws -> Data {
                    try checkpoint(); try hooks.beforeSourceRead?(node.url)
                    if offset == UInt64(node.stamp.size) { return Data() }
                    let amount = Int(min(UInt64(65_536), UInt64(node.stamp.size) - offset))
                    var bytes = Data(count: amount)
                    try bytes.withUnsafeMutableBytes { buffer in
                        var filled = 0
                        while filled < amount {
                            try checkpoint()
                            let result = pread(fd, buffer.baseAddress!.advanced(by: filled), amount - filled, off_t(offset) + off_t(filled))
                            if result < 0 && errno == EINTR { continue }
                            guard result > 0 else { throw ZIPCreationFailure.sourceChanged }; filled += result
                        }
                    }
                    crc = bytes.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count)) }
                    content.update(data: bytes); offset += UInt64(amount); progress(UInt64(amount), 0)
                    return bytes
                }
                if compression == .store {
                    while true { let bytes = try read(); if bytes.isEmpty { break }; try writer.write(bytes, check: checkpoint) }
                } else {
                    try ZIPDeflateEncoder.encode(level: compression.level, check: checkpoint, read: read,
                        output: { try writer.write($0, check: checkpoint) })
                }
            }
            guard try ZIPInputStamp(fd) == node.stamp else { throw ZIPCreationFailure.sourceChanged }
            let packed = writer.count - payload, logical = node.stamp.directory ? 0 : UInt64(node.stamp.size)
            guard offset == logical, packed <= UInt32.max, local <= UInt32.max else { throw ZIPCreationFailure.limitOrPrivacy }
            let checksum = UInt32(truncatingIfNeeded: crc)
            var descriptor = ZIPFileEncoder.le(0x08074b50, 4) + ZIPFileEncoder.le(UInt64(checksum), 4)
            descriptor += ZIPFileEncoder.le(packed, 4); descriptor += ZIPFileEncoder.le(logical, 4)
            try writer.write(descriptor, check: checkpoint)
            var entry = Data()
            for (value, width): (UInt64, Int) in [(0x02014b50, 4), (0x0314, 2), (20, 2), (0x0808, 2), (UInt64(method), 2),
                (UInt64(dates.time), 2), (UInt64(dates.date), 2), (UInt64(checksum), 4), (packed, 4), (logical, 4),
                (UInt64(name.count), 2), (UInt64(extra.count), 2), (0, 2), (0, 2), (0, 2),
                (UInt64(node.stamp.mode & (S_IFMT | 0o777)) << 16 | (node.stamp.directory ? 0x10 : 0), 4), (local, 4)] {
                entry += ZIPFileEncoder.le(value, width)
            }
            guard centralBytes <= 16 * 1_024 * 1_024 - entry.count - name.count - extra.count else { throw ZIPCreationFailure.limitOrPrivacy }
            let localHeader = header + name + extra, centralEntry = entry + name + extra
            result.append(.init(name: node.name, directory: node.stamp.directory, size: logical,
                crc: checksum, digest: Data(content.finalize()), method: method, packed: packed,
                localOffset: local, localHeader: localHeader, centralEntry: centralEntry,
                dataDescriptor: descriptor))
            centralBytes += centralEntry.count
            progress(0, 1)
        }
        return result
    }
}
