import ExplorerCore
import Foundation
import XCTest
@_spi(Qualification) @testable import LocalStorage

private final class ConnectionVaultBackend: SMBPasswordBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: Data] = [:]
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    func read(service: String, reference: SMBCredentialReference) throws -> Data {
        try lock.withLock { readCount += 1; guard let value = records[reference.id] else { throw SMBPasswordFailure.missing }; return value }
    }
    func save(service: String, reference: SMBCredentialReference, bytes: Data) throws { lock.withLock { records[reference.id] = bytes } }
    func remove(service: String, reference: SMBCredentialReference) throws { _ = lock.withLock { records.removeValue(forKey: reference.id) } }
}
private actor ConnectionPreparationHold {
    let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0; entered.continuation.yield(()) } }
    func release() { waiter?.resume(); waiter = nil }
}

final class SMBConnectionCoordinatorTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["MAC_EXPLORER_B10_COMPLETION_SOURCE"] else {
            throw XCTSkip("Use the bounded B10 completion runner")
        }
        let base = URL(fileURLWithPath: value), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard base.resolvingSymlinksInPath() == base, base.lastPathComponent == "source",
              base.path.hasPrefix(repo.appendingPathComponent(".build/b10-completion-qualification/").path) else { throw SMBTemporaryStorageFailure.unsafe }
        let root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return root
    }
    private func draft(_ share: String = "Shared", account: String = "generated") throws -> SMBServerDraft {
        try SMBServerDraft(name: "Generated", address: SMBConnectionAddress("smb://127.0.0.1:15445/" + share), account: account, domain: "", security: .encrypted)
    }
    private func coordinator(_ root: URL, store: SMBSavedServerStore, vault: SMBPasswordVault,
        prepare: SMBConnectionCoordinator.Prepare? = nil, open: SMBConnectionCoordinator.Open? = nil) throws -> SMBConnectionCoordinator {
        SMBConnectionCoordinator(bundleURL: URL(fileURLWithPath: "/unused-generated-bundle"),
            storage: try SMBTemporaryStorage(directory: root.appendingPathComponent("runtime"), sessionByteLimit: 2 << 20),
            servers: store, passwords: vault, activity: FileActivityGate(),
            prepare: prepare ?? { try await SMBPreparedConnection.prepare($0, bundleURL: $1, activity: $2) },
            open: open ?? { _, _, _, _, _, _ in throw SMBBrowserFailure.authentication })
    }
    func testInspectionAndFailedTypedAuthenticationCreateNoRememberingOrRuntimeState() async throws {
        let root = try fixture(), backend = ConnectionVaultBackend(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        let vault = SMBPasswordVault(service: "generated-memory-only", backend: backend)
        let service = try coordinator(root, store: store, vault: vault, open: { _, request, endpoint, _, _, password in
            XCTAssertEqual(request.account, "generated"); XCTAssertEqual(endpoint.numericHost, "127.0.0.1")
            XCTAssertTrue(password.withUTF8Bytes { $0 == Data("generated-only".utf8) })
            throw SMBBrowserFailure.authentication
        })
        let missing = try await service.inspect(); XCTAssertNil(missing)
        do { _ = try await service.connect(draft(), typedPassword: SMBPassword("generated-only"), savedServerID: nil, rememberServer: true, rememberPassword: true); XCTFail() }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .authentication) }
        XCTAssertEqual(backend.reads, 0); XCTAssertTrue(try FileManager().contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testFailedPreparationNeverReadsSavedSecretOrStartsRemembering() async throws {
        let root = try fixture(), backend = ConnectionVaultBackend(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        let service = try coordinator(root, store: store, vault: SMBPasswordVault(service: "generated-memory-only", backend: backend),
            prepare: { _, _, _ in throw SMBResolutionFailure.deadline })
        do { _ = try await service.connect(draft(), typedPassword: nil, savedServerID: UUID(), rememberServer: true, rememberPassword: true); XCTFail() }
        catch { XCTAssertEqual(error as? SMBResolutionFailure, .deadline) }
        XCTAssertEqual(backend.reads, 0); XCTAssertTrue(try FileManager().contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testActualForeignBundleRefusalPrecedesSavedPasswordRead() async throws {
        let root = try fixture(), backend = ConnectionVaultBackend(), request = try draft()
        let store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        let vault = SMBPasswordVault(service: "generated-memory-only", backend: backend)
        var state = try await store.openForExplicitWrite()
        state = try await store.apply(.beginPassword(request.credentialBinding()), expectedRevision: state.snapshot.revision)
        let reference = try XCTUnwrap(state.credentialReference)
        _ = try await vault.save(SMBPassword("generated-only"), reference: reference, binding: request.credentialBinding())
        state = try await store.apply(.confirmPassword(reference.id), expectedRevision: state.snapshot.revision)
        state = try await store.apply(.saveServer(request, id: nil, credentialID: reference.id), expectedRevision: state.snapshot.revision)
        let id = try XCTUnwrap(state.serverID), committed = state.snapshot; await store.close()
        let activity = FileActivityGate()
        let service = SMBConnectionCoordinator(bundleURL: root.appendingPathComponent("Not The Running App.app"),
            storage: try SMBTemporaryStorage(directory: root.appendingPathComponent("runtime"), sessionByteLimit: 2 << 20),
            servers: store, passwords: vault, activity: activity)
        do { _ = try await service.connect(request, typedPassword: nil, savedServerID: id, rememberServer: true, rememberPassword: true); XCTFail() }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .unavailable) }
        XCTAssertEqual(backend.reads, 0); XCTAssertEqual(activity.activeCount, 0)
        let after = try await service.inspect(); XCTAssertEqual(after, committed)
        XCTAssertFalse(FileManager().fileExists(atPath: root.appendingPathComponent("runtime").path))
    }
    func testSavedPasswordRequiresCurrentReadyClaimAndExactLogicalBinding() async throws {
        let root = try fixture(), backend = ConnectionVaultBackend(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        let vault = SMBPasswordVault(service: "generated-memory-only", backend: backend), request = try draft()
        var state = try await store.openForExplicitWrite()
        state = try await store.apply(.beginPassword(request.credentialBinding()), expectedRevision: state.snapshot.revision)
        let reference = try XCTUnwrap(state.credentialReference)
        _ = try await vault.save(SMBPassword("generated-only"), reference: reference, binding: request.credentialBinding())
        state = try await store.apply(.confirmPassword(reference.id), expectedRevision: state.snapshot.revision)
        state = try await store.apply(.saveServer(request, id: nil, credentialID: reference.id), expectedRevision: state.snapshot.revision)
        let id = try XCTUnwrap(state.serverID); await store.close()
        let service = try coordinator(root, store: store, vault: vault)
        for changed in [try draft("Other"), try draft(account: "other-generated-account")] {
            do { _ = try await service.connect(changed, typedPassword: nil, savedServerID: id, rememberServer: false, rememberPassword: false); XCTFail() }
            catch { XCTAssertEqual(error as? SMBPasswordFailure, .bindingMismatch) }
        }
        XCTAssertEqual(backend.reads, 0)
        do { _ = try await service.connect(request, typedPassword: nil, savedServerID: id, rememberServer: false, rememberPassword: false); XCTFail() }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .authentication) }
        XCTAssertEqual(backend.reads, 1)
        let after = try await service.inspect(); XCTAssertEqual(after, state.snapshot)
    }
    func testForgetCannotInterleaveWithPendingConnectionAndCancellationReleasesAdmission() async throws {
        let root = try fixture(), backend = ConnectionVaultBackend(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        let hold = ConnectionPreparationHold()
        let service = try coordinator(root, store: store, vault: SMBPasswordVault(service: "generated-memory-only", backend: backend),
            prepare: { address, bundle, activity in await hold.wait(); return try await SMBPreparedConnection.prepare(address, bundleURL: bundle, activity: activity) })
        let request = try draft()
        let pending = Task { try await service.connect(request, typedPassword: SMBPassword("generated-only"), savedServerID: nil, rememberServer: false, rememberPassword: false) }
        var entered = hold.entered.stream.makeAsyncIterator(); _ = await entered.next()
        let refused = await service.forget(.password(UUID())); XCTAssertEqual(refused.storeFailure, .busy)
        do { _ = try await service.inspect(); XCTFail() } catch { XCTAssertEqual(error as? SMBServerStoreFailure, .busy) }
        pending.cancel(); await hold.release()
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let missing = try await service.inspect(); XCTAssertNil(missing); XCTAssertEqual(backend.reads, 0)
    }
    func testExplicitForgetRemovesSavedServerThroughExistingDurableCoordinator() async throws {
        let root = try fixture(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        var state = try await store.openForExplicitWrite()
        state = try await store.apply(.saveServer(draft(), id: nil, credentialID: nil), expectedRevision: state.snapshot.revision)
        let id = try XCTUnwrap(state.serverID); await store.close()
        let service = try coordinator(root, store: store, vault: SMBPasswordVault(service: "generated-memory-only", backend: ConnectionVaultBackend()))
        let removed = await service.forget(.server(id, removePassword: false))
        XCTAssertEqual(removed.server, .complete); XCTAssertEqual(removed.password, .notRequested)
        let final = try await service.inspect(); XCTAssertTrue(final?.visibleServers.isEmpty == true)
    }
    func testPasswordOnlyConnectUsesLatestReadyExactClaimAndForgetDoesNotReadSecrets() async throws {
        let root = try fixture(), backend = ConnectionVaultBackend(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers"))
        let vault = SMBPasswordVault(service: "generated-memory-only", backend: backend), request = try draft(), other = try draft("Other")
        var state = try await store.openForExplicitWrite()
        for (draft, password) in [(request, "older-generated"), (other, "other-generated"), (request, "latest-generated")] {
            state = try await store.apply(.beginPassword(draft.credentialBinding()), expectedRevision: state.snapshot.revision)
            let reference = try XCTUnwrap(state.credentialReference)
            _ = try await vault.save(SMBPassword(password), reference: reference, binding: draft.credentialBinding())
            state = try await store.apply(.confirmPassword(reference.id), expectedRevision: state.snapshot.revision)
        }
        // A more recent incomplete save must never displace a completed claim.
        _ = try await store.apply(.beginPassword(request.credentialBinding()), expectedRevision: state.snapshot.revision)
        await store.close()
        let service = try coordinator(root, store: store, vault: vault, open: { _, _, _, _, _, password in
            XCTAssertTrue(password.withUTF8Bytes { $0 == Data("latest-generated".utf8) })
            throw SMBBrowserFailure.authentication
        })
        do { _ = try await service.connect(request, typedPassword: nil, savedServerID: nil, rememberServer: false, rememberPassword: false); XCTFail() }
        catch { XCTAssertEqual(error as? SMBBrowserFailure, .authentication) }
        XCTAssertEqual(backend.reads, 1)
        let removed = await service.forgetPasswords(for: request)
        XCTAssertEqual(removed.password, .complete); XCTAssertEqual(backend.reads, 1)
        let remaining = try await service.inspect()
        XCTAssertEqual(remaining?.credentials.count, 1)
        XCTAssertEqual(remaining?.credentials.first?.reference.bindingDigest, try other.credentialBinding().digest)
        do { _ = try await service.connect(request, typedPassword: nil, savedServerID: nil, rememberServer: false, rememberPassword: false); XCTFail() }
        catch { XCTAssertEqual(error as? SMBPasswordFailure, .missing) }
        XCTAssertEqual(backend.reads, 1)
    }
    func testExplicitStageDiscardRetainsCommittedPasswordCleanupAuthority() async throws {
        let root = try fixture(), directory = root.appendingPathComponent("servers"), seed = SMBSavedServerStore(directory: directory)
        var state = try await seed.openForExplicitWrite()
        state = try await seed.apply(.beginPassword(draft().credentialBinding()), expectedRevision: state.snapshot.revision)
        let reference = try XCTUnwrap(state.credentialReference)
        state = try await seed.apply(.confirmPassword(reference.id), expectedRevision: state.snapshot.revision)
        let committed = state.snapshot; await seed.close()
        let fault = SMBSavedServerStore(directory: directory, probe: { if $0 == .stagingSynchronized { throw SMBServerStoreFailure.unavailable } })
        _ = try await fault.openForExplicitWrite()
        do { _ = try await fault.apply(.saveServer(draft(), id: nil, credentialID: reference.id), expectedRevision: committed.revision); XCTFail() }
        catch { XCTAssertEqual(error as? SMBServerStoreFailure, .unavailable) }
        await fault.close()
        let copy = root.appendingPathComponent("recovery-copy")
        try FileManager().copyItem(at: directory, to: copy)
        let store = SMBSavedServerStore(directory: copy), backend = ConnectionVaultBackend()
        let service = try coordinator(root, store: store, vault: SMBPasswordVault(service: "generated-memory-only", backend: backend))
        do { _ = try await service.inspect(); XCTFail() } catch { XCTAssertEqual(error as? SMBServerStoreFailure, .recoveryRequired) }
        try await service.discardInterruptedPreferencesUpdate()
        let recovered = try await service.inspect(); XCTAssertEqual(recovered, committed); XCTAssertEqual(backend.reads, 0)
        XCTAssertTrue(FileManager().fileExists(atPath: directory.appendingPathComponent("pending.json").path))
    }
    func testRememberingExistingServerWithoutReplacingPasswordKeepsItsQualifiedCredential() async throws {
        let root = try fixture(), store = SMBSavedServerStore(directory: root.appendingPathComponent("servers")), backend = ConnectionVaultBackend()
        let request = try draft(), vault = SMBPasswordVault(service: "generated-memory-only", backend: backend)
        var state = try await store.openForExplicitWrite()
        state = try await store.apply(.beginPassword(request.credentialBinding()), expectedRevision: state.snapshot.revision)
        let reference = try XCTUnwrap(state.credentialReference)
        _ = try await vault.save(SMBPassword("generated-only"), reference: reference, binding: request.credentialBinding())
        state = try await store.apply(.confirmPassword(reference.id), expectedRevision: state.snapshot.revision)
        state = try await store.apply(.saveServer(request, id: nil, credentialID: reference.id), expectedRevision: state.snapshot.revision)
        let id = try XCTUnwrap(state.serverID); await store.close()
        let remembering = SMBServerRemembering(store: store, vault: vault)
        let outcome = try await remembering.rememberAuthenticated(request, password: SMBPassword("generated-only"), server: true, savePassword: false, editing: id)
        XCTAssertEqual(outcome.server, .complete); XCTAssertEqual(outcome.password, .notRequested)
        let saved = try await store.inspect()
        XCTAssertEqual(saved?.visibleServers.first?.credentialID, reference.id)
        XCTAssertEqual(saved?.credentials.count, 1); XCTAssertEqual(backend.reads, 0)
        let changed = try draft(account: "other-generated-account")
        let updated = try await remembering.rememberAuthenticated(changed, password: SMBPassword("new-generated-only"), server: true, savePassword: false, editing: id)
        XCTAssertEqual(updated.server, .complete)
        let different = try await store.inspect()
        XCTAssertNil(different?.visibleServers.first?.credentialID)
        XCTAssertEqual(different?.credentials.count, 1) // Retain exact cleanup authority for the old password.
    }
}
