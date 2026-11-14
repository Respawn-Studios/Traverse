import Foundation
import FileOperations

/// No ordinary factory exists in this source packet. The shared ledger is a
/// necessary storage gate; remote publication capability policy remains held.
enum SFTPOriginalConnectionPermit: Sendable {
    #if DEBUG
    case generatedQualification(UUID)
    #endif
    func validate(peer: SFTPPeerConfiguration, pool: SMBTemporaryCatalogPool?) throws {
        #if DEBUG
        switch self {
        case .generatedQualification(let id):
            guard SFTPWire.validToken(id), peer.host == "generated.example", pool != nil,
                  pool!.storage.directory.path.contains("/.build/traverse-development/") else { throw SFTPSessionFailure.input }
        }
        #else
        throw SFTPTextFailure.unsupported
        #endif
    }
}

@_spi(Qualification) public final class SFTPOriginalWorkingCopyStorage: Sendable, CustomDebugStringConvertible {
    let bodyDirectory: URL
    let sharedLayout: SFTPSharedBudgetLayout?
    let catalog: SFTPOriginalEditorCatalog, journal: SFTPOriginalJournal, edits: SFTPTextEditStorage
    public var debugDescription: String { "<SFTP Original private storage>" }
    public convenience init(directory: URL) throws {
        try self.init(directory: directory, catalogProbe: nil, journalProbe: nil)
    }
    init(directory: URL, catalogProbe: SFTPOriginalEditorCatalog.File.Probe?, journalProbe: SFTPOriginalJournal.File.Probe?) throws {
        _ = try RemoteDownloadStore(directory: directory)
        bodyDirectory = directory
        sharedLayout = nil
        catalog = try SFTPOriginalEditorCatalog(bodyDirectory: directory, probe: catalogProbe)
        journal = .init(directory: directory.appendingPathExtension("original-journal"), probe: journalProbe)
        edits = try .init(originalDirectory: directory)
    }
    public convenience init(metadataStorage: SMBTemporaryStorage) throws {
        try self.init(metadataStorage: metadataStorage, catalogProbe: nil, journalProbe: nil)
    }
    init(metadataStorage: SMBTemporaryStorage, catalogProbe: SFTPOriginalEditorCatalog.File.Probe?,
         journalProbe: SFTPOriginalJournal.File.Probe?) throws {
        try metadataStorage.requireDurableOriginalAdmission()
        let layout = SFTPSharedBudgetLayout(storage: metadataStorage)
        _ = try RemoteDownloadStore(directory: layout.bodies)
        sharedLayout = layout; bodyDirectory = layout.bodies
        catalog = try .init(bodyDirectory: layout.bodies, probe: catalogProbe, sharedLayout: layout)
        journal = .init(directory: layout.journal, probe: journalProbe, sharedLayout: layout)
        edits = try .init(originalDirectory: layout.bodies)
    }
    public func inspectRecoverySummary() async throws -> SFTPOriginalRecoverySummary {
        let editors = try await catalog.inspect(), changes = try await journal.inspect()
        return .init(documents: editors.records.filter { $0.phase != .closedUnused }.count,
            changes: changes.records.count, needsReview: editors.records.contains { $0.phase != .closedUnused }
                || changes.records.contains { $0.outcome != .notStarted })
    }
    public func inspectBudgetSummary() async throws -> SFTPOriginalBudgetSummary? {
        guard let sharedLayout else { throw SFTPSharedBudgetFailure.unsafe }
        return try await DownloadExecutor().perform { try SFTPSharedBudgetInspection.summary(sharedLayout) }
    }
}
@_spi(Qualification) public struct SFTPOriginalRecoverySummary: Sendable {
    public let documents: Int, changes: Int, needsReview: Bool
}
@_spi(Qualification) public struct SFTPOriginalSavedReceipt: Sendable, CustomDebugStringConvertible {
    public let generation: UUID, recordID: UUID
    public var debugDescription: String { "<SFTP Original captured generation saved>" }
    fileprivate init(generation: UUID, recordID: UUID) { self.generation = generation; self.recordID = recordID }
}
@_spi(Qualification) public enum SFTPOriginalDocumentSaveResult: Sendable {
    case saved(SFTPOriginalSavedReceipt)
    case refusedBeforeSubmission
    case needsReview(recordID: UUID?)
    case savedRemotelyRecoveryNeedsAttention(recordID: UUID)
}
@_spi(Qualification) public enum SFTPOriginalDocumentCloseResult: Sendable {
    case closedUnusedCopyRemoved, closedVersionsRetained, disconnectedRecoveryRetained
    case pending, needsReview
}
enum SFTPOriginalSaveCompletion: Sendable {
    case continued(SFTPOriginalBaseline, UUID)
    case verifiedRecoveryNeedsAttention(UUID)
}
/// Only a known before-command admission may keep the connection usable.
/// Errors after durable preparation or a sent command still close/drain it.
struct SFTPOriginalAdmissionFailure: Error, Sendable { let cause: SFTPTextFailure }
enum SFTPOriginalBaselineClose: Sendable { case unused(SFTPOriginalUnusedClose), retained(SFTPOriginalRetainedClose) }
enum SFTPOriginalBaselineCloseCompletion: Sendable {
    case unused(SFTPOriginalUnusedCloseResult), retained(SFTPOriginalRetainedCloseResult)
}
/// The live connection retains every handed-off document even if a window or
/// caller drops its reference. Only a completed explicit close removes it.
/// The App's separate registry still enforces its process-wide four-window cap.
final class SFTPOriginalDocumentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [UUID: SFTPOriginalDocumentSession] = [:]
    func insert(_ document: SFTPOriginalDocumentSession) throws {
        try lock.withLock {
            guard documents.count < 2, documents[document.id] == nil else { throw SFTPTextFailure.busy }
            documents[document.id] = document
        }
    }
    func remove(_ id: UUID) { lock.withLock { _ = documents.removeValue(forKey: id) } }
    var values: [SFTPOriginalDocumentSession] { lock.withLock { Array(documents.values) } }
}

/// One remote working copy, minted by the concrete Browser/worker path after183.
/// A URL, old journal row or reconnected session cannot construct this actor.
/// The App must retain it and its global writer until its real operation returns.
@_spi(Qualification) public actor SFTPOriginalDocumentSession {
    public nonisolated let id = UUID()
    public let initialContents: TextDocumentValue
    private let browser: SFTPBrowserSession, storage: SFTPOriginalWorkingCopyStorage
    private var lifetimePins: [SFTPOriginalLifetimePin]
    private var baseline: SFTPOriginalBaseline?
    private var saving: Task<SFTPOriginalDocumentSaveResult, Never>?
    private var closing: Task<SFTPOriginalDocumentCloseResult, Never>?
    private var closed = false, disconnected = false, requiresReview = false
    private var closedResult: SFTPOriginalDocumentCloseResult?
    private var stopping: Task<SFTPWorkerClose, Never>?
    init(browser: SFTPBrowserSession, baseline: SFTPOriginalBaseline, storage: SFTPOriginalWorkingCopyStorage) {
        self.browser = browser; self.baseline = baseline; self.storage = storage
        lifetimePins = [baseline.lifetimePin]; initialContents = baseline.contents
    }
    public func save(contents: TextDocumentValue, generation: UUID) async -> SFTPOriginalDocumentSaveResult {
        guard !closed, !disconnected, !requiresReview, closing == nil, saving == nil,
              let baseline, SFTPWire.validToken(generation) else { return .refusedBeforeSubmission }
        let work = Task { await self.saveCaptured(contents, generation: generation, baseline: baseline) }
        saving = work
        // Retained work is joined even if a waiting UI task is cancelled. Stop
        // is explicit and connection-scoped; no implicit autosave/retry occurs.
        let result = await work.value
        saving = nil; return result
    }
    private func saveCaptured(_ contents: TextDocumentValue, generation: UUID,
                              baseline: SFTPOriginalBaseline) async -> SFTPOriginalDocumentSaveResult {
        var snapshot: SFTPEditedTextSnapshot?
        var submitted = false
        do {
            let edited = try await storage.edits.stageOriginal(contents: contents, editorGeneration: generation, from: baseline)
            snapshot = edited
            guard !disconnected else { _ = await edited.closeAndDrain(); return .refusedBeforeSubmission }
            submitted = true
            switch try await browser.saveOriginal(baseline, snapshot: edited, journal: storage.journal) {
            case .continued(let next, let record):
                lifetimePins.append(next.lifetimePin)
                self.baseline = next
                return .saved(.init(generation: generation, recordID: record))
            case .verifiedRecoveryNeedsAttention(let record):
                self.baseline = nil; requiresReview = true; disconnected = true
                return .savedRemotelyRecoveryNeedsAttention(recordID: record)
            }
        } catch {
            if submitted {
                self.baseline = nil; requiresReview = true
                // Preparation may have claimed the baseline or durably linked
                // a record even though its task threw. Invalidate live tokens;
                // only the actual process owner finalizes their local users.
                let end = await browser.close(); disconnected = true
                if end.localResourcesEnded, let snapshot { _ = await snapshot.closeAndDrain() }
                return .needsReview(recordID: nil)
            }
            if let snapshot { _ = await snapshot.closeAndDrain() }
            return .refusedBeforeSubmission
        }
    }
    /// Requests connection Stop; caller cancellation alone never drops saving.
    public func requestStop() {
        disconnected = true
        if stopping == nil { let held = browser; stopping = Task { await held.close() } }
    }
    public func closeAfterExplicitBufferDecision() async -> SFTPOriginalDocumentCloseResult {
        if let closedResult { return closedResult }
        if let closing { return await closing.value }
        let work = Task { await self.finishClose() }; closing = work
        let result = await work.value
        switch result {
        case .closedUnusedCopyRemoved, .closedVersionsRetained, .disconnectedRecoveryRetained:
            closed = true; closedResult = result; browser.originalDocumentDidClose(id)
        case .pending, .needsReview: closing = nil
        }
        return result
    }
    private func finishClose() async -> SFTPOriginalDocumentCloseResult {
        if let saving { _ = await saving.value }
        guard let baseline else {
            if disconnected {
                let end = await browser.close()
                guard end.localResourcesEnded else { return .pending }
                return await drainBodyPins() ? .disconnectedRecoveryRetained : .needsReview
            }
            return .needsReview
        }
        let close: SFTPOriginalBaselineClose
        do {
            close = baseline.retainsSuccessfulVersions
                ? .retained(try baseline.beginRetainedClose()) : .unused(try baseline.beginUnusedClose())
        } catch { return .needsReview }
        // Original v1 has no installed App buffer in this source packet. Its
        // actor owns the pin separately from a mutable/nil baseline and ends
        // it before guarded local retirement can acquire owner EX.
        guard await drainBodyPins() else { return .needsReview }
        if case .unused(let release) = close { release.markActualBufferClosed() }
        do {
            let completion = try await browser.releaseOriginal(close)
            switch completion {
            case .unused(.closedUnusedCopyRemoved(_)): self.baseline = nil; return .closedUnusedCopyRemoved
            case .retained(.closedVersionsRetained(_)): self.baseline = nil; return .closedVersionsRetained
            case .unused(.pending), .retained(.pending): return .pending
            case .unused(.needsReview), .retained(.needsReview): requiresReview = true; return .needsReview
            }
        } catch {
            // A vanished ACK cannot establish release. Real session exit+EOF
            // permits retirement; cleanup is still a separate checked action.
            let end = await browser.close(); disconnected = true
            guard end.localResourcesEnded else { return .pending }
            switch close {
            case .unused(let release):
                do { try release.afterActualSessionDrain(end, session: baseline.session) } catch { return .needsReview }
                switch await release.finishAfterLocalDrain() {
                case .closedUnusedCopyRemoved: self.baseline = nil; return .closedUnusedCopyRemoved
                case .pending: return .pending; case .needsReview: return .needsReview
                }
            case .retained(let release):
                do { try release.afterActualSessionDrain(end, session: baseline.session) } catch { return .needsReview }
                switch await release.finishAfterLocalDrain() {
                case .closedVersionsRetained: self.baseline = nil; return .closedVersionsRetained
                case .pending: return .pending; case .needsReview: return .needsReview
                }
            }
        }
    }
    private func drainBodyPins() async -> Bool {
        for pin in lifetimePins { if !(await pin.closeAndDrain()) { return false } }
        return true
    }
}
