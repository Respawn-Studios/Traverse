import CryptoKit
import Darwin
#if !SFTP_PARENT_STANDALONE
import ExplorerCore
#endif
import Foundation

@_spi(Qualification) public enum SFTPSessionFailure: Error, Sendable, Equatable {
    case busy, input, unavailable, stopped, deadline, exited, output, remote, authentication, security, denied, storage, sourceChanged
    case keyInput, keyPassphrase, keyUnsupported, keyChanged, forwardDenied
    case certificateExpired, certificateNotYetValid
    static func terminal(_ outcome: UInt8) -> Self {
        switch outcome { case 0: .stopped; case 1: .exited; case 3: .deadline; case 4: .remote
        case 5: .authentication; case 6: .security; case 7: .input; case 8: .denied; case 9: .storage; case 10: .sourceChanged
        case 11: .keyInput; case 12: .keyPassphrase; case 13: .keyUnsupported; case 14: .keyChanged; case 15: .forwardDenied
        case 16: .certificateExpired; case 17: .certificateNotYetValid; default: .output }
    }
}
enum SFTPChildWait: Sendable, Equatable {
    case pending, exited(Int32), uncertain
    static func observe(expected: pid_t, found: pid_t, status: Int32, error: Int32) -> Self {
        if found == 0 || found < 0 && error == EINTR { return .pending }
        guard expected > 0, found == expected else { return .uncertain }
        if status & 0x7f == 0x7f { return .pending }
        return .exited(status & 0x7f == 0 ? (status >> 8) & 0xff : -(status & 0x7f))
    }
}
@_spi(Qualification) public struct SFTPWorkerClose: Sendable {
    public let actualExit: Bool
    public let exitStatus: Int32?
    public let ipcEOF: Bool
    public let contained: Bool
    public let protocolValid: Bool
    public let terminal: SFTPWorkerTerminal?
    public let temporaryStoreRemoved: Bool?
    public var drainElapsedSeconds: TimeInterval = 0
    public var localResourcesEnded: Bool { actualExit && ipcEOF }
}
struct SFTPPeerConfiguration: Sendable {
    let host: String, port: UInt16, numericHost: String, scopeID: UInt32, bundle: URL
    var validateAdmission: (@Sendable () throws -> Void)?
    var previousKey: SFTPHostKey? = nil
    var requestedScopeID: UInt32 = 0
    var allowsRequestedDownloads = false
    var allowsRequestedFolderDownloads = false
    var allowsFreshUploads = false
    var allowsFreshFolderUploads = false
    var allowsRemoteActions = false
    var allowsKeyAuthentication = false
    var allowsInteractiveAuthentication = false
    #if TRAVERSE_SFTP_EDITOR_QA
    var agentQualification = false
    #endif
    var contentAccess = SFTPContentAccess.readOnly
    var inPlaceEditingPermit: SFTPInPlaceConnectionPermit? = nil
    var originalEditingPermit: SFTPOriginalConnectionPermit? = nil
    #if DEBUG
    var inPlaceLocalProbe: (@Sendable (SFTPOriginalLocalStage) throws -> Void)? = nil
    var originalLocalProbe: (@Sendable (SFTPOriginalLocalStage) throws -> Void)? = nil
    #endif
    var jump: SFTPJumpIdentity? = nil
    var rememberedRoute: SFTPRouteDescription? = nil
}
struct SFTPVerifiedSessionContext: Sendable {
    let host: String, port: UInt16, requestedScopeID: UInt32, account: String
    let key: SFTPHostKey, previous: SFTPHostKey?
    let permitsRememberingHost: Bool
    var authenticatedIdentity: SFTPHostKey? = nil
    var authenticatedSelectionID: UUID? = nil
    var authenticatedWithUserCertificate = false
    var authenticatedCertificateSelectionID: UUID? = nil
    var usedServerPrompts = false
    var permitsSavedAuthentication = true
    var routeKeyBinding: Data? = nil
}
/// Before a public session exists, the admission registry can still own a child.
/// Preserve that uncertainty rather than let setup infer "no session = closed".
struct SFTPWorkerAdmissionFailure: Error, Sendable {
    let cause: any Error
}

/// Qualified native owner; ordinary UI activation remains separate. The public
/// prepared path requires typed peer admission and paged temporary storage;
/// raw-batch/generated factories stay internal. No SSH config/agent discovery.
@_spi(Qualification) public final class SFTPWorkerSession: SFTPAuthenticationReviewControl, @unchecked Sendable {
    private let owner: SFTPProcessOwner
    public let review: SFTPHostChallenge
    public var allowsFolderSizeSummary: Bool { owner.allowsFolderSizeSummary }
    public var allowsRequestedDownloads: Bool { owner.allowsRequestedDownloads }
    public var allowsRequestedFolderDownloads: Bool { owner.allowsRequestedFolderDownloads }
    public var allowsInPlaceEditing: Bool { owner.allowsInPlaceEditing }
    public var allowsRemoteActions: Bool { owner.allowsRemoteActions }
    public var allowsServerCopy: Bool { owner.allowsServerCopy }
    public var allowsOriginalEditing: Bool { owner.allowsOriginalEditing }
    private let account: String
    fileprivate init(_ owner: SFTPProcessOwner, review: SFTPHostChallenge, account: String) { self.owner = owner; self.review = review; self.account = account }
    static func openGenerated(port: UInt16, activity: FileActivityGate, pool: SMBTemporaryCatalogPool? = nil) async throws -> SFTPWorkerSession {
        guard port > 0 else { throw SFTPSessionFailure.input }
        guard !Task.isCancelled else { throw SFTPSessionFailure.stopped }
        return try await begin(peer: .init(host: "generated.example", port: port, numericHost: "127.0.0.1", scopeID: 0, bundle: Bundle.main.bundleURL),
            account: "generated", activity: activity, pool: pool)
    }
    #if TRAVERSE_SFTP_EDITOR_QA
    /// QA-only generated loopback route. The app must admit one generated
    /// server and socket before calling this; ordinary setup never selects Q.
    @_spi(Qualification) public static func openGeneratedAgent(port: UInt16, activity: FileActivityGate,
        pool: SMBTemporaryCatalogPool) async throws -> SFTPWorkerSession {
        guard port > 0 else { throw SFTPSessionFailure.input }
        var peer = SFTPPeerConfiguration(host: "generated.example", port: port, numericHost: "127.0.0.1",
            scopeID: 0, bundle: Bundle.main.bundleURL)
        peer.agentQualification = true
        return try await begin(peer: peer, account: "generated", activity: activity, pool: pool)
    }
    @_spi(Qualification) public func listAgentIdentities(socket: URL) async throws -> [SFTPAgentIdentitySummary] {
        try await perform { try $0.listAgentIdentities(socket: socket) }
    }
    @_spi(Qualification) public func authenticate(agentIdentity: SFTPAgentIdentitySummary) async throws {
        try await perform { try $0.authenticate(account: self.account, agentIdentity: agentIdentity) }
    }
    #endif
    static func begin(peer: SFTPPeerConfiguration, account: String, activity: FileActivityGate, pool: SMBTemporaryCatalogPool?) async throws -> SFTPWorkerSession {
        guard !Task.isCancelled else { throw SFTPSessionFailure.stopped }
        try peer.validateAdmission?()
        let owner = try SFTPProcessOwner(peer: peer, activity: activity, pool: pool)
        try SFTPProcessAdmission.shared.reserve(owner, paged: pool != nil)
        let review = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFTPHostChallenge, Error>) in
                owner.queue.async {
                    do { try owner.launch(); continuation.resume(returning: try owner.awaitReview()) }
                    catch {
                        owner.stop(); let closed = owner.finish()
                        continuation.resume(throwing: closed.localResourcesEnded ? error : SFTPWorkerAdmissionFailure(cause: error))
                    }
                }
            }
        } onCancel: { owner.stop() }
        if Task.isCancelled {
            owner.stop(); let closed = await owner.close()
            if !closed.localResourcesEnded { throw SFTPWorkerAdmissionFailure(cause: SFTPSessionFailure.stopped) }
            throw SFTPSessionFailure.stopped
        }
        return SFTPWorkerSession(owner, review: review, account: account)
    }
    public func approve(_ action: SFTPTrustAction) async throws {
        try await perform { try $0.approve(action, review: self.review) }
    }
    func authenticateGenerated() async throws {
        try await perform { try $0.authenticate(account: "generated", password: Data("ephemeral qualification password".utf8)) }
    }
    public func authenticate(_ password: SFTPPassword) async throws {
        try await perform { try $0.authenticate(account: self.account, password: password.bytes) }
    }
    public func authenticate(key: SFTPSelectedPrivateKey, passphrase: SFTPKeyPassphrase) async throws -> SFTPHostKey {
        try await perform { try $0.authenticate(account: self.account, key: key, passphrase: passphrase.bytes) }
    }
    /// Source qualification seam only; ordinary connection/profile presentation
    /// does not select certificates until its complete flow is admitted.
    public func authenticate(key: SFTPSelectedPrivateKey, certificate: SFTPSelectedUserCertificate,
                             passphrase: SFTPKeyPassphrase) async throws -> SFTPHostKey {
        try await perform { try $0.authenticate(account: self.account, key: key, passphrase: passphrase.bytes, certificate: certificate) }
    }
    public func beginInteractiveAuthentication() async throws -> SFTPInteractiveStep {
        try await perform { try $0.beginInteractive(account: self.account) }
    }
    public func beginInteractiveAuthentication(key: SFTPSelectedPrivateKey, passphrase: SFTPKeyPassphrase) async throws -> SFTPInteractiveStep {
        try await perform { try $0.beginInteractive(account: self.account, key: key, passphrase: passphrase.bytes) }
    }
    public func beginInteractiveAuthentication(key: SFTPSelectedPrivateKey, certificate: SFTPSelectedUserCertificate,
                                              passphrase: SFTPKeyPassphrase) async throws -> SFTPInteractiveStep {
        try await perform { try $0.beginInteractive(account: self.account, key: key, passphrase: passphrase.bytes, certificate: certificate) }
    }
    public func answer(_ answers: SFTPInteractiveAnswers, challenge: SFTPInteractiveChallenge) async throws -> SFTPInteractiveStep {
        try await perform { try $0.answerInteractive(answers, challenge: challenge) }
    }
    /// A setup owner serializes this nonblocking local check with submission.
    /// Cancelling this RPC cancels the connection; don't cancel it to submit.
    public func checkInteractiveChallenge(_ challenge: SFTPInteractiveChallenge) async throws {
        try await perform { try $0.checkInteractiveChallenge(challenge) }
    }
    func referenceAfterAuthentication(_ key: SFTPSelectedPrivateKey) async throws -> SFTPKeyAccessReference {
        let result: Result<SFTPKeyAccessReference, any Error> = try await perform { owner in
            let context = try owner.memoryContext(account: self.account, requireAuthenticated: true)
            do { return .success(try key.referenceAfterAuthentication(context, check: owner.checkForSelectedKey)) }
            catch { try owner.checkForSelectedKey(); return .failure(error) }
        }
        return try result.get()
    }
    func referencesAfterCertificateAuthentication(key: SFTPSelectedPrivateKey,
                                                  certificate: SFTPSelectedUserCertificate) async throws
        -> (SFTPKeyAccessReference, SFTPCertificateAccessReference) {
        let result: Result<(SFTPKeyAccessReference, SFTPCertificateAccessReference), any Error> = try await perform { owner in
            let context = try owner.memoryContext(account: self.account, requireAuthenticated: true)
            do {
                let keyReference = try key.referenceAfterCertificateAuthentication(context, check: owner.checkForSelectedKey)
                let certificateReference = try certificate.referenceAfterAuthentication(context, check: owner.checkForSelectedKey)
                return .success((keyReference, certificateReference))
            } catch { try owner.checkForSelectedKey(); return .failure(error) }
        }
        return try result.get()
    }
    func memoryContext(requireAuthenticated: Bool) async throws -> SFTPVerifiedSessionContext {
        try await perform { try $0.memoryContext(account: self.account, requireAuthenticated: requireAuthenticated) }
    }
    public func authenticateSavedRoute(using state: SFTPRememberedState, routeID: UUID) async throws {
        let peer = try await perform { try $0.routePeer(.destination, requireAuthenticated: false) }
        try await authenticate(state.passwordForVerifiedRoute(peer, id: routeID))
    }
    public func keyForSavedRoute(using state: SFTPRememberedState, routeID: UUID) async throws -> SFTPSelectedPrivateKey {
        let peer = try await perform { try $0.routePeer(.destination, requireAuthenticated: false) }
        return try await state.keyForVerifiedRoute(peer, id: routeID)
    }
    public func rememberAuthenticatedRoute(using state: SFTPRememberedState, jump: SFTPAuthenticationChoice,
        destination: SFTPAuthenticationChoice, rememberJumpPassword: Bool, rememberDestinationPassword: Bool,
        editing: UUID?) async throws -> SFTPRememberingOutcome {
        let prepared = try await perform { owner in
            let outer = try owner.routePeer(.jump, requireAuthenticated: true), inner = try owner.routePeer(.destination, requireAuthenticated: true)
            let first = try owner.routeEndpoint(jump, peer: outer), second = try owner.routeEndpoint(destination, peer: inner)
            return (outer, inner, first, second)
        }
        var passwords: [SFTPRouteRole: SFTPPassword] = [:]
        for (role, choice, remember, peer) in [(SFTPRouteRole.jump, jump, rememberJumpPassword, prepared.0),
            (.destination, destination, rememberDestinationPassword, prepared.1)] where remember {
            guard case .password(let password) = choice else { throw SFTPSettingsFailure.invalidRecord }
            if let password { passwords[role] = password }
            else if let editing { passwords[role] = try await state.passwordForVerifiedRoute(peer, id: editing) }
            else { throw SFTPSettingsFailure.invalidRecord }
        }
        var outcome = await state.rememberAuthenticatedRoute(prepared.0.route, jump: prepared.2.endpoint, destination: prepared.3.endpoint,
            passwords: passwords, editing: editing)
        if prepared.2.keyRequested || prepared.3.keyRequested {
            outcome.keyAccess = prepared.2.keyFailed || prepared.3.keyFailed || outcome.server != .complete ? .incomplete : .complete
        }
        return outcome
    }
    func openDirectory(_ path: String) async throws -> UUID {
        try await perform { try $0.openDirectory(path) }
    }
    func nextBatch(_ generation: UUID) async throws -> (entries: [SFTPWorkerEntry], end: Bool) {
        try await perform { try $0.nextBatch(generation) }
    }
    public func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
        try await perform { try $0.openStoredDirectory(path) }
    }
    func enableDirectoryRecovery() async throws {
        try await perform { try $0.enableDirectoryRecovery() }
    }
    public func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot {
        try await perform { try $0.ingestNext(generation) }
    }
    public func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
              sort: SFTPStoredSort = .name, descending: Bool = false) async throws -> SFTPStoredPage? {
        try await perform { try $0.page(generation, snapshot: snapshot, offset: offset, sort: sort, descending: descending) }
    }
    public func find(_ generation: UUID, snapshot: SFTPStoredSnapshot,
                     query: RemoteDirectoryFindQuery) async throws -> SFTPDirectoryFindResult {
        // Request-scoped refusals leave the process owner through a value, so
        // its fail-closed transport-error path cannot disconnect on Find timeout.
        let result = try await perform { try $0.find(generation, snapshot: snapshot, query: query) }
        return try result.get()
    }
    public func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
        let result = try await perform { try $0.summarizeSelectedFolder(selection) }
        return try result.get()
    }
    public func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
                     sort: SFTPStoredSort, descending: Bool, find: SFTPDirectoryFindResult?) async throws -> SFTPStoredPage? {
        guard let find else { return try await page(generation, snapshot: snapshot, offset: offset, sort: sort, descending: descending) }
        let result = try await perform { try $0.filteredPage(generation, snapshot: snapshot, offset: offset,
                                                           sort: sort, descending: descending, find: find) }
        return try result.get()
    }
    public func checkIdle() async throws { try await perform { try $0.checkIdle() } }
    func performRemoteAction(_ intent: SFTPRemoteActionIntent, store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult {
        guard allowsRemoteActions else { throw SFTPSessionFailure.denied }
        guard intent.kind != .copyFile || allowsServerCopy else { throw SFTPSessionFailure.denied }
        let context = try await memoryContext(requireAuthenticated: true)
        let directory = try await perform { try $0.remoteActionDirectory(intent) }
        let initial = try await store.prepare(intent, context: context, directory: directory)
        var needsReview: SFTPRemoteActionResult?
        var permitAttempted = false
        do {
            if Task.isCancelled || initial.completedAfterCancellation {
                return try await store.update(intent.request, outcome: .failedSafe)
            }
            let preflight = try await perform { try $0.prepareRemoteAction(intent) }
            switch preflight {
            case .remoteActionRefused(let id, let reason) where id == intent.request:
                return try await store.update(id, outcome: .failedSafe, refusal: reason)
            case .remoteActionPrepared(let id) where id == intent.request: break
            default: throw SFTPSessionFailure.output
            }
            let marked = try await store.update(intent.request, outcome: .needsReview)
            needsReview = marked
            if Task.isCancelled || marked.completedAfterCancellation {
                let safe = try await store.update(intent.request, outcome: .failedSafe)
                _ = await close()
                return safe
            }
            permitAttempted = true
            let result = try await perform { try $0.commitRemoteAction(intent.request) }
            switch result {
            case .remoteActionConfirmed(let id) where id == intent.request:
                return try await store.update(id, outcome: .confirmed)
            case .remoteActionRefused(let id, let reason) where id == intent.request:
                return try await store.update(id, outcome: .failedSafe, refusal: reason)
            case .remoteActionNeedsReview(let id) where id == intent.request:
                let drain = await close()
                if drain.localResourcesEnded { await store.releaseAfterDrain(id) }
                return marked
            default: throw SFTPSessionFailure.output
            }
        } catch {
            let drain = await close()
            if permitAttempted, let needsReview {
                if drain.localResourcesEnded { await store.releaseAfterDrain(intent.request) }
                return needsReview
            }
            if let safe = try? await store.update(intent.request, outcome: .failedSafe) { return safe }
            // The remote permit was never attempted. A poisoned local history
            // still owns the request until the worker's actual resources end;
            // release that in-process pin without altering durable evidence.
            if drain.localResourcesEnded { await store.releaseAfterDrain(intent.request) }
            throw error
        }
    }
    func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory {
        guard allowsRemoteActions, intent.kind != .copyFile || allowsServerCopy else { throw SFTPSessionFailure.denied }
        _ = try await memoryContext(requireAuthenticated: true)
        let observed = try await perform { try $0.observedActionDirectory(intent) }
        let path = try observed.get()
        do { return try SFTPDefaultDirectory.observedCanonicalServerPath(path) }
        catch { throw SFTPSessionFailure.security }
    }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPPreparedFolderDownload {
        try await perform { try $0.prepareFolderDownload(selection, progress: progress) }
    }
    func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) async throws {
        try await perform { try $0.releaseFolderDownload(prepared) }
    }
    func receiveFolderDownload(_ prepared: SFTPPreparedFolderDownload, into tree: RemoteDownloadedTree,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) async throws -> SFTPFolderDownloadReceipt {
        try await perform { try $0.receiveFolderDownload(prepared, into: tree, progress: progress) }
    }
    #endif
    /// Internal explicit-transfer adapter. Ordinary prepared connections keep
    /// the metadata-only mode until the complete B12 activation gates pass.
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    func download(_ selection: SFTPDownloadSelection, into file: RemoteDownloadedFile,
                  progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SFTPDownloadReceipt {
        try await perform { try $0.download(selection, into: file, progress: progress) }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    func textOrigin(_ selection: SFTPDownloadSelection) async throws -> SFTPTextOrigin {
        try await perform { owner in
            return .init(session: self.review.session, selection: selection,
                context: try owner.memoryContext(account: self.account, requireAuthenticated: true))
        }
    }
    public func uploadEditedText(_ request: SFTPRequestedEditedTextUpload, snapshot: SFTPStoredSnapshot,
        storage: SFTPUploadStorage, progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SFTPTextFreshCopyReceipt {
        guard owner.allowsFreshUploads else { throw SFTPSessionFailure.input }
        let destination = try await perform { try $0.uploadDestination(request.destinationGeneration, snapshot: snapshot, account: self.account) }
        let attempt: SFTPUploadAttempt
        do { attempt = try await SFTPUploadAttempt.prepare(request, destination: destination, storage: storage) }
        catch { throw SFTPUploadAdmissionFailure(cause: error) }
        do {
            guard !Task.isCancelled else { throw SFTPSessionFailure.stopped }
            let completed = try await perform { try $0.upload(attempt, account: self.account, progress: progress) }
            return try SFTPTextFreshCopyReceipt(completed, snapshot: request.snapshot)
        } catch { await attempt.discardUnsent(); throw error }
    }
    public var allowsFreshUploads: Bool { owner.allowsFreshUploads }
    public var allowsFreshFolderUploads: Bool { owner.allowsFreshFolderUploads }
    public func upload(_ request: SFTPRequestedUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                       excluding roots: [URL], progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> SFTPCompletedUpload {
        guard owner.allowsFreshUploads else { throw SFTPSessionFailure.input }
        let destination = try await perform { try $0.uploadDestination(request.generation, snapshot: snapshot, account: self.account) }
        let attempt: SFTPUploadAttempt
        do { attempt = try await SFTPUploadAttempt.prepare(request, destination: destination, storage: storage, excluding: roots) }
        catch { throw SFTPUploadAdmissionFailure(cause: error) }
        do {
            guard !Task.isCancelled else { throw SFTPSessionFailure.stopped }
            return try await perform { try $0.upload(attempt, account: self.account, progress: progress) }
        } catch { await attempt.discardUnsent(); throw error }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    public func uploadFolder(_ request: SFTPRequestedFolderUpload, snapshot: SFTPStoredSnapshot, storage: SFTPUploadStorage,
                             excluding roots: [URL], progress: (@Sendable (UInt64, Int) -> Void)? = nil) async throws -> SFTPCompletedFolderUpload {
        guard owner.allowsFreshFolderUploads else { throw SFTPSessionFailure.input }
        let destination = try await perform { try $0.uploadDestination(request.generation, snapshot: snapshot, account: self.account) }
        let attempt: SFTPFolderUploadAttempt
        do { attempt = try await SFTPFolderUploadAttempt.prepare(request, destination: destination, storage: storage, excluding: roots) }
        catch { throw SFTPUploadAdmissionFailure(cause: error) }
        do {
            guard !Task.isCancelled else { throw SFTPSessionFailure.stopped }
            return try await perform { try $0.uploadFolder(attempt, account: self.account, progress: progress) }
        } catch { await attempt.discardUnsent(); throw error }
    }
    #endif
    public func close() async -> SFTPWorkerClose { owner.stop(); return await owner.close() }
    func readInPlace(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot, storage: SFTPInPlaceWorkingCopyStorage) async throws -> SFTPInPlaceBaseline {
        try await perform { try $0.readInPlace(selection, snapshot: snapshot, storage: storage, account: self.account) }
    }
    func saveInPlace(_ baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot, journal: SFTPInPlaceJournal) async throws -> SFTPInPlaceSaveCompletion {
        do { return try await perform { try $0.saveInPlace(baseline, snapshot: snapshot, journal: journal, account: self.account) } }
        catch {
            if let verified = owner.verifiedInPlaceOutcome(for: snapshot) { _ = await owner.close(); return .verifiedRecoveryNeedsAttention(verified) }; throw error
        }
    }
    func releaseInPlace(_ release: SFTPInPlaceRelease) async throws -> SFTPInPlaceCloseResult {
        do { return try await perform { try $0.releaseInPlace(release) } }
        catch {
            let end = await owner.close(); guard end.localResourcesEnded else { throw error }
            try release.afterActualSessionDrain(end, session: review.session); return await release.finishAfterLocalDrain()
        }
    }
    func readOriginal(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot,
                      storage: SFTPOriginalWorkingCopyStorage) async throws -> SFTPOriginalBaseline {
        try await perform { try $0.readOriginal(selection, snapshot: snapshot, storage: storage, account: self.account) }
    }
    func saveOriginal(_ baseline: SFTPOriginalBaseline, snapshot: SFTPEditedTextSnapshot,
                      journal: SFTPOriginalJournal) async throws -> SFTPOriginalSaveCompletion {
        do {
            return try await perform { try $0.saveOriginal(baseline, snapshot: snapshot, journal: journal, account: self.account) }
        } catch {
            // Cancellation or a lost UI handoff cannot erase a strict187 which
            // already passed real local drain. No reusable token is returned.
            if let verified = owner.verifiedOriginalOutcome(for: snapshot) {
                _ = await owner.close(); return .verifiedRecoveryNeedsAttention(verified)
            }
            throw error
        }
    }
    func releaseOriginal(_ close: SFTPOriginalBaselineClose) async throws -> SFTPOriginalBaselineCloseCompletion {
        do { return try await perform { try $0.releaseOriginal(close) } }
        catch {
            let end = await owner.close()
            guard end.localResourcesEnded else { throw error }
            switch close {
            case .unused(let release):
                try release.afterActualSessionDrain(end, session: review.session)
                return .unused(await release.finishAfterLocalDrain())
            case .retained(let release):
                try release.afterActualSessionDrain(end, session: review.session)
                return .retained(await release.finishAfterLocalDrain())
            }
        }
    }
    /// Includes setup helpers which have not yet crossed into a browser tab.
    public static func pauseAndDrainOwned() async -> Bool { await SFTPProcessAdmission.shared.pauseAndDrain() }
    public static func resumeAdmissions() { SFTPProcessAdmission.shared.resume() }
    private func perform<T: Sendable>(_ work: @escaping @Sendable (SFTPProcessOwner) throws -> T) async throws -> T {
        try await owner.perform(work)
    }
    deinit { let retained = owner; retained.stop(); retained.queue.async { _ = retained.finish() } }
    #if DEBUG
    /// Generated offline Controls executable only. Spawns its own exact child;
    /// no descriptor/PID injection, bundled-helper claim or server authority.
    static func generatedOriginalPipeForQualification(pool: SMBTemporaryCatalogPool, activity: FileActivityGate,
        scenario: SFTPOriginalPipeScenario, probe: (@Sendable (SFTPOriginalLocalStage) throws -> Void)? = nil) async throws -> SFTPWorkerSession {
        var peer = SFTPPeerConfiguration(host: "generated.example", port: 22, numericHost: "127.0.0.1", scopeID: 0, bundle: Bundle.main.bundleURL)
        peer.allowsKeyAuthentication = true; peer.allowsInteractiveAuthentication = true
        peer.contentAccess = .transferWrites
        peer.originalEditingPermit = .generatedQualification(UUID()); peer.originalLocalProbe = probe
        let owner = try SFTPProcessOwner(peer: peer, activity: activity, pool: pool)
        try SFTPProcessAdmission.shared.reserve(owner, paged: true)
        let review: SFTPHostChallenge = try await withCheckedThrowingContinuation { continuation in
            owner.queue.async {
                do { try owner.launchGeneratedOriginalProcess(scenario: scenario); continuation.resume(returning: try owner.awaitReview()) }
                catch { owner.stop(); _ = owner.finish(); continuation.resume(throwing: error) }
            }
        }
        return .init(owner, review: review, account: "generated")
    }
    static func generatedInPlacePipeForQualification(pool: SMBTemporaryCatalogPool, activity: FileActivityGate,
        scenario: SFTPInPlacePipeScenario, probe: (@Sendable (SFTPOriginalLocalStage) throws -> Void)? = nil,
        readOnly: Bool = false, transfers: SFTPInPlaceTransfers = .none,
        gateBCaseRoot: URL? = nil) async throws -> SFTPWorkerSession {
        var peer = SFTPPeerConfiguration(host: "generated.example", port: 22, numericHost: "127.0.0.1", scopeID: 0, bundle: Bundle.main.bundleURL)
        peer.allowsKeyAuthentication = true; peer.allowsInteractiveAuthentication = true
        peer.contentAccess = readOnly ? .readOnly : .guardedInPlaceV1
        peer.allowsRequestedDownloads = transfers.downloads; peer.allowsRequestedFolderDownloads = transfers.folders
        peer.allowsFreshUploads = transfers.uploads; peer.allowsFreshFolderUploads = transfers.folderUploads
        peer.inPlaceEditingPermit = .generatedQualification(UUID()); peer.inPlaceLocalProbe = probe
        let owner = try SFTPProcessOwner(peer: peer, activity: activity, pool: pool)
        try SFTPProcessAdmission.shared.reserve(owner, paged: true)
        let review: SFTPHostChallenge = try await withCheckedThrowingContinuation { continuation in
            owner.queue.async {
                do {
                    try owner.launchGeneratedInPlaceProcess(scenario: scenario,
                        gateBCaseRoot: gateBCaseRoot)
                    #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
                    if gateBCaseRoot != nil {
                        do { continuation.resume(returning: try owner.awaitReview()) }
                        catch SFTPSessionFailure.exited { throw GateBGeneratedFailure(stage: "worker-review-exited") }
                        catch { throw GateBGeneratedFailure(stage: "worker-review-refused") }
                    } else {
                        continuation.resume(returning: try owner.awaitReview())
                    }
                    #else
                    continuation.resume(returning: try owner.awaitReview())
                    #endif
                } catch {
                    owner.stop()
                    let close = owner.finish()
                    #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
                    if gateBCaseRoot != nil {
                        var stage = (error as? GateBGeneratedFailure)?.stage ?? "worker-launch-refused"
                        if stage == "worker-review-exited", let code = close.exitStatus,
                           let reason = GateBInPlaceChildExit.stage(for: code) {
                            stage = "worker-review-" + reason
                        }
                        continuation.resume(throwing: GateBGeneratedFailure(stage:
                            close.localResourcesEnded ? stage : stage + "-worker-drain-incomplete"))
                    } else { continuation.resume(throwing: error) }
                    #else
                    _ = close
                    continuation.resume(throwing: error)
                    #endif
                }
            }
        }
        return .init(owner, review: review, account: "generated")
    }
    static func validateReadOnlyTransfersForQualification(pool: SMBTemporaryCatalogPool, transfers: SFTPInPlaceTransfers) throws {
        var peer = SFTPPeerConfiguration(host: "generated.example", port: 22, numericHost: "127.0.0.1", scopeID: 0, bundle: Bundle.main.bundleURL)
        peer.allowsKeyAuthentication = true; peer.allowsInteractiveAuthentication = true; peer.contentAccess = .readOnly
        peer.allowsRequestedDownloads = transfers.downloads; peer.allowsRequestedFolderDownloads = transfers.folders
        peer.allowsFreshUploads = transfers.uploads; peer.allowsFreshFolderUploads = transfers.folderUploads
        // Only validate immutable admission; no registry reservation/spawn/I/O.
        _ = try SFTPProcessOwner(peer: peer, activity: FileActivityGate(), pool: pool)
    }
    var inPlaceOwnershipForQualification: SFTPOriginalParentObservation { owner.inPlaceObservationForQualification }
    var originalOwnershipForQualification: SFTPOriginalParentObservation { owner.originalObservationForQualification }
    #endif
}

#if DEBUG
enum SFTPInPlacePipeScenario: String, Sendable { case success, lostSave, lostRelease, interruptedWrite, invalidStep, wrongGeneration, badRWAdmission, heldDownload, transferEOF, rejectSync, rejectRW, rejectSecondSync, rejectSecondRW, rejectWrongRequest, rejectLateHeader, rejectUnknown, rejectDuplicate, startupMissingAck, startupWrongVersion, startupWrongMask }
enum SFTPOriginalPipeScenario: String, Sendable { case readAndRelease, saveAndRelease, lostRelease, lostSave, malformedAdmission }
struct SFTPOriginalParentObservation: Sendable {
    let requestHeld: Bool, localTaskHeld: Bool, localReturned: Bool, processDrainRecorded: Bool
    let sent: [UInt8: Int]
    let receivedPositive: Int, inPlaceSaveAcknowledgements: Int, generatedLaunchAttempts: Int
}
#endif

/// Owns the verified jump until its destination's immutable review is obtained.
/// Adoption transfers this same child/catalog, rather than opening a second
/// process or mutating a direct session's peer identity.
@_spi(Qualification) public final class SFTPJumpHostStage: SFTPAuthenticationReviewControl, @unchecked Sendable {
    private enum State { case open, busy, transferred }
    private let owner: SFTPProcessOwner
    private let account: String, destinationAccount: String
    public let review: SFTPHostChallenge
    private let lock = NSLock()
    private var state: State = .open
    private init(owner: SFTPProcessOwner, review: SFTPHostChallenge, account: String, destinationAccount: String) {
        self.owner = owner; self.review = review; self.account = account; self.destinationAccount = destinationAccount
    }
    public static func openPrepared(destination: SFTPConnectionRequest, jump: SFTPConnectionRequest,
        endpoint: SFTPPreparedConnection, bundleURL: URL, activity: FileActivityGate,
        pool: SMBTemporaryCatalogPool) async throws -> SFTPJumpHostStage {
        try await open(destination: destination, jump: jump, route: nil, previous: nil,
            endpoint: endpoint, bundleURL: bundleURL, activity: activity, pool: pool,
            downloads: false, uploads: false, folderUploads: false, remoteActions: false, guardedInPlaceEditing: false)
    }
    public static func openPrepared(route: SFTPRouteDescription, previous: SFTPSavedRoute? = nil,
        endpoint: SFTPPreparedConnection, bundleURL: URL, activity: FileActivityGate,
        pool: SMBTemporaryCatalogPool, downloads: Bool = false, freshUploads: Bool = false,
        freshFolderUploads: Bool = false, remoteActions: Bool = false,
        guardedInPlaceEditing: Bool = false) async throws -> SFTPJumpHostStage {
        try route.validate()
        if let previous {
            try previous.validate()
            guard !previous.removalPending, previous.details.authorityDigest == route.authorityDigest else { throw SFTPSessionFailure.input }
        }
        return try await open(destination: route.destination.request, jump: route.jump.request, route: route, previous: previous,
            endpoint: endpoint, bundleURL: bundleURL, activity: activity, pool: pool,
            downloads: downloads, uploads: freshUploads, folderUploads: freshFolderUploads, remoteActions: remoteActions,
            guardedInPlaceEditing: guardedInPlaceEditing)
    }
    private static func open(destination: SFTPConnectionRequest, jump: SFTPConnectionRequest,
        route: SFTPRouteDescription?, previous: SFTPSavedRoute?, endpoint: SFTPPreparedConnection,
        bundleURL: URL, activity: FileActivityGate, pool: SMBTemporaryCatalogPool,
        downloads: Bool, uploads: Bool, folderUploads: Bool, remoteActions: Bool,
        guardedInPlaceEditing: Bool) async throws -> SFTPJumpHostStage {
        let peer = try configuredPreparedRoutePeer(destination: destination, jump: jump, route: route,
            previous: previous, endpoint: endpoint, bundleURL: bundleURL, pool: pool,
            downloads: downloads, uploads: uploads, folderUploads: folderUploads, remoteActions: remoteActions,
            guardedInPlaceEditing: guardedInPlaceEditing)
        let owner = try SFTPProcessOwner(peer: peer, activity: activity, pool: pool)
        try SFTPProcessAdmission.shared.reserve(owner, paged: true)
        let review: SFTPHostChallenge = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in owner.queue.async {
                do { try owner.launch(); continuation.resume(returning: try owner.awaitJumpReview()) }
                catch { owner.stop(); let end = owner.finish(); continuation.resume(throwing: end.localResourcesEnded ? error : SFTPWorkerAdmissionFailure(cause: error)) }
            } }
        } onCancel: { owner.stop() }
        if Task.isCancelled { owner.stop(); let end = await owner.close(); if !end.localResourcesEnded { throw SFTPWorkerAdmissionFailure(cause: SFTPSessionFailure.stopped) }; throw SFTPSessionFailure.stopped }
        return .init(owner: owner, review: review, account: jump.account, destinationAccount: destination.account)
    }
    /// Prepared route composition has no helper launch or network side effect.
    static func configuredPreparedRoutePeer(destination: SFTPConnectionRequest, jump: SFTPConnectionRequest,
        route: SFTPRouteDescription?, previous: SFTPSavedRoute?, endpoint: SFTPPreparedConnection,
        bundleURL: URL, pool: SMBTemporaryCatalogPool, downloads: Bool, uploads: Bool,
        folderUploads: Bool, remoteActions: Bool = false, guardedInPlaceEditing: Bool) throws -> SFTPPeerConfiguration {
        guard !Task.isCancelled, destination.address.scopeID == 0 else { throw SFTPSessionFailure.input }
        try endpoint.validate(for: jump)
        var peer = SFTPPeerConfiguration(host: destination.address.host, port: destination.address.port,
            numericHost: endpoint.numericHost, scopeID: endpoint.interfaceScopeID, bundle: bundleURL,
            validateAdmission: { try endpoint.validate(for: jump) })
        peer.allowsKeyAuthentication = true; peer.allowsInteractiveAuthentication = true
        peer.jump = .init(nonce: UUID(), host: jump.address.host, port: jump.address.port, previous: previous?.jump.key)
        peer.previousKey = previous?.destination.key; peer.rememberedRoute = route
        guard !downloads || route != nil, !uploads || downloads && route != nil, !folderUploads || uploads,
              !remoteActions || downloads && uploads && route != nil else { throw SFTPSessionFailure.input }
        peer.allowsRequestedDownloads = downloads; peer.allowsRequestedFolderDownloads = downloads
        peer.allowsFreshUploads = uploads; peer.allowsFreshFolderUploads = folderUploads; peer.allowsRemoteActions = remoteActions
        peer.contentAccess = uploads ? .transferWrites : .readOnly
        if guardedInPlaceEditing {
            peer.contentAccess = .guardedInPlaceV1
            peer.inPlaceEditingPermit = try .preparedCandidate(peer: peer, pool: pool)
        }
        return peer
    }
    public func approve(_ action: SFTPTrustAction) async throws { try await perform { try $0.approveJump(action, review: self.review) } }
    public func authenticate(_ password: SFTPPassword) async throws { try await perform { try $0.authenticateJump(account: self.account, password: password.bytes) } }
    public func authenticateSaved(using state: SFTPRememberedState, routeID: UUID) async throws {
        let peer = try await perform { try $0.routePeer(.jump, requireAuthenticated: false) }
        try await authenticate(state.passwordForVerifiedRoute(peer, id: routeID))
    }
    public func keyForSavedRoute(using state: SFTPRememberedState, routeID: UUID) async throws -> SFTPSelectedPrivateKey {
        let peer = try await perform { try $0.routePeer(.jump, requireAuthenticated: false) }
        return try await state.keyForVerifiedRoute(peer, id: routeID)
    }
    public func authenticate(key: SFTPSelectedPrivateKey, passphrase: SFTPKeyPassphrase) async throws -> SFTPHostKey {
        try await perform { try $0.authenticateJump(account: self.account, key: key, passphrase: passphrase.bytes) }
    }
    public func beginInteractiveAuthentication(key: SFTPSelectedPrivateKey? = nil, passphrase: SFTPKeyPassphrase) async throws -> SFTPInteractiveStep {
        try await perform { try $0.beginJumpInteractive(account: self.account, key: key, passphrase: passphrase.bytes) }
    }
    public func answer(_ answers: SFTPInteractiveAnswers, challenge: SFTPInteractiveChallenge) async throws -> SFTPInteractiveStep {
        try await perform { try $0.answerJumpInteractive(answers, challenge: challenge) }
    }
    public func checkInteractiveChallenge(_ challenge: SFTPInteractiveChallenge) async throws {
        try await perform { try $0.checkJumpInteractive(challenge) }
    }
    public func destinationSession() async throws -> SFTPWorkerSession {
        try start(); defer { end() }
        let review = try await owner.perform { try $0.awaitDestinationReview() }
        lock.withLock { state = .transferred }
        return SFTPWorkerSession(owner, review: review, account: destinationAccount)
    }
    public func close() async -> SFTPWorkerClose { owner.stop(); return await owner.close() }
    private func start() throws { try lock.withLock { guard state == .open else { throw SFTPSessionFailure.busy }; state = .busy } }
    private func end() { lock.withLock { if state == .busy { state = .open } } }
    private func perform<T: Sendable>(_ work: @escaping @Sendable (SFTPProcessOwner) throws -> T) async throws -> T {
        try start(); defer { end() }; return try await owner.perform(work)
    }
    deinit { if lock.withLock({ state != .transferred }) { let held = owner; held.stop(); held.queue.async { _ = held.finish() } } }
}

/// Uncertain owners retain their activity/admission. A closed view cannot admit
/// replacements while its exact child or IPC lifetime is still unknown.
private final class SFTPProcessAdmission: @unchecked Sendable {
    static let shared = SFTPProcessAdmission()
    private let lock = NSLock()
    private var held: [(owner: SFTPProcessOwner, paged: Bool, uncertain: Bool)] = []
    private var suspended = false
    func reserve(_ owner: SFTPProcessOwner, paged: Bool) throws {
        try lock.withLock {
            guard !suspended, !held.contains(where: \.uncertain), held.count < 2,
                  held.isEmpty || paged && held.allSatisfy(\.paged) else { throw SFTPSessionFailure.busy }
            held.append((owner, paged, false))
        }
    }
    func release(_ owner: SFTPProcessOwner) { lock.withLock { held.removeAll { $0.owner === owner } } }
    func retainUncertain(_ owner: SFTPProcessOwner) {
        lock.withLock { if let index = held.firstIndex(where: { $0.owner === owner }) { held[index].uncertain = true } }
    }
    func pauseAndDrain() async -> Bool {
        let owners = lock.withLock { suspended = true; return held.map(\.owner) }
        for owner in owners { owner.stop() }
        var ended = true
        for owner in owners { if !(await owner.close()).localResourcesEnded { ended = false } }
        return ended
    }
    func resume() { lock.withLock { suspended = false } }
}
private final class SFTPProcessOwner: @unchecked Sendable {
    let queue = DispatchQueue(label: "MacExplorer.SFTP.Qualification", qos: .userInitiated)
    private let lock = NSLock(), activity: FileActivityGate
    private let peer: SFTPPeerConfiguration
    private let pool: SMBTemporaryCatalogPool?
    private var mode: SFTPWireMode
    var allowsFolderSizeSummary: Bool { mode.isCatalog }
    var allowsRequestedDownloads: Bool { mode.allowsDownloads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && peer.allowsRequestedDownloads }
    var allowsRequestedFolderDownloads: Bool { mode.allowsFolderDownloads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && peer.allowsRequestedFolderDownloads }
    var allowsOriginalEditing: Bool { mode.allowsOriginalEditing }
    var allowsInPlaceEditing: Bool { mode.allowsInPlaceEditing || mode.allowsRemoteActions && peer.inPlaceEditingPermit != nil }
    var allowsRemoteActions: Bool { mode.allowsRemoteActions }
    var allowsServerCopy: Bool { lock.withLock { serverCopyNegotiated } }
    private var catalog: SMBTemporaryCatalog?, temporaryStoreRemoved: Bool?
    private let session = UUID()
    private var decoder: SFTPWorkerDecoder
    private var serverCopyNegotiated = false
    private var descriptor: Int32 = -1, child: pid_t = 0
    private var inputSequence: UInt64 = 0, startedProtocol = false
    private var stopAt: TimeInterval?, request: UUID?, completed: UUID?
    private var eof = false, status: Int32?, contained = false, valid = true
    private var childIdentityUncertain = false
    private var terminal: SFTPWorkerTerminal?, verified: SFTPVerifiedHost?
    private var jumpVerified: SFTPVerifiedHost?, jumpAuthenticated = false, jumpIdentity: SFTPHostKey?
    private var jumpPending: SFTPInteractiveChallenge?, jumpUsingKey = false
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    private var uploadAttempt: SFTPUploadAttempt?
    private var uploadNoRemoteMutation = false
    var allowsFreshUploads: Bool { mode.allowsUploads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && peer.allowsFreshUploads }
    var allowsFreshFolderUploads: Bool { mode.allowsFolderUploads || (mode.allowsInPlaceEditing || mode.allowsRemoteActions) && peer.allowsFreshFolderUploads }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    private var folderUploadAttempt: SFTPFolderUploadAttempt?
    private var folderUploadNoRemoteMutation = false
    private var folderUploadAttemptIsIdle: Bool { folderUploadAttempt == nil }
    #else
    private var folderUploadAttemptIsIdle: Bool { true }
    #endif
    private var approvedAction: SFTPTrustAction?, authenticated = false, authenticatedIdentity: SFTPHostKey?, authenticatedSelectionID: UUID?
    private var interactivePending: SFTPInteractiveChallenge?, interactiveKeySelection: UUID?
    private var authenticatedWithInteractive = false
    private var authenticatedWithUserCertificate = false, interactiveUsesUserCertificate = false
    private var authenticatedCertificateSelectionID: UUID?, interactiveCertificateSelectionID: UUID?
    private var jumpSelectionID: UUID?, jumpUsedPrompts = false
    private var maximumDrainSeconds: TimeInterval = 0
    private var completedDrainAt: TimeInterval?
    #if DEBUG && !SFTP_PARENT_STANDALONE
    private var gateAWorkerObserved = false
    #endif
    private var buffer = Data(), lease: FileActivityGate.Lease?
    private var inPlaceMailbox: SFTPInPlaceLocalMailbox?
    private var inPlaceRead: SFTPOriginalReadJob?, inPlaceAttempt: SFTPInPlaceAttempt?
    private var inPlaceRelease: SFTPInPlaceRelease?, inPlaceStorageOwner: SFTPOriginalStorageOwner?
    private var inPlaceVerified: (SFTPEditedTextSnapshot, UUID)?
    private var originalMailbox: SFTPOriginalLocalMailbox?
    private var originalRead: SFTPOriginalReadJob?, originalAttempt: SFTPOriginalAttempt?
    private var originalStorageOwner: SFTPOriginalStorageOwner?
    private var originalRelease: SFTPOriginalBaselineClose?
    private var originalVerified: (SFTPEditedTextSnapshot, UUID)?
    #if DEBUG
    private var originalSentForQualification: [UInt8: Int] = [:]
    private var gateBPositiveReceives = 0, gateBInPlaceSaveAcknowledgements = 0
    private var gateBGeneratedLaunchAttempts = 0
    #endif
    init(peer: SFTPPeerConfiguration, activity: FileActivityGate, pool: SMBTemporaryCatalogPool?) throws {
        guard !peer.allowsRequestedDownloads || pool != nil else { throw SFTPSessionFailure.input }
        guard !peer.allowsFreshFolderUploads || peer.allowsFreshUploads && peer.allowsRequestedFolderDownloads else { throw SFTPSessionFailure.input }
        guard !peer.allowsFreshUploads || pool != nil && peer.allowsRequestedDownloads && peer.allowsRequestedFolderDownloads else { throw SFTPSessionFailure.input }
        guard !peer.allowsRequestedFolderDownloads || pool != nil && peer.allowsRequestedDownloads else { throw SFTPSessionFailure.input }
        guard peer.contentAccess != .readOnly || !peer.allowsFreshUploads && !peer.allowsFreshFolderUploads
            && peer.inPlaceEditingPermit == nil && peer.originalEditingPermit == nil && !peer.allowsRemoteActions else { throw SFTPSessionFailure.denied }
        guard peer.contentAccess != .guardedInPlaceV1 || peer.inPlaceEditingPermit != nil else { throw SFTPSessionFailure.denied }
        self.peer = peer; self.activity = activity; self.pool = pool
        guard peer.inPlaceEditingPermit == nil || peer.originalEditingPermit == nil else { throw SFTPSessionFailure.input }
        if peer.allowsRemoteActions {
            guard pool != nil, peer.allowsKeyAuthentication, peer.allowsInteractiveAuthentication,
                  peer.allowsRequestedDownloads, peer.allowsRequestedFolderDownloads, peer.allowsFreshUploads,
                  peer.jump == nil || peer.rememberedRoute != nil,
                  peer.originalEditingPermit == nil else { throw SFTPSessionFailure.input }
            if let permit = peer.inPlaceEditingPermit { try permit.validate(peer: peer, pool: pool) }
            mode = peer.jump == nil ? .remoteActionCatalog : .routedRemoteActionCatalog
        } else if let permit = peer.inPlaceEditingPermit {
            try permit.validate(peer: peer, pool: pool)
            guard pool != nil, peer.allowsKeyAuthentication, peer.allowsInteractiveAuthentication,
                  peer.jump == nil || peer.rememberedRoute != nil else { throw SFTPSessionFailure.input }
            mode = peer.jump == nil ? .inPlaceEditCatalog : .routedInPlaceEditCatalog
        } else if let permit = peer.originalEditingPermit {
            try permit.validate(peer: peer, pool: pool)
            guard pool != nil, !peer.allowsRequestedDownloads, !peer.allowsRequestedFolderDownloads,
                  !peer.allowsFreshUploads, !peer.allowsFreshFolderUploads,
                  peer.allowsKeyAuthentication, peer.allowsInteractiveAuthentication,
                  peer.jump == nil || peer.rememberedRoute != nil else { throw SFTPSessionFailure.input }
            mode = peer.jump == nil ? .originalEditCatalog : .routedOriginalEditCatalog
        } else if peer.jump != nil {
            guard pool != nil, peer.rememberedRoute != nil || peer.previousKey == nil && peer.jump?.previous == nil,
                  !peer.allowsRequestedDownloads || peer.allowsRequestedFolderDownloads && peer.rememberedRoute != nil,
                  peer.allowsKeyAuthentication, peer.allowsInteractiveAuthentication else { throw SFTPSessionFailure.input }
            mode = peer.allowsFreshFolderUploads ? .routedFreshFolderUploadCatalog : peer.allowsFreshUploads ? .routedExclusiveUploadCatalog : peer.allowsRequestedFolderDownloads ? .routedFolderCatalog : peer.rememberedRoute == nil ? .jumpCatalog : .rememberedJumpCatalog
        } else if peer.allowsRequestedFolderDownloads {
            mode = peer.allowsFreshFolderUploads ? .freshFolderUploadCatalog : peer.allowsFreshUploads ? .exclusiveUploadCatalog : .folderCatalog
        } else if peer.allowsInteractiveAuthentication {
            guard peer.allowsKeyAuthentication, pool != nil else { throw SFTPSessionFailure.input }
            mode = peer.allowsFreshUploads ? .interactiveUploadCatalog : peer.allowsRequestedDownloads ? .interactiveTransferCatalog : .interactiveCatalog
        } else if peer.allowsKeyAuthentication {
            guard pool != nil else { throw SFTPSessionFailure.input }
            mode = peer.allowsFreshUploads ? .keyUploadCatalog : peer.allowsRequestedDownloads ? .keyTransferCatalog : .keyCatalog
        } else {
            mode = peer.allowsFreshUploads ? .uploadCatalog : pool == nil ? .batches : peer.allowsRequestedDownloads ? .transferCatalog : .catalog
        }
        #if TRAVERSE_SFTP_EDITOR_QA
        if peer.agentQualification {
            guard pool != nil, peer.jump == nil, peer.rememberedRoute == nil,
                  !peer.allowsRequestedDownloads, !peer.allowsRequestedFolderDownloads,
                  !peer.allowsFreshUploads, !peer.allowsFreshFolderUploads,
                  !peer.allowsRemoteActions, !peer.allowsKeyAuthentication,
                  !peer.allowsInteractiveAuthentication, peer.inPlaceEditingPermit == nil,
                  peer.originalEditingPermit == nil, peer.contentAccess == .readOnly else {
                throw SFTPSessionFailure.input
            }
            mode = .agentCatalog
        }
        #endif
        decoder = try SFTPWorkerDecoder(session: session, canonicalHost: peer.host, port: peer.port, previous: peer.previousKey,
            mode: mode, jump: peer.jump, inPlaceTransfers: mode.allowsInPlaceEditing || mode.allowsRemoteActions ? SFTPInPlaceTransfers(peer: peer) : .none,
            remoteActionEditorEnabled: mode.allowsRemoteActions && peer.inPlaceEditingPermit != nil)
    }
    func perform<T: Sendable>(_ work: @escaping @Sendable (SFTPProcessOwner) throws -> T) async throws -> T {
        let id = try admit()
        do {
          let result: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in queue.async {
                do {
                    let value = try work(self); guard self.allows(id) else { throw SFTPSessionFailure.stopped }
                    self.end(); continuation.resume(returning: value)
                } catch let rejection as SFTPInPlaceEditRefusal {
                    if self.allows(id) { self.end(); continuation.resume(throwing: rejection) }
                    else { self.stop(); _ = self.finish(); self.end(); continuation.resume(throwing: SFTPSessionFailure.stopped) }
                } catch let rejection as SFTPInPlaceAdmissionFailure {
                    if self.allows(id) { self.end(); continuation.resume(throwing: rejection) }
                    else { self.stop(); _ = self.finish(); self.end(); continuation.resume(throwing: SFTPSessionFailure.stopped) }
                } catch let rejection as SFTPOriginalAdmissionFailure {
                    if self.allows(id) { self.end(); continuation.resume(throwing: rejection) }
                    else { self.stop(); _ = self.finish(); self.end(); continuation.resume(throwing: SFTPSessionFailure.stopped) }
                } catch let rejection as SFTPDirectoryRejection {
                    // Only the strict decoder can construct this request-scoped
                    // reply. Cancellation still closes through the outer owner.
                    if self.allows(id) { self.end(); continuation.resume(throwing: rejection) }
                    else { self.stop(); _ = self.finish(); self.end(); continuation.resume(throwing: SFTPSessionFailure.stopped) }
                } catch let rejection as SFTPUploadOpenRefusal {
                    // upload() has already closed its source and durably saved
                    // notStarted. A complete negative first OPEN leaves this
                    // worker and authenticated connection reusable.
                    if self.allows(id) { self.end(); continuation.resume(throwing: rejection) }
                    else { self.stop(); _ = self.finish(); self.end(); continuation.resume(throwing: SFTPSessionFailure.stopped) }
                } catch { self.stop(); _ = self.finish(); self.end(); continuation.resume(throwing: error) }
            } }
          } onCancel: { self.stop() }
          if Task.isCancelled { stop(); _ = await close(); throw SFTPSessionFailure.stopped }
          guard allowsCompleted(id) else { throw SFTPSessionFailure.stopped }; return result
        } catch {
            if Task.isCancelled { stop(); _ = await close(); throw SFTPSessionFailure.stopped }
            throw error
        }
    }
    func admit() throws -> UUID {
        try lock.withLock {
            guard stopAt == nil, request == nil, descriptor >= 0 else { throw SFTPSessionFailure.busy }
            let id = UUID(); request = id; completed = nil; return id
        }
    }
    func allows(_ id: UUID) -> Bool { lock.withLock { stopAt == nil && request == id } }
    func allowsCompleted(_ id: UUID) -> Bool { lock.withLock { stopAt == nil && completed == id } }
    func end() { lock.withLock { completed = request; request = nil } }
    private func check() throws { if lock.withLock({ stopAt != nil }) { throw SFTPSessionFailure.stopped } }
    func checkForSelectedKey() throws { try check() }
    func checkIdle() throws {
        try check()
        // nextEvent may have just read the final frame before waitpid observes
        // exit. Consume those bytes before classifying an exited child.
        if let event = try nextEvent() ?? bufferedEvent() {
            if case let .closed(result) = event { throw SFTPSessionFailure.terminal(result.outcome) }
            throw SFTPSessionFailure.output
        }
        if eof || status != nil { throw SFTPSessionFailure.exited }
    }
    func stop() {
        lock.withLock {
            guard stopAt == nil else { return }; stopAt = ProcessInfo.processInfo.systemUptime
            originalMailbox?.requestStop(); originalAttempt?.requestStop()
            inPlaceMailbox?.requestStop(); inPlaceAttempt?.requestStop()
            #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
            uploadAttempt?.requestStop()
            #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
            folderUploadAttempt?.requestStop()
            #endif
            #endif
            guard descriptor >= 0, startedProtocol else { return }
            do { try sendLocked(kind: 6) } catch { _ = shutdown(descriptor, SHUT_WR) }
        }
    }
    private func sendLocked(kind: UInt8, payload: Data = Data()) throws {
        guard descriptor >= 0, inputSequence < UInt64.max else { throw SFTPSessionFailure.unavailable }
        var body = try SFTPWire.body(session: session, sequence: inputSequence, kind: kind, mode: mode); body.append(payload)
        var frame = try SFTPWire.frame(body)
        defer { frame.resetBytes(in: 0..<frame.count); body.resetBytes(in: 0..<body.count) }
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.remoteWriteAttempt(kind: kind)
        #endif
        let count = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        #if DEBUG && !SFTP_PARENT_STANDALONE
        if count > 0 { SFTPGeneratedBackendObservation.shared.protocolTransferred() }
        #endif
        guard count == frame.count else { _ = shutdown(descriptor, SHUT_WR); throw SFTPSessionFailure.unavailable }
        #if DEBUG
        if mode.allowsOriginalEditing || allowsInPlaceEditing { originalSentForQualification[kind, default: 0] += 1 }
        #endif
        inputSequence += 1
    }
    private func send(kind: UInt8, payload: Data = Data()) throws {
        try lock.withLock { guard stopAt == nil else { throw SFTPSessionFailure.stopped }; try sendLocked(kind: kind, payload: payload) }
    }
    func launch() throws {
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        try check(); try peer.validateAdmission?(); lease = try activity.begin()
        if let pool {
            catalog = try pool.reserveOnSessionExecutor(purpose: mode.allowsOriginalEditing || allowsInPlaceEditing ? .originalPending(session: session) : .ordinary)
        }
        try check()
        let prepared = try SMBBundledHelperIdentity.prepare(.sftp, bundle: peer.bundle)
        try check(); try prepared.validateInstallation()
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { pair.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        for index in 0..<2 {
            let copy = fcntl(pair[index], F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw SFTPSessionFailure.unavailable }
            Darwin.close(pair[index]); pair[index] = copy; var one: Int32 = 1
            guard setsockopt(copy, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SFTPSessionFailure.unavailable }
        }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SFTPSessionFailure.unavailable }
        var sendBytes: Int32 = 128 << 10
        guard setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBytes, socklen_t(MemoryLayout.size(ofValue: sendBytes))) == 0 else {
            throw SFTPSessionFailure.unavailable
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        var storeDescriptors: [Int32] = []
        defer { storeDescriptors.forEach { Darwin.close($0) } }
        if let catalog {
            for source in catalog.descriptors {
                let copy = fcntl(source, F_DUPFD_CLOEXEC, 10)
                guard copy >= 0 else { throw SFTPSessionFailure.unavailable }; storeDescriptors.append(copy)
            }
        }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_adddup2(&actions, pair[1], 3) == 0,
              posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0 else { throw SFTPSessionFailure.unavailable }
        for (index, source) in storeDescriptors.enumerated() {
            guard posix_spawn_file_actions_adddup2(&actions, source, Int32(index + 4)) == 0 else { throw SFTPSessionFailure.unavailable }
        }
        let argument: String
        switch mode {
        case .batches: argument = "--metadata-worker"
        case .catalog: argument = "--paged-worker"
        case .transferCatalog: argument = "--transfer-paged-worker"
        case .uploadCatalog: argument = "--upload-paged-worker"
        case .keyCatalog: argument = "--key-paged-worker"
        case .keyTransferCatalog: argument = "--key-transfer-paged-worker"
        case .keyUploadCatalog: argument = "--key-upload-paged-worker"
        case .interactiveCatalog: argument = "--interactive-paged-worker"
        case .interactiveTransferCatalog: argument = "--interactive-transfer-paged-worker"
        case .interactiveUploadCatalog: argument = "--interactive-upload-paged-worker"
        case .jumpCatalog: argument = "--jump-paged-worker"
        case .rememberedJumpCatalog: argument = "--remembered-jump-paged-worker"
        case .folderCatalog: argument = "--folder-paged-worker"
        case .folderUploadCatalog: argument = "--folder-upload-paged-worker"
        case .routedFolderCatalog: argument = "--routed-folder-paged-worker"
        case .exclusiveUploadCatalog: argument = "--exclusive-upload-paged-worker"
        case .freshFolderUploadCatalog: argument = "--fresh-folder-upload-paged-worker"
        case .routedExclusiveUploadCatalog: argument = "--routed-exclusive-upload-paged-worker"
        case .routedFreshFolderUploadCatalog: argument = "--routed-fresh-folder-upload-paged-worker"
        case .originalEditCatalog: argument = "--experimental-original-edit-worker"
        case .routedOriginalEditCatalog: argument = "--experimental-routed-original-edit-worker"
        case .inPlaceEditCatalog: argument = "--guarded-inplace-v1-startup3-worker"
        case .routedInPlaceEditCatalog: argument = "--routed-guarded-inplace-v1-startup3-worker"
        case .remoteActionCatalog: argument = "--remote-actions-paged-worker"
        case .routedRemoteActionCatalog: argument = "--routed-remote-actions-paged-worker"
        #if TRAVERSE_SFTP_EDITOR_QA
        case .agentCatalog: argument = "--agent-paged-worker"
        #endif
        }
        var argv = [prepared.helper.path, argument].map { strdup($0) } + [nil]
        var env = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), env.dropLast().allSatisfy({ $0 != nil }) else { throw SFTPSessionFailure.unavailable }
        var pid: pid_t = 0
        try check()
        let result = prepared.helper.withUnsafeFileSystemRepresentation { path in
            path.map { posix_spawn(&pid, $0, &actions, &attributes, &argv, &env) } ?? EINVAL
        }
        guard result == 0 else { throw SFTPSessionFailure.unavailable }
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.sftpWorkerChildStarted()
        gateAWorkerObserved = true
        #endif
        lock.withLock { child = pid; descriptor = pair[0] }; pair[0] = -1
        // Keep this exact direct child unreaped until Security returns.
        try prepared.validateInstallation(); try prepared.validateChild(pid); try check(); try peer.validateAdmission?()
        try startProtocol()
    }
    private func startProtocol() throws {
        var start = Data(); try SFTPWire.field(Data(peer.host.utf8), into: &start)
        if let jump = peer.jump {
            SFTPWire.number(UInt64(peer.port), bytes: 2, into: &start)
            try SFTPWire.field(Data(jump.host.utf8), into: &start); try SFTPWire.field(Data(peer.numericHost.utf8), into: &start)
            SFTPWire.number(UInt64(jump.port), bytes: 2, into: &start); SFTPWire.number(UInt64(peer.scopeID), bytes: 4, into: &start)
            start.append(SFTPWire.token(jump.nonce))
            if mode.hasRouteBinding {
                try SFTPWire.field(jump.previous?.bytes ?? Data(), into: &start)
                try SFTPWire.field(peer.previousKey?.bytes ?? Data(), into: &start)
            }
        } else {
            try SFTPWire.field(Data(peer.numericHost.utf8), into: &start); SFTPWire.number(UInt64(peer.port), bytes: 2, into: &start)
            SFTPWire.number(UInt64(peer.scopeID), bytes: 4, into: &start); try SFTPWire.field(peer.previousKey?.bytes ?? Data(), into: &start)
        }
        if let catalog {
            try SFTPWire.field(Data(catalog.path.path.utf8), into: &start); SFTPWire.number(catalog.quota, bytes: 8, into: &start)
        }
        if mode.allowsOriginalEditing { start.append(0x33) }
        if mode.allowsInPlaceEditing {
            guard let catalog, catalog.files.writerQuota <= 480 << 20 else { throw SFTPSharedBudgetFailure.capacity }
            start.append(contentsOf: [3, 7, 1, try SFTPInPlaceTransfers(peer: peer).rawValue])
        }
        if mode.allowsRemoteActions {
            if allowsInPlaceEditing { guard let catalog, catalog.files.writerQuota <= 480 << 20 else { throw SFTPSharedBudgetFailure.capacity } }
            start.append(contentsOf: [4, 7, 2, try SFTPInPlaceTransfers(peer: peer).rawValue,
                                      allowsInPlaceEditing ? 1 : 0])
        }
        try lock.withLock { guard stopAt == nil else { throw SFTPSessionFailure.stopped }; try sendLocked(kind: mode.isJump ? 16 : 1, payload: start); startedProtocol = true }
    }
    #if DEBUG
    var inPlaceObservationForQualification: SFTPOriginalParentObservation {
        lock.withLock {
            let local = inPlaceMailbox?.observation
            return .init(requestHeld: request != nil, localTaskHeld: inPlaceMailbox != nil,
                localReturned: local?.returned == true, processDrainRecorded: completedDrainAt != nil,
                sent: originalSentForQualification, receivedPositive: gateBPositiveReceives,
                inPlaceSaveAcknowledgements: gateBInPlaceSaveAcknowledgements,
                generatedLaunchAttempts: gateBGeneratedLaunchAttempts)
        }
    }
    var originalObservationForQualification: SFTPOriginalParentObservation {
        lock.withLock {
            let local = originalMailbox?.observation
            return .init(requestHeld: request != nil, localTaskHeld: originalMailbox != nil,
                localReturned: local?.returned == true, processDrainRecorded: completedDrainAt != nil,
                sent: originalSentForQualification, receivedPositive: gateBPositiveReceives,
                inPlaceSaveAcknowledgements: gateBInPlaceSaveAcknowledgements,
                generatedLaunchAttempts: gateBGeneratedLaunchAttempts)
        }
    }
    func launchGeneratedOriginalProcess(scenario: SFTPOriginalPipeScenario) throws {
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        guard mode == .originalEditCatalog, let pool,
              let executable = Bundle.main.executableURL,
              executable.isFileURL, executable.path.contains("/.build/traverse-development/"),
              pool.storage.directory.path.contains("/.build/traverse-development/") else { throw SFTPSessionFailure.input }
        try check(); lease = try activity.begin()
        catalog = try pool.reserveOnSessionExecutor(purpose: .originalPending(session: session))
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { pair.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        for index in 0..<2 {
            let copy = fcntl(pair[index], F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw SFTPSessionFailure.unavailable }
            Darwin.close(pair[index]); pair[index] = copy
            var one: Int32 = 1
            guard setsockopt(copy, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SFTPSessionFailure.unavailable }
        }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SFTPSessionFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_adddup2(&actions, pair[1], 3) == 0,
              posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0 else { throw SFTPSessionFailure.unavailable }
        var argv = [executable.path, "--sftp-original-pipe-child", scenario.rawValue].map { strdup($0) } + [nil]
        var environment = [strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else { throw SFTPSessionFailure.unavailable }
        var pid: pid_t = 0
        let result = executable.withUnsafeFileSystemRepresentation { path in
            path.map { posix_spawn(&pid, $0, &actions, &attributes, &argv, &environment) } ?? EINVAL
        }
        guard result == 0 else { throw SFTPSessionFailure.unavailable }
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.sftpWorkerChildStarted()
        gateAWorkerObserved = true
        #endif
        lock.withLock { child = pid; descriptor = pair[0] }; pair[0] = -1
        try startProtocol()
    }
    func launchGeneratedInPlaceProcess(scenario: SFTPInPlacePipeScenario,
        gateBCaseRoot: URL? = nil) throws {
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        var setupStage = "worker-input-refused"
        #endif
        do {
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.workerLaunchAttempt()
        #endif
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        lock.withLock { gateBGeneratedLaunchAttempts += 1 }
        #endif
        guard mode == .inPlaceEditCatalog, let pool,
              let executable = Bundle.main.executableURL,
              executable.isFileURL, executable.path.contains("/.build/traverse-development/"),
              pool.storage.directory.path.contains("/.build/traverse-development/") else { throw SFTPSessionFailure.input }
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        guard scenario == .success, let gateBCaseRoot else { throw SFTPSessionFailure.input }
        setupStage = "worker-parent-admission-refused"
        let admission = try GateBGeneratedChildAdmission.parentEnvironment(root: gateBCaseRoot,
            maximumSeconds: 60)
        guard admission.image == executable else { throw SFTPSessionFailure.input }
        let environmentStrings = admission.environment.sorted(by: { $0.key < $1.key })
            .map { $0.key + "=" + $0.value }
        #else
        guard gateBCaseRoot == nil else { throw SFTPSessionFailure.input }
        let environmentStrings = ["LANG=C", "LC_ALL=C"]
        #endif
        try check(); lease = try activity.begin()
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        setupStage = "worker-session-reserve-refused"
        #endif
        catalog = try pool.reserveOnSessionExecutor(purpose: .originalPending(session: session))
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        setupStage = "worker-socketpair-refused"
        #endif
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { pair.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        setupStage = "worker-socket-options-refused"
        #endif
        var sendBytes: Int32 = 128 << 10; guard setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBytes, socklen_t(MemoryLayout.size(ofValue: sendBytes))) == 0 else { throw SFTPSessionFailure.unavailable }
        for index in 0..<2 {
            let copy = fcntl(pair[index], F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw SFTPSessionFailure.unavailable }
            Darwin.close(pair[index]); pair[index] = copy
            var one: Int32 = 1
            guard setsockopt(copy, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { throw SFTPSessionFailure.unavailable }
        }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0 else { throw SFTPSessionFailure.unavailable }
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        setupStage = "worker-spawn-setup-refused"
        #endif
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SFTPSessionFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        guard sigemptyset(&mask) == 0, sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_adddup2(&actions, pair[1], 3) == 0,
              posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0 else { throw SFTPSessionFailure.unavailable }
        var argv = [executable.path, "--sftp-inplace-v1-pipe-child", scenario.rawValue].map { strdup($0) } + [nil]
        var environment = environmentStrings.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else { throw SFTPSessionFailure.unavailable }
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        setupStage = "worker-spawn-refused"
        #endif
        var pid: pid_t = 0
        let result = executable.withUnsafeFileSystemRepresentation { path in
            path.map { posix_spawn(&pid, $0, &actions, &attributes, &argv, &environment) } ?? EINVAL
        }
        guard result == 0 else { throw SFTPSessionFailure.unavailable }
        #if DEBUG && !SFTP_PARENT_STANDALONE
        SFTPGeneratedBackendObservation.shared.sftpWorkerChildStarted()
        gateAWorkerObserved = true
        #endif
        lock.withLock { child = pid; descriptor = pair[0] }; pair[0] = -1
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        setupStage = "worker-protocol-start-refused"
        #endif
        try startProtocol()
        } catch {
            #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
            if let failure = error as? GateBGeneratedFailure { throw failure }
            throw GateBGeneratedFailure(stage: setupStage)
            #else
            throw error
            #endif
        }
    }
    #endif
    func awaitReview() throws -> SFTPHostChallenge {
        guard case .challenge(let review) = try waitEvent() else { throw SFTPSessionFailure.output }; return review
    }
    func awaitJumpReview() throws -> SFTPHostChallenge {
        guard mode.isJump, case .jumpChallenge(let review) = try waitEvent() else { throw SFTPSessionFailure.output }; return review
    }
    func awaitDestinationReview() throws -> SFTPHostChallenge {
        try check(); guard mode.isJump, jumpAuthenticated, verified == nil else { throw SFTPSessionFailure.input }
        return try awaitReview()
    }
    func approveJump(_ action: SFTPTrustAction, review: SFTPHostChallenge) throws {
        try check(); guard let jump = peer.jump, review.session == jump.nonce else { throw SFTPSessionFailure.input }
        try decoder.noteJumpApproval(action, challenge: review)
        var payload = SFTPWire.token(jump.nonce); payload.append(action.rawValue)
        try SFTPWire.field(action == .reject ? Data() : review.current.bytes, into: &payload); try send(kind: 17, payload: payload)
        guard case .jumpVerified(let proof) = try waitEvent() else { throw SFTPSessionFailure.output }
        jumpVerified = proof
    }
    private func jumpContext(account: String, requireAuthenticated: Bool = false) throws -> SFTPVerifiedSessionContext {
        try check(); guard let jump = peer.jump, let proof = jumpVerified, proof.session == jump.nonce,
            proof.host == jump.host, proof.port == jump.port, requireAuthenticated ? jumpAuthenticated : !jumpAuthenticated,
            !account.isEmpty, account.utf8.count <= 256,
            !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw SFTPSessionFailure.input }
        if let route = peer.rememberedRoute {
            guard route.jump.address.host == jump.host, route.jump.address.port == jump.port,
                  Data(route.jump.account.utf8) == Data(account.utf8) else { throw SFTPSessionFailure.input }
        }
        return .init(host: jump.host, port: jump.port, requestedScopeID: peer.rememberedRoute?.jump.address.scopeID ?? peer.scopeID, account: account,
            key: proof.key, previous: jump.previous, permitsRememberingHost: false,
            authenticatedIdentity: requireAuthenticated ? jumpIdentity : nil, authenticatedSelectionID: requireAuthenticated ? jumpSelectionID : nil,
            usedServerPrompts: jumpUsedPrompts, permitsSavedAuthentication: false,
            routeKeyBinding: try peer.rememberedRoute?.bindingTag(role: .jump, verifiedJumpKeyDigest: Data(SHA256.hash(data: proof.key.bytes))))
    }
    func routePeer(_ role: SFTPRouteRole, requireAuthenticated: Bool) throws -> SFTPVerifiedRoutePeer {
        try check()
        guard mode.hasRouteBinding, let route = peer.rememberedRoute, let outer = jumpVerified,
              !requireAuthenticated || authenticated && jumpAuthenticated else { throw SFTPSessionFailure.input }
        let context = try role == .jump ? jumpContext(account: route.jump.account, requireAuthenticated: requireAuthenticated)
            : memoryContext(account: route.destination.account, requireAuthenticated: requireAuthenticated)
        let evidence = SFTPVerifiedRoutePeer(route: route, role: role, context: context, jumpKey: outer.key)
        try evidence.validate(); return evidence
    }
    struct RouteEndpointPreparation: Sendable {
        let endpoint: SFTPSavedRouteEndpoint
        let keyRequested: Bool, keyFailed: Bool
    }
    func routeEndpoint(_ choice: SFTPAuthenticationChoice, peer: SFTPVerifiedRoutePeer) throws -> RouteEndpointPreparation {
        let context = peer.context
        switch choice {
        case .password:
            guard context.authenticatedIdentity == nil, !context.usedServerPrompts else { throw SFTPSessionFailure.input }
            return .init(endpoint: .init(key: context.key, signIn: .password), keyRequested: false, keyFailed: false)
        case .serverPrompts:
            guard context.authenticatedIdentity == nil, context.usedServerPrompts else { throw SFTPSessionFailure.input }
            return .init(endpoint: .init(key: context.key, signIn: .serverPrompts), keyRequested: false, keyFailed: false)
        case let .keyFile(selected, _, remember, alias), let .keyFileWithServerPrompts(selected, _, remember, alias):
            guard let selected, context.authenticatedIdentity != nil, context.authenticatedSelectionID == selected.selectionID,
                  context.usedServerPrompts == choice.usesServerPrompts else { throw SFTPSessionFailure.input }
            var reference: SFTPKeyAccessReference?, failed = false
            if remember {
                do { reference = try selected.referenceAfterAuthentication(context, check: check) }
                catch { try check(); failed = true }
            }
            return .init(endpoint: .init(key: context.key, signIn: choice.usesServerPrompts ? .keyFileAndServerPrompts : .keyFile,
                keyAccess: reference, profileAlias: alias), keyRequested: remember, keyFailed: failed)
        case .userCertificate:
            throw SFTPSessionFailure.input
        }
    }
    func authenticateJump(account: String, password: Data) throws {
        _ = try jumpContext(account: account)
        guard let jump = peer.jump, !password.isEmpty, password.count <= 4096, !password.contains(0),
            String(data: password, encoding: .utf8) != nil else { throw SFTPSessionFailure.input }
        try decoder.noteJumpAuthentication(key: false, interactive: false)
        var payload = SFTPWire.token(jump.nonce); defer { payload.resetBytes(in: 0..<payload.count) }
        payload.append(0); try SFTPWire.field(Data(account.utf8), into: &payload); try SFTPWire.field(password, into: &payload)
        try send(kind: 18, payload: payload)
        guard case .jumpAuthenticated = try waitEvent() else { throw SFTPSessionFailure.output }; jumpAuthenticated = true
    }
    func authenticateJump(account: String, key: SFTPSelectedPrivateKey, passphrase: Data) throws -> SFTPHostKey {
        let context = try jumpContext(account: account)
        guard let jump = peer.jump, mode.hasRouteBinding || key.expectedIdentity == nil, passphrase.count <= 4096, !passphrase.contains(0),
            String(data: passphrase, encoding: .utf8) != nil else { throw SFTPSessionFailure.input }
        var body = try key.readAfterHostReview(context, check: check); defer { body.resetBytes(in: 0..<body.count) }
        try check(); try decoder.noteJumpAuthentication(key: true, interactive: false, expected: key.expectedIdentity)
        var payload = SFTPWire.token(jump.nonce); defer { payload.resetBytes(in: 0..<payload.count) }
        payload.append(1); try SFTPWire.field(Data(account.utf8), into: &payload); try SFTPWire.field(body, into: &payload)
        try SFTPWire.field(passphrase, into: &payload)
        if mode.hasRouteBinding { try SFTPWire.field(key.expectedIdentity?.bytes ?? Data(), into: &payload) }
        try send(kind: 18, payload: payload)
        guard case .jumpIdentity(let identity) = try waitEvent(), case .jumpAuthenticated = try waitEvent() else { throw SFTPSessionFailure.output }
        jumpIdentity = identity; jumpSelectionID = key.selectionID; jumpAuthenticated = true; return identity
    }
    func beginJumpInteractive(account: String, key: SFTPSelectedPrivateKey?, passphrase: Data) throws -> SFTPInteractiveStep {
        let context = try jumpContext(account: account)
        guard let jump = peer.jump, jumpPending == nil, passphrase.count <= 4096, !passphrase.contains(0),
            String(data: passphrase, encoding: .utf8) != nil else { throw SFTPSessionFailure.input }
        var payload = SFTPWire.token(jump.nonce); defer { payload.resetBytes(in: 0..<payload.count) }
        payload.append(key == nil ? 2 : 3); try SFTPWire.field(Data(account.utf8), into: &payload)
        if let key {
            guard mode.hasRouteBinding || key.expectedIdentity == nil else { throw SFTPSessionFailure.input }
            var body = try key.readAfterHostReview(context, check: check); defer { body.resetBytes(in: 0..<body.count) }
            try SFTPWire.field(body, into: &payload); try SFTPWire.field(passphrase, into: &payload)
            if mode.hasRouteBinding { try SFTPWire.field(key.expectedIdentity?.bytes ?? Data(), into: &payload) }
        }
        try check(); try decoder.noteJumpAuthentication(key: key != nil, interactive: true, expected: key?.expectedIdentity)
        jumpUsingKey = key != nil; jumpSelectionID = key?.selectionID; jumpUsedPrompts = true
        try send(kind: 18, payload: payload); return try jumpInteractiveStep()
    }
    func answerJumpInteractive(_ answers: SFTPInteractiveAnswers, challenge: SFTPInteractiveChallenge) throws -> SFTPInteractiveStep {
        try check(); guard !jumpAuthenticated, let jump = peer.jump, jumpPending == challenge else { throw SFTPSessionFailure.input }
        try decoder.noteJumpAnswers(challenge, answers: answers)
        var payload = SFTPWire.token(jump.nonce); defer { payload.resetBytes(in: 0..<payload.count) }
        payload.append(contentsOf: [challenge.round, UInt8(answers.values.count)])
        for answer in answers.values { try SFTPWire.field(answer, into: &payload) }
        jumpPending = nil; try send(kind: 19, payload: payload); return try jumpInteractiveStep()
    }
    private func jumpInteractiveStep() throws -> SFTPInteractiveStep {
        let event = try waitEvent()
        if case .jumpInteractiveChallenge(let challenge) = event { jumpPending = challenge; return .challenge(challenge) }
        if jumpUsingKey {
            guard case .jumpIdentity(let identity) = event, case .jumpAuthenticated = try waitEvent() else { throw SFTPSessionFailure.output }; jumpIdentity = identity
        } else { guard case .jumpAuthenticated = event else { throw SFTPSessionFailure.output } }
        jumpAuthenticated = true; return .complete
    }
    func checkJumpInteractive(_ challenge: SFTPInteractiveChallenge) throws {
        try check(); guard !jumpAuthenticated, jumpPending == challenge else { throw SFTPSessionFailure.input }
        if let event = try nextEvent(pollMilliseconds: 0) {
            if case .closed(let terminal) = event { throw SFTPSessionFailure.terminal(terminal.outcome) }; throw SFTPSessionFailure.output
        }
        guard !eof, status == nil else { throw SFTPSessionFailure.exited }
    }
    func approve(_ action: SFTPTrustAction, review: SFTPHostChallenge) throws {
        try check(); try decoder.noteApproval(action, challenge: review)
        var data = Data([action.rawValue]); try SFTPWire.field(action == .reject ? Data() : review.current.bytes, into: &data)
        try send(kind: 2, payload: data)
        guard case .verified(let proof) = try waitEvent() else { throw SFTPSessionFailure.output }
        verified = proof; approvedAction = action
    }
    #if TRAVERSE_SFTP_EDITOR_QA
    func listAgentIdentities(socket: URL) throws -> [SFTPAgentIdentitySummary] {
        try check()
        guard mode == .agentCatalog, verified?.session == session, !authenticated,
              socket.isFileURL, !socket.hasDirectoryPath,
              socket.standardizedFileURL == socket,
              socket.path.hasPrefix("/"), socket.path.utf8.count <= 103 else {
            throw SFTPSessionFailure.input
        }
        try decoder.noteAgentList()
        var payload = Data()
        try SFTPWire.field(Data(socket.path.utf8), into: &payload)
        try send(kind: 80, payload: payload)
        guard case .agentIdentities(let identities) = try waitEvent() else { throw SFTPSessionFailure.output }
        return identities
    }
    func authenticate(account: String, agentIdentity: SFTPAgentIdentitySummary) throws {
        try check()
        guard mode == .agentCatalog, verified?.session == session, !authenticated,
              !account.isEmpty, account.utf8.count <= 256,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SFTPSessionFailure.input
        }
        try decoder.noteAgentSelection(agentIdentity)
        var payload = Data()
        try SFTPWire.field(Data(account.utf8), into: &payload)
        payload.append(agentIdentity.digest)
        try send(kind: 81, payload: payload)
        guard case .agentSelected(let digest) = try waitEvent(), digest == agentIdentity.digest,
              case .authenticated = try waitEvent(), case .ready = try waitEvent() else {
            throw SFTPSessionFailure.output
        }
        authenticated = true
    }
    #endif
    func authenticate(account: String, password: Data) throws {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard mode != .agentCatalog else { throw SFTPSessionFailure.denied }
        #endif
        try check()
        guard verified?.session == session, !account.isEmpty, account.utf8.count <= 256,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !password.isEmpty, password.count <= 4096, !password.contains(0), String(data: password, encoding: .utf8) != nil else {
            throw SFTPSessionFailure.input
        }
        var data = Data(); defer { data.resetBytes(in: 0..<data.count) }
        try SFTPWire.field(Data(account.utf8), into: &data); try SFTPWire.field(password, into: &data); try send(kind: 3, payload: data)
        guard case .authenticated = try waitEvent(), case .ready = try waitEvent() else { throw SFTPSessionFailure.output }
        authenticated = true
    }
    func authenticate(account: String, key: SFTPSelectedPrivateKey, passphrase: Data,
                      certificate: SFTPSelectedUserCertificate? = nil) throws -> SFTPHostKey {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard mode != .agentCatalog else { throw SFTPSessionFailure.denied }
        #endif
        try check()
        guard verified?.session == session, mode.allowsKeyAuthentication, !authenticated,
              certificate == nil || !mode.isJump && !mode.isAgent,
              !account.isEmpty, account.utf8.count <= 256,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              passphrase.count <= 4096, !passphrase.contains(0), String(data: passphrase, encoding: .utf8) != nil else {
            throw SFTPSessionFailure.input
        }
        // This serial owner holds host evidence, cancellation and the actual
        // read. Import/presentation cannot invoke this operation speculatively.
        let context = try memoryContext(account: account, requireAuthenticated: false)
        var body = try key.readAfterHostReview(context, check: check)
        defer { body.resetBytes(in: 0..<body.count) }
        var certificateBody = try certificate?.readAfterHostReview(context, keyIdentity: key.expectedIdentity,
            check: check) ?? Data()
        defer { certificateBody.resetBytes(in: 0..<certificateBody.count) }
        try check()
        if certificate != nil { try decoder.noteCertificateAuthentication(expected: key.expectedIdentity, interactive: false) }
        else { try decoder.noteKeyAuthentication(expected: key.expectedIdentity) }
        var payload = Data(); defer { payload.resetBytes(in: 0..<payload.count) }
        try SFTPWire.field(Data(account.utf8), into: &payload); try SFTPWire.field(body, into: &payload)
        try SFTPWire.field(passphrase, into: &payload); try SFTPWire.field(key.expectedIdentity?.bytes ?? Data(), into: &payload)
        if certificate != nil { try SFTPWire.field(certificateBody, into: &payload) }
        try send(kind: certificate == nil ? 12 : 33, payload: payload)
        guard case .authenticatedIdentity(let identity) = try waitEvent(), case .authenticated = try waitEvent(),
              case .ready = try waitEvent() else { throw SFTPSessionFailure.output }
        authenticated = true; authenticatedIdentity = identity; authenticatedSelectionID = key.selectionID
        authenticatedWithUserCertificate = certificate != nil
        authenticatedCertificateSelectionID = certificate?.selectionID; return identity
    }
    func memoryContext(account: String, requireAuthenticated: Bool) throws -> SFTPVerifiedSessionContext {
        try check()
        guard let verified, verified.session == session, verified.host == peer.host, verified.port == peer.port,
              !requireAuthenticated || authenticated else { throw SFTPSessionFailure.input }
        var routeTag: Data?
        if let route = peer.rememberedRoute {
            guard jumpAuthenticated, let outer = jumpVerified, Data(route.destination.account.utf8) == Data(account.utf8),
                  route.destination.address.host == peer.host, route.destination.address.port == peer.port else { throw SFTPSessionFailure.input }
            routeTag = try route.bindingTag(role: .destination, verifiedJumpKeyDigest: Data(SHA256.hash(data: outer.key.bytes)))
        }
        return .init(host: peer.host, port: peer.port, requestedScopeID: peer.requestedScopeID, account: account,
            key: verified.key, previous: peer.previousKey, permitsRememberingHost: approvedAction == .remember || approvedAction == .replaceVerified,
            authenticatedIdentity: authenticatedIdentity, authenticatedSelectionID: authenticatedSelectionID,
            authenticatedWithUserCertificate: authenticatedWithUserCertificate,
            authenticatedCertificateSelectionID: authenticatedCertificateSelectionID,
            // Certificate sessions use their separate paired-reference save path.
            // The existing plain-key and password save paths stay closed.
            usedServerPrompts: authenticatedWithInteractive,
            permitsSavedAuthentication: !mode.isJump && !mode.isAgent && !authenticatedWithUserCertificate,
            routeKeyBinding: routeTag)
    }
    func beginInteractive(account: String, key: SFTPSelectedPrivateKey? = nil, passphrase: Data = Data(),
                          certificate: SFTPSelectedUserCertificate? = nil) throws -> SFTPInteractiveStep {
        #if TRAVERSE_SFTP_EDITOR_QA
        guard mode != .agentCatalog else { throw SFTPSessionFailure.denied }
        #endif
        try check()
        guard mode.allowsInteractiveAuthentication, verified?.session == session, !authenticated, interactivePending == nil,
              certificate == nil || key != nil && !mode.isJump && !mode.isAgent,
              !account.isEmpty, account.utf8.count <= 256,
              !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              passphrase.count <= 4096, !passphrase.contains(0), String(data: passphrase, encoding: .utf8) != nil else { throw SFTPSessionFailure.input }
        var payload = Data(); defer { payload.resetBytes(in: 0..<payload.count) }
        try SFTPWire.field(Data(account.utf8), into: &payload)
        if let key {
            let context = try memoryContext(account: account, requireAuthenticated: false)
            var body = try key.readAfterHostReview(context, check: check)
            defer { body.resetBytes(in: 0..<body.count) }
            var certificateBody = try certificate?.readAfterHostReview(context, keyIdentity: key.expectedIdentity,
                check: check) ?? Data()
            defer { certificateBody.resetBytes(in: 0..<certificateBody.count) }
            try check()
            if certificate != nil { try decoder.noteCertificateAuthentication(expected: key.expectedIdentity, interactive: true) }
            else { try decoder.noteInteractiveAuthentication(expected: key.expectedIdentity, usingKey: true) }
            interactiveKeySelection = key.selectionID
            interactiveUsesUserCertificate = certificate != nil
            interactiveCertificateSelectionID = certificate?.selectionID
            try SFTPWire.field(body, into: &payload); try SFTPWire.field(passphrase, into: &payload)
            try SFTPWire.field(key.expectedIdentity?.bytes ?? Data(), into: &payload)
            if certificate != nil { try SFTPWire.field(certificateBody, into: &payload) }
            try send(kind: certificate == nil ? 15 : 34, payload: payload)
        } else {
            try decoder.noteInteractiveAuthentication(expected: nil, usingKey: false); interactiveKeySelection = nil
            interactiveUsesUserCertificate = false
            interactiveCertificateSelectionID = nil
            try send(kind: 13, payload: payload)
        }
        return try interactiveStep()
    }
    func answerInteractive(_ answers: SFTPInteractiveAnswers, challenge: SFTPInteractiveChallenge) throws -> SFTPInteractiveStep {
        try check()
        guard !authenticated, interactivePending == challenge else { throw SFTPSessionFailure.input }
        try decoder.noteInteractiveAnswers(challenge, answers: answers)
        var payload = Data([challenge.round, UInt8(answers.values.count)]); defer { payload.resetBytes(in: 0..<payload.count) }
        for value in answers.values { try SFTPWire.field(value, into: &payload) }
        interactivePending = nil; try send(kind: 14, payload: payload); return try interactiveStep()
    }
    private func interactiveStep() throws -> SFTPInteractiveStep {
        let first = try waitEvent()
        if case .interactiveChallenge(let challenge) = first {
            guard interactivePending == nil else { throw SFTPSessionFailure.output }
            interactivePending = challenge; return .challenge(challenge)
        }
        let identity: SFTPHostKey?
        if let _ = interactiveKeySelection {
            guard case .authenticatedIdentity(let observed) = first, case .authenticated = try waitEvent() else { throw SFTPSessionFailure.output }
            identity = observed
        } else {
            guard case .authenticated = first else { throw SFTPSessionFailure.output }; identity = nil
        }
        guard case .ready = try waitEvent() else { throw SFTPSessionFailure.output }
        authenticated = true; authenticatedIdentity = identity; authenticatedSelectionID = interactiveKeySelection
        authenticatedWithInteractive = true
        authenticatedWithUserCertificate = interactiveUsesUserCertificate
        authenticatedCertificateSelectionID = interactiveCertificateSelectionID
        interactiveKeySelection = nil; interactiveUsesUserCertificate = false
        interactiveCertificateSelectionID = nil; return .complete
    }
    func checkInteractiveChallenge(_ challenge: SFTPInteractiveChallenge) throws {
        try check(); guard !authenticated, interactivePending == challenge else { throw SFTPSessionFailure.input }
        if let event = try nextEvent(pollMilliseconds: 0) {
            if case .closed(let terminal) = event { throw SFTPSessionFailure.terminal(terminal.outcome) }
            throw SFTPSessionFailure.output
        }
        guard !eof, status == nil else { throw SFTPSessionFailure.exited }
    }
    func openDirectory(_ path: String) throws -> UUID {
        try check(); guard !path.isEmpty, path.utf8.count <= 8192, !path.contains("\0") else { throw SFTPSessionFailure.input }
        let id = UUID(); try decoder.beginDirectory(id)
        var bytes = SFTPWire.token(id); try SFTPWire.field(Data(path.utf8), into: &bytes); try send(kind: 4, payload: bytes)
        guard case .directory(let actual, _) = try waitEvent(), actual == id else { throw SFTPSessionFailure.output }; return id
    }
    func nextBatch(_ generation: UUID) throws -> (entries: [SFTPWorkerEntry], end: Bool) {
        try check(); try decoder.beginNext(generation); try send(kind: 5, payload: SFTPWire.token(generation))
        guard case .batch(let actual, let rows, let end) = try waitEvent(), actual == generation else { throw SFTPSessionFailure.output }
        return (rows, end)
    }
    func openStoredDirectory(_ path: String) throws -> (UUID, SFTPStoredSnapshot) {
        try check(); guard mode.isCatalog, !path.isEmpty, path.utf8.count <= 8192, !path.contains("\0") else { throw SFTPSessionFailure.input }
        let id = UUID(); try decoder.beginDirectory(id)
        var bytes = SFTPWire.token(id); try SFTPWire.field(Data(path.utf8), into: &bytes); try send(kind: 4, payload: bytes)
        switch try waitEvent() {
        case .storedDirectory(let actual, _, let snapshot) where actual == id: return (id, snapshot)
        case .directoryRejected(let actual, let rejection) where actual == id: throw rejection
        default: throw SFTPSessionFailure.output
        }
    }
    func enableDirectoryRecovery() throws {
        try check(); try decoder.beginDirectoryRecovery(); try send(kind: 30, payload: Data([1]))
        guard case .directoryRecoveryEnabled = try waitEvent() else { throw SFTPSessionFailure.output }
    }
    func ingestNext(_ generation: UUID) throws -> SFTPStoredSnapshot {
        try check(); guard mode.isCatalog else { throw SFTPSessionFailure.input }
        try decoder.beginNext(generation); try send(kind: 5, payload: SFTPWire.token(generation))
        guard case .storedProgress(let actual, let snapshot) = try waitEvent(), actual == generation else { throw SFTPSessionFailure.output }
        return snapshot
    }
    func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64, sort: SFTPStoredSort, descending: Bool) throws -> SFTPStoredPage? {
        try check(); let request = UUID()
        do { try decoder.beginPage(request, generation: generation, snapshot: snapshot, offset: offset, limit: 256) }
        catch SFTPProtocolFailure.stale { return nil }
        var bytes = SFTPWire.token(request); bytes.append(SFTPWire.token(generation))
        SFTPWire.number(snapshot.revision, bytes: 8, into: &bytes); SFTPWire.number(offset, bytes: 8, into: &bytes)
        SFTPWire.number(256, bytes: 2, into: &bytes); bytes.append(sort.rawValue); bytes.append(descending ? 1 : 0)
        try send(kind: 7, payload: bytes)
        switch try waitEvent() {
        case .storedPage(let page) where page.request == request: return page
        case .stalePage(let actual) where actual == request: return nil
        default: throw SFTPSessionFailure.output
        }
    }
    func find(_ generation: UUID, snapshot: SFTPStoredSnapshot,
              query: RemoteDirectoryFindQuery) throws -> Result<SFTPDirectoryFindResult, RemoteDirectoryFindFailure> {
        try check()
        do { try decoder.beginFind(query, generation: generation, snapshot: snapshot) }
        catch SFTPProtocolFailure.stale { return .failure(.stale) }
        var bytes = SFTPWire.token(query.id); bytes.append(SFTPWire.token(generation))
        for number in [snapshot.read, snapshot.revision, snapshot.count, snapshot.folders] {
            SFTPWire.number(number, bytes: 8, into: &bytes)
        }
        bytes.append(snapshot.state.rawValue)
        try SFTPWire.field(Data(query.text.utf8), into: &bytes)
        try send(kind: 31, payload: bytes)
        switch try waitEvent() {
        case .found(let result) where result.query == query: return .success(result)
        case .findStale(let id) where id == query.id: return .failure(.stale)
        case .findUnavailable(let id) where id == query.id: return .failure(.unavailable)
        default: throw SFTPSessionFailure.output
        }
    }
    func filteredPage(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
                      sort: SFTPStoredSort, descending: Bool, find: SFTPDirectoryFindResult) throws -> Result<SFTPStoredPage?, RemoteDirectoryFindFailure> {
        try check(); let request = UUID()
        do { try decoder.beginPage(request, generation: generation, snapshot: snapshot, offset: offset, limit: 256, find: find) }
        catch SFTPProtocolFailure.stale { return .failure(.stale) }
        var bytes = SFTPWire.token(request); bytes.append(SFTPWire.token(generation))
        SFTPWire.number(snapshot.revision, bytes: 8, into: &bytes); SFTPWire.number(offset, bytes: 8, into: &bytes)
        SFTPWire.number(256, bytes: 2, into: &bytes); bytes.append(sort.rawValue); bytes.append(descending ? 1 : 0)
        bytes.append(SFTPWire.token(find.query.id)); try send(kind: 7, payload: bytes)
        switch try waitEvent() {
        case .storedPage(let page) where page.request == request: return .success(page)
        case .stalePage(let id) where id == request: return .failure(.stale)
        case .filteredPageUnavailable(let id) where id == request: return .failure(.unavailable)
        default: throw SFTPSessionFailure.output
        }
    }
    func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) throws -> Result<RemoteFolderSizeSummary, RemoteFolderSizeFailure> {
        try check()
        do { try decoder.beginFolderSize(selection) }
        catch SFTPProtocolFailure.stale { return .failure(.stale) }
        var bytes = SFTPWire.token(selection.request); bytes.append(SFTPWire.token(selection.generation))
        for number in [selection.snapshot.read, selection.snapshot.revision, selection.snapshot.count, selection.snapshot.folders] {
            SFTPWire.number(number, bytes: 8, into: &bytes)
        }
        bytes.append(selection.snapshot.state.rawValue)
        SFTPWire.number(selection.row.observation, bytes: 8, into: &bytes)
        try send(kind: 32, payload: bytes)
        switch try waitEvent(timeout: 125) {
        case .folderSize(let request, let value) where request == selection.request: return .success(value)
        case .folderSizeUnavailable(let request, let reason) where request == selection.request: return .failure(reason)
        default: throw SFTPSessionFailure.output
        }
    }
    func remoteActionDirectory(_ intent: SFTPRemoteActionIntent) throws -> String {
        try check(); return try decoder.remoteActionDirectory(intent)
    }
    func observedActionDirectory(_ intent: SFTPRemoteActionIntent) throws -> Result<String, SFTPProtocolFailure> {
        try check()
        do { return .success(try decoder.remoteActionDirectory(intent)) }
        catch SFTPProtocolFailure.stale { return .failure(.stale) }
        catch SFTPProtocolFailure.phase { return .failure(.phase) }
    }
    func prepareRemoteAction(_ intent: SFTPRemoteActionIntent) throws -> SFTPWorkerEvent {
        try check(); try decoder.beginRemoteAction(intent)
        try send(kind: 60, payload: intent.command())
        let result = try waitEvent()
        switch result {
        case .remoteActionPrepared(let id) where id == intent.request,
             .remoteActionRefused(let id, _) where id == intent.request: return result
        default: throw SFTPSessionFailure.output
        }
    }
    func commitRemoteAction(_ request: UUID) throws -> SFTPWorkerEvent {
        try check(); try decoder.permitRemoteAction(request)
        try send(kind: 61, payload: SFTPWire.token(request))
        let result = try waitEvent()
        switch result {
        case .remoteActionConfirmed(let id) where id == request,
             .remoteActionRefused(let id, _) where id == request,
             .remoteActionNeedsReview(let id) where id == request: return result
        default: throw SFTPSessionFailure.output
        }
    }
    private func waitEvent(timeout: TimeInterval = 32) throws -> SFTPWorkerEvent {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try check(); if let event = try nextEvent() {
                if case .closed(let result) = event { throw SFTPSessionFailure.terminal(result.outcome) }; return event
            }
            if eof { throw SFTPSessionFailure.exited }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SFTPSessionFailure.deadline }
        }
    }
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
    func prepareFolderDownload(_ selection: SFTPFolderDownloadSelection,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) throws -> SFTPPreparedFolderDownload {
        try check(); guard allowsRequestedFolderDownloads else { throw SFTPSessionFailure.input }
        try decoder.beginFolder(selection); try send(kind: 20, payload: selection.command())
        while true {
            switch try waitEvent() {
            case .folderStarted(let request) where request == selection.request:
                progress?(.init(phase: .checkingFolders, receivedBytes: 0, completedFiles: 0, checkedEntries: 0))
            case .folderMetadataProgress(let request, 0, let count) where request == selection.request:
                progress?(.init(phase: .checkingFolders, receivedBytes: 0, completedFiles: 0, checkedEntries: count))
            case .folderPrepared(let value) where value.selection == selection: return value
            default: throw SFTPSessionFailure.output
            }
        }
    }
    func releaseFolderDownload(_ prepared: SFTPPreparedFolderDownload) throws {
        try check(); try decoder.releaseFolder(prepared.selection.request)
        try send(kind: 22, payload: SFTPWire.token(prepared.selection.request))
        guard case .folderReleased(let request) = try waitEvent(), request == prepared.selection.request else { throw SFTPSessionFailure.output }
    }
    func receiveFolderDownload(_ prepared: SFTPPreparedFolderDownload, into tree: RemoteDownloadedTree,
        progress: (@Sendable (SFTPFolderDownloadProgress) -> Void)?) throws -> SFTPFolderDownloadReceipt {
        try check(); guard allowsRequestedFolderDownloads, tree.matches(prepared) else { throw SFTPSessionFailure.input }
        try decoder.receiveFolder(prepared); try send(kind: 21, payload: SFTPWire.token(prepared.selection.request))
        var total: UInt64 = 0, files = 0, lastProgress = ProcessInfo.processInfo.systemUptime
        while true {
            switch try waitEvent() {
            case .folderReceiving(let request) where request == prepared.selection.request:
                progress?(.init(phase: .checkingFolders, receivedBytes: 0, completedFiles: 0, checkedEntries: 0))
            case .folderMetadataProgress(let request, let phase, let count) where request == prepared.selection.request:
                progress?(.init(phase: phase == 3 ? .checkingCopy : .checkingFolders, receivedBytes: total, completedFiles: files, checkedEntries: count))
            case .folderMemberStarted(let request, let ordinal):
                try tree.beginMember(request: request, ordinal: ordinal)
            case .folderMemberBytes(let request, let ordinal, let offset, let bytes):
                try tree.appendOnSessionExecutor(request: request, ordinal: ordinal, offset: offset, bytes: bytes); total += UInt64(bytes.count)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 0.25 { lastProgress = now; progress?(.init(phase: .receiving, receivedBytes: total, completedFiles: files, checkedEntries: 0)) }
            case .folderMemberFinished(let request, let ordinal, let bytes):
                try tree.endMember(request: request, ordinal: ordinal, receivedBytes: bytes); files += 1
            case .folderComplete(let request, let bytes, let count) where request == prepared.selection.request:
                guard bytes == total, count == files else { throw SFTPSessionFailure.output }
                progress?(.init(phase: .checkingCopy, receivedBytes: total, completedFiles: files, checkedEntries: prepared.manifest.nodes.count))
                return .init(request: request, bytes: bytes, files: count)
            default: throw SFTPSessionFailure.output
            }
        }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_DOWNLOAD_QUALIFICATION
    func download(_ selection: SFTPDownloadSelection, into file: RemoteDownloadedFile,
                  progress: (@Sendable (UInt64) -> Void)?) throws -> SFTPDownloadReceipt {
        try check(); guard allowsRequestedDownloads, selection == file.selection else { throw SFTPSessionFailure.input }
        try decoder.beginDownload(selection); try send(kind: 8, payload: selection.command())
        var started = false, lastProgress = ProcessInfo.processInfo.systemUptime
        while true {
            try check()
            switch try waitEvent() {
            case .downloadStarted(let observed) where observed == selection:
                guard !started else { throw SFTPSessionFailure.output }; started = true; progress?(0)
            #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_QUALIFICATION
            case .downloadCheckpoint(let request) where started && request == selection.request: break
            #endif
            case .downloadBytes(let request, let offset, let bytes) where started && request == selection.request:
                try file.appendOnSessionExecutor(request: request, offset: offset, bytes: bytes)
                let now = ProcessInfo.processInfo.systemUptime, written = offset + UInt64(bytes.count)
                if now - lastProgress >= 0.25 || written == selection.logicalBytes { lastProgress = now; progress?(written) }
            case .downloadComplete(let receipt) where started && receipt.selection == selection: return receipt
            default: throw SFTPSessionFailure.output
            }
        }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
    func uploadDestination(_ generation: UUID, snapshot: SFTPStoredSnapshot, account: String) throws -> SFTPUploadDestination {
        try check(); guard allowsFreshUploads, snapshot.state == .complete else { throw SFTPSessionFailure.input }
        let directory = try decoder.uploadDirectory(generation, revision: snapshot.revision)
        return .init(session: session, generation: generation, revision: snapshot.revision, directory: directory,
            context: try memoryContext(account: account, requireAuthenticated: true))
    }
    func upload(_ attempt: SFTPUploadAttempt, account: String, progress: (@Sendable (UInt64) -> Void)?) throws -> SFTPCompletedUpload {
        try check(); guard allowsFreshUploads else { throw SFTPSessionFailure.input }
        try attempt.validate(session: session, context: memoryContext(account: account, requireAuthenticated: true))
        try decoder.beginUpload(attempt.selection)
        try lock.withLock {
            guard stopAt == nil, uploadAttempt == nil, folderUploadAttemptIsIdle else { throw SFTPSessionFailure.stopped }
            try attempt.takeForWorker(); uploadAttempt = attempt; uploadNoRemoteMutation = true
        }
        // This executes on the session's bounded background executor. If the
        // durable barrier fails, no remote Upload command is sent.
        try attempt.requestCreationOnSessionExecutor(); try check()
        uploadNoRemoteMutation = false
        try send(kind: 9, payload: attempt.selection.command())
        var started = false, lastProgress = ProcessInfo.processInfo.systemUptime
        while true {
            try check()
            switch try waitEvent() {
            case .uploadStarted(let selection) where selection == attempt.selection:
                guard !started else { throw SFTPSessionFailure.output }; started = true; progress?(0)
            case .uploadSourceRequest(let request, let offset, let count) where started && request == attempt.selection.request:
                let bytes = try attempt.readOnSessionExecutor(offset: offset, count: count); try check()
                try send(kind: 10, payload: decoder.noteUploadSource(request, offset: offset, bytes: bytes))
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 0.25 { lastProgress = now; progress?(offset) }
            case .uploadPublicationRequest(let request, let digest) where started && request == attempt.selection.request:
                try attempt.permitPublicationOnSessionExecutor(digest: digest); try check()
                try send(kind: 11, payload: decoder.noteUploadPublication(request, digest: digest)); progress?(attempt.selection.logicalBytes)
            case .uploadComplete(let receipt) where started && receipt.selection == attempt.selection:
                let result = try attempt.finishOnSessionExecutor(receipt)
                #if DEBUG && !SFTP_PARENT_STANDALONE
                SFTPGeneratedBackendObservation.shared.remoteSaveAcknowledged()
                #endif
                lock.withLock { uploadAttempt = nil }; return result
            case .uploadInterrupted(let interruption) where started && interruption.selection == attempt.selection:
                uploadNoRemoteMutation = !interruption.temporaryMayExist && !interruption.publicationMayHaveHappened
                throw interruption
            case .uploadOpenRefused(let refusal) where started && refusal.selection == attempt.selection:
                // Worker may continue only after source and durable history
                // have ended. A failed local outcome save fails this session.
                uploadNoRemoteMutation = true
                try attempt.finishRefusedOpenOnSessionExecutor()
                lock.withLock { uploadAttempt = nil }
                throw refusal
            default: throw SFTPSessionFailure.output
            }
        }
    }
    #endif
    #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
    func uploadFolder(_ attempt: SFTPFolderUploadAttempt, account: String, progress: (@Sendable (UInt64, Int) -> Void)?) throws -> SFTPCompletedFolderUpload {
        try check(); guard allowsFreshFolderUploads else { throw SFTPSessionFailure.input }
        try attempt.validate(session: session, context: memoryContext(account: account, requireAuthenticated: true))
        try decoder.beginFolderUpload(attempt.selection)
        try lock.withLock {
            guard stopAt == nil, uploadAttempt == nil, folderUploadAttempt == nil else { throw SFTPSessionFailure.stopped }
            try attempt.takeForWorker(); folderUploadAttempt = attempt; folderUploadNoRemoteMutation = true
        }
        try attempt.requestCreationOnSessionExecutor(); try check(); folderUploadNoRemoteMutation = false
        try send(kind: 23, payload: attempt.selection.command())
        var started = false, lastProgress = ProcessInfo.processInfo.systemUptime, sent: UInt64 = 0, verified = 0
        let request = attempt.selection.request
        func respond(_ response: SFTPFolderUploadReply) throws {
            try check(); let (tag, payload) = try decoder.noteFolderUploadReply(request: request, response); try send(kind: tag, payload: payload)
        }
        while true {
            try check()
            switch try waitEvent() {
            case .folderUploadStarted(let selection) where selection == attempt.selection:
                guard !started else { throw SFTPSessionFailure.output }; started = true; progress?(0, 0)
            case .folderUploadManifestRequest(let id, let offset, let count) where started && id == request:
                try respond(.manifest(offset: offset, bytes: attempt.manifestOnSessionExecutor(offset: offset, count: count)))
            case .folderUploadRootCreated(let id) where started && id == request:
                try attempt.acknowledgeRootOnSessionExecutor(); try respond(.rootAcknowledged)
            case .folderUploadSourceRequest(let id, let node, let offset, let count) where started && id == request:
                let bytes = try attempt.readOnSessionExecutor(node: node, offset: offset, count: count); try respond(.source(node: node, offset: offset, bytes: bytes)); sent += UInt64(bytes.count)
                let now = ProcessInfo.processInfo.systemUptime; if now - lastProgress >= 0.25 { lastProgress = now; progress?(sent, verified) }
            case .folderUploadFilePermitRequest(let id, let node, let digest) where started && id == request:
                try attempt.permitFileOnSessionExecutor(node: node, digest: digest); try respond(.filePermit(node: node, digest: digest))
            case .folderUploadVerified(let id, let node, let files, let bytes) where started && id == request:
                try attempt.checkpointOnSessionExecutor(node: node, files: files, bytes: bytes); try respond(.progress(node: node, files: files, bytes: bytes)); verified = files; progress?(sent, files)
            case .folderUploadFinalPermitRequest(let id, let digest) where started && id == request:
                try attempt.permitFinalOnSessionExecutor(digest: digest); try respond(.finalPermit(digest))
            case .folderUploadComplete(let receipt) where started && receipt.selection == attempt.selection:
                let result = try attempt.finishOnSessionExecutor(receipt)
                #if DEBUG && !SFTP_PARENT_STANDALONE
                SFTPGeneratedBackendObservation.shared.remoteSaveAcknowledged()
                #endif
                lock.withLock { folderUploadAttempt = nil }; return result
            case .folderUploadInterrupted(let interruption) where started:
                folderUploadNoRemoteMutation = !interruption.rootMayExist && !interruption.rootAcknowledged; throw interruption
            default: throw SFTPSessionFailure.output
            }
        }
    }
    #endif
    private func inPlaceLocal(_ operation: SFTPInPlaceLocalOperation, afterOperationReturn: Bool = false) throws -> SFTPInPlaceLocalReply {
        if !afterOperationReturn { try check() }
        let mailbox = try lock.withLock { () throws -> SFTPInPlaceLocalMailbox in
            guard inPlaceMailbox == nil, originalMailbox == nil else { throw SFTPTextFailure.busy }
            guard afterOperationReturn || stopAt == nil else { throw SFTPTextFailure.stopped }
            #if DEBUG
            let probe: (@Sendable () throws -> Void)?
            if let held = peer.inPlaceLocalProbe { probe = { try held(operation.stage) } } else { probe = nil }
            let mailbox = SFTPInPlaceLocalMailbox(operation, probe: probe)
            #else
            let mailbox = SFTPInPlaceLocalMailbox(operation)
            #endif
            inPlaceMailbox = mailbox; return mailbox
        }
        defer { lock.withLock { if inPlaceMailbox === mailbox { inPlaceMailbox = nil } } }
        let reply = try mailbox.joinedOnSessionExecutor(); if !afterOperationReturn { try check() }; return reply
    }
    func readInPlace(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot,
        storage: SFTPInPlaceWorkingCopyStorage, account: String) throws -> SFTPInPlaceBaseline {
        try check()
        guard allowsInPlaceEditing else { throw SFTPSessionFailure.input }
        guard inPlaceRead == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerReadBusy) }
        guard inPlaceAttempt == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerAttemptBusy) }
        guard inPlaceRelease == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerReleaseBusy) }
        guard decoder.inPlaceBaselineCapacityAvailable else { throw SFTPInPlaceAdmissionFailure(reason: .workerBaselineCapacity) }
        let context = try memoryContext(account: account, requireAuthenticated: true)
        guard let catalog, storage.layout == SFTPSharedBudgetLayout(storage: catalog.files.storage), catalog.quota <= 480 << 20 else { throw SFTPSharedBudgetFailure.unsafe }
        // Metadata-only compatibility check BEFORE any selected body command.
        // K/L history stays preserved and cannot be treated as an empty store.
        do { guard case .revision = try inPlaceLocal(.journalRevision(storage.journal)) else { throw SFTPSessionFailure.output } }
        catch RemoteSettingsFailure.incompatibleVersion { throw SFTPInPlaceAdmissionFailure(reason: .workerSettingsUnsupported) }
        catch RemoteSettingsFailure.busy { throw SFTPInPlaceAdmissionFailure(reason: .workerSettingsBusy) }
        if inPlaceStorageOwner == nil { inPlaceStorageOwner = try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: catalog.files, session: session, context: context) }
        guard let owner = inPlaceStorageOwner else { throw SFTPSharedBudgetFailure.unsafe }; try owner.validate(session: session, context: context)
        try decoder.beginInPlaceRead(selection, snapshot: snapshot)
        let job = try SFTPOriginalReadJob(session: session, selection: selection, context: context, directory: storage.layout.bodies,
            catalog: storage.catalog, storageOwner: owner, strategy: .inPlaceV1); inPlaceRead = job
        guard case .bytes(let command) = try inPlaceLocal(.begin(job, snapshot.revision)) else { throw SFTPSessionFailure.output }
        try check(); try send(kind: 50, payload: command)
        while true {
            switch try waitEvent() {
            case .inPlace(.rejected(let proof)):
                do {
                    guard case .ended = try inPlaceLocal(.rejectBeforeBody(job, proof)) else { throw SFTPSessionFailure.output }
                    inPlaceRead = nil
                } catch {
                    // Keep the actual job/metadata charge. No body was admitted,
                    // but local durability cannot be presented as released.
                    try check()
                    throw SFTPInPlaceEditRefusal(proof, localCleanupNeedsReview: true)
                }
                throw SFTPInPlaceEditRefusal(proof, localCleanupNeedsReview: false)
            case .inPlace(.header(let data)): guard case .ended = try inPlaceLocal(.header(job, data)) else { throw SFTPSessionFailure.output }
            case .inPlace(.chunk(let data)): guard case .ended = try inPlaceLocal(.chunk(job, data)) else { throw SFTPSessionFailure.output }
            case .inPlace(.seal(let data)):
                guard case .bytes(let reply) = try inPlaceLocal(.accept(job, data)) else { throw SFTPSessionFailure.output }
                try decoder.noteInPlaceAcceptance(reply); try check(); try send(kind: 51, payload: reply)
            case .inPlace(.admitted(let data)):
                guard case .baseline(let baseline) = try inPlaceLocal(.admit(job, data)) else { throw SFTPSessionFailure.output }
                try check(); inPlaceRead = nil; return baseline
            default: throw SFTPSessionFailure.output
            }
        }
    }
    func saveInPlace(_ baseline: SFTPInPlaceBaseline, snapshot: SFTPEditedTextSnapshot,
        journal: SFTPInPlaceJournal, account: String) throws -> SFTPInPlaceSaveCompletion {
        try check()
        guard allowsInPlaceEditing else { throw SFTPSessionFailure.input }
        guard inPlaceRead == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerReadBusy) }
        guard inPlaceAttempt == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerAttemptBusy) }
        guard inPlaceRelease == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerReleaseBusy) }
        let context = try memoryContext(account: account, requireAuthenticated: true)
        guard inPlaceStorageOwner === baseline.storageOwner else { throw SFTPSharedBudgetFailure.stale }
        try baseline.storageOwner.validate(session: session, context: context); lock.withLock { inPlaceVerified = nil }
        guard case .revision(let revision) = try inPlaceLocal(.journalRevision(journal)),
              case .attempt(let attempt) = try inPlaceLocal(.prepare(baseline, snapshot, session, context, journal, revision)) else { throw SFTPSessionFailure.output }
        lock.withLock { inPlaceAttempt = attempt }; try decoder.beginInPlaceSave(attempt.record)
        let command = try attempt.command(); try check(); try send(kind: 52, payload: command)
        while true {
            try check()
            switch try waitEvent() {
            case .inPlace(.source(let data)):
                let reply = try attempt.sourceOnSessionExecutor(data); try decoder.noteInPlaceSource(reply); try check(); try send(kind: 53, payload: reply)
            case .inPlace(.permit(let data)):
                let reply = try attempt.permitOnSessionExecutor(data); try decoder.noteInPlacePermit(reply); try check(); try send(kind: 54, payload: reply)
            case .inPlace(.observed(let data)): try attempt.observedOnSessionExecutor(data)
            case .inPlace(.completed(let data)):
                try attempt.completedOnSessionExecutor(data)
                #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
                lock.withLock { gateBInPlaceSaveAcknowledgements += 1 }
                #endif
                #if DEBUG && !SFTP_PARENT_STANDALONE
                SFTPGeneratedBackendObservation.shared.remoteSaveAcknowledged()
                #endif
                //197 follows the serial kernel's return; its RW handle stays
                // in the actual worker table. Join only the LOCAL Save users.
                guard case .ended = try inPlaceLocal(.finishAttempt(attempt), afterOperationReturn: true) else { throw SFTPSessionFailure.output }
                lock.withLock { inPlaceAttempt = nil; inPlaceVerified = (snapshot, attempt.record.id) }
                guard case .baseline(let next) = try inPlaceLocal(.continuation(attempt)) else { throw SFTPSessionFailure.output }
                try check(); return .continued(next, attempt.record.id)
            case .inPlace(.interrupted(let data)): throw try attempt.interruptedOnSessionExecutor(data)
            default: throw SFTPSessionFailure.output
            }
        }
    }
    func verifiedInPlaceOutcome(for snapshot: SFTPEditedTextSnapshot) -> UUID? {
        lock.withLock { guard let value = inPlaceVerified, value.0 === snapshot else { return nil }; return value.1 }
    }
    func releaseInPlace(_ release: SFTPInPlaceRelease) throws -> SFTPInPlaceCloseResult {
        try check()
        guard allowsInPlaceEditing else { throw SFTPSessionFailure.input }
        guard inPlaceRead == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerReadBusy) }
        guard inPlaceAttempt == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerAttemptBusy) }
        guard inPlaceRelease == nil else { throw SFTPInPlaceAdmissionFailure(reason: .workerReleaseBusy) }
        inPlaceRelease = release
        guard case .bytes(let payload) = try inPlaceLocal(.releaseCommand(release)) else { throw SFTPSessionFailure.output }
        try decoder.beginInPlaceRelease(payload); try check(); try send(kind: 58, payload: payload)
        guard case .inPlace(.released(let data)) = try waitEvent() else { throw SFTPSessionFailure.output }
        try release.observedOnSessionExecutor(data, session: session)
        guard case .closed(let result) = try inPlaceLocal(.finishRelease(release), afterOperationReturn: true) else { throw SFTPSessionFailure.output }
        inPlaceRelease = nil; return result
    }
    private func finishInPlaceAfterActualSessionDrain(_ end: SFTPWorkerClose) {
        precondition(end.localResourcesEnded)
        if let read = inPlaceRead { _ = try? inPlaceLocal(.abandon(read), afterOperationReturn: true); inPlaceRead = nil }
        if let attempt = lock.withLock({ inPlaceAttempt }) {
            _ = try? inPlaceLocal(.finishAttempt(attempt), afterOperationReturn: true); lock.withLock { inPlaceAttempt = nil }
        }
        if let release = inPlaceRelease {
            if (try? release.afterActualSessionDrain(end, session: session)) != nil { _ = try? inPlaceLocal(.finishRelease(release), afterOperationReturn: true) }
            inPlaceRelease = nil
        }
    }
    /// Only this owner reads/writes IPC. The mailbox body never calls this
    /// queue; Stop cancels it but waits for its actual task return.
    private func originalLocal(_ operation: SFTPOriginalLocalOperation,
                               afterTransportDrain: Bool = false) throws -> SFTPOriginalLocalReply {
        if !afterTransportDrain { try check() }
        let mailbox = try lock.withLock { () throws -> SFTPOriginalLocalMailbox in
            guard originalMailbox == nil else { throw SFTPTextFailure.busy }
            guard afterTransportDrain || stopAt == nil else { throw SFTPTextFailure.stopped }
            #if DEBUG
            let qualifiedProbe: (@Sendable () throws -> Void)?
            if let probe = peer.originalLocalProbe { qualifiedProbe = { try probe(operation.stage) } }
            else { qualifiedProbe = nil }
            let mailbox = SFTPOriginalLocalMailbox(operation, probe: qualifiedProbe)
            #else
            let mailbox = SFTPOriginalLocalMailbox(operation)
            #endif
            originalMailbox = mailbox
            return mailbox
        }
        defer { lock.withLock { if originalMailbox === mailbox { originalMailbox = nil } } }
        let reply = try mailbox.joinedOnSessionExecutor()
        if !afterTransportDrain { try check() }
        return reply
    }
    func readOriginal(_ selection: SFTPDownloadSelection, snapshot: SFTPStoredSnapshot,
                      storage: SFTPOriginalWorkingCopyStorage, account: String) throws -> SFTPOriginalBaseline {
        try check()
        guard mode.allowsOriginalEditing, originalRead == nil, originalAttempt == nil,
              originalRelease == nil else { throw SFTPSessionFailure.input }
        guard decoder.originalBaselineCapacityAvailable else { throw SFTPOriginalAdmissionFailure(cause: .busy) }
        let context = try memoryContext(account: account, requireAuthenticated: true)
        guard let catalog, storage.sharedLayout == SFTPSharedBudgetLayout(storage: catalog.files.storage) else { throw SFTPSharedBudgetFailure.unsafe }
        if originalStorageOwner == nil {
            originalStorageOwner = try SFTPOriginalStorageOwner.bindOnMetadataExecutor(files: catalog.files, session: session, context: context)
        }
        guard let storageOwner = originalStorageOwner else { throw SFTPSharedBudgetFailure.unsafe }
        try storageOwner.validate(session: session, context: context)
        try decoder.beginOriginalRead(selection, snapshot: snapshot)
        let job = try SFTPOriginalReadJob(session: session, selection: selection, context: context,
            directory: storage.bodyDirectory, catalog: storage.catalog, storageOwner: storageOwner)
        originalRead = job
        guard case .bytes(let command) = try originalLocal(.begin(job, snapshot.revision)) else { throw SFTPSessionFailure.output }
        try check(); try send(kind: 40, payload: command)
        while true {
            switch try waitEvent() {
            case .original(.header(let payload)):
                guard case .ended = try originalLocal(.header(job, payload)) else { throw SFTPSessionFailure.output }
            case .original(.chunk(let payload)):
                guard case .ended = try originalLocal(.chunk(job, payload)) else { throw SFTPSessionFailure.output }
            case .original(.seal(let payload)):
                guard case .bytes(let acceptance) = try originalLocal(.accept(job, payload)) else { throw SFTPSessionFailure.output }
                try decoder.noteOriginalAcceptance(acceptance)
                // This is the final real owner/cancellation fence. A local
                // method returning Accept cannot revoke already-written bytes.
                try check(); try send(kind: 41, payload: acceptance)
            case .original(.admitted(let payload)):
                guard case .baseline(let baseline) = try originalLocal(.admit(job, payload)) else { throw SFTPSessionFailure.output }
                try check(); originalRead = nil; return baseline
            default: throw SFTPSessionFailure.output
            }
        }
    }
    func saveOriginal(_ baseline: SFTPOriginalBaseline, snapshot: SFTPEditedTextSnapshot,
                      journal: SFTPOriginalJournal, account: String) throws -> SFTPOriginalSaveCompletion {
        try check()
        guard mode.allowsOriginalEditing, originalRead == nil, originalAttempt == nil,
              originalRelease == nil else { throw SFTPSessionFailure.input }
        let context = try memoryContext(account: account, requireAuthenticated: true)
        guard originalStorageOwner === baseline.storageOwner else { throw SFTPSharedBudgetFailure.stale }
        try baseline.storageOwner.validate(session: session, context: context)
        lock.withLock { originalVerified = nil }
        guard case .revision(let revision) = try originalLocal(.journalRevision(journal)) else { throw SFTPSessionFailure.output }
        guard case .attempt(let attempt) = try originalLocal(.prepare(baseline, snapshot, session, context, journal, revision)) else { throw SFTPSessionFailure.output }
        lock.withLock { originalAttempt = attempt }
        try decoder.beginOriginalSave(attempt.record)
        let command = try attempt.command()
        try check(); try send(kind: 42, payload: command)
        while true {
            try check()
            switch try waitEvent() {
            case .original(.source(let payload)):
                let reply = try attempt.readOnSessionExecutor(payload)
                try decoder.noteOriginalSource(reply); try check(); try send(kind: 43, payload: reply)
            case .original(.permit(let payload)):
                let reply = try attempt.permitOnSessionExecutor(payload)
                try decoder.noteOriginalPermit(reply); try check(); try send(kind: 44, payload: reply)
            case .original(.observed(let payload)):
                try attempt.observedOnSessionExecutor(payload)
            case .original(.completed(let payload)):
                try attempt.completedOnSessionExecutor(payload)
                #if DEBUG && !SFTP_PARENT_STANDALONE
                SFTPGeneratedBackendObservation.shared.remoteSaveAcknowledged()
                #endif
                //187 is emitted only after the Source6 body channel returns
                // from actual shutdown. No body callback/mailbox remains here.
                guard case .ended = try originalLocal(.endAttemptAfterTransportDrain(attempt), afterTransportDrain: true) else { throw SFTPSessionFailure.output }
                lock.withLock { originalAttempt = nil; originalVerified = (snapshot, attempt.record.id) }
                guard case .baseline(let next) = try originalLocal(.continuation(attempt)) else { throw SFTPSessionFailure.output }
                try check(); return .continued(next, attempt.record.id)
            case .original(.interrupted(let payload)):
                // The worker terminates after188. No uncertain attempt is
                // finalized until finish observes real child exit AND IPC EOF.
                throw try attempt.interruptedOnSessionExecutor(payload)
            default: throw SFTPSessionFailure.output
            }
        }
    }
    func verifiedOriginalOutcome(for snapshot: SFTPEditedTextSnapshot) -> UUID? {
        lock.withLock { guard let originalVerified, originalVerified.0 === snapshot else { return nil }; return originalVerified.1 }
    }
    func releaseOriginal(_ close: SFTPOriginalBaselineClose) throws -> SFTPOriginalBaselineCloseCompletion {
        try check()
        guard mode.allowsOriginalEditing, originalRead == nil, originalAttempt == nil,
              originalRelease == nil else { throw SFTPSessionFailure.input }
        originalRelease = close
        let command: Data
        switch close {
        case .unused(let release):
            guard case .bytes(let value) = try originalLocal(.releaseCommand(release)) else { throw SFTPSessionFailure.output }; command = value
        case .retained(let release):
            guard case .bytes(let value) = try originalLocal(.retainedReleaseCommand(release)) else { throw SFTPSessionFailure.output }; command = value
        }
        try decoder.beginOriginalRelease(command)
        try check(); try send(kind: 48, payload: command)
        guard case .original(.released(let payload)) = try waitEvent() else { throw SFTPSessionFailure.output }
        let result: SFTPOriginalBaselineCloseCompletion
        switch close {
        case .unused(let release):
            try release.observedReleaseOnSessionExecutor(payload, session: session)
            guard case .unusedClose(let value) = try originalLocal(.finishUnusedClose(release), afterTransportDrain: true) else { throw SFTPSessionFailure.output }
            result = .unused(value)
        case .retained(let release):
            try release.observedReleaseOnSessionExecutor(payload, session: session)
            guard case .retainedClose(let value) = try originalLocal(.finishRetainedClose(release), afterTransportDrain: true) else { throw SFTPSessionFailure.output }
            result = .retained(value)
        }
        originalRelease = nil; return result
    }
    private func finishOriginalAfterActualSessionDrain(_ end: SFTPWorkerClose) {
        precondition(end.localResourcesEnded)
        if let read = originalRead {
            _ = try? originalLocal(.abandonReadAfterTransportDrain(read), afterTransportDrain: true)
            originalRead = nil
        }
        if let attempt = lock.withLock({ originalAttempt }) {
            _ = try? originalLocal(.endAttemptAfterTransportDrain(attempt), afterTransportDrain: true)
            lock.withLock { originalAttempt = nil }
        }
        if let close = originalRelease {
            switch close {
            case .unused(let release):
                if (try? release.afterActualSessionDrain(end, session: session)) != nil {
                    _ = try? originalLocal(.finishUnusedClose(release), afterTransportDrain: true)
                }
            case .retained(let release):
                if (try? release.afterActualSessionDrain(end, session: session)) != nil {
                    _ = try? originalLocal(.finishRetainedClose(release), afterTransportDrain: true)
                }
            }
            originalRelease = nil
        }
    }
    private func reap() {
        guard child > 0, status == nil else { return }; var value: Int32 = 0
        let found = waitpid(child, &value, WNOHANG)
        switch SFTPChildWait.observe(expected: child, found: found, status: value, error: errno) {
        case .pending: break
        case .exited(let code): status = code
        case .uncertain: childIdentityUncertain = true
        }
    }
    private func bufferedEvent() throws -> SFTPWorkerEvent? {
        while buffer.count >= 4 {
            let count = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard (33...65536).contains(count) else { throw SFTPSessionFailure.output }
            if buffer.count < Int(count) + 4 { break }
            let frame = Data(buffer.dropFirst(4).prefix(Int(count))); buffer.removeFirst(Int(count) + 4)
            let event = try decoder.consume(frame)
            if decoder.supportsServerCopy { lock.withLock { serverCopyNegotiated = true } }
            if let event { if case .closed(let result) = event { terminal = result }; return event }
        }
        return nil
    }
    private func nextEvent(pollMilliseconds: Int32 = 20) throws -> SFTPWorkerEvent? {
        if let event = try bufferedEvent() { return event }
        let fd = lock.withLock { descriptor }; guard fd >= 0 else { throw SFTPSessionFailure.exited }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, pollMilliseconds)
        guard ready >= 0 || errno == EINTR else { throw SFTPSessionFailure.unavailable }
        if ready > 0 {
            var bytes = [UInt8](repeating: 0, count: 16384); let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { eof = true; reap(); return nil }
            if count < 0 { if errno == EINTR || errno == EAGAIN { return nil }; throw SFTPSessionFailure.unavailable }
            #if DEBUG && !SFTP_PARENT_STANDALONE
            if count > 0 { SFTPGeneratedBackendObservation.shared.protocolReceived() }
            #endif
            #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
            if count > 0 { lock.withLock { gateBPositiveReceives += 1 } }
            #endif
            guard buffer.count + count <= 81924 else { throw SFTPSessionFailure.output }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        reap(); if eof { throw SFTPSessionFailure.exited }; return nil
    }
    func close() async -> SFTPWorkerClose {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.finish()) } }
    }
    func finish() -> SFTPWorkerClose {
        stop()
        // Include time queued behind the active RPC. Repeated close/finish
        // calls never restart Stop grace or extend an already-ended lifetime.
        let began = lock.withLock { stopAt ?? ProcessInfo.processInfo.systemUptime }; var killed = false
        // The worker may spend500ms ending an SSH task after an in-flight
        // challenge is cancelled. Its parent must not kill it at that same
        // boundary, before terminal/writer evidence can be delivered.
        let gracefulSeconds: TimeInterval = mode.allowsInteractiveAuthentication ? 1.25 : 0.5
        while child > 0 && (status == nil || !eof) {
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if childIdentityUncertain { break } // Never signal a PID after ownership becomes uncertain.
            if elapsed > gracefulSeconds && status == nil && !contained { contained = true; _ = kill(child, SIGTERM) }
            if elapsed > 1.5 && status == nil && !killed { killed = true; _ = kill(child, SIGKILL) }
            if elapsed > 3 { break }
            if valid {
                do { _ = try nextEvent() } catch { valid = false; buffer.removeAll(keepingCapacity: false) }
            } else {
                let fd = lock.withLock { descriptor }; var bytes = [UInt8](repeating: 0, count: 16384)
                if fd >= 0 {
                    let n = Darwin.read(fd, &bytes, bytes.count)
                    if n == 0 { eof = true }
                    #if DEBUG && !SFTP_PARENT_STANDALONE
                    if n > 0 { SFTPGeneratedBackendObservation.shared.protocolReceived() }
                    #endif
                    #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
                    if n > 0 { lock.withLock { gateBPositiveReceives += 1 } }
                    #endif
                }
                usleep(1000)
            }
            reap()
        }
        if child == 0 || status != nil && eof {
            // Local task return is joined before process/activity/admission
            // release. A timer or stopped UI never reaches this finalizer.
            let actualEnd = SFTPWorkerClose(actualExit: true, exitStatus: status, ipcEOF: true,
                contained: contained, protocolValid: valid, terminal: terminal, temporaryStoreRemoved: nil)
            finishOriginalAfterActualSessionDrain(actualEnd)
            finishInPlaceAfterActualSessionDrain(actualEnd)
            #if !SFTP_PARENT_STANDALONE || SFTP_UPLOAD_QUALIFICATION
            let upload = lock.withLock { let held = uploadAttempt; uploadAttempt = nil; return held }
            upload?.endAfterActualDrainOnSessionExecutor(noRemoteMutation: uploadNoRemoteMutation && valid && !contained && terminal?.runtimeDisposed == true)
            #endif
            #if !SFTP_PARENT_STANDALONE || SFTP_FOLDER_UPLOAD_QUALIFICATION
            let folderUpload = lock.withLock { let held = folderUploadAttempt; folderUploadAttempt = nil; return held }
            folderUpload?.endAfterActualDrainOnSessionExecutor(noRemoteMutation: folderUploadNoRemoteMutation && valid && !contained && terminal?.runtimeDisposed == true)
            #endif
            lock.withLock { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
            if let catalog {
                temporaryStoreRemoved = catalog.files.finish(clean: child == 0 || valid && terminal?.catalogWriterEnd == .closed)
                self.catalog = nil
            }
            lease = nil; SFTPProcessAdmission.shared.release(self)
            if completedDrainAt == nil {
                #if DEBUG && !SFTP_PARENT_STANDALONE
                if gateAWorkerObserved {
                    SFTPGeneratedBackendObservation.shared.workerDrained()
                    gateAWorkerObserved = false
                }
                #endif
                completedDrainAt = ProcessInfo.processInfo.systemUptime
            }
        } else { SFTPProcessAdmission.shared.retainUncertain(self) }
        maximumDrainSeconds = max(maximumDrainSeconds, (completedDrainAt ?? ProcessInfo.processInfo.systemUptime) - began)
        return SFTPWorkerClose(actualExit: child == 0 || status != nil, exitStatus: status, ipcEOF: child == 0 || eof,
            contained: contained, protocolValid: valid, terminal: terminal, temporaryStoreRemoved: temporaryStoreRemoved,
            drainElapsedSeconds: maximumDrainSeconds)
    }
}
