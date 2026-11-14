import Foundation

@_spi(Qualification) public enum SFTPRememberingStatus: Sendable, Equatable { case notRequested, complete, incomplete }
@_spi(Qualification) public struct SFTPRememberingOutcome: Sendable {
    public internal(set) var host: SFTPRememberingStatus = .notRequested
    public internal(set) var server: SFTPRememberingStatus = .notRequested
    public internal(set) var password: SFTPRememberingStatus = .notRequested
    public internal(set) var keyAccess: SFTPRememberingStatus = .notRequested
    public internal(set) var serverID: UUID?
    public internal(set) var routeID: UUID?
    public internal(set) var credential: SFTPCredentialReference?
    public internal(set) var settingsFailure: SFTPSettingsFailure?
    public internal(set) var passwordFailure: SFTPPasswordFailure?
    public internal(set) var certificateAccessFailure: SFTPCertificateAccessFailure?
    public internal(set) var completedAfterCancellation = false
}

/// One coordinator spans file/Keychain awaits. Raw Remember entry points are
/// internal: the worker owner must supply actual verified/authenticated evidence.
/// Startup/inspection never creates metadata or queries a saved password.
@_spi(Qualification) public actor SFTPRememberedState {
    public enum ForgetTarget: Sendable {
        case host(SFTPHostIdentity), server(UUID, removePassword: Bool), route(UUID, removePasswords: Bool), password(UUID), all
    }
    private let store: SFTPSettingsStore
    private let vault: SFTPPasswordVault
    private var busy = false
    private var drains = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public init(settings: SFTPSettingsStore, passwords: SFTPPasswordVault) { store = settings; vault = passwords }
    public func inspect() async throws -> SFTPSettingsSnapshot? {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }; return try await store.inspect()
    }
    /// Explicit metadata-only edits never open the password vault/key bookmark.
    public func updatePresentation(id: UUID, route: Bool = false, expectedRevision: UInt64,
                                   label: String, directory: SFTPDefaultDirectory,
                                   transferPreference: SFTPTransferPreference? = nil,
                                   expectedBinding: SFTPConnectionPreferenceBinding? = nil) async throws -> SFTPSettingsMutation {
        try await editMetadata(.updatePresentation(id, label: label, directory: directory, route: route,
            transferPreference: transferPreference, expectedBinding: expectedBinding), revision: expectedRevision)
    }
    public func saveMetadata(_ draft: SFTPServerDraft, expectedRevision: UInt64,
                             directory: SFTPDefaultDirectory, signIn: SFTPRouteSignIn = .password,
                             transferPreference: SFTPTransferPreference? = nil,
                             requiresCertificate: Bool = false) async throws -> SFTPSettingsMutation {
        try await editMetadata(.saveMetadata(draft, directory: directory, signIn: signIn,
            transferPreference: transferPreference, requiresCertificate: requiresCertificate), revision: expectedRevision)
    }
    private func editMetadata(_ change: SFTPSettingsChange, revision: UInt64) async throws -> SFTPSettingsMutation {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }
        try Task.checkCancellation(); busy = true
        do {
            let snapshot = try await store.openForExplicitWrite().snapshot
            guard snapshot.revision == revision else { throw SFTPSettingsFailure.staleRevision }
            try Task.checkCancellation()
            let result = try await store.apply(change, revision: revision)
            await store.close(); release(); return result
        } catch { await store.close(); release(); throw error }
    }
    public func discardInterruptedUpdate() async throws {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }; busy = true
        do { _ = try await store.openForExplicitWrite(discardUncommittedStage: true) }
        catch { await store.close(); release(); throw error }
        await store.close(); release()
    }
    func previousKey(for identity: SFTPHostIdentity) async throws -> SFTPHostKey? {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }; try identity.validate()
        return try await store.inspect()?.visibleHosts.first(where: { $0.identity == identity })?.key
    }
    func keyForVerified(_ request: SFTPConnectionRequest, key: SFTPHostKey, serverID: UUID) async throws -> SFTPSelectedPrivateKey {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }
        guard !Task.isCancelled else { throw SFTPSettingsFailure.cancelled }; busy = true
        do {
            guard let server = try await store.inspect()?.visibleServers.first(where: { $0.id == serverID }),
                  server.details.address == request.address, Data(server.details.account.utf8) == Data(request.account.utf8),
                  server.keyAuthentication?.requiresCertificate != true,
                  let reference = server.keyAuthentication?.reference else { throw SFTPSettingsFailure.missing }
            guard try reference.matches(request, host: key) else { throw SFTPSessionFailure.keyChanged }
            let selected = try SFTPSelectedPrivateKey(reference: reference); release(); return selected
        } catch { release(); throw error }
    }
    /// Retrieve both halves in one verified-state observation. A certificate
    /// method can never be exposed through the plain-key retrieval path.
    func certificatePairForVerified(_ request: SFTPConnectionRequest, key: SFTPHostKey,
                                    serverID: UUID) async throws -> (SFTPSelectedPrivateKey, SFTPSelectedUserCertificate) {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }
        guard !Task.isCancelled else { throw SFTPSettingsFailure.cancelled }; busy = true
        do {
            guard let server = try await store.inspect()?.visibleServers.first(where: { $0.id == serverID }),
                  server.details.address == request.address, Data(server.details.account.utf8) == Data(request.account.utf8),
                  let method = server.keyAuthentication, method.requiresCertificate,
                  let privateKey = method.reference, let certificate = method.certificate else {
                throw SFTPSettingsFailure.missing
            }
            guard privateKey.identity == certificate.identity,
                  try privateKey.matches(request, host: key),
                  try certificate.matches(request, host: key, identity: privateKey.identity) else {
                throw SFTPSessionFailure.keyChanged
            }
            let selectedKey = try SFTPSelectedPrivateKey(reference: privateKey)
            let selectedCertificate = try SFTPSelectedUserCertificate(reference: certificate)
            release(); return (selectedKey, selectedCertificate)
        } catch { release(); throw error }
    }
    func rememberVerified(identity: SFTPHostIdentity, key: SFTPHostKey, previous: SFTPHostKey?) async -> SFTPRememberingOutcome {
        var outcome = SFTPRememberingOutcome(host: .incomplete)
        guard !busy, drains == 0 else { outcome.settingsFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.settingsFailure = .cancelled; return outcome }; busy = true
        do {
            let snapshot = try await store.openForExplicitWrite().snapshot
            let result = try await store.apply(.saveHost(.init(identity: identity, key: key), replacing: previous), revision: snapshot.revision)
            outcome.host = .complete; outcome.completedAfterCancellation = result.completedAfterCancellation
        } catch { outcome.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
        await store.close(); release(); return outcome
    }
    func passwordForVerified(_ request: SFTPConnectionRequest, key: SFTPHostKey, serverID: UUID?) async throws -> SFTPPassword {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }; busy = true
        do {
            guard let snapshot = try await store.inspect(), !snapshot.forgetAllPending else { throw SFTPPasswordFailure.missing }
            let binding = try SFTPCredentialBinding(request: request, key: key)
            let claim: SFTPOwnedCredential
            if let serverID {
                guard let server = snapshot.visibleServers.first(where: { $0.id == serverID }), let id = server.credentialID,
                      let found = snapshot.credentials.first(where: { $0.reference.id == id && $0.state == .ready }) else { throw SFTPPasswordFailure.missing }
                claim = found
            } else {
                guard let found = snapshot.credentials.last(where: { $0.state == .ready && $0.reference.bindingDigest == binding.digest }) else { throw SFTPPasswordFailure.missing }
                claim = found
            }
            // Check key/peer/account before the first OS secret lookup.
            guard claim.reference.bindingDigest == binding.digest, claim.reference.hostKeyDigest == binding.hostKeyDigest else { throw SFTPPasswordFailure.bindingMismatch }
            let password = try await vault.password(claim.reference, binding: binding)
            await vault.drain(); release(); return password
        } catch { await vault.drain(); release(); throw error }
    }
    func rememberAuthenticated(_ draft: SFTPServerDraft, key: SFTPHostKey, password: SFTPPassword,
        server: Bool, savePassword: Bool, editing: UUID?) async -> SFTPRememberingOutcome {
        var outcome = SFTPRememberingOutcome(server: server ? .incomplete : .notRequested, password: savePassword ? .incomplete : .notRequested)
        guard server || savePassword else { return outcome }
        guard !busy, drains == 0 else { outcome.settingsFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.settingsFailure = .cancelled; return outcome }; busy = true
        do {
            try draft.validate(); let binding = try SFTPCredentialBinding(request: draft.request, key: key)
            var snapshot = try await store.openForExplicitWrite().snapshot
            if savePassword {
                do {
                    let intent = try await store.apply(.beginPassword(binding), revision: snapshot.revision); snapshot = intent.snapshot
                    guard let reference = intent.credential else { throw SFTPSettingsFailure.invalidRecord }
                    try Task.checkCancellation()
                    let saved = try await vault.save(password, reference: reference, binding: binding)
                    snapshot = try await finishing(.confirmPassword(reference.id), revision: snapshot.revision).snapshot
                    outcome.password = .complete; outcome.credential = reference
                    outcome.completedAfterCancellation = saved.completedAfterCancellation || Task.isCancelled
                } catch let failure as SFTPPasswordFailure { outcome.passwordFailure = failure }
                catch { outcome.settingsFailure = Task.isCancelled ? .cancelled : error as? SFTPSettingsFailure ?? .unavailable }
            }
            if server && !Task.isCancelled {
                do {
                    var credentialID = outcome.credential?.id
                    if credentialID == nil, let editing,
                       let previous = snapshot.visibleServers.first(where: { $0.id == editing })?.credentialID,
                       let claim = snapshot.credentials.first(where: { $0.reference.id == previous && $0.state == .ready }),
                       claim.reference.bindingDigest == binding.digest { credentialID = previous }
                    let saved = try await store.apply(.saveServer(draft, id: editing, credentialID: credentialID), revision: snapshot.revision)
                    outcome.server = .complete; outcome.serverID = saved.serverID
                    outcome.completedAfterCancellation = outcome.completedAfterCancellation || saved.completedAfterCancellation
                } catch { outcome.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
            }
        } catch { outcome.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
        await vault.drain(); await store.close(); release(); return outcome
    }
    func rememberAuthenticatedKey(_ draft: SFTPServerDraft, method: SFTPServerKeyAuthentication,
        server: Bool, editing: UUID?) async -> SFTPRememberingOutcome {
        var outcome = SFTPRememberingOutcome(server: server ? .incomplete : .notRequested)
        guard server else { return outcome }
        guard !busy, drains == 0 else { outcome.settingsFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.settingsFailure = .cancelled; return outcome }; busy = true
        do {
            try draft.validate(); try method.validate()
            let snapshot = try await store.openForExplicitWrite().snapshot
            // A prior password claim remains explicitly owned and can still be
            // forgotten, but is detached from the newly selected key method.
            // Never delete another credential as an incidental method change.
            let saved = try await store.apply(.saveServer(draft, id: editing, credentialID: nil, keyAuthentication: method), revision: snapshot.revision)
            outcome.server = .complete; outcome.serverID = saved.serverID
            outcome.completedAfterCancellation = saved.completedAfterCancellation
        } catch { outcome.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
        await store.close(); release(); return outcome
    }
    func rememberAuthenticatedInteractive(_ draft: SFTPServerDraft, server: Bool, editing: UUID?) async -> SFTPRememberingOutcome {
        var outcome = SFTPRememberingOutcome(server: server ? .incomplete : .notRequested)
        guard server else { return outcome }
        guard !busy, drains == 0 else { outcome.settingsFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.settingsFailure = .cancelled; return outcome }; busy = true
        do {
            try draft.validate(); let snapshot = try await store.openForExplicitWrite().snapshot
            let saved = try await store.apply(.saveServer(draft, id: editing, credentialID: nil, serverPrompts: true), revision: snapshot.revision)
            outcome.server = .complete; outcome.serverID = saved.serverID; outcome.completedAfterCancellation = saved.completedAfterCancellation
        } catch { outcome.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
        await store.close(); release(); return outcome
    }
    func passwordForVerifiedRoute(_ peer: SFTPVerifiedRoutePeer, id: UUID) async throws -> SFTPPassword {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }; busy = true
        do {
            let password = try await SFTPRouteStorage.password(peer, id: id, store: store, vault: vault)
            await vault.drain(); release(); return password
        } catch { await vault.drain(); release(); throw error }
    }
    func keyForVerifiedRoute(_ peer: SFTPVerifiedRoutePeer, id: UUID) async throws -> SFTPSelectedPrivateKey {
        guard !busy, drains == 0 else { throw SFTPSettingsFailure.busy }; busy = true
        do { let selected = try await SFTPRouteStorage.key(peer, id: id, store: store); release(); return selected }
        catch { release(); throw error }
    }
    func rememberAuthenticatedRoute(_ route: SFTPRouteDescription, jump: SFTPSavedRouteEndpoint, destination: SFTPSavedRouteEndpoint,
        passwords: [SFTPRouteRole: SFTPPassword], editing: UUID?) async -> SFTPRememberingOutcome {
        guard !busy, drains == 0 else { return .init(server: .incomplete, settingsFailure: .busy) }
        guard !Task.isCancelled else { return .init(server: .incomplete, settingsFailure: .cancelled) }; busy = true
        let outcome = await SFTPRouteStorage.remember(route, jump: jump, destination: destination, passwords: passwords,
            editing: editing, store: store, vault: vault)
        await vault.drain(); await store.close(); release(); return outcome
    }
    /// Forget only the exact server shown by the caller's confirmation. The
    /// settings writer compares the full saved value under its write owner.
    public func forget(server expected: SFTPSavedServer, removePassword: Bool) async -> SFTPRememberingOutcome {
        await forget(.server(expected.id, removePassword: removePassword), expectedServer: expected)
    }
    public func forget(route expected: SFTPSavedRoute, removePasswords: Bool) async -> SFTPRememberingOutcome {
        await forget(.route(expected.id, removePasswords: removePasswords), expectedRoute: expected)
    }
    public func forget(_ target: ForgetTarget) async -> SFTPRememberingOutcome {
        await forget(target, expectedServer: nil, expectedRoute: nil)
    }
    private func forget(_ target: ForgetTarget, expectedServer: SFTPSavedServer? = nil,
                        expectedRoute: SFTPSavedRoute? = nil) async -> SFTPRememberingOutcome {
        var outcome = SFTPRememberingOutcome()
        switch target {
        case .host: outcome.host = .incomplete
        case let .server(_, remove): outcome.server = .incomplete; outcome.password = remove ? .incomplete : .notRequested
        case let .route(_, remove): outcome.server = .incomplete; outcome.password = remove ? .incomplete : .notRequested
        case .password: outcome.password = .incomplete
        case .all: outcome.host = .incomplete; outcome.server = .incomplete; outcome.password = .incomplete
        }
        guard !busy, drains == 0 else { outcome.settingsFailure = .busy; return outcome }
        guard !Task.isCancelled else { outcome.settingsFailure = .cancelled; return outcome }; busy = true
        do {
            var snapshot = try await store.openForExplicitWrite().snapshot
            var references: [SFTPCredentialReference] = []; var serverID: UUID?, routeID: UUID?
            switch target {
            case let .host(identity):
                snapshot = try await store.apply(.forgetHost(identity), revision: snapshot.revision).snapshot; outcome.host = .complete
            case let .server(id, remove):
                guard let server = snapshot.servers.first(where: { $0.id == id }) else { throw SFTPSettingsFailure.missing }
                if let expectedServer {
                    guard server == expectedServer, !server.removalPending else { throw SFTPSettingsFailure.staleRevision }
                }
                if remove, let id = server.credentialID, let claim = snapshot.credentials.first(where: { $0.reference.id == id }) { references = [claim.reference] }
                let change: SFTPSettingsChange = expectedServer.map { .beginForgetExpectedServer($0, removePassword: remove) }
                    ?? .beginForgetServer(id, removePassword: remove)
                snapshot = try await store.apply(change, revision: snapshot.revision).snapshot; serverID = id
                if remove && references.isEmpty { outcome.password = .complete }
            case let .route(id, remove):
                guard let route = snapshot.routes?.first(where: { $0.id == id }) else { throw SFTPSettingsFailure.missing }
                if let expectedRoute {
                    guard route == expectedRoute, !route.removalPending else { throw SFTPSettingsFailure.staleRevision }
                }
                if remove {
                    let ids = Set([route.jump.credentialID, route.destination.credentialID].compactMap { $0 })
                    references = snapshot.credentials.filter { ids.contains($0.reference.id) }.map(\.reference)
                }
                let change: SFTPSettingsChange = expectedRoute.map { .beginForgetExpectedRoute($0, removePasswords: remove) }
                    ?? .beginForgetRoute(id, removePasswords: remove)
                snapshot = try await store.apply(change, revision: snapshot.revision).snapshot; routeID = id
                if remove && references.isEmpty { outcome.password = .complete }
            case let .password(id):
                guard let claim = snapshot.credentials.first(where: { $0.reference.id == id }) else { throw SFTPSettingsFailure.missing }
                references = [claim.reference]
                snapshot = try await store.apply(.beginForgetPassword(id), revision: snapshot.revision).snapshot
            case .all:
                snapshot = try await store.apply(.beginForgetAll, revision: snapshot.revision).snapshot
                references = snapshot.credentials.map(\.reference); outcome.host = .complete
            }
            for reference in references {
                await vault.drain()
                // The durable hidden/delete intent is already committed. Drain
                // the exact OS call even if the caller cancels after admission.
                let result = try await Task.detached { [vault] in try await vault.removeOwned(reference) }.value
                snapshot = try await finishing(.finishForgetPassword(reference.id), revision: snapshot.revision).snapshot
                outcome.completedAfterCancellation = outcome.completedAfterCancellation || result.completedAfterCancellation || Task.isCancelled
            }
            if !references.isEmpty { outcome.password = .complete }
            if let serverID { snapshot = try await finishing(.finishForgetServer(serverID), revision: snapshot.revision).snapshot; outcome.server = .complete }
            if let routeID { snapshot = try await finishing(.finishForgetRoute(routeID), revision: snapshot.revision).snapshot; outcome.server = .complete }
            if case .all = target {
                _ = try await finishing(.finishForgetAll, revision: snapshot.revision)
                outcome.host = .complete; outcome.server = .complete; outcome.password = .complete
            }
        } catch let failure as SFTPPasswordFailure { outcome.passwordFailure = failure }
        catch { outcome.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
        if outcome.host == .complete || outcome.server == .complete || outcome.password == .complete {
            outcome.completedAfterCancellation = outcome.completedAfterCancellation || Task.isCancelled
        }
        await vault.drain(); await store.close(); release(); return outcome
    }
    /// Explicit removal uses saved claim digests, never a password lookup and
    /// never the server's currently presented key as authority for another item.
    public func forgetPasswords(for request: SFTPConnectionRequest) async -> SFTPRememberingOutcome {
        var result = SFTPRememberingOutcome(password: .incomplete)
        do {
            let snapshot = try await inspect()
            let matches = try snapshot?.credentials.filter { claim in
                try SFTPCredentialBinding(request: request, keyDigest: claim.reference.hostKeyDigest).digest == claim.reference.bindingDigest
            } ?? []
            for claim in matches {
                let removed = await forget(.password(claim.reference.id))
                guard removed.password == .complete else { return removed }
            }
            result.password = .complete
        } catch { result.settingsFailure = error as? SFTPSettingsFailure ?? .unavailable }
        return result
    }
    private func finishing(_ change: SFTPSettingsChange, revision: UInt64) async throws -> SFTPSettingsMutation {
        try await Task.detached { [store] in try await store.apply(change, revision: revision) }.value
    }
    private func release() {
        busy = false
        let waiters = idleWaiters; idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    public func drain() async {
        drains += 1
        if busy { await withCheckedContinuation { idleWaiters.append($0) } }
        await vault.drain(); await store.close(); drains -= 1
    }
}
