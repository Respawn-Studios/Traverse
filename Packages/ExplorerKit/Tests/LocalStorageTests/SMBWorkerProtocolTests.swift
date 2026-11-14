import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SMBWorkerProtocolTests: XCTestCase {
    private let session = UUID(uuidString: "A1B2C3D4-1234-4567-8ABC-123456789ABC")!
    private let read = UUID(uuidString: "11111111-1234-4567-8ABC-123456789ABC")!
    private func frame(_ sequence: Int, _ payload: String, read: UUID? = nil) -> Data {
        Data("MEXSMB1 \(session.uuidString) \(read?.uuidString ?? "-") \(sequence) \(payload)".utf8)
    }
    private func decoder() throws -> SMBWorkerDecoder {
        var value = SMBWorkerDecoder(session: session)
        _ = try value.consume(frame(0, "connected")); try value.beginRead(read); return value
    }
    func testPagePublishesOnlyOnCommitAndEndsOnExplicitEOF() throws {
        var value = try decoder()
        XCTAssertNil(try value.consume(frame(1,"row 128 123 004f006e0065",read:read)))
        guard case .page(let page) = try value.consume(frame(2,"page 0 1",read:read)) else { return XCTFail() }
        XCTAssertEqual(page.entries.first?.name,"One"); XCTAssertEqual(page.entries.first?.logicalBytes,123)
        XCTAssertEqual(value.activeRead,read)
        guard case .readEnd(let id,let count) = try value.consume(frame(3,"readEnd 1",read:read)) else { return XCTFail() }
        XCTAssertEqual(id,read); XCTAssertEqual(count,1); XCTAssertNil(value.activeRead)
        try value.beginRead(UUID())
    }
    func testWrongGenerationDuplicateSequenceAndUnknownVersionRefuse() throws {
        for data in [frame(1,"row 128 123 0041",read:UUID()),frame(0,"row 128 123 0041",read:read),
                     Data("MEXSMB2 \(session) \(read) 1 row 128 123 0041".utf8)] {
            var value = try decoder(); XCTAssertThrowsError(try value.consume(data))
        }
    }
    func testInvalidUTF16AmbiguousNamesAndNumericFormsRefuse() throws {
        for name in ["d800","dc00","0000","002f","002e002e","xyz0","004"] {
            var value = try decoder(); XCTAssertThrowsError(try value.consume(frame(1,"row 128 0 \(name)",read:read)))
        }
        for number in ["-1","01","18446744073709551616"] {
            var value = try decoder(); XCTAssertThrowsError(try value.consume(frame(1,"row 128 \(number) 0041",read:read)))
        }
    }
    func testCompositionsStayDistinctButExactDuplicateRefuses() throws {
        var value = try decoder()
        _ = try value.consume(frame(1,"row 128 1 00e9",read:read))
        _ = try value.consume(frame(2,"row 128 1 00650301",read:read))
        XCTAssertThrowsError(try value.consume(frame(3,"row 128 1 00e9",read:read)))
    }
    func testIncompletePageCannotCompleteOrClaimDifferentCount() throws {
        for payload in ["readEnd 1","page 0 2","page 1 1"] {
            var value = try decoder(); _ = try value.consume(frame(1,"row 128 1 0041",read:read))
            XCTAssertThrowsError(try value.consume(frame(2,payload,read:read)))
        }
    }
    func testTerminalRequiresActualOwnerCountsAndRefusesBodyCommands() throws {
        var value = try decoder()
        let counts = Array(repeating:"0",count:19).joined(separator:",")
        guard case .closed(let result) = try value.consume(frame(1,"closed stopped 4 0 0 0 100 \(counts)",read:read)) else { return XCTFail() }
        XCTAssertTrue(result.provesDrain)
        XCTAssertThrowsError(try value.consume(frame(2,"readEnd 0",read:read)))
        var bad = try decoder(); var commands=Array(repeating:"0",count:19); commands[8]="1"
        XCTAssertThrowsError(try bad.consume(frame(1,"closed stopped 4 0 0 0 100 \(commands.joined(separator:","))",read:read)))
    }
    func testSparseBoundedPagesDoNotAssumeFullSizedServerReplies() throws {
        var value = try decoder()
        for page in 0..<40 {
            let name=String(format:"%04x",0x100+page)
            _ = try value.consume(frame(page*2+1,"row 128 1 \(name)",read:read))
            guard case .page(let result) = try value.consume(frame(page*2+2,"page \(page) 1",read:read)) else { return XCTFail() }
            XCTAssertEqual(result.index,page)
        }
        guard case .readEnd(_,40) = try value.consume(frame(81,"readEnd 40",read:read)) else { return XCTFail() }
    }
    private func authenticated(_ sequence: Int, _ payload: String) -> Data {
        Data("MEXSMB2 \(session.uuidString) - \(sequence) \(payload)".utf8)
    }
    func testAuthenticatedDecoderRequiresItsVersionAndActualSecurity() throws {
        for bad in [frame(0, "connected"), authenticated(0, "connected"), authenticated(0, "connected guest"),
                    authenticated(0, "connected signed")] {
            var value = SMBWorkerDecoder(session: session, profile: .authenticated(.encrypted))
            XCTAssertThrowsError(try value.consume(bad))
        }
        var valid = SMBWorkerDecoder(session: session, profile: .authenticated(.encrypted))
        guard case .connected = try valid.consume(authenticated(0, "connected encrypted")) else { return XCTFail() }
        XCTAssertEqual(valid.security, .encrypted)
    }
    func testSignedCompatibilityKeepsVisibleShareRequiredEncryption() throws {
        for actual in ["signed", "encrypted"] {
            var value = SMBWorkerDecoder(session: session, profile: .authenticated(.signedCompatibility))
            _ = try value.consume(authenticated(0, "connected \(actual)"))
            XCTAssertEqual(value.security?.rawValue, actual)
        }
    }
    func testAuthenticationFailureCannotMasqueradeAsConnectedOrGuestProtocol() throws {
        let counts = ["1", "2"] + Array(repeating: "0", count: 17)
        var value = SMBWorkerDecoder(session: session, profile: .authenticated(.encrypted))
        guard case .closed(let result) = try value.consume(authenticated(0, "closed authentication 4 0 0 0 20 \(counts.joined(separator: ","))")) else { return XCTFail() }
        XCTAssertFalse(value.connected); XCTAssertNil(value.security); XCTAssertTrue(result.provesDrain)
        XCTAssertThrowsError(try value.consume(authenticated(1, "connected encrypted")))
        var guest = SMBWorkerDecoder(session: session)
        XCTAssertThrowsError(try guest.consume(frame(0, "closed authentication 4 0 0 0 20 \(counts.joined(separator: ","))")))
    }
    func testZeroOwnersIsValidOnlyBeforeConnectionAndCommandAdmission() throws {
        let zero = Array(repeating: "0", count: 19).joined(separator: ",")
        var early = SMBWorkerDecoder(session: session, profile: .authenticated(.encrypted))
        guard case .closed(let result) = try early.consume(authenticated(0, "closed remote-error 0 0 0 0 0 \(zero)")) else { return XCTFail() }
        XCTAssertTrue(result.provesDrain)
        var connected = SMBWorkerDecoder(session: session, profile: .authenticated(.encrypted))
        _ = try connected.consume(authenticated(0, "connected encrypted"))
        XCTAssertThrowsError(try connected.consume(authenticated(1, "closed stopped 0 0 0 0 0 \(zero)")))
        var attempted = SMBWorkerDecoder(session: session, profile: .authenticated(.encrypted))
        let counts = (["1"] + Array(repeating: "0", count: 18)).joined(separator: ",")
        XCTAssertThrowsError(try attempted.consume(authenticated(0, "closed remote-error 0 0 0 0 0 \(counts)")))
    }
}
