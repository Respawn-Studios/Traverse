import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPWorkerProtocolTests: XCTestCase {
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let directory = UUID(uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA")!
    private func key(_ seed: UInt8 = 0) throws -> SFTPHostKey {
        var data = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &data)
        try SFTPWire.field(Data((0..<32).map { UInt8($0) &+ seed }), into: &data); return try SFTPHostKey(data)
    }
    private func body(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data()) throws -> Data {
        var data = try SFTPWire.body(session: session, sequence: sequence, kind: kind); data.append(payload); return data
    }
    private func challenge(_ sequence: UInt64 = 0, previous: SFTPHostKey? = nil, host: String = "generated.example", port: UInt16 = 22) throws -> Data {
        let current = try key(); var payload = Data([previous.map { $0 == current ? 2 : 3 } ?? 1])
        try SFTPWire.field(Data(host.utf8), into: &payload); SFTPWire.number(UInt64(port), bytes: 2, into: &payload)
        try SFTPWire.field(current.bytes, into: &payload); try SFTPWire.field(previous?.bytes ?? Data(), into: &payload)
        return try body(sequence, 100, payload)
    }
    private func decoder(previous: SFTPHostKey? = nil) throws -> SFTPWorkerDecoder {
        try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, previous: previous)
    }
    private func ready() throws -> SFTPWorkerDecoder {
        var value = try decoder()
        guard case .challenge(let c) = try value.consume(challenge()) else { throw SFTPProtocolFailure.phase }
        try value.noteApproval(.connectOnce, challenge: c)
        _ = try value.consume(body(1, 101)); _ = try value.consume(body(2, 102)); _ = try value.consume(body(3, 109))
        return value
    }
    private func opened() throws -> SFTPWorkerDecoder {
        var value = try ready(); try value.beginDirectory(directory)
        var path = SFTPWire.token(directory); try SFTPWire.field(Data("/generated".utf8), into: &path)
        _ = try value.consume(body(4, 103, path)); try value.beginNext(directory); return value
    }
    private func row(_ sequence: UInt64, name: Data = Data("Generated file.txt".utf8), generation: UUID? = nil,
                     flags: UInt8 = 7, size: UInt64 = 123, modified: UInt32 = 19, mode: UInt32 = 0o100644) throws -> Data {
        var data = SFTPWire.token(generation ?? directory); data.append(flags)
        SFTPWire.number(size, bytes: 8, into: &data); SFTPWire.number(UInt64(modified), bytes: 4, into: &data)
        SFTPWire.number(UInt64(mode), bytes: 4, into: &data); try SFTPWire.field(name, into: &data); return try body(sequence, 104, data)
    }
    private func batch(_ sequence: UInt64, count: Int, end: Bool = false) throws -> Data {
        var data = SFTPWire.token(directory); SFTPWire.number(UInt64(count), bytes: 4, into: &data)
        data.append(end ? 1 : 0); return try body(sequence, 105, data)
    }
    private func closed(_ sequence: UInt64, ack: Bool = false, before: UInt64 = 0, after: UInt64 = 0) throws -> Data {
        var data = Data([0, ack ? 1 : 0, 0]); SFTPWire.number(before, bytes: 8, into: &data)
        SFTPWire.number(after, bytes: 8, into: &data); return try body(sequence, 107, data)
    }
    func testCanonicalHostKeyAndFingerprintAreDerivedFromExactBlob() throws {
        let value = try key(); XCTAssertEqual(value.bytes.count, 51)
        XCTAssertEqual(value.fingerprint, "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA")
        XCTAssertTrue(value.fingerprint.hasPrefix("SHA256:")); XCTAssertEqual(value.fingerprint.count, 50)
        XCTAssertEqual(String(describing: value), "<SFTP host key>")
        for invalid in [value.bytes + Data([0]), Data(), Data(repeating: 0, count: 65536)] {
            XCTAssertThrowsError(try SFTPHostKey(invalid))
        }
        var wrong = value.bytes; wrong[10] = 0; XCTAssertThrowsError(try SFTPHostKey(wrong))
    }
    func testVerificationEvidenceRequiresExactApprovalBeforeAuthentication() throws {
        var value = try decoder()
        guard case .challenge(let request) = try value.consume(challenge()) else { return XCTFail() }
        XCTAssertEqual(request.kind, .first)
        var unapproved = value; XCTAssertThrowsError(try unapproved.consume(body(1, 101)))
        try value.noteApproval(.remember, challenge: request)
        guard case .verified(let verified) = try value.consume(body(1, 101)) else { return XCTFail() }
        XCTAssertEqual(verified.session, session); XCTAssertEqual(verified.host, "generated.example"); XCTAssertEqual(verified.key, try key())
        guard case .authenticated = try value.consume(body(2, 102)) else { return XCTFail() }
        guard case .ready = try value.consume(body(3, 109)) else { return XCTFail() }
    }
    func testChangedKeyRequiresSeparateReplacementAndCannotUseFirstApproval() throws {
        let previous = try key(1)
        for action in [SFTPTrustAction.connectOnce, .remember, .useMatching] {
            var value = try decoder(previous: previous)
            guard case .challenge(let request) = try value.consume(challenge(previous: previous)) else { return XCTFail() }
            XCTAssertEqual(request.kind, .changed); XCTAssertThrowsError(try value.noteApproval(action, challenge: request))
        }
        var value = try decoder(previous: previous)
        guard case .challenge(let request) = try value.consume(challenge(previous: previous)) else { return XCTFail() }
        try value.noteApproval(.replaceVerified, challenge: request)
        guard case .verified = try value.consume(body(1, 101)) else { return XCTFail() }
    }
    func testMatchingKeyStillRequiresQualifiedStoredKeyAndExactSession() throws {
        let previous = try key(); var value = try decoder(previous: previous)
        guard case .challenge(let request) = try value.consume(challenge(previous: previous)) else { return XCTFail() }
        XCTAssertEqual(request.kind, .matching); try value.noteApproval(.useMatching, challenge: request)
        guard case .verified = try value.consume(body(1, 101)) else { return XCTFail() }
        for frame in [try challenge(host: "other.example"), try challenge(port: 2222), try challenge(previous: key(1))] {
            var other = try decoder(); XCTAssertThrowsError(try other.consume(frame))
        }
    }
    func testVersionSequenceTokenAndFailedDecoderCannotBeReused() throws {
        let good = try challenge()
        var version = good; version[0] = 0
        var token = good; token[8] ^= 1
        for wrong in [version, token, try challenge(1), good + Data([0]), Data(repeating: 0, count: 65537)] {
            var value = try decoder(); XCTAssertThrowsError(try value.consume(wrong)); XCTAssertThrowsError(try value.consume(good))
        }
        for count in 0..<good.count { var value = try decoder(); XCTAssertThrowsError(try value.consume(good.prefix(count))) }
    }
    func testRowsPublishOnlyOnExactBatchCommitAndEOFIsExplicit() throws {
        var value = try opened(); XCTAssertNil(try value.consume(row(5)))
        guard case .batch(let id, let rows, false) = try value.consume(batch(6, count: 1)) else { return XCTFail() }
        XCTAssertEqual(id, directory); XCTAssertEqual(rows.first?.name.displayName, "Generated file.txt")
        XCTAssertEqual(rows.first?.logicalBytes, 123); XCTAssertEqual(rows.first?.modifiedSeconds, 19)
        XCTAssertEqual(rows.first?.isDirectory, false)
        try value.beginNext(directory)
        guard case .batch(_, let rows, true) = try value.consume(batch(7, count: 0, end: true)) else { return XCTFail() }
        XCTAssertTrue(rows.isEmpty); XCTAssertThrowsError(try value.beginNext(directory))
        XCTAssertNoThrow(try value.beginDirectory(UUID()))
    }
    func testRemoteNameIdentityPreservesCompositionAndEscapesDisplayOnly() throws {
        let composed = try SFTPRemoteName(Data("é".utf8)), decomposed = try SFTPRemoteName(Data("e\u{301}".utf8))
        XCTAssertNotEqual(composed, decomposed)
        let literalBackslash = try SFTPRemoteName(Data("a\\b".utf8))
        XCTAssertEqual(literalBackslash.displayName, "a\\\\b")
        XCTAssertTrue(literalBackslash.isSafeForSingleLineEntry)
        let controlled = try SFTPRemoteName(Data("a\nb\u{202e}".utf8))
        XCTAssertEqual(controlled.displayName, "a\\u{a}b\\u{202e}")
        XCTAssertFalse(controlled.isSafeForSingleLineEntry)
        let lineSeparator = try SFTPRemoteName(Data("line\u{2028}break".utf8))
        XCTAssertEqual(lineSeparator.displayName, "line\\u{2028}break")
        XCTAssertFalse(lineSeparator.isSafeForSingleLineEntry)
        let escapedText = try SFTPRemoteName(Data("\\u{202e}".utf8))
        let actualBidi = try SFTPRemoteName(Data("\u{202e}".utf8))
        XCTAssertNotEqual(escapedText.displayName, actualBidi.displayName)
        XCTAssertEqual(controlled.wireUTF8, Data("a\nb\u{202e}".utf8))
        for bad in [Data(), Data([255]), Data("a/b".utf8), Data([0]), Data("..".utf8)] { XCTAssertThrowsError(try SFTPRemoteName(bad)) }
    }
    func testStaleGenerationDuplicateRowsAndWrongCommitRefuse() throws {
        var stale = try opened(); XCTAssertThrowsError(try stale.consume(row(5, generation: UUID())))
        var duplicate = try opened(); _ = try duplicate.consume(row(5)); XCTAssertThrowsError(try duplicate.consume(row(6)))
        for commit in [try batch(6, count: 0), try batch(6, count: 2), try batch(6, count: 1, end: true)] {
            var value = try opened(); _ = try value.consume(row(5)); XCTAssertThrowsError(try value.consume(commit))
        }
        var equivalent = try opened()
        _ = try equivalent.consume(row(5, name: Data("é".utf8))); _ = try equivalent.consume(row(6, name: Data("e\u{301}".utf8)))
        guard case .batch(_, let rows, false) = try equivalent.consume(batch(7, count: 2)) else { return XCTFail() }; XCTAssertEqual(rows.count, 2)
    }
    func testAbsentMetadataIsUnknownAndCannotCarryHiddenNonzeroValues() throws {
        var value = try opened(); _ = try value.consume(row(5, flags: 0, size: 0, modified: 0, mode: 0))
        guard case .batch(_, let rows, _) = try value.consume(batch(6, count: 1)) else { return XCTFail() }
        XCTAssertNil(rows[0].logicalBytes); XCTAssertNil(rows[0].modifiedSeconds); XCTAssertNil(rows[0].isDirectory)
        for invalid in [try row(5, flags: 0), try row(5, flags: 8), try row(5, size: UInt64.max)] {
            var value = try opened(); XCTAssertThrowsError(try value.consume(invalid))
        }
    }
    func testTerminalDropsUncommittedRowsAndDoesNotClaimProcessExit() throws {
        var value = try opened(); _ = try value.consume(row(5))
        guard case .closed(let end) = try value.consume(closed(6, before: 1)) else { return XCTFail() }
        XCTAssertTrue(end.runtimeDisposed); XCTAssertFalse(end.directoryCloseAcknowledged); XCTAssertEqual(end.tasksBeforeRuntimeDrop, 1)
        XCTAssertThrowsError(try value.consume(batch(7, count: 1)))
        var invalid = try opened(); XCTAssertThrowsError(try invalid.consume(closed(5, after: 1)))
        var early = try decoder(); XCTAssertThrowsError(try early.consume(closed(0, ack: true)))
    }
    func testPrimitiveFramesMatchTheVersionedBinaryLayout() throws {
        let body = try SFTPWire.body(session: session, sequence: 9, kind: 6)
        XCTAssertEqual(body.count, 33); XCTAssertEqual(body.prefix(8), Data("MEXSFTP1".utf8))
        let framed = try SFTPWire.frame(body); XCTAssertEqual(framed.prefix(4), Data([0, 0, 0, 33]))
        XCTAssertEqual(framed.dropFirst(4), body)
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertThrowsError(try SFTPWire.body(session: zero, sequence: 0, kind: 6))
        for host in ["", "host.", "user@host", "a..b", "-host", "Host", "a/b"] {
            XCTAssertThrowsError(try SFTPWorkerDecoder(session: session, canonicalHost: host, port: 22))
        }
    }
    func testRejectedHostCannotPublishVerificationOrPrivateDiagnostics() throws {
        var value = try decoder()
        guard case .challenge(let request) = try value.consume(challenge()) else { return XCTFail() }
        XCTAssertEqual(String(describing: request), "<SFTP host review>")
        XCTAssertFalse(String(reflecting: SFTPWorkerEvent.challenge(request)).contains("generated.example"))
        try value.noteApproval(.reject, challenge: request)
        XCTAssertThrowsError(try value.consume(body(1, 101)))
    }
    func testHostileBatchCountAndByteBudgetsRefuseWithoutPublishing() throws {
        var countLimited = try opened()
        for index in 0..<1024 { XCTAssertNil(try countLimited.consume(row(UInt64(index + 5), name: Data("generated-\(index)".utf8)))) }
        XCTAssertThrowsError(try countLimited.consume(row(1029, name: Data("overflow".utf8))))
        var byteLimited = try opened()
        var refused = false
        for index in 0..<70 {
            let name = Data((String(repeating: "x", count: 8100) + String(index)).utf8)
            do { let event = try byteLimited.consume(row(UInt64(index + 5), name: name)); XCTAssertNil(event) }
            catch { XCTAssertEqual(error as? SFTPProtocolFailure, .invalidOutput); refused = true; break }
        }
        XCTAssertTrue(refused)
    }
}
