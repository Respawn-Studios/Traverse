import Foundation

/// Patches only fields changed by a member edit. Retained ustar/GNU header
/// fields and unrelated local PAX records stay byte-for-byte intact.
internal enum TARMemberHeader {
    static func replacingSize(_ record: TARRecord, with size: UInt64,
        read: (UInt64, Int) throws -> Data) throws -> Data {
        var member = try read(record.headerOffset, 512)
        try setOctal(size, in: &member, range: 124..<136)
        checksum(&member)
        guard let extensionOffset = record.extensionOffset else { return member }
        var header = try read(extensionOffset, 512)
        guard extensionOffset < record.headerOffset,
              record.headerOffset - extensionOffset <= (65_536 + 1_024) else {
            throw TARMemberEditFailure.unsupportedArchive
        }
        let bytes = Int(record.headerOffset - extensionOffset - 512)
        let payload = try read(extensionOffset + 512, bytes)
        guard header[156] == 120 else {
            // A GNU long-name record changes no size semantics.
            guard header[156] == 76 else { throw TARMemberEditFailure.unsupportedArchive }
            return header + payload + member
        }
        let count = try octal(header, range: 124..<136)
        guard count <= UInt64(payload.count) else { throw TARMemberEditFailure.unsupportedArchive }
        let pax = try replacingPAXSize(payload.prefix(Int(count)), size: size)
        try setOctal(UInt64(pax.count), in: &header, range: 124..<136)
        checksum(&header)
        return header + pax + Data(repeating: 0, count: (512 - pax.count % 512) % 512) + member
    }

    private static func replacingPAXSize(_ bytes: Data, size: UInt64) throws -> Data {
        var cursor = 0, result = Data()
        while cursor < bytes.count {
            guard let space = bytes[cursor...].firstIndex(of: 32), space - cursor <= 6,
                  let length = Int(String(decoding: bytes[cursor..<space], as: UTF8.self)),
                  length > space - cursor + 3, length <= bytes.count - cursor,
                  bytes[cursor + length - 1] == 10,
                  let equals = bytes[(space + 1)..<(cursor + length - 1)].firstIndex(of: 61) else {
                throw TARMemberEditFailure.unsupportedArchive
            }
            if bytes[(space + 1)..<equals].elementsEqual("size".utf8) {
                result.append(attribute("size", String(size)))
            } else { result.append(bytes[cursor..<(cursor + length)]) }
            cursor += length
        }
        return result
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
