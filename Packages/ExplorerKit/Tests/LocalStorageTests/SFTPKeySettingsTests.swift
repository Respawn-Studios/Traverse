import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

final class SFTPKeySettingsTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = try LocalStorageTestFixtures.directory()
            .appendingPathComponent("key-state-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return root
    }
    private func key() throws -> SFTPHostKey {
        var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes)
        try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &bytes); return try .init(bytes)
    }
    private func draft(_ host: String = "generated.example", account: String = "generated") throws -> SFTPServerDraft {
        try .init(name: "Generated", address: .init("sftp://" + host + ":2222/fixture"), account: account)
    }
    func testPassiveLegacyReadDoesNotCreateOrUpgradeAndOptionalFieldRetainsCanonicalBytes() async throws {
        let root = try fixture(), location = root.appendingPathComponent("sftp"), store = SFTPSettingsStore(directory: location)
        let absent = try await store.inspect(); XCTAssertNil(absent); XCTAssertFalse(FileManager().fileExists(atPath: location.path))
        let first = try await store.openForExplicitWrite()
        let saved = try await store.apply(.saveServer(draft(), id: nil, credentialID: nil), revision: first.snapshot.revision)
        XCTAssertEqual(saved.snapshot.format, 1); XCTAssertNil(saved.snapshot.servers.first?.keyAuthentication)
        await store.close()
        let before = try Data(contentsOf: location.appendingPathComponent("servers.json"))
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("keyAuthentication"))
        let snapshot = try await store.inspect(); XCTAssertEqual(snapshot?.format, 1)
        XCTAssertEqual(try Data(contentsOf: location.appendingPathComponent("servers.json")), before)
        XCTAssertEqual(try SFTPSettingsSnapshot.decode(before).encoded(), before)
    }
    func testExplicitKeySaveUpgradesAndForgetRemovesReferenceWithoutPasswordAccess() async throws {
        let root = try fixture(), location = root.appendingPathComponent("sftp"), store = SFTPSettingsStore(directory: location)
        let request = try draft().request, host = try key(), identity = try key()
        let reference = try SFTPKeyAccessReference(bookmark: Data("generated-bookmark-only".utf8), request: request, host: host, identity: identity)
        let opened = try await store.openForExplicitWrite()
        let saved = try await store.apply(.saveServer(draft(), id: nil, credentialID: nil,
            keyAuthentication: .init(reference: reference, profileAlias: "studio")), revision: opened.snapshot.revision)
        XCTAssertEqual(saved.snapshot.format, 2); XCTAssertEqual(saved.snapshot.visibleServers.first?.keyAuthentication?.reference, reference)
        XCTAssertTrue(saved.snapshot.credentials.isEmpty)
        let id = try XCTUnwrap(saved.serverID)
        let hidden = try await store.apply(.beginForgetServer(id, removePassword: true), revision: saved.snapshot.revision)
        XCTAssertTrue(hidden.snapshot.visibleServers.isEmpty)
        let forgotten = try await store.apply(.finishForgetServer(id), revision: hidden.snapshot.revision)
        XCTAssertTrue(forgotten.snapshot.servers.isEmpty); XCTAssertEqual(forgotten.snapshot.format, 2)
        await store.close()
        let bytes = try Data(contentsOf: location.appendingPathComponent("servers.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(reference.bookmark.base64EncodedString()))
    }
    func testReferenceCannotCrossHostPortAccountOrAcceptedHostKey() throws {
        let request = try draft().request, host = try key(), identity = try key()
        let reference = try SFTPKeyAccessReference(bookmark: Data([1]), request: request, host: host, identity: identity)
        XCTAssertTrue(try reference.matches(request, host: host))
        XCTAssertFalse(try reference.matches(draft("other.example").request, host: host))
        XCTAssertFalse(try reference.matches(draft(account: "other").request, host: host))
        let differentPort = try SFTPConnectionRequest(address: .init("sftp://generated.example:2223/fixture"), account: "generated")
        XCTAssertFalse(try reference.matches(differentPort, host: host))
        XCTAssertFalse(try reference.matches(request, host: key()))
        XCTAssertFalse(String(reflecting: reference).contains("generated.example"))
    }
    func testCertificateReferenceBindsDirectoryNameHostAccountAndPublicIdentity() throws {
        let request = try draft().request, host = try key(), identity = try key()
        let bookmark = Data("generated-directory-bookmark-only".utf8)
        let reference = try SFTPCertificateAccessReference(directoryBookmark: bookmark,
            leafName: "generated-cert.pub", request: request, host: host, identity: identity)
        XCTAssertTrue(try reference.matches(request, host: host, identity: identity))
        XCTAssertFalse(try reference.matches(draft("other.example").request, host: host, identity: identity))
        XCTAssertFalse(try reference.matches(draft(account: "other").request, host: host, identity: identity))
        XCTAssertFalse(try reference.matches(request, host: key(), identity: identity))
        XCTAssertFalse(try reference.matches(request, host: host, identity: key()))
        XCTAssertThrowsError(try SFTPCertificateAccessReference(directoryBookmark: bookmark,
            leafName: "../outside", request: request, host: host, identity: identity))
        XCTAssertFalse(String(reflecting: reference).contains("generated-cert.pub"))
    }
    func testCertificateMethodRequiresPairedReferencesAndFormatEight() async throws {
        let root = try fixture(), location = root.appendingPathComponent("sftp")
        let draft = try draft(), host = try key(), identity = try key()
        let keyReference = try SFTPKeyAccessReference(bookmark: Data("generated-key-bookmark".utf8),
            request: draft.request, host: host, identity: identity)
        let certificateReference = try SFTPCertificateAccessReference(directoryBookmark: Data("generated-directory-bookmark".utf8),
            leafName: "generated-cert.pub", request: draft.request, host: host, identity: identity)
        XCTAssertThrowsError(try SFTPServerKeyAuthentication(reference: keyReference, requiresCertificate: true))
        XCTAssertThrowsError(try SFTPServerKeyAuthentication(certificate: certificateReference, requiresCertificate: true))
        let method = try SFTPServerKeyAuthentication(reference: keyReference, certificate: certificateReference,
            profileAlias: "studio", requiresCertificate: true)
        let store = SFTPSettingsStore(directory: location)
        let opened = try await store.openForExplicitWrite()
        let saved = try await store.apply(.saveServer(draft, id: nil, credentialID: nil,
            keyAuthentication: method), revision: opened.snapshot.revision)
        XCTAssertEqual(saved.snapshot.format, 8)
        XCTAssertEqual(saved.snapshot.visibleServers.first?.keyAuthentication, method)
        var old = saved.snapshot; old.format = 7
        XCTAssertThrowsError(try old.encoded())
        await store.close()
        let bytes = try Data(contentsOf: location.appendingPathComponent("servers.json"))
        XCTAssertEqual(try SFTPSettingsSnapshot.decode(bytes), saved.snapshot)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE KEY"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("CERTIFICATE BODY"))

        let state = SFTPRememberedState(settings: store,
            passwords: .refusingQualification(observed: {}))
        let id = try XCTUnwrap(saved.serverID)
        do { _ = try await state.keyForVerified(draft.request, key: host, serverID: id)
            XCTFail("Certificate method exposed a plain-key selection")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .missing) }
        let pair = try await state.certificatePairForVerified(draft.request, key: host, serverID: id)
        XCTAssertEqual(pair.0.expectedIdentity, identity)
        do { _ = try await state.certificatePairForVerified(self.draft(account: "other").request, key: host, serverID: id)
            XCTFail("Changed account reused a certificate pair")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .missing) }
    }
    func testCertificateRequiredMarkerSurvivesFailedAccessWithoutPlainKeyFallback() async throws {
        let root = try fixture(), location = root.appendingPathComponent("sftp")
        let store = SFTPSettingsStore(directory: location), draft = try draft()
        let method = try SFTPServerKeyAuthentication(profileAlias: "studio", requiresCertificate: true)
        let opened = try await store.openForExplicitWrite()
        let saved = try await store.apply(.saveServer(draft, id: nil, credentialID: nil,
            keyAuthentication: method), revision: opened.snapshot.revision)
        XCTAssertEqual(saved.snapshot.format, 8)
        XCTAssertTrue(saved.snapshot.visibleServers.first?.keyAuthentication?.requiresCertificate == true)
        XCTAssertNil(saved.snapshot.visibleServers.first?.keyAuthentication?.reference)
        await store.close()
        let bytes = try Data(contentsOf: location.appendingPathComponent("servers.json"))
        XCTAssertEqual(try SFTPSettingsSnapshot.decode(bytes), saved.snapshot)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("certificateRequired"))
    }
    func testCertificateMetadataSaveKeepsRequiredMarkerWithoutKeyOnlyAccess() async throws {
        let root = try fixture(), store = SFTPSettingsStore(directory: root.appendingPathComponent("sftp"))
        let state = SFTPRememberedState(settings: store, passwords: .refusingQualification(observed: {}))
        let draft = try draft(), directory = try SFTPDefaultDirectory(legacy: draft.address)
        let saved = try await state.saveMetadata(draft, expectedRevision: 0, directory: directory,
            signIn: .keyFileAndServerPrompts, requiresCertificate: true)
        let method = try XCTUnwrap(saved.snapshot.visibleServers.first?.keyAuthentication)
        XCTAssertEqual(saved.snapshot.format, 8)
        XCTAssertTrue(method.requiresCertificate)
        XCTAssertTrue(method.requiresServerPrompts)
        XCTAssertNil(method.reference); XCTAssertNil(method.certificate)
        let serverID = try XCTUnwrap(saved.serverID), host = try key()
        do { _ = try await state.keyForVerified(draft.request, key: host, serverID: serverID)
            XCTFail("Metadata-only certificate method exposed plain-key access")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .missing) }
        do { _ = try await state.certificatePairForVerified(draft.request, key: host, serverID: serverID)
            XCTFail("Metadata-only certificate method exposed a saved pair")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .missing) }
        do { _ = try await state.saveMetadata(draft, expectedRevision: saved.snapshot.revision,
            directory: directory, signIn: .password, requiresCertificate: true)
            XCTFail("Password metadata admitted certificate-required state")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .invalidRecord) }
        let reopened = try await state.inspect()
        XCTAssertEqual(reopened?.visibleServers.first?.keyAuthentication, method)
    }
    func testNewStateRefusesLegacyFormatFutureVersionsAndMismatchedKeyClaims() throws {
        let value = try draft(), reference = try SFTPKeyAccessReference(bookmark: Data([1]), request: value.request, host: key(), identity: key())
        var snapshot = SFTPSettingsSnapshot()
        snapshot.servers = [.init(id: UUID(), details: value, credentialID: nil, removalPending: false, keyAuthentication: try .init(reference: reference))]
        XCTAssertThrowsError(try snapshot.encoded())
        snapshot.format = 2; let bytes = try snapshot.encoded(); XCTAssertEqual(try SFTPSettingsSnapshot.decode(bytes), snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); object["format"] = 3
        XCTAssertThrowsError(try SFTPSettingsSnapshot.decode(JSONSerialization.data(withJSONObject: object)))
        snapshot.servers[0].details = try draft(account: "other"); XCTAssertThrowsError(try snapshot.encoded())
        XCTAssertThrowsError(try SFTPKeyAccessReference(bookmark: Data(repeating: 1, count: 16385), request: value.request, host: key(), identity: key()))
    }
    func testChangedHostRefusesSavedReferenceBeforeBookmarkResolutionOrFileScope() async throws {
        final class Calls: @unchecked Sendable { let lock = NSLock(); var value = 0; func start() -> Bool { lock.withLock { value += 1 }; return true } }
        let draft = try draft(), original = try key(), changed = try key(), identity = try key(), calls = Calls()
        let reference = try SFTPKeyAccessReference(bookmark: Data("deliberately-not-a-bookmark".utf8), request: draft.request, host: original, identity: identity)
        let selection = try SFTPSelectedPrivateKey(reference: reference)
        let context = SFTPVerifiedSessionContext(host: draft.address.host, port: draft.address.port, requestedScopeID: 0,
            account: draft.account, key: changed, previous: original, permitsRememberingHost: true)
        let failure = await Task.detached { () -> SFTPSessionFailure? in
            do { _ = try selection.readAfterHostReview(context, check: {}, hooks: .init(start: { _ in calls.start() }, stop: { _ in })); return nil }
            catch { return error as? SFTPSessionFailure }
        }.value
        XCTAssertEqual(failure, .keyChanged); XCTAssertEqual(calls.lock.withLock { calls.value }, 0)
    }
    func testInterruptedForgetKeepsReferenceHiddenUntilExplicitRecoveryThenDeletion() async throws {
        final class Fault: @unchecked Sendable { let lock = NSLock(); var armed = false; func check(_ stage: SFTPSettingsStore.File.Stage) throws {
            if stage == .beforeRename, lock.withLock({ armed }) { throw SFTPSettingsFailure.unavailable }
        } }
        let root = try fixture(), location = root.appendingPathComponent("sftp"), fault = Fault()
        let store = SFTPSettingsStore(directory: location, probe: { try fault.check($0) })
        let opened = try await store.openForExplicitWrite(), draft = try draft()
        let reference = try SFTPKeyAccessReference(bookmark: Data("generated-interrupted-reference".utf8), request: draft.request, host: key(), identity: key())
        let saved = try await store.apply(.saveServer(draft, id: nil, credentialID: nil, keyAuthentication: .init(reference: reference)), revision: opened.snapshot.revision)
        let id = try XCTUnwrap(saved.serverID)
        let hidden = try await store.apply(.beginForgetServer(id, removePassword: true), revision: saved.snapshot.revision)
        fault.lock.withLock { fault.armed = true }
        do { _ = try await store.apply(.finishForgetServer(id), revision: hidden.snapshot.revision); XCTFail("Injected failure ignored") }
        catch { XCTAssertEqual(error as? SFTPSettingsFailure, .unavailable) }
        await store.close()
        let probe = SFTPSettingsStore(directory: location)
        do { _ = try await probe.inspect(); XCTFail("Interrupted state silently repaired") }
        catch { XCTAssertEqual(error as? SFTPSettingsFailure, .recoveryRequired) }
        let resumed = try await probe.openForExplicitWrite(discardUncommittedStage: true)
        XCTAssertTrue(resumed.snapshot.visibleServers.isEmpty); XCTAssertEqual(resumed.snapshot.servers.first?.keyAuthentication?.reference, reference)
        let end = try await probe.apply(.finishForgetServer(id), revision: resumed.snapshot.revision); await probe.close()
        XCTAssertTrue(end.snapshot.servers.isEmpty)
    }
}
