import Foundation

/// Patches only fields changed by a member edit. Retained ustar/GNU header
/// fields and unrelated local PAX records stay byte-for-byte intact.
internal enum TARMemberHeader {
    static func replacingSize(_ record: TARRecord, with size: UInt64,
        read: (UInt64, Int) throws -> Data) throws -> Data {
        try rewriting(record, path: nil, size: size, read: read)
    }
    static func rewriting(_ record: TARRecord, path: String?, size: UInt64? = nil,
        read: (UInt64, Int) throws -> Data) throws -> Data {
        var member = try read(record.headerOffset, 512)
        if let size { try setOctal(size, in: &member, range: 124..<136) }
        let name = path.map { $0 + (record.kind == .directory ? "/" : "") }
        var needsPAXPath = false
        if let name {
            let ustar = member[257..<263].elementsEqual("ustar\0".utf8)
            if ustar, let fields = TARCreationHeader.ustarName(name) {
                member.replaceSubrange(0..<100, with: repeatElement(UInt8(0), count: 100))
                member.replaceSubrange(345..<500, with: repeatElement(UInt8(0), count: 155))
                member.replaceSubrange(0..<fields.0.utf8.count, with: fields.0.utf8)
                member.replaceSubrange(345..<(345 + fields.1.utf8.count), with: fields.1.utf8)
            } else if !ustar, name.utf8.count <= 100, name.utf8.allSatisfy({ $0 < 128 }) {
                member.replaceSubrange(0..<100, with: repeatElement(UInt8(0), count: 100))
                member.replaceSubrange(0..<name.utf8.count, with: name.utf8)
            } else { needsPAXPath = true }
        }
        checksum(&member)
        guard let extensionOffset = record.extensionOffset else {
            guard needsPAXPath, let name else { return member }
            return try syntheticPAX(attribute("path", name)) + member
        }
        var header = try read(extensionOffset, 512)
        guard extensionOffset < record.headerOffset,
              record.headerOffset - extensionOffset <= (65_536 + 1_024) else {
            throw TARMemberEditFailure.unsupportedArchive
        }
        let bytes = Int(record.headerOffset - extensionOffset - 512)
        let payload = try read(extensionOffset + 512, bytes)
        guard header[156] == 120 else {
            guard header[156] == 76 else { throw TARMemberEditFailure.unsupportedArchive }
            guard let name else { return header + payload + member }
            let longName = Data(name.utf8) + Data([0])
            try setOctal(UInt64(longName.count), in: &header, range: 124..<136); checksum(&header)
            return header + padded(longName) + member
        }
        let count = try octal(header, range: 124..<136)
        guard count <= UInt64(payload.count) else { throw TARMemberEditFailure.unsupportedArchive }
        let pax = try replacingPAX(payload.prefix(Int(count)), size: size, path: name, addPath: needsPAXPath)
        guard pax.count <= 65_536 else { throw TARMemberEditFailure.limitReached }
        try setOctal(UInt64(pax.count), in: &header, range: 124..<136)
        checksum(&header)
        return header + padded(pax) + member
    }

    private static func replacingPAX(_ bytes: Data, size: UInt64?, path: String?, addPath: Bool) throws -> Data {
        var cursor = 0, result = Data(), sawPath = false
        while cursor < bytes.count {
            guard let space = bytes[cursor...].firstIndex(of: 32), space - cursor <= 6,
                  let length = Int(String(decoding: bytes[cursor..<space], as: UTF8.self)),
                  length > space - cursor + 3, length <= bytes.count - cursor,
                  bytes[cursor + length - 1] == 10,
                  let equals = bytes[(space + 1)..<(cursor + length - 1)].firstIndex(of: 61) else {
                throw TARMemberEditFailure.unsupportedArchive
            }
            let key = bytes[(space + 1)..<equals]
            if key.elementsEqual("size".utf8), let size {
                result.append(attribute("size", String(size)))
            } else if key.elementsEqual("path".utf8) {
                sawPath = true
                if let path { result.append(attribute("path", path)) }
                else { result.append(bytes[cursor..<(cursor + length)]) }
            } else { result.append(bytes[cursor..<(cursor + length)]) }
            cursor += length
        }
        if addPath, !sawPath, let path { result.append(attribute("path", path)) }
        return result
    }

    private static func syntheticPAX(_ payload: Data) throws -> Data {
        let header = try TARCreationHeader.header(name: "PaxHeaders/Edited", prefix: "", mode: 0o644,
            bytes: UInt64(payload.count), modified: 0, kind: 120)
        return header + padded(payload)
    }
    private static func padded(_ data: Data) -> Data {
        data + Data(repeating: 0, count: (512 - data.count % 512) % 512)
    }

    internal static func attribute(_ key: String, _ value: String) -> Data {
        let content = " " + key + "=" + value + "\n"
        var length = content.utf8.count + 1
        while String(length).utf8.count + content.utf8.count != length {
            length = String(length).utf8.count + content.utf8.count
        }
        return Data((String(length) + content).utf8)
    }
    internal static func setOctal(_ value: UInt64, in header: inout Data, range: Range<Int>) throws {
        let text = String(value, radix: 8)
        guard header.count == 512, text.utf8.count < range.count else { throw TARMemberEditFailure.limitReached }
        let field = String(repeating: "0", count: range.count - text.utf8.count - 1) + text + "\0"
        header.replaceSubrange(range, with: field.utf8)
    }
    internal static func checksum(_ header: inout Data) {
        header.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
        let sum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        let text = String(sum, radix: 8)
        let field = String(repeating: "0", count: 6 - text.utf8.count) + text + "\0 "
        header.replaceSubrange(148..<156, with: field.utf8)
    }
    private static func octal(_ header: Data, range: Range<Int>) throws -> UInt64 {
        let value = String(decoding: header[range].prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let count = UInt64(value, radix: 8) else { throw TARMemberEditFailure.unsupportedArchive }
        return count
    }
}
