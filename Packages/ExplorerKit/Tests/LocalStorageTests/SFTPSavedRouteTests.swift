import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private struct RouteStateFixture {
    let root: URL
    var location: URL { root.appendingPathComponent("sftp") }
    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_SSH_PROFILE_STATE_ROOT"] else { throw XCTSkip("Use the charged SSH route packet") }
        let base = URL(fileURLWithPath: raw), owner = base.deletingLastPathComponent().deletingLastPathComponent()
        guard base.lastPathComponent == "StateFixtures", base.deletingLastPathComponent().lastPathComponent == "source",
              owner.deletingLastPathComponent().lastPathComponent == "traverse-development",
              UUID(uuidString: owner.lastPathComponent)?.uuidString == owner.lastPathComponent,
              base.resolvingSymlinksInPath() == base, #filePath.hasPrefix(owner.appendingPathComponent("source/package/").path),
              let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: owner.appendingPathComponent("reservation.json"))) as? [String: Any],
              reservation["packet"] as? String == "traverse-development-v1",
              reservation["action"] as? String == "ssh-native-module-contracts" else { throw SFTPSettingsFailure.unsafe }
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
private final class RouteMemoryBackend: SFTPPasswordBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:], removed: [UUID] = [], denyDelete = false, denySave = false, holdSave = false
    private var reads = 0, saves = 0, main = false
    private var removeAttempts = 0, deniedRemoveAttempt: Int?
    let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
    var facts: (count: Int, removed: [UUID], reads: Int, saves: Int, main: Bool) { lock.withLock { (values.count, removed, reads, saves, main) } }
    func denyNextDelete() { lock.withLock { denyDelete = true } }
    func denySecondDelete() { lock.withLock { deniedRemoveAttempt = removeAttempts + 2 } }
    func denyNextSave() { lock.withLock { denySave = true } }
    func holdNextSave() { lock.withLock { holdSave = true } }
    func read(service: String, reference: SFTPCredentialReference) throws -> Data {
        try lock.withLock { reads += 1; main = main || Thread.isMainThread; guard let bytes = values[reference.id] else { throw SFTPPasswordFailure.missing }; return bytes }
    }
    func save(service: String, reference: SFTPCredentialReference, bytes: Data) throws {
        let flags = lock.withLock { main = main || Thread.isMainThread; saves += 1; let flags = (denySave, holdSave); denySave = false; holdSave = false; return flags }
        if flags.1 { entered.continuation.yield(()); guard release.wait(timeout: .now() + 5) == .success else { throw SFTPPasswordFailure.unavailable } }
        if flags.0 { throw SFTPPasswordFailure.denied }; lock.withLock { values[reference.id] = bytes }
    }
    func remove(service: String, reference: SFTPCredentialReference) throws {
        try lock.withLock {
            removeAttempts += 1
            if denyDelete || deniedRemoveAttempt == removeAttempts { denyDelete = false; deniedRemoveAttempt = nil; throw SFTPPasswordFailure.denied }
            removed.append(reference.id); values.removeValue(forKey: reference.id)
        }
    }
}

final class SFTPSavedRouteTests: XCTestCase, @unchecked Sendable {
    private func key() throws -> SFTPHostKey {
        var bytes = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &bytes)
        try SFTPWire.field(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, into: &bytes); return try .init(bytes)
    }
    private func details() throws -> SFTPRouteDescription {
        try .init(destination: .init(name: "Generated destination", address: .init("sftp://private.internal.test:2225/folder"), account: "target"),
            jump: .init(name: "Generated jump", address: .init("sftp://jump.example.test:2224"), account: "gateway"))
    }
    private func save(_ store: SFTPSettingsStore, backend: RouteMemoryBackend? = nil) async throws -> SFTPSettingsMutation {
        let route = try details(), outer = try key(), inner = try key()
        var snapshot = try await store.openForExplicitWrite().snapshot
        var ids: [SFTPRouteRole: UUID] = [:]
        if let backend {
            let vault = SFTPPasswordVault(service: "Generated.Routes.MemoryOnly", backend: backend)
            for (role, peer) in [(SFTPRouteRole.jump, outer), (.destination, inner)] {
                let binding = try route.passwordBinding(role: role, verifiedJumpKeyDigest: Data(SHA256.hash(data: outer.bytes)), peerKeyDigest: Data(SHA256.hash(data: peer.bytes)))
                let preparing = try await store.apply(.beginPassword(binding), revision: snapshot.revision)
                let reference = try XCTUnwrap(preparing.credential)
                _ = try await vault.save(.init("generated-only-password"), reference: reference, binding: binding)
                snapshot = try await store.apply(.confirmPassword(reference.id), revision: preparing.snapshot.revision).snapshot
                ids[role] = reference.id
            }
            await vault.drain()
        }
        return try await store.apply(.saveRoute(route,
            jump: .init(key: outer, signIn: .password, credentialID: ids[.jump]),
            destination: .init(key: inner, signIn: .password, credentialID: ids[.destination]), id: nil), revision: snapshot.revision)
    }
    private func expect(_ failure: SFTPSettingsFailure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected a refused state change") } catch { XCTAssertEqual(error as? SFTPSettingsFailure, failure) }
    }
    private func peers(_ route: SFTPRouteDescription) throws -> (jump: SFTPSavedRouteEndpoint, destination: SFTPSavedRouteEndpoint) {
        (.init(key: try key(), signIn: .password), .init(key: try key(), signIn: .password))
    }
    private func proof(_ route: SFTPRouteDescription, role: SFTPRouteRole, key: SFTPHostKey, jumpKey: SFTPHostKey) throws -> SFTPVerifiedRoutePeer {
        let request = try route.request(for: role)
        return .init(route: route, role: role, context: .init(host: request.address.host, port: request.address.port,
            requestedScopeID: request.address.scopeID, account: request.account, key: key, previous: nil, permitsRememberingHost: false,
            permitsSavedAuthentication: false, routeKeyBinding: try route.bindingTag(role: role, verifiedJumpKeyDigest: Data(SHA256.hash(data: jumpKey.bytes)))), jumpKey: jumpKey)
    }
    func testBothVerifiedRolesReconnectButChangedJumpCannotReadEitherPassword() async throws {
        let fixture = try RouteStateFixture(), store = SFTPSettingsStore(directory: fixture.location), backend = RouteMemoryBackend()
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let route = try details(), peers = try peers(route), password = try SFTPPassword("generated-only-password")
        let saved = await state.rememberAuthenticatedRoute(route, jump: peers.jump, destination: peers.destination,
            passwords: [.jump: password, .destination: password], editing: nil)
        let id = try XCTUnwrap(saved.routeID); XCTAssertEqual(saved.server, .complete); XCTAssertEqual(saved.password, .complete)
        let changed = try key()
        for (role, peerKey) in [(SFTPRouteRole.jump, changed), (.destination, peers.destination.key)] {
            do { _ = try await state.passwordForVerifiedRoute(proof(route, role: role, key: peerKey, jumpKey: changed), id: id); XCTFail("Changed route read a password") }
            catch SFTPSessionFailure.keyChanged { }
        }
        XCTAssertEqual(backend.facts.reads, 0)
        for (role, peerKey) in [(SFTPRouteRole.jump, peers.jump.key), (.destination, peers.destination.key)] {
            let value = try await state.passwordForVerifiedRoute(proof(route, role: role, key: peerKey, jumpKey: peers.jump.key), id: id)
            XCTAssertEqual(value.bytes, password.bytes)
        }
        XCTAssertEqual(backend.facts.reads, 2); XCTAssertFalse(backend.facts.main); _ = await state.forget(.all)
    }
    func testDeniedOptionalPasswordSavePreservesUsableRouteAndExactCleanupClaim() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let route = try details(), peers = try peers(route), password = try SFTPPassword("generated-only-password")
        backend.denyNextSave()
        let saved = await state.rememberAuthenticatedRoute(route, jump: peers.jump, destination: peers.destination,
            passwords: [.jump: password, .destination: password], editing: nil)
        XCTAssertEqual(saved.server, .complete); XCTAssertEqual(saved.password, .incomplete); XCTAssertEqual(saved.passwordFailure, .denied)
        let snapshot = try await state.inspect(), record = try XCTUnwrap(snapshot?.visibleRoutes.first)
        XCTAssertNil(record.jump.credentialID); XCTAssertNotNil(record.destination.credentialID)
        XCTAssertEqual(snapshot?.credentials.filter { $0.state == .preparing }.count, 1); XCTAssertEqual(backend.facts.count, 1)
        let forgotten = await state.forget(.all); XCTAssertEqual(forgotten.password, .complete)
        XCTAssertEqual(Set(backend.facts.removed), Set(snapshot?.credentials.map { $0.reference.id } ?? []))
    }
    func testCancellationDrainsAdmittedSaveWithoutStartingSecondRoleOrPublishingRoute() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let route = try details(), peers = try peers(route), password = try SFTPPassword("generated-only-password")
        backend.holdNextSave()
        let saving = Task { await state.rememberAuthenticatedRoute(route, jump: peers.jump, destination: peers.destination,
            passwords: [.jump: password, .destination: password], editing: nil) }
        var entered = backend.entered.stream.makeAsyncIterator(); _ = await entered.next(); saving.cancel()
        let blocked = await state.forget(.all); XCTAssertEqual(blocked.settingsFailure, .busy)
        let drain = Task { await state.drain() }; await Task.yield(); backend.release.signal()
        let cancelled = await saving.value; await drain.value
        XCTAssertEqual(cancelled.settingsFailure, .cancelled); XCTAssertTrue(cancelled.completedAfterCancellation)
        XCTAssertEqual(backend.facts.saves, 1); XCTAssertEqual(backend.facts.count, 1)
        let snapshot = try await state.inspect(); XCTAssertTrue(snapshot?.visibleRoutes.isEmpty == true); XCTAssertEqual(snapshot?.credentials.first?.state, .ready)
        let removed = await state.forget(.all); XCTAssertEqual(removed.password, .complete)
    }
    func testEditingRouteAccountDetachesOldPasswordsWithoutDeletingThem() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let seeded = try await save(store, backend: backend), route = try XCTUnwrap(seeded.snapshot.visibleRoutes.first); await store.close()
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let changed = try SFTPRouteDescription(destination: .init(name: route.details.destination.name, address: route.details.destination.address, account: "another-generated-account"), jump: route.details.jump)
        let edited = await state.rememberAuthenticatedRoute(changed, jump: .init(key: route.jump.key, signIn: .password),
            destination: .init(key: route.destination.key, signIn: .password), passwords: [:], editing: route.id)
        XCTAssertEqual(edited.server, .complete)
        let after = try await state.inspect(), record = try XCTUnwrap(after?.visibleRoutes.first)
        XCTAssertNil(record.jump.credentialID); XCTAssertNil(record.destination.credentialID); XCTAssertEqual(after?.credentials.count, 2)
        XCTAssertEqual(backend.facts.count, 2); XCTAssertTrue(backend.facts.removed.isEmpty)
        _ = await state.forget(.all)
    }
    func testPassiveReadCreatesNothingAndExplicitRouteSaveIsVersionedAndMonotonic() async throws {
        let fixture = try RouteStateFixture(), store = SFTPSettingsStore(directory: fixture.location)
        let absent = try await store.inspect(); XCTAssertNil(absent); XCTAssertTrue(try fixture.image().isEmpty)
        let saved = try await save(store); XCTAssertEqual(saved.snapshot.format, 4)
        XCTAssertEqual(saved.snapshot.visibleRoutes.count, 1); XCTAssertTrue(saved.snapshot.visibleServers.isEmpty)
        let direct = try details().destination
        let added = try await store.apply(.saveServer(direct, id: nil, credentialID: nil, serverPrompts: true), revision: saved.snapshot.revision)
        XCTAssertEqual(added.snapshot.format, 4); await store.close()
        let bytes = try XCTUnwrap(fixture.image()["servers.json"])
        XCTAssertEqual(try SFTPSettingsSnapshot.decode(bytes), added.snapshot)
        var legacy = added.snapshot; legacy.format = 3
        XCTAssertThrowsError(try legacy.encoded())
        let original = try SFTPSettingsSnapshot().encoded()
        XCTAssertFalse(String(decoding: original, as: UTF8.self).contains("routes"))
    }
    func testWrongRoleClaimsAndDirectBookmarksCannotBeAttachedToRoute() async throws {
        let fixture = try RouteStateFixture(), store = SFTPSettingsStore(directory: fixture.location), backend = RouteMemoryBackend()
        let saved = try await save(store, backend: backend), route = try XCTUnwrap(saved.snapshot.visibleRoutes.first), before = try fixture.image()
        var wrong = route.destination; wrong.credentialID = route.jump.credentialID
        await expect(.invalidRecord) { _ = try await store.apply(.saveRoute(route.details, jump: route.jump, destination: wrong, id: route.id), revision: saved.snapshot.revision) }
        let direct = try SFTPKeyAccessReference(bookmark: Data([1]), request: route.details.destination.request, host: route.destination.key, identity: key())
        let invalid = SFTPSavedRouteEndpoint(key: route.destination.key, signIn: .keyFile, keyAccess: direct)
        await expect(.invalidRecord) { _ = try await store.apply(.saveRoute(route.details, jump: route.jump, destination: invalid, id: route.id), revision: saved.snapshot.revision) }
        XCTAssertEqual(try fixture.image(), before); await store.close()
    }
    func testRouteForgetIsHiddenBeforeDeniedDeletionAndExactRetryPreservesDirectRecord() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let saved = try await save(store, backend: backend), routeID = try XCTUnwrap(saved.routeID)
        let direct = try await store.apply(.saveServer(details().destination, id: nil, credentialID: nil), revision: saved.snapshot.revision)
        let directID = try XCTUnwrap(direct.serverID); await store.close()
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        backend.denyNextDelete()
        let denied = await state.forget(.route(routeID, removePasswords: true))
        XCTAssertEqual(denied.passwordFailure, .denied); XCTAssertEqual(denied.server, .incomplete)
        let cold = try await SFTPSettingsStore(directory: fixture.location).inspect()
        XCTAssertTrue(cold?.visibleRoutes.isEmpty == true); XCTAssertEqual(cold?.visibleServers.first?.id, directID)
        XCTAssertEqual(cold?.credentials.filter { $0.state == .deleting }.count, 2); XCTAssertEqual(backend.facts.count, 2)
        let retry = await state.forget(.route(routeID, removePasswords: true))
        XCTAssertEqual(retry.server, .complete); XCTAssertEqual(retry.password, .complete)
        let after = try await state.inspect(); XCTAssertNil(after?.routes); XCTAssertEqual(after?.visibleServers.first?.id, directID)
        XCTAssertEqual(Set(backend.facts.removed), Set(saved.snapshot.credentials.map { $0.reference.id })); await state.drain()
    }
    func testForgetAllHidesBothKindsAcrossReopenAndRequiresEveryExactPasswordCleanup() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let saved = try await save(store, backend: backend)
        let direct = try await store.apply(.saveServer(details().destination, id: nil, credentialID: nil), revision: saved.snapshot.revision)
        let hidden = try await store.apply(.beginForgetAll, revision: direct.snapshot.revision)
        await expect(.recoveryRequired) { _ = try await store.apply(.finishForgetAll, revision: hidden.snapshot.revision) }
        await store.close()
        let cold = try await SFTPSettingsStore(directory: fixture.location).inspect()
        XCTAssertTrue(cold?.forgetAllPending == true); XCTAssertTrue(cold?.visibleRoutes.isEmpty == true); XCTAssertTrue(cold?.visibleServers.isEmpty == true)
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let finished = await state.forget(.all); XCTAssertEqual(finished.server, .complete); XCTAssertEqual(finished.password, .complete)
        let after = try await state.inspect(); XCTAssertNil(after?.routes); XCTAssertTrue(after?.servers.isEmpty == true)
        XCTAssertTrue(after?.credentials.isEmpty == true); XCTAssertEqual(backend.facts.count, 0); await state.drain()
    }
    func testFailureDeletingSecondRoleRetainsOnlyRemainingClaimAndCannotSkipItsCleanup() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let saved = try await save(store, backend: backend), id = try XCTUnwrap(saved.routeID); await store.close()
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        backend.denySecondDelete()
        let interrupted = await state.forget(.route(id, removePasswords: true)); XCTAssertEqual(interrupted.passwordFailure, .denied)
        let cold = try await SFTPSettingsStore(directory: fixture.location).inspect()
        XCTAssertTrue(cold?.visibleRoutes.isEmpty == true); XCTAssertEqual(cold?.credentials.count, 1)
        XCTAssertEqual(cold?.credentials.first?.state, .deleting); XCTAssertEqual(backend.facts.count, 1)
        let bypass = await state.forget(.route(id, removePasswords: false)); XCTAssertEqual(bypass.settingsFailure, .recoveryRequired)
        let retry = await state.forget(.route(id, removePasswords: true)); XCTAssertEqual(retry.server, .complete)
        let after = try await state.inspect(); XCTAssertNil(after?.routes); XCTAssertTrue(after?.credentials.isEmpty == true)
        XCTAssertEqual(backend.facts.removed.count, 2); XCTAssertEqual(Set(backend.facts.removed).count, 2)
    }
    func testRemovingOnlySettingsRetainsExplicitPasswordCleanupOwnership() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let saved = try await save(store, backend: backend); await store.close()
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let removed = await state.forget(.route(try XCTUnwrap(saved.routeID), removePasswords: false))
        XCTAssertEqual(removed.server, .complete); XCTAssertEqual(removed.password, .notRequested)
        let after = try await state.inspect(); XCTAssertNil(after?.routes); XCTAssertEqual(after?.credentials.count, 2); XCTAssertEqual(backend.facts.count, 2)
        let cleanup = await state.forget(.all); XCTAssertEqual(cleanup.password, .complete); XCTAssertEqual(backend.facts.count, 0)
    }
    func testPasswordForgetDetachesOnlyItsOwnVisibleEndpoint() async throws {
        let fixture = try RouteStateFixture(), backend = RouteMemoryBackend(), store = SFTPSettingsStore(directory: fixture.location)
        let saved = try await save(store, backend: backend), route = try XCTUnwrap(saved.snapshot.visibleRoutes.first); await store.close()
        let state = SFTPRememberedState(settings: store, passwords: .init(service: "Generated.Routes.MemoryOnly", backend: backend))
        let removed = await state.forget(.password(try XCTUnwrap(route.jump.credentialID))); XCTAssertEqual(removed.password, .complete)
        let after = try await state.inspect(), survivor = try XCTUnwrap(after?.visibleRoutes.first)
        XCTAssertNil(survivor.jump.credentialID); XCTAssertEqual(survivor.destination.credentialID, route.destination.credentialID)
        XCTAssertEqual(backend.facts.count, 1); _ = await state.forget(.all)
    }
    func testDurableForgetFaultsNeverRepairPassivelyAndPublishedIntentStaysHidden() async throws {
        for stage in [SFTPSettingsStore.File.Stage.stagingSynchronized, .renamed] {
            let fixture = try RouteStateFixture(), seed = SFTPSettingsStore(directory: fixture.location)
            let saved = try await save(seed); await seed.close()
            let store = SFTPSettingsStore(directory: fixture.location, probe: { if $0 == stage { throw SFTPSettingsFailure.unavailable } })
            _ = try await store.openForExplicitWrite()
            await expect(stage == .renamed ? .durabilityUncertain : .unavailable) { _ = try await store.apply(.beginForgetAll, revision: saved.snapshot.revision) }
            await store.close(); let before = try fixture.image()
            if stage == .renamed {
                let cold = try await seed.inspect(); XCTAssertTrue(cold?.forgetAllPending == true); XCTAssertTrue(cold?.visibleRoutes.isEmpty == true)
            } else {
                await expect(.recoveryRequired) { _ = try await seed.inspect() }
                let recovering = SFTPSettingsStore(directory: fixture.location)
                let restored = try await recovering.openForExplicitWrite(discardUncommittedStage: true)
                XCTAssertEqual(restored.snapshot.visibleRoutes.count, 1); await recovering.close()
                continue
            }
            XCTAssertEqual(try fixture.image(), before)
        }
    }
    func testCombinedCapacityRejectsRatherThanDroppingExistingConnections() throws {
        let details = try details(), endpoint = SFTPSavedRouteEndpoint(key: try key(), signIn: .serverPrompts)
        var snapshot = SFTPSettingsSnapshot(); snapshot.format = 4
        snapshot.routes = (0..<64).map { _ in .init(id: UUID(), details: details, jump: endpoint, destination: endpoint, removalPending: false) }
        XCTAssertNoThrow(try snapshot.encoded())
        snapshot.servers.append(.init(id: UUID(), details: details.destination, credentialID: nil, removalPending: false))
        XCTAssertThrowsError(try snapshot.encoded())
        snapshot.servers.removeAll(); snapshot.hosts.append(.init(identity: .init(address: details.jump.address), key: endpoint.key))
        XCTAssertThrowsError(try snapshot.encoded())
    }
}
