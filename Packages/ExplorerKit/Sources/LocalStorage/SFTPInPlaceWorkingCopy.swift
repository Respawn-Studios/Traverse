import Foundation
import FileOperations

/// Intent is NOT a capability. Read-only is the default, and changing this
/// enum without the separately sealed connection permit cannot arm writes.
enum SFTPContentAccess: Sendable, Equatable { case readOnly, transferWrites, guardedInPlaceV1 }
/// Independently captured existing transfer capabilities. An editor permit
/// cannot create these bits; only the actual peer's approved flags supply them.
struct SFTPInPlaceTransfers: Sendable, Equatable {
    let rawValue: UInt8
    private init(unchecked: UInt8) { rawValue = unchecked }
    static let none = Self(unchecked: 0), selectedDownloads = Self(unchecked: 1), readTransfers = Self(unchecked: 3), freshUploads = Self(unchecked: 7), all = Self(unchecked: 15)
    init(rawValue: UInt8) throws {
        guard [UInt8(0), 1, 3, 7, 15].contains(rawValue) else { throw SFTPSessionFailure.input }; self.rawValue = rawValue
    }
    init(peer: SFTPPeerConfiguration) throws {
        try self.init(rawValue: (peer.allowsRequestedDownloads ? 1 : 0) | (peer.allowsRequestedFolderDownloads ? 2 : 0)
            | (peer.allowsFreshUploads ? 4 : 0) | (peer.allowsFreshFolderUploads ? 8 : 0))
    }
    var downloads: Bool { rawValue & 1 != 0 }
    var folders: Bool { rawValue & 2 != 0 }
    var uploads: Bool { rawValue & 4 != 0 }
    var folderUploads: Bool { rawValue & 8 != 0 }
}
struct SFTPInPlaceConnectionPermit: Sendable {
    private struct PreparedBinding: Sendable, Equatable {
        let host: String, numericHost: String
        let port: UInt16
        let scopeID: UInt32, requestedScopeID: UInt32
        let jumpNonce: UUID?, jumpHost: String?
        let jumpPort: UInt16?
        let transfers: SFTPInPlaceTransfers
        init(peer: SFTPPeerConfiguration) throws {
            host = peer.host; numericHost = peer.numericHost; port = peer.port
            scopeID = peer.scopeID; requestedScopeID = peer.requestedScopeID
            jumpNonce = peer.jump?.nonce; jumpHost = peer.jump?.host; jumpPort = peer.jump?.port
            transfers = try SFTPInPlaceTransfers(peer: peer)
        }
    }
    private enum Source: Sendable {
        #if DEBUG
        case generated(UUID)
        #endif
        case prepared(PreparedBinding)
    }
    private let source: Source
    private init(_ source: Source) { self.source = source }
    #if DEBUG
    static func generatedQualification(_ id: UUID) -> Self { .init(.generated(id)) }
    #endif
    /// A prepared, write-enabled connection may request this candidate only
    /// before its worker starts. Ordinary UI activation remains separate.
    static func preparedCandidate(peer: SFTPPeerConfiguration, pool: SMBTemporaryCatalogPool?) throws -> Self {
        guard let pool, peer.validateAdmission != nil,
              peer.contentAccess == .guardedInPlaceV1,
              peer.allowsRequestedDownloads, peer.allowsRequestedFolderDownloads,
              peer.allowsFreshUploads, peer.allowsKeyAuthentication,
              peer.allowsInteractiveAuthentication,
              peer.jump == nil || peer.rememberedRoute != nil else { throw SFTPSessionFailure.input }
        try pool.storage.requireDurableOriginalAdmission()
        try peer.validateAdmission?()
        return .init(.prepared(try .init(peer: peer)))
    }
    func validate(peer: SFTPPeerConfiguration, pool: SMBTemporaryCatalogPool?) throws {
        guard peer.contentAccess == .guardedInPlaceV1 else { throw SFTPSessionFailure.denied }
        guard let pool else { throw SFTPSessionFailure.input }
        switch source {
        #if DEBUG
        case .generated(let id):
            guard SFTPWire.validToken(id), peer.host == "generated.example",
                  pool.storage.directory.path.contains("/.build/traverse-development/") else { throw SFTPSessionFailure.input }
        #endif
        case .prepared(let binding):
            guard peer.validateAdmission != nil,
                  peer.allowsRequestedDownloads, peer.allowsRequestedFolderDownloads,
                  peer.allowsFreshUploads, peer.allowsKeyAuthentication,
                  peer.allowsInteractiveAuthentication,
                  peer.jump == nil || peer.rememberedRoute != nil,
                  binding == (try PreparedBinding(peer: peer)) else { throw SFTPSessionFailure.input }
            try pool.storage.requireDurableOriginalAdmission()
            try peer.validateAdmission?()
        }
    }
}
@_spi(Qualification) public final class SFTPInPlaceWorkingCopyStorage: Sendable, CustomDebugStringConvertible {
    let recoveryReader = SFTPInPlaceRecoveryReadOwner()
    let layout: SFTPSharedBudgetLayout, catalog: SFTPOriginalEditorCatalog, journal: SFTPInPlaceJournal, edits: SFTPTextEditStorage
    public var debugDescription: String { "<guarded in-place private storage>" }
    public convenience init(metadataStorage: SMBTemporaryStorage) throws { try self.init(metadataStorage: metadataStorage, catalogProbe: nil, journalProbe: nil) }
    init(metadataStorage: SMBTemporaryStorage, catalogProbe: SFTPOriginalEditorCatalog.File.Probe?, journalProbe: SFTPInPlaceJournal.File.Probe?) throws {
        try metadataStorage.requireDurableOriginalAdmission()
        layout = .init(storage: metadataStorage); _ = try RemoteDownloadStore(directory: layout.bodies)
        catalog = try .init(bodyDirectory: layout.bodies, probe: catalogProbe, sharedLayout: layout)
        journal = .init(layout: layout, probe: journalProbe); edits = try .init(originalDirectory: layout.bodies)
    }
    /// Explicit metadata discovery only. It creates no owner, body or file.
    public func recoveryChoicesAfterExplicitRequest() async throws -> [SFTPInPlaceRecoveryChoice] {
        try await recoveryReader.discover(layout: layout, origin: nil)
    }
    public func inspectBudgetSummary() async throws -> SFTPOriginalBudgetSummary? {
        try await DownloadExecutor().perform { [layout] in try SFTPSharedBudgetInspection.summary(layout) }
    }
    public func inspectRecoverySummary() async throws -> SFTPInPlaceRecoverySummary {
        let editors = try await catalog.inspect(), saves = try await journal.inspect()
        return .init(documents: editors.records.filter { $0.phase != .closedUnused }.count, saves: saves.records.count,
            pendingMutations: saves.records.filter { $0.outcome != .verified && $0.mutationMayHaveHappened }.count,
            requiresReview: editors.records.contains { $0.phase != .closedUnused } || !saves.records.isEmpty)
    }
}
@_spi(Qualification) public struct SFTPInPlaceRecoverySummary: Sendable {
    public let documents: Int, saves: Int, pendingMutations: Int, requiresReview: Bool
}
@_spi(Qualification) public struct SFTPInPlaceSavedReceipt: Sendable, CustomDebugStringConvertible {
    public let generation: UUID, recordID: UUID
    public var debugDescription: String { "<captured generation verified through retained handle and current location>" }
    fileprivate init(generation: UUID, recordID: UUID) { self.generation = generation; self.recordID = recordID }
}
@_spi(Qualification) public enum SFTPInPlaceSaveResult: Sendable {
    case saved(SFTPInPlaceSavedReceipt), refusedBeforeSubmission(SFTPInPlaceRefusalReason), needsReview(recordID: UUID?, facts: SFTPInPlaceReviewFacts? = nil), savedRemotelyRecoveryNeedsAttention(recordID: UUID)
}
/// Fixed, input-free boundary for generated qualification diagnostics. It is
/// never an authority to retry a Save or infer that remote bytes were changed.
@_spi(Qualification) public enum SFTPInPlaceRefusalReason: String, Sendable {
    case sessionUnavailable, stagingFailed, stagingCapacity, stagingBusy, disconnected
    case browserEditorBusy, browserFolderBusy, browserDownloadBusy, browserUploadBusy, browserNavigationBusy
    case workerReadBusy, workerAttemptBusy, workerReleaseBusy, workerBaselineCapacity
    case workerSettingsBusy, workerSettingsUnsupported
}
@_spi(Qualification) public enum SFTPInPlaceCloseResult: Sendable {
    case readyToCloseBuffer, closedUnusedCopyRemoved, closedVersionsRetained, disconnectedRecoveryRetained, pending, needsReview
}
enum SFTPInPlaceSaveCompletion: Sendable { case continued(SFTPInPlaceBaseline, UUID), verifiedRecoveryNeedsAttention(UUID) }
struct SFTPInPlaceAdmissionFailure: Error, Sendable { let reason: SFTPInPlaceRefusalReason }
private final class SFTPInPlaceBufferPresence: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var installed: Bool { lock.withLock { value } }
    func install() { lock.withLock { value = true } }
}
final class SFTPInPlaceDocumentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var valuesByID: [UUID: SFTPInPlaceDocumentSession] = [:]
    func insert(_ value: SFTPInPlaceDocumentSession) throws {
        try lock.withLock { guard valuesByID.count < 2, valuesByID[value.id] == nil else { throw SFTPTextFailure.busy }; valuesByID[value.id] = value }
    }
    func remove(_ id: UUID) { lock.withLock { _ = valuesByID.removeValue(forKey: id) } }
    var values: [SFTPInPlaceDocumentSession] { lock.withLock { Array(valuesByID.values) } }
}
/// Concrete reusable document API. No AppKit, raw remote URL or generic provider.
/// The serial browser keeps navigation and Save jobs in one connection lane;
/// after Edit, a new folder generation does NOT redirect/revoke this baseline.
@_spi(Qualification) public actor SFTPInPlaceDocumentSession {
    public nonisolated let id = UUID()
    public let initialContents: TextDocumentValue
    private let browser: SFTPBrowserSession, storage: SFTPInPlaceWorkingCopyStorage
    private let recoveryOrigin: SFTPInPlaceRecoveryOrigin
    private var lifetimePins: [SFTPOriginalLifetimePin]
    private let recoveryReader = SFTPInPlaceRecoveryReadOwner()
    private var baseline: SFTPInPlaceBaseline?
    private var saving: Task<SFTPInPlaceSaveResult, Never>?, closing: Task<SFTPInPlaceCloseResult, Never>?, stopping: Task<SFTPWorkerClose, Never>?
    private var disconnected = false, requiresReview = false
    private var closedResult: SFTPInPlaceCloseResult?
    private let bufferPresence = SFTPInPlaceBufferPresence()
    private var actualBufferClosed = false, pendingDisconnected = false, closeHandoffPrepared = false
    #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
    private var gateBNativeCloseEntry: (@Sendable () -> Void)?
    func installGateBEventObservers(nativeClose: @escaping @Sendable () -> Void,
        pinDrain: @escaping @Sendable () -> Void) async throws {
        guard gateBNativeCloseEntry == nil, lifetimePins.count == 1,
              !actualBufferClosed, !closeHandoffPrepared else { throw SFTPTextFailure.changed }
        let pin = lifetimePins[0]
        try await Task.detached { try pin.installGateBDrainObserver(pinDrain) }.value
        gateBNativeCloseEntry = nativeClose
    }
    #endif
    private var pendingRelease: SFTPInPlaceRelease?, stagedTerminal: SFTPInPlaceCloseResult?
    init(browser: SFTPBrowserSession, baseline: SFTPInPlaceBaseline, storage: SFTPInPlaceWorkingCopyStorage) {
        self.browser = browser; self.baseline = baseline; self.storage = storage
        initialContents = baseline.contents; recoveryOrigin = .capture(baseline)
        lifetimePins = [baseline.lifetimePin]
    }
    /// Called only after the App has installed this exact session's native
    /// text buffer. Failed opens retain the uninstalled cleanup path.
    public nonisolated func nativeBufferDidInstall() { bufferPresence.install() }
    public func save(contents: TextDocumentValue, generation: UUID) async -> SFTPInPlaceSaveResult {
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        GateBReadObservation.shared.saveEntered()
        #endif
        // A pending close already claimed the baseline even if native buffer
        // handoff has not become ready and the closing task has returned.
        guard closedResult == nil, pendingRelease == nil, stagedTerminal == nil,
              !pendingDisconnected, !closeHandoffPrepared, !actualBufferClosed,
              !disconnected, !requiresReview, saving == nil, closing == nil,
              let baseline, SFTPWire.validToken(generation) else { return .refusedBeforeSubmission(.sessionUnavailable) }
        let work = Task { await self.saveCaptured(contents, generation: generation, baseline: baseline) }; saving = work
        let result = await work.value; saving = nil; return result
    }
    private func saveCaptured(_ contents: TextDocumentValue, generation: UUID, baseline: SFTPInPlaceBaseline) async -> SFTPInPlaceSaveResult {
        var snapshot: SFTPEditedTextSnapshot?, submitted = false
        do {
            let edited = try await storage.edits.stageInPlace(contents: contents, editorGeneration: generation, from: baseline); snapshot = edited
            guard !disconnected else { _ = await edited.closeAndDrain(); return .refusedBeforeSubmission(.disconnected) }
            submitted = true
            switch try await browser.saveInPlace(baseline, snapshot: edited, journal: storage.journal) {
            case .continued(let next, let record):
                lifetimePins.append(next.lifetimePin)
                self.baseline = next; return .saved(.init(generation: generation, recordID: record))
            case .verifiedRecoveryNeedsAttention(let record):
                self.baseline = nil; requiresReview = true; disconnected = true; return .savedRemotelyRecoveryNeedsAttention(recordID: record)
            }
        } catch {
            // A typed browser/worker admission refusal occurs before baseline
            // claim, journal preparation or IPC. Keep the document usable.
            if let admission = error as? SFTPInPlaceAdmissionFailure {
                if let snapshot { _ = await snapshot.closeAndDrain() }; return .refusedBeforeSubmission(admission.reason)
            }
            if submitted {
                self.baseline = nil; requiresReview = true
                let end = await browser.close(); disconnected = true
                if end.localResourcesEnded, let snapshot { _ = await snapshot.closeAndDrain() }
                let interruption = error as? SFTPInPlaceInterruption
                return .needsReview(recordID: interruption?.recordID, facts: interruption?.facts)
            }
            if let snapshot { _ = await snapshot.closeAndDrain() }
            switch error {
            case RemoteDownloadStorageFailure.capacity, SFTPSharedBudgetFailure.capacity, SFTPTextFailure.full:
                return .refusedBeforeSubmission(.stagingCapacity)
            case RemoteDownloadStorageFailure.busy, SFTPSharedBudgetFailure.busy, SFTPTextFailure.busy:
                return .refusedBeforeSubmission(.stagingBusy)
            default: return .refusedBeforeSubmission(.stagingFailed)
            }
        }
    }
    /// Explicit Stop is connection scoped; ordinary task cancellation does not
    /// abandon a running Save or turn a pending write into a Saved receipt.
    public func requestStop() {
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        GateBReadObservation.shared.stopEntered()
        #endif
        disconnected = true
        if stopping == nil { let held = browser; stopping = Task { await held.close() } }
    }
    /// Stop has no buffer/discard decision. Join BOTH actual network Save and
    /// explicit local recovery reads before returning the real owner report.
    public func stopAndDrain() async -> SFTPWorkerClose {
        requestStop(); let stopping = self.stopping!
        await recoveryReader.stopAndDrain()
        if let saving { _ = await saving.value }
        return await stopping.value
    }
    public func recoveryChoicesAfterExplicitRequest() async throws -> [SFTPInPlaceRecoveryChoice] {
        guard recoveryReaderAvailable else { throw SFTPTextFailure.closed }
        if let saving { _ = await saving.value }
        guard recoveryReaderAvailable else { throw SFTPTextFailure.closed }
        if let stopping { guard (await stopping.value).localResourcesEnded else { throw SFTPTextFailure.busy } }
        guard recoveryReaderAvailable else { throw SFTPTextFailure.closed }
        let choices = try await recoveryReader.discover(layout: storage.layout, origin: recoveryOrigin)
        guard recoveryReaderAvailable else { throw SFTPTextFailure.closed }
        return choices
    }
    private var recoveryReaderAvailable: Bool {
        closing == nil && pendingRelease == nil && stagedTerminal == nil
            && !pendingDisconnected && !closeHandoffPrepared && !actualBufferClosed
            && closedResult == nil
    }
    public func closeAfterExplicitBufferDecision() async -> SFTPInPlaceCloseResult {
        if let closedResult { return closedResult }
        if closeHandoffPrepared {
            return actualBufferClosed ? await nativeBufferDidClose() : .readyToCloseBuffer
        }
        if let closing { return await closing.value }
        let work = Task { await self.finishClose() }; closing = work; let result = await work.value
        switch result {
        case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
            baseline = nil; closedResult = result; browser.inPlaceDocumentDidClose(id)
        case .readyToCloseBuffer, .pending, .needsReview: closing = nil
        }
        return result
    }
    /// The App calls this only from the actual native window-close handoff.
    /// Until then the owner SH cannot end and the unused body cannot retire.
    public func nativeBufferDidClose() async -> SFTPInPlaceCloseResult {
        #if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
        gateBNativeCloseEntry?()
        #endif
        if let closedResult { return closedResult }
        guard bufferPresence.installed, closeHandoffPrepared,
              pendingDisconnected || pendingRelease != nil else { return .needsReview }
        guard pendingDisconnected || stagedTerminal != nil || pendingRelease?.readyForActualBufferClose == true
        else { return .pending }
        actualBufferClosed = true
        recoveryReader.seal()
        guard await recoveryReader.sealAndDrain() else { return .needsReview }
        guard await drainBodyPins() else { return .needsReview }
        if pendingDisconnected { return completeClose(.disconnectedRecoveryRetained) }
        guard let release = pendingRelease else { return .needsReview }
        release.markActualBufferClosed()
        if let stagedTerminal { return completeClose(stagedTerminal) }
        return completeClose(await release.finishAfterLocalDrain())
    }
    private func completeClose(_ result: SFTPInPlaceCloseResult) -> SFTPInPlaceCloseResult {
        switch result {
        case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
            baseline = nil; closedResult = result; browser.inPlaceDocumentDidClose(id)
        case .readyToCloseBuffer, .pending, .needsReview: break
        }
        return result
    }
    private func closeStage(_ result: SFTPInPlaceCloseResult, release: SFTPInPlaceRelease) -> SFTPInPlaceCloseResult {
        switch result {
        case .closedUnusedCopyRemoved:
            // This is impossible while an installed buffer's SH remains held.
            guard !bufferPresence.installed || actualBufferClosed else { return .needsReview }
            return result
        case .closedVersionsRetained, .disconnectedRecoveryRetained:
            if bufferPresence.installed && !actualBufferClosed {
                stagedTerminal = result; closeHandoffPrepared = true; return .readyToCloseBuffer
            }
            return result
        case .pending:
            if bufferPresence.installed && !actualBufferClosed && release.readyForActualBufferClose {
                closeHandoffPrepared = true; return .readyToCloseBuffer
            }
            return .pending
        case .readyToCloseBuffer, .needsReview: return .needsReview
        }
    }
    private func finishClose() async -> SFTPInPlaceCloseResult {
        if let saving { _ = await saving.value }
        await recoveryReader.stopAndDrain()
        guard let baseline else {
            if disconnected {
                guard (await browser.close()).localResourcesEnded else { return .pending }
                if bufferPresence.installed && !actualBufferClosed {
                    pendingDisconnected = true; closeHandoffPrepared = true; return .readyToCloseBuffer
                }
                recoveryReader.seal()
                guard await recoveryReader.sealAndDrain() else { return .needsReview }
                return await drainBodyPins() ? .disconnectedRecoveryRetained : .needsReview
            }
            return .needsReview
        }
        let release: SFTPInPlaceRelease
        do { release = try baseline.beginClose() } catch { return .needsReview }
        pendingRelease = release
        if !bufferPresence.installed {
            recoveryReader.seal()
            guard await recoveryReader.sealAndDrain() else { return .needsReview }
            guard await drainBodyPins() else { return .needsReview }
            release.markActualBufferClosed()
        }
        do {
            let result = try await browser.releaseInPlace(release)
            return closeStage(result, release: release)
        } catch {
            let end = await browser.close(); disconnected = true; guard end.localResourcesEnded else { return .pending }
            do { try release.afterActualSessionDrain(end, session: baseline.session) } catch { return .needsReview }
            let result = await release.finishAfterLocalDrain()
            return closeStage(result, release: release)
        }
    }
    private func drainBodyPins() async -> Bool {
        for pin in lifetimePins { if !(await pin.closeAndDrain()) { return false } }
        return true
    }
}
