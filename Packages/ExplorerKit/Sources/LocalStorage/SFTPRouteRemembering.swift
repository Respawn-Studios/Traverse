import CryptoKit
import Foundation

/// Constructed inside the serial worker owner from its live decoder evidence.
/// A saved route or displayed fingerprint alone cannot produce this authority.
struct SFTPVerifiedRoutePeer: Sendable {
    let route: SFTPRouteDescription
    let role: SFTPRouteRole
    let context: SFTPVerifiedSessionContext
    let jumpKey: SFTPHostKey
    var binding: SFTPCredentialBinding {
        get throws {
            try validate()
            return try route.passwordBinding(role: role, verifiedJumpKeyDigest: Data(SHA256.hash(data: jumpKey.bytes)),
                peerKeyDigest: Data(SHA256.hash(data: context.key.bytes)))
        }
    }
    func validate() throws {
        let request = try route.request(for: role)
        guard !context.permitsSavedAuthentication, context.host == request.address.host,
              context.port == request.address.port, context.requestedScopeID == request.address.scopeID,
              Data(context.account.utf8) == Data(request.account.utf8),
              context.routeKeyBinding == (try route.bindingTag(role: role, verifiedJumpKeyDigest: Data(SHA256.hash(data: jumpKey.bytes)))),
              role != .jump || context.key == jumpKey else { throw SFTPSettingsFailure.invalidRecord }
    }
}

/// Storage mechanics share the existing coordinator's admission, writer,
/// durability barriers and exact password ownership. No UI or network work.
enum SFTPRouteStorage {
    private static func savedPeer(_ peer: SFTPVerifiedRoutePeer, id: UUID, store: SFTPSettingsStore) async throws -> SFTPSavedRouteEndpoint {
        try peer.validate()
        guard !Task.isCancelled else { throw SFTPSettingsFailure.cancelled }
        guard let snapshot = try await store.inspect(), let saved = snapshot.visibleRoutes.first(where: { $0.id == id }),
              saved.details.authorityDigest == peer.route.authorityDigest else { throw SFTPSettingsFailure.missing }
        guard saved.jump.key == peer.jumpKey, saved.endpoint(peer.role).key == peer.context.key else { throw SFTPSessionFailure.keyChanged }
        return saved.endpoint(peer.role)
    }
    static func password(_ peer: SFTPVerifiedRoutePeer, id: UUID, store: SFTPSettingsStore, vault: SFTPPasswordVault) async throws -> SFTPPassword {
        let endpoint = try await savedPeer(peer, id: id, store: store)
        guard endpoint.signIn == .password, let credentialID = endpoint.credentialID,
              let claim = try await store.inspect()?.credentials.first(where: { $0.reference.id == credentialID && $0.state == .ready }) else { throw SFTPPasswordFailure.missing }
        let binding = try peer.binding
        guard claim.reference.bindingDigest == binding.digest, claim.reference.hostKeyDigest == binding.hostKeyDigest else { throw SFTPPasswordFailure.bindingMismatch }
        return try await vault.password(claim.reference, binding: binding)
    }
    static func key(_ peer: SFTPVerifiedRoutePeer, id: UUID, store: SFTPSettingsStore) async throws -> SFTPSelectedPrivateKey {
        let endpoint = try await savedPeer(peer, id: id, store: store)
        guard endpoint.signIn.usesKey, let reference = endpoint.keyAccess,
              try reference.matches(peer.route.request(for: peer.role), host: peer.context.key, routeBinding: peer.context.routeKeyBinding) else { throw SFTPSettingsFailure.missing }
        return try SFTPSelectedPrivateKey(reference: reference)
    }
    static func remember(_ route: SFTPRouteDescription, jump: SFTPSavedRouteEndpoint, destination: SFTPSavedRouteEndpoint,
        passwords: [SFTPRouteRole: SFTPPassword], editing: UUID?, store: SFTPSettingsStore, vault: SFTPPasswordVault) async -> SFTPRememberingOutcome {
        var outcome = SFTPRememberingOutcome(server: .incomplete, password: passwords.isEmpty ? .notRequested : .incomplete)
        do {
            try route.validate()
            var snapshot = try await store.openForExplicitWrite().snapshot
            guard !snapshot.forgetAllPending else { throw SFTPSettingsFailure.recoveryRequired }
            if let editing { guard snapshot.visibleRoutes.contains(where: { $0.id == editing }) else { throw SFTPSettingsFailure.missing } }
            var peers: [SFTPRouteRole: SFTPSavedRouteEndpoint] = [.jump: jump, .destination: destination]
            let candidate = SFTPSavedRoute(id: editing ?? UUID(), details: route, jump: jump, destination: destination, removalPending: false)
            try candidate.validate()
            var passwordFailed = false
            for role in [SFTPRouteRole.jump, .destination] {
                guard var endpoint = peers[role] else { throw SFTPSettingsFailure.invalidRecord }
                let binding = try candidate.binding(role)
                if let password = passwords[role] {
                    guard endpoint.signIn == .password else { throw SFTPSettingsFailure.invalidRecord }
                    try Task.checkCancellation()
                    let intent = try await store.apply(.beginPassword(binding), revision: snapshot.revision); snapshot = intent.snapshot
                    guard let reference = intent.credential else { throw SFTPSettingsFailure.invalidRecord }
                    do {
                        try Task.checkCancellation()
                        let result = try await vault.save(password, reference: reference, binding: binding)
                        snapshot = try await Task.detached { [store, revision = snapshot.revision] in
                            try await store.apply(.confirmPassword(reference.id), revision: revision)
                        }.value.snapshot
                        endpoint.credentialID = reference.id
                        outcome.completedAfterCancellation = outcome.completedAfterCancellation || result.completedAfterCancellation || Task.isCancelled
                    } catch let failure as SFTPPasswordFailure { passwordFailed = true; outcome.passwordFailure = failure }
                } else if endpoint.signIn == .password, let editing,
                    let previous = snapshot.visibleRoutes.first(where: { $0.id == editing })?.endpoint(role).credentialID,
                    snapshot.credentials.contains(where: { $0.reference.id == previous && $0.state == .ready && $0.reference.bindingDigest == binding.digest }) {
                    endpoint.credentialID = previous
                }
                peers[role] = endpoint
            }
            if !passwords.isEmpty && !passwordFailed { outcome.password = .complete }
            try Task.checkCancellation()
            guard let outer = peers[.jump], let inner = peers[.destination] else { throw SFTPSettingsFailure.invalidRecord }
            let saved = try await store.apply(.saveRoute(route, jump: outer, destination: inner, id: editing), revision: snapshot.revision)
            outcome.server = .complete; outcome.routeID = saved.routeID
            outcome.completedAfterCancellation = outcome.completedAfterCancellation || saved.completedAfterCancellation
        } catch { outcome.settingsFailure = Task.isCancelled ? .cancelled : error as? SFTPSettingsFailure ?? .unavailable }
        return outcome
    }
}
