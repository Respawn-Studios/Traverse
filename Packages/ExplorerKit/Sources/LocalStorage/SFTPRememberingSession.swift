import Foundation

extension SFTPVerifiedSessionContext {
    func request() throws -> SFTPConnectionRequest {
        guard permitsSavedAuthentication, routeKeyBinding == nil else { throw SFTPSessionFailure.input }
        return try describedRequest()
    }
    var permitsKeyReference: Bool { permitsSavedAuthentication && routeKeyBinding == nil || routeKeyBinding?.count == 32 }
    func keyAccessRequest() throws -> SFTPConnectionRequest {
        guard permitsKeyReference else { throw SFTPSessionFailure.input }; return try describedRequest()
    }
    func certificateAccessRequest() throws -> SFTPConnectionRequest {
        guard authenticatedWithUserCertificate, authenticatedIdentity != nil, routeKeyBinding == nil else {
            throw SFTPSessionFailure.input
        }
        return try describedRequest()
    }
    private func describedRequest() throws -> SFTPConnectionRequest {
        let authority = host.contains(":") ? "[\(host)\(requestedScopeID == 0 ? "" : "%25\(requestedScopeID)")]:\(port)" : "\(host):\(port)"
        return try .init(address: .init("sftp://" + authority), account: account)
    }
    func matches(_ request: SFTPConnectionRequest) -> Bool {
        permitsSavedAuthentication && routeKeyBinding == nil && request.address.host == host && request.address.port == port && request.address.scopeID == requestedScopeID && Data(request.account.utf8) == Data(account.utf8)
    }
    func matchesCertificate(_ request: SFTPConnectionRequest) -> Bool {
        authenticatedWithUserCertificate && routeKeyBinding == nil && request.address.host == host
            && request.address.port == port && request.address.scopeID == requestedScopeID
            && Data(request.account.utf8) == Data(account.utf8)
    }
}
extension SFTPWorkerSession {
    @_spi(Qualification) public func rememberAuthenticatedKey(_ draft: SFTPServerDraft, key: SFTPSelectedPrivateKey,
        profileAlias: String?, using state: SFTPRememberedState, rememberServer: Bool, rememberKey: Bool, editing: UUID?,
        serverPrompts: Bool = false) async throws -> SFTPRememberingOutcome {
        let context = try await memoryContext(requireAuthenticated: true)
        guard context.matches(try draft.request), context.authenticatedIdentity != nil, !rememberKey || rememberServer,
              !serverPrompts || context.usedServerPrompts else { throw SFTPSettingsFailure.invalidRecord }
        var reference: SFTPKeyAccessReference?, failed = false
        if rememberKey {
            do { reference = try await referenceAfterAuthentication(key) }
            catch { failed = true }
        }
        let method = try SFTPServerKeyAuthentication(reference: reference, profileAlias: profileAlias, requiresServerPrompts: serverPrompts)
        var result = await state.rememberAuthenticatedKey(draft, method: method, server: rememberServer, editing: editing)
        if rememberKey { result.keyAccess = !failed && result.server == .complete ? .complete : .incomplete }
        return result
    }
    /// Persist a certificate-required method even when access is not remembered.
    /// A failed bookmark never becomes a key-only saved method.
    @_spi(Qualification) public func rememberAuthenticatedCertificate(_ draft: SFTPServerDraft,
        key: SFTPSelectedPrivateKey, certificate: SFTPSelectedUserCertificate, profileAlias: String?,
        using state: SFTPRememberedState, rememberServer: Bool, rememberAccess: Bool, editing: UUID?,
        serverPrompts: Bool) async throws -> SFTPRememberingOutcome {
        let context = try await memoryContext(requireAuthenticated: true)
        guard context.matchesCertificate(try draft.request), context.authenticatedSelectionID == key.selectionID,
              context.authenticatedCertificateSelectionID == certificate.selectionID,
              context.usedServerPrompts == serverPrompts, !rememberAccess || rememberServer else {
            throw SFTPSettingsFailure.invalidRecord
        }
        guard rememberServer else { return SFTPRememberingOutcome() }
        var references: (SFTPKeyAccessReference, SFTPCertificateAccessReference)?
        var accessFailure: SFTPCertificateAccessFailure?
        if rememberAccess {
            do { references = try await referencesAfterCertificateAuthentication(key: key, certificate: certificate) }
            catch { accessFailure = error as? SFTPCertificateAccessFailure }
        }
        let method = try SFTPServerKeyAuthentication(reference: references?.0, certificate: references?.1,
            profileAlias: profileAlias, requiresServerPrompts: serverPrompts, requiresCertificate: true)
        var outcome = await state.rememberAuthenticatedKey(draft, method: method, server: true, editing: editing)
        if rememberAccess { outcome.keyAccess = references != nil && outcome.server == .complete ? .complete : .incomplete }
        outcome.certificateAccessFailure = accessFailure
        return outcome
    }
    @_spi(Qualification) public func rememberAuthenticatedInteractive(_ draft: SFTPServerDraft, using state: SFTPRememberedState,
        rememberServer: Bool, editing: UUID?) async throws -> SFTPRememberingOutcome {
        let context = try await memoryContext(requireAuthenticated: true)
        guard context.matches(try draft.request), context.usedServerPrompts, context.authenticatedIdentity == nil else { throw SFTPSettingsFailure.invalidRecord }
        return await state.rememberAuthenticatedInteractive(draft, server: rememberServer, editing: editing)
    }
    /// Saving trust requires this exact live worker's completed verification and
    /// its explicit Remember/Replace action. A rendered fingerprint is not proof.
    @_spi(Qualification) public func rememberVerifiedHost(using state: SFTPRememberedState) async throws -> SFTPRememberingOutcome {
        let context = try await memoryContext(requireAuthenticated: false)
        guard context.permitsRememberingHost else { throw SFTPSettingsFailure.invalidRecord }
        return await state.rememberVerified(identity: SFTPHostIdentity(address: try context.request().address), key: context.key, previous: context.previous)
    }
    /// No Keychain lookup can precede the actual worker's verification event.
    @_spi(Qualification) public func authenticateSaved(using state: SFTPRememberedState, serverID: UUID?) async throws {
        let context = try await memoryContext(requireAuthenticated: false)
        let password = try await state.passwordForVerified(context.request(), key: context.key, serverID: serverID)
        try await authenticate(password)
    }
    /// Keep a retrieved secret inside the session/storage layer. Native setup
    /// receives only the authenticated result and truthful remembering statuses.
    @_spi(Qualification) public func authenticateSavedAndRemember(_ draft: SFTPServerDraft, using state: SFTPRememberedState,
        serverID: UUID?, rememberServer: Bool, rememberPassword: Bool) async throws -> SFTPRememberingOutcome {
        let context = try await memoryContext(requireAuthenticated: false)
        guard context.matches(try draft.request) else { throw SFTPSettingsFailure.invalidRecord }
        let password = try await state.passwordForVerified(draft.request, key: context.key, serverID: serverID)
        try await authenticate(password)
        return try await rememberAuthenticatedServer(draft, password: password, using: state,
            rememberServer: rememberServer, rememberPassword: rememberPassword, editing: serverID)
    }
    @_spi(Qualification) public func rememberAuthenticatedServer(_ draft: SFTPServerDraft, password: SFTPPassword,
        using state: SFTPRememberedState, rememberServer: Bool, rememberPassword: Bool, editing: UUID?) async throws -> SFTPRememberingOutcome {
        let context = try await memoryContext(requireAuthenticated: true)
        guard context.matches(try draft.request) else { throw SFTPSettingsFailure.invalidRecord }
        return await state.rememberAuthenticated(draft, key: context.key, password: password, server: rememberServer, savePassword: rememberPassword, editing: editing)
    }
}
