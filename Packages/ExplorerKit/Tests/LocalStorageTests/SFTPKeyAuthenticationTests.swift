import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

// The async fixture check captures only immutable Sendable selections; the
// XCTest instance has no mutable state shared with its detached reader.
final class SFTPKeyAuthenticationTests: XCTestCase, @unchecked Sendable {
    private let session = UUID(uuidString: "D91E7F43-A46A-4DBC-92F1-A954696A59DA")!
    private func key() throws -> SFTPHostKey {
        var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes)
        try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &bytes)
        return try SFTPHostKey(bytes)
    }
    private func body(_ sequence: UInt64, _ kind: UInt8, _ payload: Data = Data(), mode: SFTPWireMode = .keyCatalog) throws -> Data {
        try SFTPWire.body(session: session, sequence: sequence, kind: kind, mode: mode) + payload
    }
    private func verified(mode: SFTPWireMode = .keyCatalog) throws -> SFTPWorkerDecoder {
        var decoder = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: mode)
        var payload = Data([1]); try SFTPWire.field(Data("generated.example".utf8), into: &payload)
        SFTPWire.number(22, bytes: 2, into: &payload); try SFTPWire.field(key().bytes, into: &payload); try SFTPWire.field(Data(), into: &payload)
        guard case .challenge(let challenge) = try decoder.consume(body(0, 100, payload, mode: mode)) else { throw SFTPProtocolFailure.phase }
        try decoder.noteApproval(.connectOnce, challenge: challenge)
        _ = try decoder.consume(body(1, 101, mode: mode)); return decoder
    }
    func testImportedECDSACanonicalKeysValidateCurvesPointsAndTrailingBytes() throws {
        let values: [(String, String, Data)] = [
            ("ecdsa-sha2-nistp256", "nistp256", P256.Signing.PrivateKey().publicKey.x963Representation),
            ("ecdsa-sha2-nistp384", "nistp384", P384.Signing.PrivateKey().publicKey.x963Representation),
            ("ecdsa-sha2-nistp521", "nistp521", P521.Signing.PrivateKey().publicKey.x963Representation)]
        for (name, curve, point) in values {
            var bytes = Data(); try SFTPWire.field(Data(name.utf8), into: &bytes); try SFTPWire.field(Data(curve.utf8), into: &bytes)
            try SFTPWire.field(point, into: &bytes)
            let parsed = try SFTPHostKey(bytes); XCTAssertEqual(parsed.algorithm, name)
            XCTAssertEqual(parsed.fingerprint, "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
            XCTAssertThrowsError(try SFTPHostKey(bytes + Data([0])))
            var bad = Data(); try SFTPWire.field(Data(name.utf8), into: &bad); try SFTPWire.field(Data("nistp999".utf8), into: &bad); try SFTPWire.field(point, into: &bad)
            XCTAssertThrowsError(try SFTPHostKey(bad))
            var invalid = Data(); try SFTPWire.field(Data(name.utf8), into: &invalid); try SFTPWire.field(Data(curve.utf8), into: &invalid)
            try SFTPWire.field(Data(repeating: 0, count: point.count), into: &invalid); XCTAssertThrowsError(try SFTPHostKey(invalid))
        }
    }
    func testKeyIdentityEvidenceIsVersionedBoundToExpectedKeyAndOrderedBeforeReady() throws {
        let identity = try key(); var payload = Data(); try SFTPWire.field(identity.bytes, into: &payload)
        var decoder = try verified(); try decoder.noteKeyAuthentication(expected: identity)
        guard case .authenticatedIdentity(let actual) = try decoder.consume(body(2, 135, payload)) else { return XCTFail("Identity evidence missing") }
        XCTAssertEqual(actual, identity); _ = try decoder.consume(body(3, 102)); _ = try decoder.consume(body(4, 109))
        var missing = try verified(); try missing.noteKeyAuthentication(expected: nil)
        XCTAssertThrowsError(try missing.consume(body(2, 102)))
        var changed = try verified(); try changed.noteKeyAuthentication(expected: key())
        XCTAssertThrowsError(try changed.consume(body(2, 135, payload)))
        var password = try verified(); XCTAssertThrowsError(try password.consume(body(2, 135, payload)))
        var old = try verified(mode: .catalog); XCTAssertThrowsError(try old.noteKeyAuthentication(expected: nil))
        var repeated = try verified(); try repeated.noteKeyAuthentication(expected: nil)
        _ = try repeated.consume(body(2, 135, payload)); XCTAssertThrowsError(try repeated.consume(body(3, 135, payload)))
    }
    func testNewModesRetainIndependentTransferCapabilitiesAndRejectOldMagic() throws {
        for mode in [SFTPWireMode.keyCatalog, .keyTransferCatalog, .keyUploadCatalog] {
            XCTAssertTrue(mode.allowsKeyAuthentication); XCTAssertTrue(mode.isCatalog)
            XCTAssertEqual(mode.allowsDownloads, mode != .keyCatalog)
            // Legacy modes no longer grant writes; uploads require the newer
            // guarded exclusive-publication protocol.
            XCTAssertFalse(mode.allowsUploads)
            var decoder = try verified(mode: mode)
            XCTAssertThrowsError(try decoder.consume(body(2, 102, mode: .catalog)))
        }
        XCTAssertFalse(SFTPWireMode.catalog.allowsKeyAuthentication)
        XCTAssertFalse(SFTPWireMode.transferCatalog.allowsKeyAuthentication)
    }
    func testKeySelectionAndPassphraseRemainRedactedAndConstructionReadsNoBody() throws {
        let selection = try SFTPSelectedPrivateKey(file: URL(fileURLWithPath: "/definitely-not-opened/generated-identity"))
        let phrase = try SFTPKeyPassphrase("generated-private-phrase")
        XCTAssertFalse(String(reflecting: selection).contains("generated-identity"))
        XCTAssertFalse(String(reflecting: phrase).contains("generated-private-phrase"))
        XCTAssertThrowsError(try SFTPKeyPassphrase(String(repeating: "a", count: 4097)))
        XCTAssertThrowsError(try SFTPKeyPassphrase("generated\0phrase"))
        XCTAssertThrowsError(try SFTPSelectedPrivateKey(file: URL(string: "sftp://generated.example/key")!))
        let certificate = try SFTPSelectedUserCertificate(file: URL(fileURLWithPath: "/definitely-not-opened/generated-cert.pub"))
        XCTAssertFalse(String(reflecting: certificate).contains("generated-cert.pub"))
        XCTAssertThrowsError(try SFTPSelectedUserCertificate(file: URL(string: "sftp://generated.example/cert.pub")!))
        XCTAssertThrowsError(try SFTPSelectedUserCertificate(file: URL(fileURLWithPath: "/generated-other/cert.pub"),
            accessRoot: URL(fileURLWithPath: "/generated", isDirectory: true)))
    }
    func testCertificateValidityOutcomesRequireDirectRecordedAttemptAndPrecedeAuthentication() throws {
        func terminal(_ outcome: UInt8) -> Data {
            var bytes = Data([outcome, 0, 1])
            SFTPWire.number(0, bytes: 8, into: &bytes); SFTPWire.number(0, bytes: 8, into: &bytes)
            bytes.append(SFTPWorkerTerminal.WriterEnd.notStarted.rawValue); return bytes
        }
        for outcome in [UInt8(16), 17] {
            var certificate = try verified()
            try certificate.noteCertificateAuthentication(expected: nil, interactive: false)
            guard case .closed(let result) = try certificate.consume(body(2, 107, terminal(outcome))) else {
                return XCTFail("Certificate validity result missing")
            }
            XCTAssertEqual(result.outcome, outcome)
            var plain = try verified(); try plain.noteKeyAuthentication(expected: nil)
            XCTAssertThrowsError(try plain.consume(body(2, 107, terminal(outcome))))
            var unsubmitted = try verified()
            XCTAssertThrowsError(try unsubmitted.consume(body(2, 107, terminal(outcome))))
        }
        var duplicate = try verified()
        try duplicate.noteCertificateAuthentication(expected: nil, interactive: false)
        XCTAssertThrowsError(try duplicate.noteCertificateAuthentication(expected: nil, interactive: false))
        var premature = try SFTPWorkerDecoder(session: session, canonicalHost: "generated.example", port: 22, mode: .keyCatalog)
        XCTAssertThrowsError(try premature.noteCertificateAuthentication(expected: nil, interactive: false))
        var old = try verified(mode: .catalog)
        XCTAssertThrowsError(try old.noteCertificateAuthentication(expected: nil, interactive: false))
        var noPrompts = try verified()
        XCTAssertThrowsError(try noPrompts.noteCertificateAuthentication(expected: nil, interactive: true))
        var complete = try verified()
        try complete.noteCertificateAuthentication(expected: nil, interactive: false)
        var identity = Data(); try SFTPWire.field(key().bytes, into: &identity)
        _ = try complete.consume(body(2, 135, identity)); _ = try complete.consume(body(3, 102))
        _ = try complete.consume(body(4, 109))
        XCTAssertThrowsError(try complete.consume(body(5, 107, terminal(16))))
        XCTAssertEqual(SFTPSessionFailure.terminal(16), .certificateExpired)
        XCTAssertEqual(SFTPSessionFailure.terminal(17), .certificateNotYetValid)
    }
    func testSelectedCertificateRereadsReplacementAndKeepsTheExistingBoundedFileRules() async throws {
        let root = try LocalStorageTestFixtures.directory().appendingPathComponent("certificate-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("generated-cert.pub")
        let selection = try SFTPSelectedUserCertificate(file: file, accessRoot: root)
        let context = SFTPVerifiedSessionContext(host: "generated.example", port: 22, requestedScopeID: 0,
            account: "generated", key: try key(), previous: nil, permitsRememberingHost: false)
        let first = Data("Generated certificate reader fixture one\n".utf8)
        let second = Data("Generated certificate reader fixture two\n".utf8)
        try first.write(to: file)
        let a = try await Task.detached { try selection.readAfterHostReview(context, keyIdentity: nil, check: {}) }.value
        XCTAssertEqual(a, first)
        try second.write(to: file, options: .atomic)
        let b = try await Task.detached { try selection.readAfterHostReview(context, keyIdentity: nil, check: {}) }.value
        XCTAssertEqual(b, second)
        try first.write(to: file, options: .atomic)
        let replacement = await Task.detached { () -> SSHSelectedFileFailure? in
            var checks = 0
            do {
                _ = try selection.readAfterHostReview(context, keyIdentity: nil, check: {
                    checks += 1
                    if checks == 3 { try second.write(to: file, options: .atomic) }
                })
                return nil
            } catch { return error as? SSHSelectedFileFailure }
        }.value
        XCTAssertTrue(replacement == .changed || replacement == .unsupported)
        try Data(repeating: 65, count: 8193).write(to: file)
        let capacity = await Task.detached { () -> SSHSelectedFileFailure? in
            do { _ = try selection.readAfterHostReview(context, keyIdentity: nil, check: {}); return nil }
            catch { return error as? SSHSelectedFileFailure }
        }.value
        XCTAssertEqual(capacity, .capacity)
        try FileManager().removeItem(at: file)
        let target = root.appendingPathComponent("unselected.txt"); try first.write(to: target)
        try FileManager().createSymbolicLink(at: file, withDestinationURL: target)
        let link = await Task.detached { () -> SSHSelectedFileFailure? in
            do { _ = try selection.readAfterHostReview(context, keyIdentity: nil, check: {}); return nil }
            catch { return error as? SSHSelectedFileFailure }
        }.value
        XCTAssertEqual(link, .unavailable)
    }
    func testFileOnlyCertificateSelectionCannotRememberRenewalAuthority() async throws {
        let file = URL(fileURLWithPath: "/generated-only/cert.pub")
        let certificate = try SFTPSelectedUserCertificate(file: file)
        var context = SFTPVerifiedSessionContext(host: "generated.example", port: 22, requestedScopeID: 0,
            account: "generated", key: try key(), previous: nil, permitsRememberingHost: true)
        context.authenticatedWithUserCertificate = true
        context.authenticatedIdentity = try key()
        context.authenticatedCertificateSelectionID = certificate.selectionID
        context.permitsSavedAuthentication = false
        let failure = await Task.detached { () -> SFTPCertificateAccessFailure? in
            do { _ = try certificate.referenceAfterAuthentication(context, check: {}); return nil }
            catch { return error as? SFTPCertificateAccessFailure }
        }.value
        XCTAssertEqual(failure, .renewalDirectoryRequired)
    }
}
