import Darwin
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage
import Testing

struct TARTestFixture {
    let root: URL, source: URL, bytes: Data
    init(pax: Bool = false, link: Bool = false, folderTree: Bool = false) throws {
        var result = Data()
        if pax {
            let payload = TARMemberHeader.attribute("uid", "123456789")
                + TARMemberHeader.attribute("uname", "original owner")
                + TARMemberHeader.attribute("size", "3")
                + TARMemberHeader.attribute("atime", "1700000000.125")
            result += Self.member("PaxHeader", body: payload, type: 120)
        }
        result += Self.member("data.json", body: Data("{}\n".utf8), declaredSize: pax ? 0 : nil)
        result += Self.member("other.bin", body: Data([0, 1, 2, 3, 0, 255]))
        result += Self.member("empty/", body: Data(), type: 53)
        if folderTree {
            result += Self.member("Folder/", body: Data(), type: 53)
            result += Self.member("Folder/Nested/", body: Data(), type: 53)
            result += Self.member("Folder/Nested/note.json", body: Data("{\"nested\":true}\n".utf8))
            result += Self.member("Folder/Empty/", body: Data(), type: 53)
            result += Self.member("Destination/", body: Data(), type: 53)
        }
        if link { result += Self.member("link", body: Data(), type: 50) }
        try self.init(rawMembers: result)
    }
    init(rawMembers: Data) throws {
        root = try LocalStorageTestFixtures.directory()
        source = root.appendingPathComponent("Source.tar")
        bytes = rawMembers + Data(repeating: 0, count: 1024)
        try bytes.write(to: source, options: .withoutOverwriting)
    }
    static func member(_ name: String, body: Data, type: UInt8 = 48, declaredSize: UInt64? = nil) -> Data {
        var header = Data(repeating: 0, count: 512)
        func text(_ value: String, at offset: Int) { header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8) }
        text(name, at: 0); text("0000751\0", at: 100); text("0000173\0", at: 108); text("0000710\0", at: 116)
        try! TARMemberHeader.setOctal(declaredSize ?? UInt64(body.count), in: &header, range: 124..<136)
        text("14524770400\0", at: 136); header[156] = type
        text("ustar\0", at: 257); text("00", at: 263)
        text("retained-user", at: 265); text("retained-group", at: 297)
        text("0000000\0", at: 329); text("0000000\0", at: 337)
        TARMemberHeader.checksum(&header)
        return header + body + Data(repeating: 0, count: (512 - body.count % 512) % 512)
    }
    func document() async throws -> TARTextEditDocument {
        let reader = TARArchiveReader(), session = try await reader.open(source)
        let page = try await session.page(in: session.root)
        let member = try #require(page.items.first { $0.name == "data.json" })
        return try await reader.openTextForEdit(session.selectionForTextPreview(member.id))
    }
    func output() throws -> (URL, Int32) {
        let url = root.appendingPathComponent("Edited.tar")
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0); return (url, fd)
    }
}
