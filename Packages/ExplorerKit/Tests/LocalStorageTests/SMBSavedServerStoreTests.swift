import Darwin
import CryptoKit
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private struct ServerFixture {
    let root: URL
    var store: URL { root.appendingPathComponent("servers") }
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_B10_SERVER_STORE_ROOT"] else {
            throw XCTSkip("Run through tools/smb_reader/qualify_server_store.py for a charged generated root")
        }
        let base = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let b11 = ProcessInfo.processInfo.environment["MAC_EXPLORER_B11_PRIVATE_STATE_ROOT"] == path
            && base.path.hasPrefix(repo.appendingPathComponent(".build/b11-native-qualification/").path)
            && (try? Data(contentsOf: base.deletingLastPathComponent().appendingPathComponent("reservation.json"))) != nil
        guard (b11 || base.path.hasPrefix(repo.appendingPathComponent(".build/b10-browser-qualification/").path)),
              base.resolvingSymlinksInPath() == base, base.lastPathComponent == "source" else { throw SMBServerStoreFailure.unsafe }
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func image() throws -> [String: Data] {
        guard FileManager().fileExists(atPath: store.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(atPath: store.path).map {
            ($0, try Data(contentsOf: store.appendingPathComponent($0)))
        })
    }
    func recordLinkControl(_ kind: String) throws {
        let packet = root.deletingLastPathComponent().deletingLastPathComponent(), marker = packet.appendingPathComponent("fixture-links.json")
        var object = FileManager().fileExists(atPath: marker.path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
            : ["version": 1, "guardChecksPassed": true, "entries": []]
        var entries = object["entries"] as! [[String: Any]]
        let paths = kind == "symlink" ? [store.appendingPathComponent("servers.json")]
            : [store.appendingPathComponent("servers.json"), root.appendingPathComponent("retained.json")]
        for path in paths {
            var facts = stat(); guard lstat(path.path, &facts) == 0 else { throw SMBServerStoreFailure.unavailable }
            var record: [String: Any] = ["kind": kind, "path": String(path.path.dropFirst(packet.path.count + 1)),
                "identity": ["device": Int(facts.st_dev), "inode": facts.st_ino, "mode": Int(facts.st_mode), "links": Int(facts.st_nlink), "size": facts.st_size]]
            if kind == "symlink" {
                let target = root.appendingPathComponent("retained.json")
                record["target"] = target.path
                record["targetSHA256"] = Data(SHA256.hash(data: try Data(contentsOf: target))).map { String(format: "%02x", $0) }.joined()
            } else {
                record["sha256"] = Data(SHA256.hash(data: try Data(contentsOf: path))).map { String(format: "%02x", $0) }.joined()
            }
            entries.append(record)
        }
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: marker, options: .atomic)
    }
}
private final class ServerHold: @unchecked Sendable {
    let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var used = false
    func hold(_ stage: SMBServerFile.Stage) throws {
        guard stage == .beforeRename, lock.withLock({ if used { return false }; used = true; return true }) else { return }
        entered.continuation.yield(())
        guard gate.wait(timeout: .now() + 5) == .success else { throw SMBServerStoreFailure.unavailable }
    }
}

final class SMBSavedServerStoreTests: XCTestCase, @unchecked Sendable {
    private func draft(_ host: String = "studio.invalid", name: String = "Studio") throws -> SMBServerDraft {
        try SMBServerDraft(name: name, address: SMBConnectionAddress("smb://\(host)/Shared"), account: "generated", domain: "", security: .encrypted)
    }
    @discardableResult private func failure(_ expected: SMBServerStoreFailure, _ action: () async throws -> Void) async -> Bool {
        do { try await action(); XCTFail("Expected guarded refusal"); return false }
        catch { XCTAssertEqual(error as? SMBServerStoreFailure, expected); return error as? SMBServerStoreFailure == expected }
    }
    func testPassiveInspectionDoesNotCreateStateOrRecoverAnInterruptedFile() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store)
        let missing = try await store.inspect(); XCTAssertNil(missing)
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.store.path))
        _ = try await store.openForExplicitWrite(); await store.close()
        let staged = fixture.store.appendingPathComponent("pending.json")
        try Data("Generated incomplete metadata".utf8).write(to: staged, options: .withoutOverwriting)
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        let before = try fixture.image()
        await failure(.recoveryRequired) { _ = try await store.inspect() }
        XCTAssertEqual(try fixture.image(), before)
    }
    func testServerAndPasswordOnlyChoicesRoundTripIndependentlyWithoutSecrets() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store), description = try draft()
        var result = try await store.openForExplicitWrite()
        result = try await store.apply(.saveServer(description, id: nil, credentialID: nil), expectedRevision: result.snapshot.revision)
        let id = try XCTUnwrap(result.serverID)
        XCTAssertNil(result.snapshot.visibleServers.first?.credentialID)
        result = try await store.apply(.beginPassword(description.credentialBinding()), expectedRevision: result.snapshot.revision)
        let reference = try XCTUnwrap(result.credentialReference)
        XCTAssertEqual(result.snapshot.credentials.first?.state, .preparing)
        result = try await store.apply(.confirmPassword(reference.id), expectedRevision: result.snapshot.revision)
        XCTAssertNil(result.snapshot.visibleServers.first?.credentialID) // Password-only does not link a server implicitly.
        await store.close()
        let inspection = try await store.inspect(), cold = try XCTUnwrap(inspection)
        XCTAssertEqual(cold.visibleServers.first?.id, id); XCTAssertEqual(cold.credentials.first?.state, .ready)
        XCTAssertFalse(String(decoding: try XCTUnwrap(fixture.image()["servers.json"]), as: UTF8.self).contains("generated-password"))
        XCTAssertEqual(String(reflecting: description), "<SMB server description>")
        XCTAssertEqual(String(reflecting: cold), "<SMB server snapshot>")
    }
    func testPasswordOnlyIntentPersistsNoServerAccountOrPath() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store), description = try draft()
        _ = try await store.openForExplicitWrite()
        _ = try await store.apply(.beginPassword(description.credentialBinding()), expectedRevision: 0)
        await store.close()
        let text = String(decoding: try XCTUnwrap(fixture.image()["servers.json"]), as: UTF8.self)
        for sensitive in ["studio.invalid", "generated", "Shared", "Studio"] { XCTAssertFalse(text.contains(sensitive)) }
        let inspection = try await store.inspect(); XCTAssertEqual(inspection?.visibleServers.count, 0)
    }
    func testCredentialCannotBeLinkedBeforeReadyOrReboundToAnEditedEndpoint() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store), description = try draft()
        _ = try await store.openForExplicitWrite()
        var result = try await store.apply(.beginPassword(description.credentialBinding()), expectedRevision: 0)
        let reference = try XCTUnwrap(result.credentialReference)
        await failure(.invalidRecord) { _ = try await store.apply(.saveServer(description, id: nil, credentialID: reference.id), expectedRevision: 1) }
        result = try await store.apply(.confirmPassword(reference.id), expectedRevision: 1)
        result = try await store.apply(.saveServer(description, id: nil, credentialID: reference.id), expectedRevision: 2)
        let id = try XCTUnwrap(result.serverID), before = try fixture.image()
        await failure(.invalidRecord) { _ = try await store.apply(.saveServer(try self.draft("other.invalid"), id: id, credentialID: reference.id), expectedRevision: 3) }
        XCTAssertEqual(try fixture.image(), before)
        await failure(.staleRevision) { _ = try await store.apply(.beginForgetPassword(reference.id), expectedRevision: 2) }
        await store.close()
    }
    func testForgetHidesDurablyBeforeDeletingNamesAndRetainsExactPasswordCleanupAuthority() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store), description = try draft()
        _ = try await store.openForExplicitWrite()
        var result = try await store.apply(.beginPassword(description.credentialBinding()), expectedRevision: 0)
        let reference = try XCTUnwrap(result.credentialReference)
        result = try await store.apply(.confirmPassword(reference.id), expectedRevision: 1)
        result = try await store.apply(.saveServer(description, id: nil, credentialID: reference.id), expectedRevision: 2)
        let id = try XCTUnwrap(result.serverID)
        result = try await store.apply(.beginForgetServer(id, removePassword: true), expectedRevision: 3)
        XCTAssertTrue(result.snapshot.visibleServers.isEmpty); await store.close()
        let inspection = try await store.inspect(), cold = try XCTUnwrap(inspection)
        XCTAssertTrue(cold.visibleServers.isEmpty)
        XCTAssertEqual(cold.credentials, [SMBOwnedCredential(reference: reference, state: .deleting)])
        _ = try await store.openForExplicitWrite()
        await failure(.missing) { _ = try await store.apply(.confirmPassword(reference.id), expectedRevision: 4) }
        result = try await store.apply(.finishForgetPassword(reference.id), expectedRevision: 4)
        result = try await store.apply(.finishForgetServer(id), expectedRevision: 5)
        XCTAssertTrue(result.snapshot.servers.isEmpty); XCTAssertTrue(result.snapshot.credentials.isEmpty)
        await store.close()
        let final = try await store.inspect(); XCTAssertTrue(final?.servers.isEmpty == true)
    }
    func testServerForgetCanKeepAnIndependentOwnedPassword() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store), description = try draft()
        _ = try await store.openForExplicitWrite()
        var result = try await store.apply(.beginPassword(description.credentialBinding()), expectedRevision: 0)
        let reference = try XCTUnwrap(result.credentialReference)
        result = try await store.apply(.confirmPassword(reference.id), expectedRevision: 1)
        result = try await store.apply(.saveServer(description, id: nil, credentialID: reference.id), expectedRevision: 2)
        let id = try XCTUnwrap(result.serverID)
        result = try await store.apply(.beginForgetServer(id, removePassword: false), expectedRevision: 3)
        result = try await store.apply(.finishForgetServer(id), expectedRevision: 4)
        XCTAssertTrue(result.snapshot.servers.isEmpty); XCTAssertEqual(result.snapshot.credentials.first?.state, .ready)
        await store.close()
    }
    func testExpectedServerIsComparedInsideTheWriterAtTheCurrentRevision() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store)
        _ = try await store.openForExplicitWrite()
        let saved = try await store.apply(.saveServer(try draft(), id: nil, credentialID: nil), expectedRevision: 0)
        var expected = try XCTUnwrap(saved.snapshot.visibleServers.first)
        expected.details = try draft(name: "Another generated label")
        let before = try fixture.image()
        await failure(.staleRevision) {
            _ = try await store.apply(.beginForgetExpectedServer(expected, removePassword: false), expectedRevision: saved.snapshot.revision)
        }
        XCTAssertEqual(try fixture.image(), before)
        let inspection = try await store.inspect()
        XCTAssertEqual(inspection?.visibleServers.count, 1)
        await store.close()
    }
    func testSecondOwnerIsBusyAndReplacedCatalogIsNeverOverwritten() async throws {
        let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store), second = SMBSavedServerStore(directory: fixture.store)
        _ = try await store.openForExplicitWrite()
        _ = try await store.apply(.saveServer(try draft(), id: nil, credentialID: nil), expectedRevision: 0)
        await failure(.busy) { _ = try await second.openForExplicitWrite() }
        await failure(.busy) { _ = try await second.inspect() }
        let file = fixture.store.appendingPathComponent("servers.json"), original = fixture.root.appendingPathComponent("retained-original.json")
        try FileManager().moveItem(at: file, to: original)
        try Data(contentsOf: original).write(to: file, options: .withoutOverwriting); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let before = try fixture.image()
        await failure(.unsafe) { _ = try await store.apply(.saveServer(try self.draft(), id: nil, credentialID: nil), expectedRevision: 1) }
        XCTAssertEqual(try fixture.image(), before); await store.close()
    }
    func testUnsafeLinksPermissionsAndUnknownVersionRemainUntouched() async throws {
        for scenario in ["symlink", "hardlink", "permissions", "future", "unknown-field"] {
            let fixture = try ServerFixture(), store = SMBSavedServerStore(directory: fixture.store)
            _ = try await store.openForExplicitWrite()
            _ = try await store.apply(.saveServer(try draft(), id: nil, credentialID: nil), expectedRevision: 0); await store.close()
            let file = fixture.store.appendingPathComponent("servers.json"), retained = fixture.root.appendingPathComponent("retained.json")
            if scenario == "permissions" { XCTAssertEqual(chmod(file.path, 0o644), 0) }
            else if scenario == "symlink" || scenario == "hardlink" {
                try FileManager().moveItem(at: file, to: retained)
                if scenario == "symlink" { try FileManager().createSymbolicLink(at: file, withDestinationURL: retained) }
                else { try FileManager().linkItem(at: retained, to: file) }
            } else {
                let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
                try Data(text.replacingOccurrences(of: "\"format\":1", with: scenario == "future" ? "\"format\":99" : "\"unknown\":1,\"format\":1").utf8).write(to: file)
            }
            let expected: SMBServerStoreFailure = scenario == "future" ? .incompatibleVersion : scenario == "unknown-field" ? .invalidRecord : .unsafe
            let readRefused = await failure(expected) { _ = try await store.inspect() }
            let writeRefused = await failure(expected) { _ = try await store.openForExplicitWrite() }
            if readRefused && writeRefused && ["symlink", "hardlink"].contains(scenario) { try fixture.recordLinkControl(scenario) }
            if scenario != "symlink" { XCTAssertTrue(FileManager().fileExists(atPath: file.path)) }
        }
    }
    func testStagingFailureRequiresExplicitRecoveryAndRenameFailureIsUncertain() async throws {
        for stage in [SMBServerFile.Stage.stagingWritten, .stagingSynchronized, .renamed] {
            let fixture = try ServerFixture(), seed = SMBSavedServerStore(directory: fixture.store)
            _ = try await seed.openForExplicitWrite()
            _ = try await seed.apply(.saveServer(try draft(), id: nil, credentialID: nil), expectedRevision: 0); await seed.close()
            let store = SMBSavedServerStore(directory: fixture.store, probe: { if $0 == stage { throw SMBServerStoreFailure.unavailable } })
            _ = try await store.openForExplicitWrite()
            await failure(stage == .renamed ? .durabilityUncertain : .unavailable) {
                _ = try await store.apply(.saveServer(try self.draft(name: "After"), id: nil, credentialID: nil), expectedRevision: 1)
            }
            await failure(.recoveryRequired) { _ = try await store.inspect() }; await store.close()
            let before = try fixture.image()
            if stage != .renamed {
                await failure(.recoveryRequired) { _ = try await seed.inspect() }
                XCTAssertEqual(try fixture.image(), before)
                let copy = fixture.root.appendingPathComponent("recovery-copy")
                try FileManager().copyItem(at: fixture.store, to: copy)
                let recovering = SMBSavedServerStore(directory: copy)
                _ = try await recovering.openForExplicitWrite(discardUncommittedStage: true)
                let inspection = try await recovering.inspect(); XCTAssertEqual(inspection?.servers.count, 1)
                await recovering.close()
                XCTAssertEqual(try fixture.image(), before)
            } else {
                let inspection = try await seed.inspect(); XCTAssertEqual(inspection?.servers.count, 2)
                XCTAssertEqual(try fixture.image(), before)
            }
            await seed.close()
        }
    }
    func testLateCancellationAndBoundedAdmissionDrainActualCommit() async throws {
        let fixture = try ServerFixture(), held = ServerHold(), store = SMBSavedServerStore(directory: fixture.store, probe: { try held.hold($0) })
        _ = try await store.openForExplicitWrite()
        let value = try draft()
        let saving = Task { try await store.apply(.saveServer(value, id: nil, credentialID: nil), expectedRevision: 0) }
        var entered = held.entered.stream.makeAsyncIterator(); _ = await entered.next(); saving.cancel()
        let queued = (0..<7).map { _ in Task { try await store.inspect() } }
        let deadline = ContinuousClock.now + .seconds(1)
        while store.admittedRequestCount < 8 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(store.admittedRequestCount, 8)
        await failure(.busy) { _ = try await store.inspect() }
        queued.forEach { $0.cancel() }; held.gate.signal()
        let outcome = try await saving.value
        XCTAssertTrue(outcome.completedAfterCancellation); XCTAssertEqual(outcome.snapshot.visibleServers.count, 1)
        for read in queued {
            await failure(.cancelled) { _ = try await read.value }
        }
        await store.close(); XCTAssertEqual(store.admittedRequestCount, 0)
        let inspection = try await store.inspect(); XCTAssertEqual(inspection?.visibleServers.count, 1)
    }
}

private final class RememberingBackend: SMBPasswordBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var holdSave = false, denySave = false, denyDelete = false
    private var main = false
    let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let gate = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { values.count } }
    var usedMain: Bool { lock.withLock { main } }
    func holdNextSave() { lock.withLock { holdSave = true } }
    func denyNextSave() { lock.withLock { denySave = true } }
    func denyNextDelete() { lock.withLock { denyDelete = true } }
    func read(service: String, reference: SMBCredentialReference) throws -> Data {
        try lock.withLock {
            main = main || Thread.isMainThread
            guard let data = values[service + reference.id.uuidString] else { throw SMBPasswordFailure.missing }
            return data
        }
    }
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws {
        let (hold, denied) = lock.withLock {
            main = main || Thread.isMainThread
            let result = (holdSave, denySave); holdSave = false; denySave = false; return result
        }
        if hold { entered.continuation.yield(()); guard gate.wait(timeout: .now() + 5) == .success else { throw SMBPasswordFailure.unavailable } }
        if denied { throw SMBPasswordFailure.denied }
        lock.withLock { values[service + reference.id.uuidString] = bytes }
    }
    func remove(service: String, reference: SMBCredentialReference) throws {
        try lock.withLock {
            main = main || Thread.isMainThread
            if denyDelete { denyDelete = false; throw SMBPasswordFailure.denied }
            values.removeValue(forKey: service + reference.id.uuidString)
        }
    }
}

final class SMBServerRememberingTests: XCTestCase, @unchecked Sendable {
    private func draft() throws -> SMBServerDraft {
        try SMBServerDraft(name: "Generated studio", address: SMBConnectionAddress("smb://generated.invalid/Shared"), account: "generated", domain: "", security: .encrypted)
    }
    private func system(_ fixture: ServerFixture, _ backend: RememberingBackend) -> (SMBSavedServerStore, SMBServerRemembering) {
        let store = SMBSavedServerStore(directory: fixture.store)
        return (store, SMBServerRemembering(store: store, vault: SMBPasswordVault(service: "generated-no-keychain", backend: backend)))
    }
    func testExactServerForgetRejectsChangedConfirmationThenCleansOnlyItsClaim() async throws {
        let fixture = try ServerFixture(), backend = RememberingBackend(), (store, owner) = system(fixture, backend)
        let absent = try await owner.inspect()
        XCTAssertNil(absent)
        XCTAssertFalse(FileManager().fileExists(atPath: fixture.store.path))
        let saved = await owner.rememberAuthenticated(try draft(), password: try .init("generated-password"), server: true, savePassword: true)
        XCTAssertEqual(saved.server, .complete); XCTAssertEqual(saved.password, .complete)
        let shownSnapshot = try await owner.inspect(), shown = try XCTUnwrap(shownSnapshot?.visibleServers.first)
        let changed = try SMBServerDraft(name: "Changed generated label", address: shown.details.address,
            account: shown.details.account, domain: shown.details.domain, security: shown.details.security)
        let currentInspection = try await store.inspect(), current = try XCTUnwrap(currentInspection)
        _ = try await store.openForExplicitWrite()
        _ = try await store.apply(.saveServer(changed, id: shown.id, credentialID: shown.credentialID), expectedRevision: current.revision)
        await store.close()
        let before = try fixture.image()
        let stale = await owner.forget(server: shown, removePassword: true)
        XCTAssertEqual(stale.storeFailure, .staleRevision)
        XCTAssertEqual(stale.server, .incomplete); XCTAssertEqual(stale.password, .incomplete)
        XCTAssertEqual(try fixture.image(), before); XCTAssertEqual(backend.count, 1)
        let freshSnapshot = try await owner.inspect(), fresh = try XCTUnwrap(freshSnapshot?.visibleServers.first)
        let forgotten = await owner.forget(server: fresh, removePassword: true)
        XCTAssertEqual(forgotten.server, .complete); XCTAssertEqual(forgotten.password, .complete)
        XCTAssertEqual(backend.count, 0)
        let final = try await owner.inspect()
        XCTAssertTrue(final?.servers.isEmpty == true)
    }
    func testNoRememberingCreatesNothingAndIndependentChoicesStayIndependent() async throws {
        let empty = try ServerFixture(), backend = RememberingBackend()
        let (_, inert) = system(empty, backend)
        let none = try await inert.rememberAuthenticated(draft(), password: SMBPassword("generated-password"), server: false, savePassword: false)
        XCTAssertEqual(none.server, .notRequested); XCTAssertFalse(FileManager().fileExists(atPath: empty.store.path))
        let fixture = try ServerFixture(), (store, coordinator) = system(fixture, backend)
        let server = try await coordinator.rememberAuthenticated(draft(), password: SMBPassword("generated-password"), server: true, savePassword: false)
        XCTAssertEqual(server.server, .complete); XCTAssertEqual(server.password, .notRequested); XCTAssertEqual(backend.count, 0)
        let password = try await coordinator.rememberAuthenticated(draft(), password: SMBPassword("generated-password"), server: false, savePassword: true)
        XCTAssertEqual(password.server, .notRequested); XCTAssertEqual(password.password, .complete); XCTAssertEqual(backend.count, 1)
        let snapshot = try await store.inspect()
        XCTAssertEqual(snapshot?.servers.count, 1); XCTAssertNil(snapshot?.servers.first?.credentialID)
        XCTAssertEqual(snapshot?.credentials.first?.state, .ready); XCTAssertFalse(backend.usedMain)
        XCTAssertFalse(String(decoding: try XCTUnwrap(fixture.image()["servers.json"]), as: UTF8.self).contains("generated-password"))
    }
    func testDeniedSaveRetainsExactPendingClaimAndServerCanStillBeSaved() async throws {
        let fixture = try ServerFixture(), backend = RememberingBackend(), (store, coordinator) = system(fixture, backend)
        backend.denyNextSave()
        let outcome = try await coordinator.rememberAuthenticated(draft(), password: SMBPassword("generated-password"), server: true, savePassword: true)
        XCTAssertEqual(outcome.server, .complete); XCTAssertEqual(outcome.password, .incomplete)
        XCTAssertEqual(outcome.passwordFailure, .denied); XCTAssertEqual(backend.count, 0)
        let snapshot = try await store.inspect(), claim = try XCTUnwrap(snapshot?.credentials.first)
        XCTAssertEqual(claim.state, .preparing); XCTAssertNil(snapshot?.servers.first?.credentialID)
        let removed = await coordinator.forget(.password(claim.reference.id))
        XCTAssertEqual(removed.password, .complete)
        let final = try await store.inspect(); XCTAssertTrue(final?.credentials.isEmpty == true)
    }
    func testDeniedForgetStaysHiddenAndRetryDeletesOnlyItsExactCredential() async throws {
        let fixture = try ServerFixture(), backend = RememberingBackend(), (store, coordinator) = system(fixture, backend)
        let first = try await coordinator.rememberAuthenticated(draft(), password: SMBPassword("generated-password"), server: true, savePassword: true)
        _ = try await coordinator.rememberAuthenticated(draft(), password: SMBPassword("other-generated-password"), server: false, savePassword: true)
        let id = try XCTUnwrap(first.serverID)
        backend.denyNextDelete()
        let failed = await coordinator.forget(.server(id, removePassword: true))
        XCTAssertEqual(failed.server, .incomplete); XCTAssertEqual(failed.password, .incomplete); XCTAssertEqual(failed.passwordFailure, .denied)
        XCTAssertEqual(backend.count, 2)
        let snapshot = try await store.inspect()
        XCTAssertTrue(snapshot?.visibleServers.isEmpty == true)
        XCTAssertEqual(snapshot?.credentials.filter { $0.state == .deleting }.count, 1)
        let pending = try XCTUnwrap(snapshot?.credentials.first(where: { $0.state == .deleting })?.reference.id)
        backend.denyNextDelete()
        let pendingRetry = await coordinator.forget(.password(pending))
        XCTAssertEqual(pendingRetry.password, .incomplete)
        let stillHidden = try await store.inspect()
        XCTAssertEqual(stillHidden?.servers.first?.credentialID, pending)
        let retry = await coordinator.forget(.server(id, removePassword: true))
        XCTAssertEqual(retry.server, .complete); XCTAssertEqual(retry.password, .complete); XCTAssertEqual(backend.count, 1)
        let final = try await store.inspect(); XCTAssertTrue(final?.servers.isEmpty == true)
        XCTAssertEqual(final?.credentials.count, 1); XCTAssertEqual(final?.credentials.first?.state, .ready)
    }
    func testCancelledActualSaveFinishesItsClaimAndCannotRaceForget() async throws {
        let fixture = try ServerFixture(), backend = RememberingBackend(), (store, coordinator) = system(fixture, backend)
        backend.holdNextSave()
        let value = try draft(), password = try SMBPassword("generated-password")
        let saving = Task { await coordinator.rememberAuthenticated(value, password: password, server: false, savePassword: true) }
        var entered = backend.entered.stream.makeAsyncIterator(); _ = await entered.next(); saving.cancel()
        let blocked = await coordinator.forget(.password(UUID()))
        XCTAssertEqual(blocked.storeFailure, .busy)
        backend.gate.signal()
        let outcome = await saving.value
        XCTAssertEqual(outcome.password, .complete); XCTAssertTrue(outcome.completedAfterCancellation)
        XCTAssertEqual(backend.count, 1)
        let snapshot = try await store.inspect()
        XCTAssertEqual(snapshot?.credentials.first?.state, .ready); XCTAssertEqual(store.admittedRequestCount, 0)
    }
}
