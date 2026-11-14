import Foundation

@_spi(Qualification) public enum SMBRememberingStatus: Sendable, Equatable { case notRequested, complete, incomplete }
@_spi(Qualification) public struct SMBRememberingOutcome: Sendable {
    public internal(set) var server: SMBRememberingStatus = .notRequested
    public internal(set) var password: SMBRememberingStatus = .notRequested
    public internal(set) var serverID: UUID?
    public internal(set) var credential: SMBCredentialReference?
    public internal(set) var storeFailure: SMBServerStoreFailure?
    public internal(set) var passwordFailure: SMBPasswordFailure?
    public internal(set) var completedAfterCancellation = false
}

/// The SMB session calls raw Remember only after actual authentication and
/// admission. Saved-server management may inspect metadata and Forget an exact
/// confirmed record through SPI without constructing a connection coordinator.
/// An actor-level busy flag spans awaits; serial native backends alone cannot
/// prevent a Forget from interleaving with an unfinished password save.
@_spi(Qualification) public actor SMBServerRemembering {
    private let store: SMBSavedServerStore
    private let vault: SMBPasswordVault
    private var busy = false
    public init(store: SMBSavedServerStore, vault: SMBPasswordVault) { self.store = store; self.vault = vault }

    /// Metadata-only access for saved-server management before a connection
    /// workspace or network session has been prepared.
    public func inspect() async throws -> SMBServerSnapshot? {
        guard !busy else { throw SMBServerStoreFailure.busy }
        return try await store.inspect()
    }

    /// A confirmation is valid only for the exact record that was displayed.
    /// The writer checks it again under its exclusive owner before hiding it.
    public func forget(server expected: SMBSavedServer, removePassword: Bool) async -> SMBRememberingOutcome {
        await forget(.server(expected.id, removePassword: removePassword), expectedServer: expected)
    }

    func rememberAuthenticated(_ draft: SMBServerDraft, password: SMBPassword, server: Bool, savePassword: Bool, editing: UUID? = nil) async -> SMBRememberingOutcome {
        var outcome = SMBRememberingOutcome(server: server ? .incomplete : .notRequested, password: savePassword ? .incomplete : .notRequested)
        guard server || savePassword else { return outcome }
        guard !busy else { outcome.storeFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.storeFailure = .cancelled; return outcome }
        busy = true
        do {
            var snapshot = try await store.openForExplicitWrite().snapshot
            if savePassword {
                do {
                    let intent = try await store.apply(.beginPassword(draft.credentialBinding()), expectedRevision: snapshot.revision)
                    snapshot = intent.snapshot
                    guard let reference = intent.credentialReference else { throw SMBServerStoreFailure.invalidRecord }
                    guard !Task.isCancelled else { throw SMBServerStoreFailure.cancelled }
                    let saved = try await vault.save(password, reference: reference, binding: draft.credentialBinding())
                    // Once Keychain actually mutated, finish its durable claim
                    // even if Cancel arrived during SecItem. Never lose cleanup
                    // authority or report that the saved password disappeared.
                    let confirmed = try await finishing(.confirmPassword(reference.id), revision: snapshot.revision)
                    snapshot = confirmed.snapshot; outcome.credential = reference; outcome.password = .complete
                    outcome.completedAfterCancellation = saved.completedAfterCancellation || Task.isCancelled
                } catch let error as SMBPasswordFailure { outcome.passwordFailure = error }
                catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
            }
            if server && !Task.isCancelled {
                do {
                    var credentialID = outcome.credential?.id
                    if credentialID == nil, let editing,
                       let existing = snapshot.visibleServers.first(where: { $0.id == editing }),
                       let previous = existing.credentialID,
                       let claim = snapshot.credentials.first(where: { $0.reference.id == previous && $0.state == .ready }),
                       claim.reference.bindingDigest == (try draft.credentialBinding()).digest {
                        // Remember Server does not mean Forget Password. Keep
                        // its completed reference only for the exact binding;
                        // changed endpoint/account details never borrow it.
                        credentialID = previous
                    }
                    let saved = try await store.apply(.saveServer(draft, id: editing, credentialID: credentialID), expectedRevision: snapshot.revision)
                    outcome.server = .complete; outcome.serverID = saved.serverID
                    outcome.completedAfterCancellation = outcome.completedAfterCancellation || saved.completedAfterCancellation
                } catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
            }
        } catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
        await vault.drain(); await store.close(); busy = false
        return outcome
    }

    enum ForgetTarget: Sendable { case server(UUID, removePassword: Bool), password(UUID) }
    func forget(_ target: ForgetTarget) async -> SMBRememberingOutcome {
        await forget(target, expectedServer: nil)
    }
    private func forget(_ target: ForgetTarget, expectedServer: SMBSavedServer?) async -> SMBRememberingOutcome {
        var outcome = SMBRememberingOutcome()
        switch target {
        case let .server(_, remove): outcome.server = .incomplete; outcome.password = remove ? .incomplete : .notRequested
        case .password: outcome.password = .incomplete
        }
        guard !busy else { outcome.storeFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.storeFailure = .cancelled; return outcome }
        busy = true
        do {
            var snapshot = try await store.openForExplicitWrite().snapshot
            let reference: SMBCredentialReference?
            let serverID: UUID?
            switch target {
            case let .server(id, remove):
                guard let saved = snapshot.servers.first(where: { $0.id == id }) else { throw SMBServerStoreFailure.missing }
                if let expectedServer {
                    guard saved == expectedServer, !saved.removalPending else { throw SMBServerStoreFailure.staleRevision }
                }
                reference = remove ? snapshot.credentials.first(where: { $0.reference.id == saved.credentialID })?.reference : nil
                serverID = id
                let change: SMBServerChange = expectedServer.map { .beginForgetExpectedServer($0, removePassword: remove) }
                    ?? .beginForgetServer(id, removePassword: remove)
                snapshot = try await store.apply(change, expectedRevision: snapshot.revision).snapshot
                if remove && reference == nil { outcome.password = .complete } // No linked password was requested for deletion.
            case let .password(id):
                guard let claim = snapshot.credentials.first(where: { $0.reference.id == id }) else { throw SMBServerStoreFailure.missing }
                reference = claim.reference; serverID = nil
                snapshot = try await store.apply(.beginForgetPassword(id), expectedRevision: snapshot.revision).snapshot
            }
            if let reference {
                do {
                    await vault.drain()
                    let removed = try await Task.detached { [vault] in try await vault.removeOwned(reference) }.value
                    snapshot = try await finishing(.finishForgetPassword(reference.id), revision: snapshot.revision).snapshot
                    outcome.password = .complete
                    outcome.completedAfterCancellation = removed.completedAfterCancellation || Task.isCancelled
                } catch let error as SMBPasswordFailure { outcome.passwordFailure = error }
                catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
            }
            if let serverID {
                do {
                    _ = try await finishing(.finishForgetServer(serverID), revision: snapshot.revision)
                    outcome.server = .complete
                } catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
            }
        } catch { outcome.storeFailure = error as? SMBServerStoreFailure ?? .unavailable }
        await vault.drain(); await store.close(); busy = false
        return outcome
    }
    private func finishing(_ change: SMBServerChange, revision: UInt64) async throws -> SMBServerMutation {
        // At most one finishing task per coordinator. This is admitted work,
        // retained through its real file-queue drain, not fire-and-forget cleanup.
        try await Task.detached { [store] in try await store.apply(change, expectedRevision: revision) }.value
    }
}
