import ExplorerCore
import Foundation

@_spi(Qualification) public struct SFTPConnectionReview: Sendable {
    public let verified: Bool
    public let host: SFTPRememberingStatus
    public init(verified: Bool, host: SFTPRememberingStatus = .notRequested) { self.verified = verified; self.host = host }
}
@_spi(Qualification) public struct SFTPConnectionOutcome: Sendable {
    public let session: SFTPBrowserSession
    public let remembering: SFTPRememberingOutcome
}
/// Fixed setup stages for privacy-safe failure diagnostics. No endpoint,
/// account, credential, or server-provided text is retained here.
@_spi(Qualification) public enum SFTPConnectionStage: Sendable, Equatable {
    case configurationPreparation, addressPreparation, workerAdmission
    case hostReview, authenticationAndRemembering, browserAdoption
}
@_spi(Qualification) public struct SFTPConnectionFailure: Error, Sendable, CustomStringConvertible {
    public let cause: any Error
    public let remembering: SFTPRememberingOutcome
    public let localResourcesEnded: Bool
    public let stage: SFTPConnectionStage?
    public init(cause: any Error, remembering: SFTPRememberingOutcome, localResourcesEnded: Bool,
        stage: SFTPConnectionStage? = nil) {
        self.cause = cause; self.remembering = remembering
        self.localResourcesEnded = localResourcesEnded; self.stage = stage
    }
    public var description: String { "<SFTP connection setup failed>" }
}

/// Concrete SFTP setup only. The review callback must act on this actual worker;
/// presentation text cannot establish trust. Saved secrets never cross into UI.
/// A single setup owner spans DNS, review, authentication and remembered state.
@_spi(Qualification) public actor SFTPConnectionCoordinator {
    public typealias Review = @Sendable (SFTPWorkerSession, SFTPRememberedState) async -> SFTPConnectionReview
    public typealias ServerPrompts = @Sendable (SFTPWorkerSession, SFTPInteractiveChallenge) async -> SFTPInteractiveAnswers?
    private let bundle: URL, activity: FileActivityGate, pool: SMBTemporaryCatalogPool
    private let requestedDownloads: Bool, requestedFolderDownloads: Bool, requestedTextReads: Bool
    public let remembered: SFTPRememberedState
    private var busy = false, drains = 0
    private let configurationReader = SSHConfigurationReader()
    private var idle: [CheckedContinuation<Void, Never>] = []
    public init(bundleURL: URL, storage: SMBTemporaryStorage, remembered: SFTPRememberedState, activity: FileActivityGate,
        requestedDownloads: Bool = false, requestedFolderDownloads: Bool = false, requestedTextReads: Bool = false) {
        bundle = bundleURL; self.activity = activity; self.remembered = remembered
        pool = SMBTemporaryCatalogPool(storage: storage)
        self.requestedDownloads = requestedDownloads
        self.requestedFolderDownloads = requestedFolderDownloads
        self.requestedTextReads = requestedTextReads
    }
    public func connect(_ draft: SFTPServerDraft, typedPassword: SFTPPassword?, savedServerID: UUID?,
        rememberServer: Bool, rememberPassword: Bool, freshUploads: Bool = false, freshFolderUploads: Bool = false, review: @escaping Review) async throws -> SFTPConnectionOutcome {
        try await connect(draft, authentication: .password(typedPassword), savedServerID: savedServerID,
                          rememberServer: rememberServer, rememberPassword: rememberPassword, freshUploads: freshUploads, freshFolderUploads: freshFolderUploads,
                          profileFeatures: false, review: review)
    }
    public func connect(_ draft: SFTPServerDraft, authentication: SFTPAuthenticationChoice, savedServerID: UUID?,
        rememberServer: Bool, rememberPassword: Bool, freshUploads: Bool = false, freshFolderUploads: Bool = false, profileFeatures: Bool = true,
        configuration: SSHConfigurationImport? = nil, profileAlias: String? = nil, serverPrompts: ServerPrompts? = nil,
        remoteActions: Bool = false, guardedInPlaceEditing: Bool = false,
        review: @escaping Review) async throws -> SFTPConnectionOutcome {
        guard !busy, drains == 0 else { throw SFTPSessionFailure.busy }
        // The worker's M/N/O upload and editor modes need transfer framing,
        // even when binary Download publication is held at the browser boundary.
        let transportDownloads = requestedDownloads || requestedTextReads || freshUploads
        let transportFolderDownloads = requestedFolderDownloads || freshUploads
        guard !freshFolderUploads || freshUploads && transportFolderDownloads else { throw SFTPSessionFailure.input }
        guard !guardedInPlaceEditing || profileFeatures && freshUploads && transportDownloads && transportFolderDownloads else { throw SFTPSessionFailure.input }
        guard !remoteActions || profileFeatures && freshUploads && transportDownloads && transportFolderDownloads else { throw SFTPSessionFailure.input }
        try draft.validate(); try Task.checkCancellation(); busy = true
        defer { busy = false; let pending = idle; idle.removeAll(); for waiter in pending { waiter.resume() } }
        var raw: SFTPWorkerSession?, remembering = SFTPRememberingOutcome()
        var stage: SFTPConnectionStage = .configurationPreparation
        do {
            guard !authentication.usesServerPrompts || profileFeatures && serverPrompts != nil && !rememberPassword else { throw SFTPSessionFailure.input }
            if let configuration {
                guard let profileAlias else { throw SFTPSessionFailure.input }
                try configuration.validateConnection(alias: profileAlias, draft: draft, authentication: authentication)
                try await configurationReader.revalidate(configuration)
            } else if profileAlias != nil { throw SFTPSessionFailure.input }
            let request = try draft.request
            stage = .addressPreparation
            let endpoint = try await SFTPPreparedConnection.prepare(request, bundleURL: bundle, activity: activity)
            try Task.checkCancellation()
            stage = .workerAdmission
            let session = try await SFTPWorkerSession.openPrepared(request, endpoint: endpoint, bundleURL: bundle,
                activity: activity, pool: pool, remembered: remembered, requestedDownloads: transportDownloads, requestedFolderDownloads: transportFolderDownloads,
                freshUploads: freshUploads, keyAuthentication: profileFeatures, interactiveAuthentication: authentication.usesServerPrompts,
                freshFolderUploads: freshFolderUploads, remoteActions: remoteActions, guardedInPlaceEditing: guardedInPlaceEditing)
            raw = session
            stage = .hostReview
            let decision = await review(session, remembered); remembering.host = decision.host
            guard decision.verified else { throw SFTPSessionFailure.stopped }
            try Task.checkCancellation()
            stage = .authenticationAndRemembering
            var saved: SFTPRememberingOutcome
            switch authentication {
            case .password(let typedPassword):
              if let typedPassword {
                try await session.authenticate(typedPassword)
                saved = try await session.rememberAuthenticatedServer(draft, password: typedPassword, using: remembered,
                    rememberServer: rememberServer, rememberPassword: rememberPassword, editing: savedServerID)
              } else {
                saved = try await session.authenticateSavedAndRemember(draft, using: remembered, serverID: savedServerID,
                    rememberServer: rememberServer, rememberPassword: rememberPassword)
              }
            case .serverPrompts:
                guard let serverPrompts else { throw SFTPSessionFailure.input }
                let step = try await session.beginInteractiveAuthentication()
                try await finishInteractive(step, session: session, respond: serverPrompts)
                saved = try await session.rememberAuthenticatedInteractive(draft, using: remembered, rememberServer: rememberServer, editing: savedServerID)
            case let .keyFile(selected, passphrase, rememberKey, alias), let .keyFileWithServerPrompts(selected, passphrase, rememberKey, alias):
                guard profileFeatures, !rememberPassword, !rememberKey || rememberServer else { throw SFTPSessionFailure.input }
                let selection: SFTPSelectedPrivateKey
                if let selected { selection = selected }
                else {
                    guard let savedServerID else { throw SFTPSettingsFailure.missing }
                    let context = try await session.memoryContext(requireAuthenticated: false)
                    selection = try await remembered.keyForVerified(request, key: context.key, serverID: savedServerID)
                }
                if authentication.usesServerPrompts {
                    guard let serverPrompts else { throw SFTPSessionFailure.input }
                    let step = try await session.beginInteractiveAuthentication(key: selection, passphrase: passphrase)
                    try await finishInteractive(step, session: session, respond: serverPrompts)
                } else { _ = try await session.authenticate(key: selection, passphrase: passphrase) }
                saved = try await session.rememberAuthenticatedKey(draft, key: selection, profileAlias: alias, using: remembered,
                    rememberServer: rememberServer, rememberKey: rememberKey, editing: savedServerID, serverPrompts: authentication.usesServerPrompts)
            case let .userCertificate(key, certificate, passphrase, rememberAccess, alias, prompts):
                guard profileFeatures, !rememberPassword, !rememberAccess || rememberServer else {
                    throw SFTPSessionFailure.input
                }
                let selection: (SFTPSelectedPrivateKey, SFTPSelectedUserCertificate)
                switch (key, certificate) {
                case let (.some(key), .some(certificate)):
                    selection = (key, certificate)
                case (.none, .none):
                    guard let savedServerID else { throw SFTPSettingsFailure.missing }
                    let context = try await session.memoryContext(requireAuthenticated: false)
                    selection = try await remembered.certificatePairForVerified(request,
                        key: context.key, serverID: savedServerID)
                default:
                    // A new selection must not borrow one half of an older identity.
                    throw SFTPSessionFailure.input
                }
                if prompts {
                    guard let serverPrompts else { throw SFTPSessionFailure.input }
                    let step = try await session.beginInteractiveAuthentication(key: selection.0,
                        certificate: selection.1, passphrase: passphrase)
                    try await finishInteractive(step, session: session, respond: serverPrompts)
                } else {
                    _ = try await session.authenticate(key: selection.0, certificate: selection.1,
                        passphrase: passphrase)
                }
                saved = try await session.rememberAuthenticatedCertificate(draft, key: selection.0,
                    certificate: selection.1, profileAlias: alias, using: remembered,
                    rememberServer: rememberServer, rememberAccess: rememberAccess,
                    editing: savedServerID, serverPrompts: prompts)
            }
            saved.host = remembering.host; remembering = saved
            // A save already admitted is reported even when cancellation arrives
            // late. The form must drain/discard rather than publish the session.
            stage = .browserAdoption
            let browser = try await SFTPBrowserSession.adoptAuthenticated(session, exposedDownloads: requestedDownloads,
                                                                          exposedFolderDownloads: requestedFolderDownloads,
                                                                          exposedTextReads: requestedTextReads)
            return SFTPConnectionOutcome(session: browser, remembering: saved)
        } catch {
            let address = error as? SFTPAddressPreparationFailure
            let admission = error as? SFTPWorkerAdmissionFailure
            let ended: Bool
            if let raw { ended = await raw.close().localResourcesEnded }
            else if let address { ended = address.localResourcesEnded }
            else { ended = admission == nil }
            let cause: any Error
            if let address { cause = address.cause }
            else if let admission { cause = admission.cause }
            else { cause = error }
            throw SFTPConnectionFailure(cause: cause,
                remembering: remembering, localResourcesEnded: ended, stage: stage)
        }
    }
    private func finishInteractive(_ initial: SFTPInteractiveStep, session: SFTPWorkerSession, respond: ServerPrompts) async throws {
        var step = initial
        while case .challenge(let challenge) = step {
            try Task.checkCancellation()
            guard let answers = await respond(session, challenge) else { throw SFTPSessionFailure.stopped }
            try Task.checkCancellation(); step = try await session.answer(answers, challenge: challenge)
        }
    }
    public func connectRoute(_ route: SFTPRouteDescription, jumpAuthentication: SFTPAuthenticationChoice,
        destinationAuthentication: SFTPAuthenticationChoice, savedRouteID: UUID?, remember: Bool,
        rememberJumpPassword: Bool, rememberDestinationPassword: Bool, configuration: SSHConfigurationImport? = nil,
        profileAlias: String? = nil,
        serverPrompts: (@Sendable (SFTPRouteRole, any SFTPAuthenticationReviewControl, SFTPInteractiveChallenge) async -> SFTPInteractiveAnswers?)? = nil,
        review: @escaping @Sendable (SFTPRouteRole, any SFTPAuthenticationReviewControl) async -> Bool,
        downloads: Bool = false, textReads: Bool = false, freshUploads: Bool = false, freshFolderUploads: Bool = false,
        remoteActions: Bool = false, guardedInPlaceEditing: Bool = false) async throws -> SFTPConnectionOutcome {
        guard !busy, drains == 0 else { throw SFTPSessionFailure.busy }
        let transportDownloads = downloads || textReads || freshUploads
        guard !freshFolderUploads || freshUploads && transportDownloads else { throw SFTPSessionFailure.input }
        guard !guardedInPlaceEditing || transportDownloads && freshUploads else { throw SFTPSessionFailure.input }
        guard !remoteActions || transportDownloads && freshUploads else { throw SFTPSessionFailure.input }
        try route.validate(); try Task.checkCancellation(); busy = true
        defer { busy = false; let pending = idle; idle.removeAll(); for waiter in pending { waiter.resume() } }
        if let configuration {
            guard let profileAlias else { throw SFTPSessionFailure.input }
            try configuration.validateRouteConnection(alias: profileAlias, route: route, jump: jumpAuthentication, destination: destinationAuthentication)
            try await configurationReader.revalidate(configuration)
        } else if profileAlias != nil { throw SFTPSessionFailure.input }
        return try await SFTPRouteConnection.connect(route, jumpAuthentication: jumpAuthentication, destinationAuthentication: destinationAuthentication,
            savedRouteID: savedRouteID, remember: remember, rememberJumpPassword: rememberJumpPassword,
            rememberDestinationPassword: rememberDestinationPassword, bundle: bundle, activity: activity, pool: pool,
            state: remembered, prompts: serverPrompts, review: review, downloads: transportDownloads,
            freshUploads: freshUploads, exposedDownloads: downloads, exposedTextReads: textReads,
            freshFolderUploads: freshFolderUploads, remoteActions: remoteActions,
            guardedInPlaceEditing: guardedInPlaceEditing)
    }
    public func drain() async {
        drains += 1
        if busy { await withCheckedContinuation { idle.append($0) } }
        await remembered.drain(); drains -= 1
    }
}
