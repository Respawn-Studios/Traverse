import Foundation
import XCTest
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

final class WorkspaceConnectionBindingTests: XCTestCase {
    private func sftp(_ address: String = "sftp://studio.example.test/", _ account: String = "artist", name: String = "Generated") throws -> SFTPServerDraft {
        try .init(name: name, address: .init(address), account: account)
    }
    private func smb(_ address: String = "smb://studio.example.test/Art", account: String = "artist", domain: String = "", security: SMBWorkerSecurityPolicy = .encrypted) throws -> SMBServerDraft {
        try .init(name: "Generated", address: .init(address), account: account, domain: domain, security: security)
    }
    func testLogicalSFTPEndpointAccountScopeAndHomeBasisBindButBrowsePathAndNameDoNot() throws {
        let target = try sftp(), original = WorkspaceConnectionBinding.sftp(target)
        XCTAssertEqual(original.count, 32)
        XCTAssertEqual(original, WorkspaceConnectionBinding.sftp(try sftp("sftp://STUDIO.example.test:22/Artwork", name: "New title")))
        for change in [try sftp("sftp://other.example.test/"), try sftp("sftp://studio.example.test:2222/"),
            try sftp("sftp://studio.example.test"), try sftp("sftp://studio.example.test/", "Artist")] {
            XCTAssertNotEqual(original, WorkspaceConnectionBinding.sftp(change))
        }
        XCTAssertNotEqual(WorkspaceConnectionBinding.sftp(try sftp("sftp://[fe80::1%251]/")), WorkspaceConnectionBinding.sftp(try sftp("sftp://[fe80::1%252]/")))
        XCTAssertNotEqual(WorkspaceConnectionBinding.sftp(try sftp("sftp://studio.example.test/", "caf\u{e9}")),
                          WorkspaceConnectionBinding.sftp(try sftp("sftp://studio.example.test/", "cafe\u{301}")))
    }
    func testSMBShareAccountDomainAndSecurityCannotBeSubstituted() throws {
        let original = WorkspaceConnectionBinding.smb(try smb())
        XCTAssertEqual(original, WorkspaceConnectionBinding.smb(try smb("smb://STUDIO.example.test:445/Art/Subfolder")))
        for change in [try smb("smb://other.example.test/Art"), try smb("smb://studio.example.test:1445/Art"),
            try smb("smb://studio.example.test/art"), try smb(account: "Artist"), try smb(domain: "Studio"), try smb(security: .signedCompatibility)] {
            XCTAssertNotEqual(original, WorkspaceConnectionBinding.smb(change))
        }
        XCTAssertNotEqual(WorkspaceConnectionBinding.smb(try smb("smb://studio.example.test/Caf%C3%A9")),
                          WorkspaceConnectionBinding.smb(try smb("smb://studio.example.test/Cafe%CC%81")))
    }
    func testJumpCannotBecomeDirectOrAnotherRouteAndDestinationHomeBasisIsExact() throws {
        let jump = try sftp("sftp://gateway.example.test", "gateway"), destination = try sftp()
        let route = try SFTPRouteDescription(destination: destination, jump: jump)
        let original = WorkspaceConnectionBinding.route(route)
        XCTAssertNotEqual(original, WorkspaceConnectionBinding.sftp(destination))
        for change in [try SFTPRouteDescription(destination: try sftp("sftp://other.example.test/"), jump: jump),
            try SFTPRouteDescription(destination: destination, jump: try sftp("sftp://other.gateway.test", "gateway")),
            try SFTPRouteDescription(destination: try sftp("sftp://studio.example.test"), jump: jump)] {
            XCTAssertNotEqual(original, WorkspaceConnectionBinding.route(change))
        }
    }
    func testExactTypedDirectoryRoundTripAndWrongProviderRefusal() throws {
        let sftpParts = try [SFTPRemoteName(Data("e\u{301}".utf8)), SFTPRemoteName(Data("line\nname".utf8))]
        let sftp = try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: UUID(), binding: Data(repeating: 3, count: 32), title: "Generated", components: sftpParts.map(\.wireUTF8))
        XCTAssertEqual(try WorkspaceConnectionBinding.sftpComponents(sftp), sftpParts)
        XCTAssertThrowsError(try WorkspaceConnectionBinding.smbComponents(sftp))
        let smbParts = try [SMBRemoteName("e\u{301}"), SMBRemoteName("Artwork")]
        let smb = try WorkspaceConnectionBookmark(kind: .smbServer, serverID: UUID(), binding: Data(repeating: 4, count: 32), title: "Generated", components: smbParts.map(\.wireUTF16))
        XCTAssertEqual(try WorkspaceConnectionBinding.smbComponents(smb), smbParts)
        XCTAssertThrowsError(try WorkspaceConnectionBinding.sftpComponents(smb))
    }
}
