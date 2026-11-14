import ExplorerCore
import Foundation

@_spi(Qualification) public struct SMBConnectionOutcome: Sendable {
    public let session: SMBBrowserSession
    public let remembering: SMBRememberingOutcome
}

/// One setup owner binds the explicit form, frozen resolver result, exact
/// credential reference and authenticated session. No UI, automatic reconnect,
/// implicit recovery, endpoint substitution or security fallback lives here.
@_spi(Qualification) public actor SMBConnectionCoordinator {
    public enum ForgetTarget: Sendable { case server(UUID, removePassword: Bool), password(UUID) }
    typealias Prepare = @Sendable (SMBConnectionAddress, URL, FileActivityGate) async throws -> SMBPreparedConnection
    typealias Open = @Sendable (URL, SMBServerDraft, SMBPreparedConnection, SMBTemporaryStorage, FileActivityGate, SMBPassword) async throws -> SMBBrowserSession
    private let bundle: URL, storage: SMBTemporaryStorage, activity: FileActivityGate
    private let store: SMBSavedServerStore, vault: SMBPasswordVault, remembering: SMBServerRemembering
    private let prepare: Prepare, open: Open
    private let openInPlace: Open?
    private var busy = false

    public init(bundleURL: URL, storage: SMBTemporaryStorage, servers: SMBSavedServerStore, passwords: SMBPasswordVault, activity: FileActivityGate,
        selectedDownloads: Bool = false, textReads: Bool = false, folderDownloads: Bool = false, freshUploads: Bool = false,
        folderUploads: Bool = false) {
        bundle = bundleURL; self.storage = storage; store = servers; vault = passwords; self.activity = activity
        remembering = SMBServerRemembering(store: servers, vault: passwords)
        prepare = { address, bundle, activity in try await SMBPreparedConnection.prepareValidated(address, bundleURL: bundle, activity: activity) }
        open = { bundle, request, endpoint, storage, activity, password in
            try await SMBBrowserSession.connectPrepared(bundleURL: bundle, request: request, endpoint: endpoint, storage: storage,
                activity: activity, password: password, selectedDownloads: selectedDownloads, textReads: textReads, folderDownloads: folderDownloads,
                freshUploads: freshUploads, folderUploads: folderUploads)
        }
        openInPlace = { bundle, request, endpoint, storage, activity, password in
            try await SMBBrowserSession.connectPrepared(bundleURL: bundle, request: request, endpoint: endpoint, storage: storage,
                activity: activity, password: password, selectedDownloads: selectedDownloads, folderDownloads: folderDownloads,
                freshUploads: freshUploads, folderUploads: folderUploads, inPlaceTextEdits: true)
        }
    }
    /// Actual same orchestration with injected preparation/open failures for
    /// offline controls. The production initializer always uses real modules.
    init(bundleURL: URL, storage: SMBTemporaryStorage, servers: SMBSavedServerStore, passwords: SMBPasswordVault,
         activity: FileActivityGate, prepare: @escaping Prepare, open: @escaping Open) {
        bundle = bundleURL; self.storage = storage; store = servers; vault = passwords; self.activity = activity
        remembering = SMBServerRemembering(store: servers, vault: passwords); self.prepare = prepare; self.open = open
        openInPlace = nil
    }
    public func inspect() async throws -> SMBServerSnapshot? {
        guard !busy else { throw SMBServerStoreFailure.busy }
        return try await store.inspect()
    }
    public func updatePresentation(id: UUID, expectedRevision: UInt64, label: String,
                                   components: [SMBRemoteName]) async throws -> SMBServerMutation {
        try await editMetadata(.updatePresentation(id, label: label, components: components), revision: expectedRevision)
    }
    public func saveMetadata(_ draft: SMBServerDraft, expectedRevision: UInt64) async throws -> SMBServerMutation {
        try await editMetadata(.saveServer(draft, id: nil, credentialID: nil), revision: expectedRevision)
    }
    private func editMetadata(_ change: SMBServerChange, revision: UInt64) async throws -> SMBServerMutation {
        guard !busy else { throw SMBServerStoreFailure.busy }; try Task.checkCancellation(); busy = true
        do {
            let snapshot = try await store.openForExplicitWrite().snapshot
            guard snapshot.revision == revision else { throw SMBServerStoreFailure.staleRevision }
            try Task.checkCancellation()
            let value = try await store.apply(change, expectedRevision: revision)
            await store.close(); busy = false; return value
        } catch { await store.close(); busy = false; throw error }
    }
    /// Explicit reviewed discard of an interrupted settings stage, retaining
    /// the last committed catalog and all durable password cleanup claims.
    public func discardInterruptedPreferencesUpdate() async throws {
        guard !busy else { throw SMBServerStoreFailure.busy }
        busy = true; defer { busy = false }
        do { _ = try await store.openForExplicitWrite(discardUncommittedStage: true) }
        catch { await store.close(); throw error }
        await store.close()
    }
    public func drain() async { await vault.drain(); await store.close() }
    public func connect(_ request: SMBServerDraft, typedPassword: SMBPassword?, savedServerID: UUID?,
                        rememberServer: Bool, rememberPassword: Bool,
                        inPlaceTextEdits: Bool = false,
                        metadataStorage: SMBTemporaryStorage? = nil) async throws -> SMBConnectionOutcome {
        guard !busy else { throw SMBBrowserFailure.busy }
        try Task.checkCancellation(); try request.validate()
        let selectedStorage = metadataStorage ?? storage
        if let metadataStorage {
            guard metadataStorage.directory == storage.directory,
                  let original = storage.workspaceWitness, let updated = metadataStorage.workspaceWitness,
                  original.paths == updated.paths, updated.access == .connection,
                  updated.record.locationDigest == original.record.locationDigest else {
                throw SMBBrowserFailure.unavailable
            }
        }
        if inPlaceTextEdits {
            guard request.security == .encrypted, request.effectiveTransferPreference != .readOnly,
                  openInPlace != nil, selectedStorage.workspaceWitness?.record.format == 4 else {
                throw SMBBrowserFailure.unavailable
            }
        }
        busy = true; defer { busy = false }
        // Resolution finishes before any saved secret is queried. Its numeric
        // target is immutable through the following credential/network awaits.
        let endpoint = try await prepare(request.address, bundle, activity)
        try endpoint.validate(for: request); try Task.checkCancellation()
        let password: SMBPassword
        if let typedPassword { password = typedPassword }
        else {
            guard let snapshot = try await store.inspect() else { throw SMBPasswordFailure.missing }
            let binding = try request.credentialBinding()
            let claim: SMBOwnedCredential
            if let id = savedServerID {
                guard let saved = snapshot.visibleServers.first(where: { $0.id == id }), let credentialID = saved.credentialID,
                      let found = snapshot.credentials.first(where: { $0.reference.id == credentialID && $0.state == .ready }) else {
                    throw SMBPasswordFailure.missing
                }
                claim = found
            } else {
                // Password-only remembering is independent of saved servers.
                // An explicit Connect may use the latest completed exact-bound
                // claim; failed authentication never tries older passwords.
                guard let found = snapshot.credentials.last(where: { $0.state == .ready && $0.reference.bindingDigest == binding.digest }) else {
                    throw SMBPasswordFailure.missing
                }
                claim = found
            }
            guard claim.reference.bindingDigest == binding.digest else { throw SMBPasswordFailure.bindingMismatch }
            password = try await vault.password(claim.reference, binding: binding)
        }
        try Task.checkCancellation(); try endpoint.validate(for: request)
        let session = try await (inPlaceTextEdits ? openInPlace! : open)(bundle, request, endpoint, selectedStorage, activity, password)
        if Task.isCancelled { _ = await session.close(); throw SMBBrowserFailure.stopped }
        // A successful handshake is the first authority for remembering. Once a
        // save starts, return its actual outcome even when Cancel arrives late;
        // the form drains/discards the unpublished session and reports the save.
        let saved = await remembering.rememberAuthenticated(request, password: password,
            server: rememberServer, savePassword: rememberPassword, editing: savedServerID)
        return SMBConnectionOutcome(session: session, remembering: saved)
    }
    public func forget(_ target: ForgetTarget) async -> SMBRememberingOutcome {
        guard !busy else {
            var outcome = SMBRememberingOutcome(); outcome.storeFailure = .busy
            switch target {
            case let .server(_, remove): outcome.server = .incomplete; outcome.password = remove ? .incomplete : .notRequested
            case .password: outcome.password = .incomplete
            }
            return outcome
        }
        busy = true; defer { busy = false }
        switch target {
        case let .server(id, remove): return await remembering.forget(.server(id, removePassword: remove))
        case let .password(id): return await remembering.forget(.password(id))
        }
    }
    public func forgetPasswords(for request: SMBServerDraft) async -> SMBRememberingOutcome {
        var outcome = SMBRememberingOutcome(password: .incomplete)
        guard !busy else { outcome.storeFailure = .busy; return outcome }
        busy = true; defer { busy = false }
        do {
            try request.validate()
            let binding = try request.credentialBinding(), snapshot = try await store.inspect()
            let matches = snapshot?.credentials.filter { $0.reference.bindingDigest == binding.digest } ?? []
            for claim in matches {
                let removed = await remembering.forget(.password(claim.reference.id))
                if removed.password != .complete { return removed }
            }
            outcome.password = .complete
        } catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
        return outcome
    }
}
