import ExplorerCore
import Foundation

/// Concrete one-hop setup. Both peers remain owned by one worker;
/// native callbacks can review that worker, never manufacture verification.
enum SFTPRouteConnection {
    typealias Review = @Sendable (SFTPRouteRole, any SFTPAuthenticationReviewControl) async -> Bool
    typealias Prompts = @Sendable (SFTPRouteRole, any SFTPAuthenticationReviewControl, SFTPInteractiveChallenge) async -> SFTPInteractiveAnswers?
    static func connect(_ route: SFTPRouteDescription, jumpAuthentication: SFTPAuthenticationChoice,
        destinationAuthentication: SFTPAuthenticationChoice, savedRouteID: UUID?, remember: Bool,
        rememberJumpPassword: Bool, rememberDestinationPassword: Bool, bundle: URL,
        activity: FileActivityGate, pool: SMBTemporaryCatalogPool, state: SFTPRememberedState,
        prompts: Prompts?, review: @escaping Review, downloads: Bool = false, freshUploads: Bool = false,
        exposedDownloads: Bool = false, exposedTextReads: Bool = false,
        freshFolderUploads: Bool = false, remoteActions: Bool = false,
        guardedInPlaceEditing: Bool = false) async throws -> SFTPConnectionOutcome {
        var stage: SFTPJumpHostStage?, raw: SFTPWorkerSession?, remembering = SFTPRememberingOutcome()
        do {
            try route.validate()
            guard !jumpAuthentication.usesServerPrompts && !destinationAuthentication.usesServerPrompts || prompts != nil,
                  remember || !rememberJumpPassword && !rememberDestinationPassword else { throw SFTPSessionFailure.input }
            let saved = try await state.inspect()?.visibleRoutes.first(where: { $0.id == savedRouteID })
            let previous = saved?.details.authorityDigest == route.authorityDigest ? saved : nil
            let endpoint = try await SFTPPreparedConnection.prepare(route.jump.request, bundleURL: bundle, activity: activity)
            try Task.checkCancellation()
            let outer = try await SFTPJumpHostStage.openPrepared(route: route, previous: previous, endpoint: endpoint,
                bundleURL: bundle, activity: activity, pool: pool, downloads: downloads,
                freshUploads: freshUploads, freshFolderUploads: freshFolderUploads, remoteActions: remoteActions,
                guardedInPlaceEditing: guardedInPlaceEditing); stage = outer
            guard await review(.jump, outer) else { throw SFTPSessionFailure.stopped }
            try Task.checkCancellation()
            let outerChoice = try await authenticate(outer, choice: jumpAuthentication, savedID: savedRouteID, state: state, prompts: prompts)
            let inner = try await outer.destinationSession(); raw = inner
            guard await review(.destination, inner) else { throw SFTPSessionFailure.stopped }
            try Task.checkCancellation()
            let innerChoice = try await authenticate(inner, choice: destinationAuthentication, savedID: savedRouteID, state: state, prompts: prompts)
            if remember {
                remembering = try await inner.rememberAuthenticatedRoute(using: state, jump: outerChoice, destination: innerChoice,
                    rememberJumpPassword: rememberJumpPassword, rememberDestinationPassword: rememberDestinationPassword, editing: savedRouteID)
            }
            let browser = try await SFTPBrowserSession.adoptAuthenticated(inner, exposedDownloads: exposedDownloads,
                                                                          exposedFolderDownloads: exposedDownloads,
                                                                          exposedTextReads: exposedTextReads)
            return .init(session: browser, remembering: remembering)
        } catch {
            let address = error as? SFTPAddressPreparationFailure
            let admission = error as? SFTPWorkerAdmissionFailure
            let ended: Bool
            if let raw { ended = await raw.close().localResourcesEnded }
            else if let stage { ended = await stage.close().localResourcesEnded }
            else if let address { ended = address.localResourcesEnded }
            else { ended = admission == nil }
            let cause: any Error
            if let address { cause = address.cause }
            else if let admission { cause = admission.cause }
            else { cause = error }
            throw SFTPConnectionFailure(cause: cause,
                remembering: remembering, localResourcesEnded: ended)
        }
    }
    private static func authenticate(_ session: SFTPJumpHostStage, choice: SFTPAuthenticationChoice,
        savedID: UUID?, state: SFTPRememberedState, prompts: Prompts?) async throws -> SFTPAuthenticationChoice {
        switch choice {
        case .password(let typed):
            if let typed { try await session.authenticate(typed) }
            else { guard let savedID else { throw SFTPPasswordFailure.missing }; try await session.authenticateSaved(using: state, routeID: savedID) }
        case .serverPrompts:
            try await finish(try await session.beginInteractiveAuthentication(passphrase: .init("")), role: .jump, session: session,
                prompts: prompts, answer: { try await session.answer($0, challenge: $1) })
        case let .keyFile(selected, passphrase, remember, alias), let .keyFileWithServerPrompts(selected, passphrase, remember, alias):
            let key: SFTPSelectedPrivateKey
            if let selected { key = selected }
            else { guard let savedID else { throw SFTPSettingsFailure.missing }; key = try await session.keyForSavedRoute(using: state, routeID: savedID) }
            if choice.usesServerPrompts {
                try await finish(try await session.beginInteractiveAuthentication(key: key, passphrase: passphrase), role: .jump, session: session,
                    prompts: prompts, answer: { try await session.answer($0, challenge: $1) })
                return .keyFileWithServerPrompts(key, passphrase: try .init(""), rememberKey: remember, profileAlias: alias)
            }
            _ = try await session.authenticate(key: key, passphrase: passphrase)
            return .keyFile(key, passphrase: try .init(""), rememberKey: remember, profileAlias: alias)
        case .userCertificate:
            throw SFTPSessionFailure.input
        }
        return choice
    }
    private static func authenticate(_ session: SFTPWorkerSession, choice: SFTPAuthenticationChoice,
        savedID: UUID?, state: SFTPRememberedState, prompts: Prompts?) async throws -> SFTPAuthenticationChoice {
        switch choice {
        case .password(let typed):
            if let typed { try await session.authenticate(typed) }
            else { guard let savedID else { throw SFTPPasswordFailure.missing }; try await session.authenticateSavedRoute(using: state, routeID: savedID) }
        case .serverPrompts:
            try await finish(try await session.beginInteractiveAuthentication(), role: .destination, session: session,
                prompts: prompts, answer: { try await session.answer($0, challenge: $1) })
        case let .keyFile(selected, passphrase, remember, alias), let .keyFileWithServerPrompts(selected, passphrase, remember, alias):
            let key: SFTPSelectedPrivateKey
            if let selected { key = selected }
            else { guard let savedID else { throw SFTPSettingsFailure.missing }; key = try await session.keyForSavedRoute(using: state, routeID: savedID) }
            if choice.usesServerPrompts {
                try await finish(try await session.beginInteractiveAuthentication(key: key, passphrase: passphrase), role: .destination, session: session,
                    prompts: prompts, answer: { try await session.answer($0, challenge: $1) })
                return .keyFileWithServerPrompts(key, passphrase: try .init(""), rememberKey: remember, profileAlias: alias)
            }
            _ = try await session.authenticate(key: key, passphrase: passphrase)
            return .keyFile(key, passphrase: try .init(""), rememberKey: remember, profileAlias: alias)
        case .userCertificate:
            throw SFTPSessionFailure.input
        }
        return choice
    }
    private static func finish(_ initial: SFTPInteractiveStep, role: SFTPRouteRole, session: any SFTPAuthenticationReviewControl,
        prompts: Prompts?, answer: @Sendable (SFTPInteractiveAnswers, SFTPInteractiveChallenge) async throws -> SFTPInteractiveStep) async throws {
        guard let prompts else { throw SFTPSessionFailure.input }
        var step = initial
        while case .challenge(let challenge) = step {
            try Task.checkCancellation()
            guard let values = await prompts(role, session, challenge) else { throw SFTPSessionFailure.stopped }
            try Task.checkCancellation(); step = try await answer(values, challenge)
        }
    }
}
