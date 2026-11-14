import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private struct StateFixture {
    let root: URL
    var location: URL { root.appendingPathComponent("sftp") }
    init() throws {
        #if SSH_PROFILE_QUALIFICATION
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_SSH_PROFILE_STATE_ROOT"] else { throw XCTSkip("Use the charged SSH profile packet") }
        let base = URL(fileURLWithPath: raw), owner = base.deletingLastPathComponent().deletingLastPathComponent()
        guard base.lastPathComponent == "StateFixtures", base.deletingLastPathComponent().lastPathComponent == "source",
              owner.deletingLastPathComponent().lastPathComponent == "traverse-development",
              UUID(uuidString: owner.lastPathComponent)?.uuidString == owner.lastPathComponent,
              base.resolvingSymlinksInPath() == base,
              #filePath.hasPrefix(owner.appendingPathComponent("source/package/").path),
              let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: owner.appendingPathComponent("reservation.json"))) as? [String: Any],
              reservation["packet"] as? String == "traverse-development-v1",
              reservation["action"] as? String == "ssh-native-module-contracts" else { throw SFTPSettingsFailure.unsafe }
        #else
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_B11_PRIVATE_STATE_ROOT"] else { throw XCTSkip("Use the charged SFTP private-state packet") }
        let base = URL(fileURLWithPath: raw)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard base.path.hasPrefix(repo.appendingPathComponent(".build/b11-native-qualification/").path), base.lastPathComponent == "source",
              base.resolvingSymlinksInPath() == base,
              let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: base.deletingLastPathComponent().appendingPathComponent("reservation.json"))) as? [String: Any],
              reservation["packet"] as? String == "b11-native-v1" else { throw SFTPSettingsFailure.unsafe }
        #endif
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func image() throws -> [String: Data] {
        guard FileManager().fileExists(atPath: location.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: location.path).map {
            ($0, try Data(contentsOf: location.appendingPathComponent($0)))
        })
    }
}
private final class StateBackend: SFTPPasswordBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    private var reads = 0, main = false, holdSave = false, denySave = false, denyDelete = false
    let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
    var facts: (count: Int, reads: Int, main: Bool) { lock.withLock { (values.count, reads, main) } }
    func holdNextSave() { lock.withLock { holdSave = true } }
    func denyNextSave() { lock.withLock { denySave = true } }
    func denyNextDelete() { lock.withLock { denyDelete = true } }
    func read(service: String, reference: SFTPCredentialReference) throws -> Data {
        try lock.withLock { reads += 1; main = main || Thread.isMainThread; guard let bytes = values[reference.id] else { throw SFTPPasswordFailure.missing }; return bytes }
    }
    func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws {
        let (hold, denied) = lock.withLock { main = main || Thread.isMainThread; let result = (holdSave, denySave); holdSave = false; denySave = false; return result }
        if hold { entered.continuation.yield(()); guard release.wait(timeout: .now() + 5) == .success else { throw SFTPPasswordFailure.unavailable } }
        if denied { throw SFTPPasswordFailure.denied }; lock.withLock { values[reference.id] = bytes }
    }
    func remove(service: String, reference: SFTPCredentialReference) throws {
        try lock.withLock { main = main || Thread.isMainThread; if denyDelete { denyDelete = false; throw SFTPPasswordFailure.denied }; values.removeValue(forKey: reference.id) }
    }
}

final class SFTPPrivateStateTests: XCTestCase, @unchecked Sendable {
    func testExactPasswordRemovalAcrossHostKeysPreservesDifferentAccountAndRetriesDenial() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend)
        let selected = try draft(account: "caf\u{e9}"), other = try draft(account: "cafe\u{301}")
        for (item, keyByte) in [(selected, UInt8(1)), (selected, UInt8(2)), (other, UInt8(1))] {
            let saved = await state.rememberAuthenticated(item, key: try key(keyByte), password: try .init("generated-password"), server: false, savePassword: true, editing: nil)
            XCTAssertEqual(saved.password, .complete)
        }
        XCTAssertEqual(backend.facts.count, 3); backend.denyNextDelete()
        let request = try selected.request
        let denied = await state.forgetPasswords(for: request)
        XCTAssertEqual(denied.password, .incomplete); XCTAssertEqual(denied.passwordFailure, .denied)
        let pending = try await store.inspect(); XCTAssertEqual(pending?.credentials.filter { $0.state == .deleting }.count, 1)
        let removed = await state.forgetPasswords(for: request)
        XCTAssertEqual(removed.password, .complete); XCTAssertEqual(backend.facts.count, 1); XCTAssertEqual(backend.facts.reads, 0)
        let after = try await store.inspect(); XCTAssertEqual(after?.credentials.count, 1)
        let cleanup = await state.forget(.all); XCTAssertEqual(cleanup.password, .complete); XCTAssertEqual(backend.facts.count, 0)
    }
    private func key(_ byte: UInt8 = 1) throws -> SFTPHostKey {
        var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes); try SFTPWire.field(Data(repeating: byte, count: 32), into: &bytes)
        return try SFTPHostKey(bytes)
    }
    private func draft(_ address: String = "sftp://studio.invalid/Folder", account: String = "generated") throws -> SFTPServerDraft {
        try .init(name: "Generated Studio", address: .init(address), account: account)
    }
    private func system(_ fixture: StateFixture, _ backend: StateBackend) -> (SFTPSettingsStore, SFTPRememberedState) {
        let store = SFTPSettingsStore(directory: fixture.location)
        return (store, SFTPRememberedState(settings: store, passwords: .init(service: "generated-not-keychain", backend: backend)))
    }
    private func settingsFailure(_ expected: SFTPSettingsFailure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected settings refusal") } catch { XCTAssertEqual(error as? SFTPSettingsFailure, expected) }
    }
    private func passwordFailure(_ expected: SFTPPasswordFailure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected password refusal") } catch { XCTAssertEqual(error as? SFTPPasswordFailure, expected) }
    }
    func testCredentialBindsProtocolHostPortScopeAccountAndVerifiedKeyButNotPath() throws {
        let request = try draft().request, value = try key(), binding = try SFTPCredentialBinding(request: request, key: value)
        XCTAssertEqual(binding.digest, try SFTPCredentialBinding(request: draft("studio.invalid/Elsewhere").request, key: value).digest)
        for changed in [try draft("alias.invalid").request, try draft("studio.invalid:2222").request, try draft(account: "different").request] {
            XCTAssertNotEqual(binding.digest, try SFTPCredentialBinding(request: changed, key: value).digest)
        }
        XCTAssertNotEqual(binding.digest, try SFTPCredentialBinding(request: request, key: key(2)).digest)
        let scoped = try SFTPCredentialBinding(request: draft("[fe80::1%252]").request, key: value)
        XCTAssertNotEqual(scoped.digest, try SFTPCredentialBinding(request: draft("[fe80::1%253]").request, key: value).digest)
        XCTAssertNotEqual(binding.digest, try SMBCredentialBinding(host: request.address.host, port: 22, share: "Folder", account: request.account, domain: "").digest)
        XCTAssertEqual(String(reflecting: request), "<SFTP connection request>")
        XCTAssertThrowsError(try SFTPServerDraft(name: "bad\nname", address: request.address, account: request.account))
    }
    func testPassiveStateAndIndependentChoicesNeverReadPasswordsOrCreateImplicitTrust() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend)
        let empty = try await state.inspect(); XCTAssertNil(empty); XCTAssertFalse(FileManager().fileExists(atPath: fixture.location.path))
        let value = try draft(), password = try SFTPPassword("generated-private-password")
        let none = await state.rememberAuthenticated(value, key: try key(), password: password, server: false, savePassword: false, editing: nil)
        XCTAssertEqual(none.server, .notRequested); XCTAssertFalse(FileManager().fileExists(atPath: fixture.location.path))
        let server = await state.rememberAuthenticated(value, key: try key(), password: password, server: true, savePassword: false, editing: nil)
        XCTAssertEqual(server.server, .complete); XCTAssertEqual(backend.facts.count, 0)
        let secret = await state.rememberAuthenticated(value, key: try key(), password: password, server: false, savePassword: true, editing: nil)
        XCTAssertEqual(secret.password, .complete); XCTAssertEqual(secret.server, .notRequested)
        let saved = try await store.inspect(); XCTAssertEqual(saved?.servers.count, 1); XCTAssertNil(saved?.servers.first?.credentialID); XCTAssertEqual(saved?.hosts.count, 0)
        XCTAssertEqual(backend.facts.reads, 0); XCTAssertFalse(backend.facts.main)
        let text = String(decoding: try XCTUnwrap(fixture.image()["servers.json"]), as: UTF8.self)
        XCTAssertFalse(text.contains("generated-private-password"))
        let forgotten = await state.forget(.all); XCTAssertEqual(forgotten.password, .complete); XCTAssertEqual(backend.facts.count, 0)
    }
    func testHostCompareAndSwapAliasesAndForgetRemainIndependentOfSavedServer() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend), value = try draft()
        let identity = SFTPHostIdentity(address: value.address)
        let first = await state.rememberVerified(identity: identity, key: try key(), previous: nil); XCTAssertEqual(first.host, .complete)
        let stale = await state.rememberVerified(identity: identity, key: try key(2), previous: nil); XCTAssertEqual(stale.settingsFailure, .staleRevision)
        let replaced = await state.rememberVerified(identity: identity, key: try key(2), previous: try key()); XCTAssertEqual(replaced.host, .complete)
        let alias = SFTPHostIdentity(address: try SFTPConnectionAddress("alias.invalid"))
        let missing = try await state.previousKey(for: alias); XCTAssertNil(missing)
        let named = await state.rememberAuthenticated(value, key: try key(2), password: try .init("generated-password"), server: true, savePassword: false, editing: nil)
        XCTAssertEqual(named.server, .complete)
        let forgotten = await state.forget(.host(identity)); XCTAssertEqual(forgotten.host, .complete)
        let after = try await store.inspect(); XCTAssertTrue(after?.hosts.isEmpty == true); XCTAssertEqual(after?.servers.count, 1)
    }
    func testChangedKeyAndEditedAccountRefuseBeforeAnyPasswordBackendRead() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (_, state) = system(fixture, backend), value = try draft(), original = try key()
        let saved = await state.rememberAuthenticated(value, key: original, password: try .init("generated-password"), server: true, savePassword: true, editing: nil)
        let id = try XCTUnwrap(saved.serverID)
        await passwordFailure(.bindingMismatch) { _ = try await state.passwordForVerified(value.request, key: self.key(2), serverID: id) }
        await passwordFailure(.bindingMismatch) { _ = try await state.passwordForVerified(self.draft(account: "other").request, key: original, serverID: id) }
        XCTAssertEqual(backend.facts.reads, 0)
        _ = try await state.passwordForVerified(value.request, key: original, serverID: id); XCTAssertEqual(backend.facts.reads, 1)
        let all = await state.forget(.all); XCTAssertEqual(all.password, .complete)
    }
    func testPasswordOnlyRecordDoesNotStoreHostPathAccountOrPublicKey() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (_, state) = system(fixture, backend), value = try draft()
        let result = await state.rememberAuthenticated(value, key: try key(), password: try .init("generated-password"), server: false, savePassword: true, editing: nil)
        XCTAssertEqual(result.password, .complete)
        let text = String(decoding: try XCTUnwrap(fixture.image()["servers.json"]), as: UTF8.self)
        for part in ["studio.invalid", "Folder", "generated", "Generated Studio", try key().fingerprint] { XCTAssertFalse(text.contains(part)) }
        let removed = await state.forget(.all); XCTAssertEqual(removed.password, .complete)
    }
    func testDeniedSaveRetainsPreparingClaimAndExactCleanupCanBeRetried() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend)
        backend.denyNextSave()
        let result = await state.rememberAuthenticated(try draft(), key: try key(), password: try .init("generated-password"), server: true, savePassword: true, editing: nil)
        XCTAssertEqual(result.server, .complete); XCTAssertEqual(result.password, .incomplete); XCTAssertEqual(result.passwordFailure, .denied)
        let snapshot = try await store.inspect(), claim = try XCTUnwrap(snapshot?.credentials.first)
        XCTAssertEqual(claim.state, .preparing); XCTAssertNil(snapshot?.servers.first?.credentialID)
        let removed = await state.forget(.password(claim.reference.id)); XCTAssertEqual(removed.password, .complete)
        let after = try await store.inspect(); XCTAssertTrue(after?.credentials.isEmpty == true)
    }
    func testDeniedServerForgetStaysHiddenAcrossReopenAndLeavesUnrelatedPassword() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend), value = try draft()
        let saved = await state.rememberAuthenticated(value, key: try key(), password: try .init("generated-password"), server: true, savePassword: true, editing: nil)
        _ = await state.rememberAuthenticated(try draft(account: "other"), key: try key(), password: try .init("other-generated-password"), server: false, savePassword: true, editing: nil)
        let id = try XCTUnwrap(saved.serverID); backend.denyNextDelete()
        let denied = await state.forget(.server(id, removePassword: true)); XCTAssertEqual(denied.passwordFailure, .denied); XCTAssertEqual(denied.server, .incomplete)
        let cold = try await SFTPSettingsStore(directory: fixture.location).inspect()
        XCTAssertTrue(cold?.visibleServers.isEmpty == true); XCTAssertEqual(cold?.credentials.filter { $0.state == .deleting }.count, 1)
        XCTAssertEqual(backend.facts.count, 2)
        let retry = await state.forget(.server(id, removePassword: true)); XCTAssertEqual(retry.server, .complete); XCTAssertEqual(retry.password, .complete)
        let after = try await store.inspect(); XCTAssertTrue(after?.servers.isEmpty == true); XCTAssertEqual(after?.credentials.count, 1); XCTAssertEqual(backend.facts.count, 1)
        _ = await state.forget(.all)
    }
    func testExactServerForgetRejectsChangedRecordAndCanKeepItsPasswordWithoutVaultAccess() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend)
        let saved = await state.rememberAuthenticated(try draft(), key: try key(), password: try .init("generated-password"),
            server: true, savePassword: true, editing: nil)
        XCTAssertEqual(saved.server, .complete); XCTAssertEqual(saved.password, .complete)
        let shownSnapshot = try await state.inspect(), shown = try XCTUnwrap(shownSnapshot?.visibleServers.first)
        var forged = shown
        forged.details = try .init(name: "Forged generated label", address: shown.details.address, account: shown.details.account)
        let before = try fixture.image()
        _ = try await store.openForExplicitWrite()
        do {
            _ = try await store.apply(.beginForgetExpectedServer(forged, removePassword: true), revision: shownSnapshot!.revision)
            XCTFail("Expected exact-record refusal inside the settings writer")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .staleRevision) }
        XCTAssertEqual(try fixture.image(), before)
        let updated = try SFTPServerDraft(name: "Updated generated label", address: shown.details.address, account: shown.details.account)
        _ = try await store.apply(.saveServer(updated, id: shown.id, credentialID: shown.credentialID), revision: shownSnapshot!.revision)
        await store.close()
        let changedBytes = try fixture.image()
        let stale = await state.forget(server: shown, removePassword: true)
        XCTAssertEqual(stale.settingsFailure, .staleRevision)
        XCTAssertEqual(stale.server, .incomplete); XCTAssertEqual(try fixture.image(), changedBytes)
        XCTAssertEqual(backend.facts.count, 1); XCTAssertEqual(backend.facts.reads, 0)
        let freshSnapshot = try await state.inspect(), fresh = try XCTUnwrap(freshSnapshot?.visibleServers.first)
        let forgotten = await state.forget(server: fresh, removePassword: false)
        XCTAssertEqual(forgotten.server, .complete); XCTAssertEqual(forgotten.password, .notRequested)
        XCTAssertEqual(backend.facts.count, 1); XCTAssertEqual(backend.facts.reads, 0)
        let remaining = try await state.inspect()
        XCTAssertTrue(remaining?.servers.isEmpty == true)
        XCTAssertEqual(remaining?.credentials.first?.state, .ready)
        _ = await state.forget(.password(try XCTUnwrap(remaining?.credentials.first?.reference.id)))
        XCTAssertEqual(backend.facts.count, 0)
    }
    func testExactRouteForgetChecksWholeRecordBeforeHidingAndUsesNoVaultWhenKeepingPasswords() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend)
        let route = try SFTPRouteDescription(destination: draft("sftp://destination.invalid/folder"),
            jump: draft("sftp://jump.invalid"))
        let endpoint = SFTPSavedRouteEndpoint(key: try key(), signIn: .password)
        let vault = SFTPPasswordVault(service: "generated-not-keychain", backend: backend)
        var snapshot = try await store.openForExplicitWrite().snapshot
        var ids: [SFTPRouteRole: UUID] = [:]
        let keyDigest = Data(SHA256.hash(data: endpoint.key.bytes))
        for role in [SFTPRouteRole.jump, .destination] {
            let binding = try route.passwordBinding(role: role, verifiedJumpKeyDigest: keyDigest, peerKeyDigest: keyDigest)
            let intent = try await store.apply(.beginPassword(binding), revision: snapshot.revision)
            let reference = try XCTUnwrap(intent.credential)
            _ = try await vault.save(try .init("generated-password"), reference: reference, binding: binding)
            snapshot = try await store.apply(.confirmPassword(reference.id), revision: intent.snapshot.revision).snapshot
            ids[role] = reference.id
        }
        await vault.drain()
        let seeded = try await store.apply(.saveRoute(route,
            jump: .init(key: endpoint.key, signIn: .password, credentialID: ids[.jump]),
            destination: .init(key: endpoint.key, signIn: .password, credentialID: ids[.destination]), id: nil),
            revision: snapshot.revision)
        await store.close()
        let shown = try XCTUnwrap(seeded.snapshot.visibleRoutes.first)
        let forgedDetails = try SFTPRouteDescription(destination: .init(name: "Forged destination",
            address: shown.details.destination.address, account: shown.details.destination.account), jump: shown.details.jump)
        let forged = SFTPSavedRoute(id: shown.id, details: forgedDetails, jump: shown.jump,
            destination: shown.destination, removalPending: false)
        let before = try fixture.image()
        _ = try await store.openForExplicitWrite()
        do {
            _ = try await store.apply(.beginForgetExpectedRoute(forged, removePasswords: false), revision: seeded.snapshot.revision)
            XCTFail("Expected exact-route refusal inside the settings writer")
        } catch { XCTAssertEqual(error as? SFTPSettingsFailure, .staleRevision) }
        XCTAssertEqual(try fixture.image(), before)
        let changed = try SFTPRouteDescription(destination: .init(name: "Updated destination", address: shown.details.destination.address,
            account: shown.details.destination.account), jump: shown.details.jump)
        _ = try await store.apply(.saveRoute(changed, jump: shown.jump, destination: shown.destination, id: shown.id),
            revision: seeded.snapshot.revision)
        await store.close()
        let changedBytes = try fixture.image()
        let stale = await state.forget(route: shown, removePasswords: false)
        XCTAssertEqual(stale.settingsFailure, .staleRevision)
        XCTAssertEqual(stale.server, .incomplete); XCTAssertEqual(try fixture.image(), changedBytes)
        let freshSnapshot = try await state.inspect(), fresh = try XCTUnwrap(freshSnapshot?.visibleRoutes.first)
        let forgotten = await state.forget(route: fresh, removePasswords: false)
        XCTAssertEqual(forgotten.server, .complete); XCTAssertEqual(forgotten.password, .notRequested)
        let final = try await state.inspect()
        XCTAssertTrue(final?.visibleRoutes.isEmpty == true)
        XCTAssertEqual(final?.credentials.count, 2)
        XCTAssertTrue(final?.credentials.allSatisfy { $0.state == .ready } == true)
        XCTAssertEqual(backend.facts.reads, 0); XCTAssertEqual(backend.facts.count, 2)
    }
    func testInterruptedForgetAllBlocksReuseAndNewSavesUntilExactCleanupFinishes() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend), value = try draft()
        _ = await state.rememberVerified(identity: .init(address: value.address), key: try key(), previous: nil)
        _ = await state.rememberAuthenticated(value, key: try key(), password: try .init("generated-password"), server: true, savePassword: true, editing: nil)
        backend.denyNextDelete(); let failed = await state.forget(.all)
        XCTAssertEqual(failed.passwordFailure, .denied); XCTAssertEqual(failed.server, .incomplete)
        let cold = try await store.inspect(); XCTAssertTrue(cold?.forgetAllPending == true); XCTAssertTrue(cold?.visibleHosts.isEmpty == true); XCTAssertTrue(cold?.visibleServers.isEmpty == true)
        await passwordFailure(.missing) { _ = try await state.passwordForVerified(value.request, key: self.key(), serverID: nil) }
        let blocked = await state.rememberVerified(identity: .init(address: value.address), key: try key(), previous: nil); XCTAssertEqual(blocked.settingsFailure, .recoveryRequired)
        let retry = await state.forget(.all); XCTAssertEqual(retry.server, .complete); XCTAssertEqual(retry.password, .complete); XCTAssertEqual(backend.facts.count, 0)
        let after = try await store.inspect(); XCTAssertFalse(after?.forgetAllPending ?? true); XCTAssertTrue(after?.credentials.isEmpty == true)
    }
    func testLateCancelledSaveAndDrainRetainActualCommitAndPreventInterleavingForget() async throws {
        let fixture = try StateFixture(), backend = StateBackend(), (store, state) = system(fixture, backend), value = try draft(), hostKey = try key()
        backend.holdNextSave()
        let saving = Task { await state.rememberAuthenticated(value, key: hostKey, password: try SFTPPassword("generated-password"), server: false, savePassword: true, editing: nil) }
        var entered = backend.entered.stream.makeAsyncIterator(); _ = await entered.next(); saving.cancel()
        let blocked = await state.forget(.all); XCTAssertEqual(blocked.settingsFailure, .busy)
        let draining = Task { await state.drain() }
        await Task.yield(); backend.release.signal()
        let result = try await saving.value; await draining.value
        XCTAssertEqual(result.password, .complete); XCTAssertTrue(result.completedAfterCancellation)
        let saved = try await store.inspect(); XCTAssertEqual(saved?.credentials.first?.state, .ready); XCTAssertFalse(backend.facts.main)
        let removed = await state.forget(.all); XCTAssertEqual(removed.password, .complete)
    }
    func testStagingAndRenameFaultsPreserveExplicitRecoveryAndColdTruth() async throws {
        for stage in [SFTPSettingsStore.File.Stage.stagingSynchronized, .renamed] {
            let fixture = try StateFixture(), seed = SFTPSettingsStore(directory: fixture.location)
            _ = try await seed.openForExplicitWrite(); _ = try await seed.apply(.saveServer(try draft(), id: nil, credentialID: nil), revision: 0); await seed.close()
            let store = SFTPSettingsStore(directory: fixture.location, probe: { if $0 == stage { throw SFTPSettingsFailure.unavailable } })
            _ = try await store.openForExplicitWrite()
            await settingsFailure(stage == .renamed ? .durabilityUncertain : .unavailable) { _ = try await store.apply(.beginForgetAll, revision: 1) }
            await store.close(); let before = try fixture.image()
            if stage == .renamed {
                let state = try await seed.inspect(); XCTAssertTrue(state?.forgetAllPending == true); XCTAssertTrue(state?.visibleServers.isEmpty == true)
            } else {
                await settingsFailure(.recoveryRequired) { _ = try await seed.inspect() }; XCTAssertEqual(try fixture.image(), before)
                let copy = fixture.root.appendingPathComponent("recovery-copy"); try FileManager().copyItem(at: fixture.location, to: copy)
                let recovering = SFTPSettingsStore(directory: copy); let restored = try await recovering.openForExplicitWrite(discardUncommittedStage: true)
                XCTAssertEqual(restored.snapshot.visibleServers.count, 1); await recovering.close()
            }
            XCTAssertEqual(try fixture.image(), before)
        }
    }
    func testCanonicalFormatRejectsUnknownFieldsAndSMBFilesWithoutChangingAnything() async throws {
        let fixture = try StateFixture(), store = SFTPSettingsStore(directory: fixture.location)
        _ = try await store.openForExplicitWrite(); _ = try await store.apply(.saveServer(try draft(), id: nil, credentialID: nil), revision: 0); await store.close()
        let original = try XCTUnwrap(fixture.image()["servers.json"]), file = fixture.location.appendingPathComponent("servers.json")
        for kind in ["future", "unknown", "smb"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if kind == "future" { object["format"] = 99 } else if kind == "unknown" { object["unknown"] = true } else { object.removeValue(forKey: "protocolIdentity") }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
            let before = try fixture.image()
            await settingsFailure(kind == "unknown" ? .invalidRecord : .incompatibleVersion) { _ = try await store.inspect() }
            XCTAssertEqual(try fixture.image(), before)
        }
    }
    func testCompetingOwnerAndReplacedCatalogRefuseWithoutOverwriting() async throws {
        let fixture = try StateFixture(), store = SFTPSettingsStore(directory: fixture.location), second = SFTPSettingsStore(directory: fixture.location)
        _ = try await store.openForExplicitWrite(); _ = try await store.apply(.saveServer(try draft(), id: nil, credentialID: nil), revision: 0)
        await settingsFailure(.busy) { _ = try await second.inspect() }
        let file = fixture.location.appendingPathComponent("servers.json"), original = fixture.root.appendingPathComponent("retained.json")
        try FileManager().moveItem(at: file, to: original); try Data(contentsOf: original).write(to: file, options: .withoutOverwriting); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let before = try fixture.image(); await settingsFailure(.unsafe) { _ = try await store.apply(.beginForgetAll, revision: 1) }
        XCTAssertEqual(try fixture.image(), before); await store.close()
    }
}
