import Foundation
@testable @_spi(Qualification) import LocalStorage
import XCTest

final class SMBResolverProtocolTests: XCTestCase {
    let generation = UUID()
    func line(_ index: Int, _ text: String) -> Data { Data("MEXDNS1 \(generation.uuidString) \(index + 1) \(text)".utf8) }
    func ready() throws -> SMBResolverDecoder {
        var decoder = SMBResolverDecoder(generation: generation)
        _ = try decoder.consume(Data("MEXDNS1 \(generation.uuidString) 0 started".utf8)); return decoder
    }

    func testAddressSnapshotCommitsOnlyWithExactTerminal() throws {
        var decoder = try ready()
        XCTAssertNil(try decoder.consume(line(0, "address 4 7f000001 0 1")))
        XCTAssertNil(decoder.terminal)
        let result = try XCTUnwrap(decoder.consume(line(1, "done resolved 1 1 1 1")))
        XCTAssertEqual(result.addresses.count, 1); XCTAssertEqual(result.addresses[0].addressBytes, Data([127,0,0,1]))
        XCTAssertTrue(result.submitted); XCTAssertTrue(result.deallocated)
        XCTAssertThrowsError(try decoder.consume(line(2, "done resolved 1 1 1 1")))
    }
    func testLinkLocalScopeSurvivesWithoutStringFormatting() throws {
        var decoder = try ready()
        _ = try decoder.consume(line(0, "address 6 fe800000000000000000000000000001 3 3"))
        let result = try XCTUnwrap(decoder.consume(line(1, "done resolved 1 1 0 0")))
        XCTAssertEqual(result.addresses[0].scopeID, 3); XCTAssertEqual(result.addresses[0].interfaceIndex, 3)
        XCTAssertEqual(result.addresses[0].description, "Resolved network address")
    }
    func testInvalidScopeAddressAndHexNeverBecomeAnEndpoint() throws {
        for row in ["address 6 fe800000000000000000000000000001 0 3", "address 6 fe800000000000000000000000000001 4294967295 3",
            "address 4 7f000001 3 1", "address 4 00000000 0 1", "address 4 e0000001 0 1",
            "address 6 00000000000000000000000000000000 0 1", "address 6 ff020000000000000000000000000001 0 1",
            "address 4 7F000001 0 1", "address 4 7f0000 0 1", "address 4 7f000001 0 -1"] {
            var decoder = try ready()
            XCTAssertThrowsError(try decoder.consume(line(0, row)), row)
        }
    }
    func testDuplicateBoundStaleGenerationAndSequenceRefuse() throws {
        var duplicate = try ready()
        _ = try duplicate.consume(line(0, "address 4 7f000001 0 1"))
        XCTAssertThrowsError(try duplicate.consume(line(1, "address 4 7f000001 0 1")))
        var bounded = try ready()
        for index in 0..<16 { _ = try bounded.consume(line(index, String(format: "address 4 7f0000%02x 0 1", index+1))) }
        XCTAssertThrowsError(try bounded.consume(line(16, "address 4 7f000011 0 1")))
        for raw in ["MEXDNS2 \(generation.uuidString) 0 done failed 0 0 0 0",
            "MEXDNS1 \(UUID().uuidString) 0 done failed 0 0 0 0", "MEXDNS1 \(generation.uuidString) 01 done failed 0 0 0 0"] {
            var invalid = SMBResolverDecoder(generation: generation)
            XCTAssertThrowsError(try invalid.consume(Data(raw.utf8)))
        }
    }
    func testFailedOrUndeallocatedResultCannotPublishCandidateRows() throws {
        for terminal in ["done failed 1 1 1 1", "done resolved 2 1 1 1", "done resolved 1 257 1 1", "done resolved 1 1 1 0"] {
            var decoder = try ready()
            _ = try decoder.consume(line(0, "address 4 7f000001 0 1"))
            XCTAssertThrowsError(try decoder.consume(line(1, terminal)))
        }
        var empty = try ready()
        XCTAssertThrowsError(try empty.consume(line(0, "done resolved 0 0 0 0")))
    }
}
