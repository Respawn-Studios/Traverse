import AppKit
@_spi(Qualification) import LocalStorage

/// Own the actual native review through cancellation, a late save and uncertain
/// closure. The coordinator never accepts a fingerprint string as verification.
@MainActor final class SFTPSetupTrust {
    private(set) var controller: SFTPTrustWindowController?
    private var completion: CheckedContinuation<SFTPConnectionReview, Never>?
    func review(_ session: SFTPWorkerSession, remembered: SFTPRememberedState,
                address: SFTPConnectionAddress? = nil, rememberServer: Bool = false,
                allowsInteractiveReview: Bool = true,
                settings: BrowserSettings, owner: NSWindow?) async -> SFTPConnectionReview {
        if session.review.kind == .matching {
            // Re-read the exact durable host identity after the worker observed
            // its key. A forgotten or replaced record cannot silently approve
            // an in-flight connection or admit a Keychain read.
            guard let address, let snapshot = try? await remembered.inspect(),
                  Self.durableMatchingHost(session.review, address: address, snapshot: snapshot),
                  !Task.isCancelled else { return .init(verified: false) }
            do { try await session.approve(.useMatching); return .init(verified: true) }
            catch { return .init(verified: false) }
        }
        guard allowsInteractiveReview else { return .init(verified: false) }
        return await present(session.review, settings: settings, owner: owner,
            prefillRememberKey: rememberServer, decision: { intent in
            let action: SFTPTrustAction
            switch intent { case .connectOnce: action = .connectOnce; case .rememberVerified: action = .remember
            case .useMatching: action = .useMatching; case .replaceVerified: action = .replaceVerified }
            try await session.approve(action)
            guard action == .remember || action == .replaceVerified else { return .notRequested }
            let saved = try await session.rememberVerifiedHost(using: remembered)
            return saved.host == .complete ? .saved : .incomplete
        }, drain: { await session.close().localResourcesEnded })
    }
    static func durableMatchingHost(_ challenge: SFTPHostChallenge, address: SFTPConnectionAddress,
                                    snapshot: SFTPSettingsSnapshot) -> Bool {
        challenge.kind == .matching && challenge.host == address.host && challenge.port == address.port
            && snapshot.visibleHosts.contains {
                $0.identity == SFTPHostIdentity(address: address) && $0.key == challenge.current
            }
    }
    func reviewOnce(_ session: any SFTPAuthenticationReviewControl, heading: String,
                    settings: BrowserSettings, owner: NSWindow?) async -> SFTPConnectionReview {
        await present(session.review, settings: settings, owner: owner, allowsRemembering: false, heading: heading, decision: { intent in
            guard intent == .connectOnce else { throw SFTPSessionFailure.input }
            try await session.approve(.connectOnce); return .notRequested
        }, drain: { await session.close().localResourcesEnded })
    }
    func reviewRoute(_ session: any SFTPAuthenticationReviewControl, heading: String,
                     settings: BrowserSettings, owner: NSWindow?) async -> SFTPConnectionReview {
        await present(session.review, settings: settings, owner: owner, allowsRemembering: false, heading: heading, decision: { intent in
            let action: SFTPTrustAction
            switch intent {
            case .connectOnce: action = .connectOnce
            case .useMatching: action = .useMatching
            case .replaceVerified: action = .replaceVerified
            case .rememberVerified: throw SFTPSessionFailure.input
            }
            // Route identities are saved together only after both peers finish
            // authentication and the user chooses Remember this connection.
            try await session.approve(action); return .notRequested
        }, drain: { await session.close().localResourcesEnded })
    }
    func reviewSavedRoute(_ session: any SFTPAuthenticationReviewControl, role: SFTPRouteRole,
                          route: SFTPRouteDescription, routeID: UUID?, remembered: SFTPRememberedState,
                          allowsInteractiveReview: Bool = true, settings: BrowserSettings, owner: NSWindow?) async -> SFTPConnectionReview {
        if session.review.kind == .matching {
            let address = role == .jump ? route.jump.address : route.destination.address
            guard let routeID, session.review.host == address.host, session.review.port == address.port,
                  let snapshot = try? await remembered.inspect(),
                  let saved = snapshot.visibleRoutes.first(where: { $0.id == routeID }),
                  WorkspaceConnectionBinding.route(saved.details) == WorkspaceConnectionBinding.route(route),
                  (role == .jump ? saved.jump.key : saved.destination.key) == session.review.current,
                  !Task.isCancelled else { return .init(verified: false) }
            do { try await session.approve(.useMatching); return .init(verified: true) }
            catch { return .init(verified: false) }
        }
        guard allowsInteractiveReview else { return .init(verified: false) }
        return await reviewRoute(session, heading: role == .jump ? "Verify jump host" : "Verify destination server",
            settings: settings, owner: owner)
    }
    private func present(_ challenge: SFTPHostChallenge, settings: BrowserSettings, owner: NSWindow?,
        allowsRemembering: Bool = true, prefillRememberKey: Bool = false, heading: String? = nil,
        decision: @escaping SFTPTrustModel.Decision, drain: @escaping @MainActor () async -> Bool) async -> SFTPConnectionReview {
        guard controller == nil, !Task.isCancelled else { return .init(verified: false) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                let algorithm: String
                switch challenge.current.algorithm {
                case "ssh-ed25519": algorithm = "Ed25519"
                case "ecdsa-sha2-nistp256": algorithm = "ECDSA P-256"
                case "ecdsa-sha2-nistp384": algorithm = "ECDSA P-384"
                case "ecdsa-sha2-nistp521": algorithm = "ECDSA P-521"
                default: algorithm = "RSA"
                }
                let model = SFTPTrustModel(review: .init(host: challenge.host, port: challenge.port,
                    fingerprint: challenge.current.fingerprint, previousFingerprint: challenge.previous?.fingerprint,
                    algorithm: algorithm, heading: heading), allowsRemembering: allowsRemembering,
                    prefillRememberKey: prefillRememberKey, decision: decision, drain: drain)
                let window = SFTPTrustWindowController(settings: settings, model: model); controller = window
                window.onFinished = { [weak self, weak window] outcome in
                    guard let self, let window else { return }
                    complete(verified: outcome == .verified, remembering: window.model.remembering)
                    window.close(); controller = nil
                }
                model.onClosureAttention = { [weak self, weak model] in
                    guard let self, let model else { return }
                    complete(verified: false, remembering: model.remembering)
                    // Keep this window and its retry action until actual drain.
                }
                window.present(relativeTo: owner)
                if Task.isCancelled { model.cancel() }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.controller?.model.cancel() } }
    }
    private func complete(verified: Bool, remembering: SFTPTrustRemembering) {
        let status: SFTPRememberingStatus
        switch remembering { case .notRequested: status = .notRequested; case .saved: status = .complete; case .incomplete: status = .incomplete }
        let pending = completion; completion = nil; pending?.resume(returning: .init(verified: verified, host: status))
    }
    func closeAndDrain() async -> Bool {
        guard let controller else { return true }
        return await controller.model.cancelAndDrain()
    }
}
