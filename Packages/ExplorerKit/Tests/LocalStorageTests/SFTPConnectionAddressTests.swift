import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPConnectionAddressTests: XCTestCase {
    func testHomeAndExplicitRootAreDifferentAndDoNotContainCredentials() throws {
        let home = try SFTPConnectionAddress("Studio.Example.invalid"), root = try SFTPConnectionAddress("sftp://studio.example.invalid/")
        XCTAssertEqual(home.host, "studio.example.invalid"); XCTAssertEqual(home.hostKind, .dns); XCTAssertEqual(home.port, 22)
        XCTAssertNil(home.components); XCTAssertEqual(home.initialPathUTF8, Data(".".utf8)); XCTAssertEqual(root.components, [])
        XCTAssertEqual(root.initialPathUTF8, Data("/".utf8)); XCTAssertNotEqual(home, root)
        XCTAssertEqual(home.displayAddress, "sftp://studio.example.invalid"); XCTAssertEqual(root.displayAddress, "sftp://studio.example.invalid/")
        XCTAssertEqual(String(reflecting: home), "<SFTP address>")
    }
    func testExactUTF8CompositionAndPOSIXSymbolsRoundTripWithoutNormalization() throws {
        for text in ["sftp://server/home/Caf%C3%A9", "sftp://server/home/Cafe%CC%81", "server/a%5Cb/a%0Ab/%E2%80%AEname/%23%3F%25", "server/a\\b"] {
            let address = try SFTPConnectionAddress(text)
            XCTAssertEqual(try SFTPConnectionAddress(address.displayAddress), address)
            XCTAssertEqual(try JSONDecoder().decode(SFTPConnectionAddress.self, from: JSONEncoder().encode(address)), address)
            XCTAssertEqual(String(reflecting: address), "<SFTP address>")
        }
        let a = try SFTPConnectionAddress("server/Caf%C3%A9"), b = try SFTPConnectionAddress("server/Cafe%CC%81")
        XCTAssertNotEqual(a, b); XCTAssertNotEqual(a.initialPathUTF8, b.initialPathUTF8)
        let symbolic = try SFTPConnectionAddress("server/a%5Cb/a%0Ab")
        XCTAssertEqual(symbolic.initialPathUTF8, Data("/a\\b/a\nb".utf8))
        XCTAssertEqual(symbolic.components?.map(\.displayName), ["a\\\\b", "a\\u{a}b"])
    }
    func testNumericHostsScopesAndPortsUseTheSameAuthorityRulesAsSMB() throws {
        for authority in ["127.0.0.1", "127.0.0.1:2222", "[::1]", "[fe80:0:0:0:0:0:0:1%253]:2222", "STUDIO.example.invalid"] {
            let sftp = try SFTPConnectionAddress(authority + "/home"), smb = try SMBConnectionAddress(authority + "/QA")
            XCTAssertEqual(sftp.host, smb.host); XCTAssertEqual(sftp.scopeID, smb.scopeID)
            XCTAssertEqual(try SFTPConnectionAddress(sftp.displayAddress), sftp)
        }
        XCTAssertEqual(try SFTPConnectionAddress("[fe80::1%253]").displayAddress, "sftp://[fe80::1%253]")
        XCTAssertEqual(try SMBConnectionAddress("server/QA").port, 445)
    }
    func testMalformedMixedProtocolAndLocalPathsNeverBecomeConnectionAuthority() {
        let values = ["", "/Volumes/Workspace", "file:///tmp", "smb://server/QA", "https://server", "sftp://user:secret@server",
            "sftp://server/home?password=secret", "server/#part", "server//home", "server/home/..", "server/home/%2e", "server/a%2fb",
            "server/%00", "server/%ff", "server/%xx", "server:0", "server:022", "server:65536", "server:", "0.0.0.0", "224.0.0.1",
            "127.00.0.1", "-server", "server.", "server_.local", "[fe80::1]", "[fe80::1%25en0]", "[::]", "[ff02::1]", " server", "server\n"]
        for (index, text) in values.enumerated() { XCTAssertThrowsError(try SFTPConnectionAddress(text), "Invalid generated case \(index) admitted") }
    }
    func testPathAndComponentCountLimitsAreExplicit() throws {
        XCTAssertThrowsError(try SFTPConnectionAddress("server/" + Array(repeating: "a", count: 129).joined(separator: "/")))
        XCTAssertThrowsError(try SFTPConnectionAddress("server/" + String(repeating: "a", count: 8192)))
        XCTAssertNoThrow(try SFTPConnectionAddress("server/" + String(repeating: "a", count: 8191)))
        XCTAssertThrowsError(try SFTPConnectionAddress(String(repeating: "a", count: 65537)))
        XCTAssertThrowsError(try RemoteNetworkAuthority("[::1\0untrusted]", defaultPort: 22))
    }
}
