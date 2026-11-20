import Foundation
import FileOperations

struct EditorOpenedDocument: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let contents: TextDocumentValue
    let binding: TextDocumentBinding
    let url: URL
    var description: String { "<opened editor document>" }
    var debugDescription: String { description }
}

enum EditorFileSaveReply: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case confirmed(generation: UUID, binding: TextDocumentBinding, url: URL, recordID: UUID?, baselineAdopted: Bool)
    case refused(FileOperationStatus, recordID: UUID?)
    case historyReviewRequired(LocalTextCapacityReason)
    case uncertain(recordID: UUID?, intendedURL: URL, isFreshCopy: Bool)
    case publishedNeedsReload(recordID: UUID?, intendedURL: URL)
    var description: String { "<editor Save result>" }
    var debugDescription: String { description }
}

struct EditorUndoSectionPlan: Sendable, CustomDebugStringConvertible {
    fileprivate let plan: LocalTextCheckpointPlan
    fileprivate let binding: TextDocumentBinding
    fileprivate let url: URL
    var review: LocalTextCheckpointReview { plan.review }
    var debugDescription: String { "<prepared editor Undo section>" }
}
enum EditorFileSessionFailure: Error { case closed, busy, noDocument, staleBinding }

/// One concrete local-document adapter. All authority stays in the existing
/// engine's opaque read/save plans and receipts. There is no generic producer,
/// caller-created Saved token, native descriptor or UI filesystem callback.
/// The application owns global mutation admission and retains access grants.
@MainActor
final class LocalEditorFileSession {
    private struct Source {
        let url: URL, token: LocalTextReadToken, binding: TextDocumentBinding
    }
    let engine: RecoverableFileOperations
    let selectedHistoricalRecordID: UUID?
    private var source: Source?
    private var closed = false
    private var work: UUID?
    private var explicitReloadPending = false
    private var sourceNeedsReload = false
    private struct PendingSection {
        let id: UUID, binding: TextDocumentBinding
        let url: URL
    }
    private var pendingSection: PendingSection?
    private(set) var lastConfirmedSectionID: UUID?
    var sectionNeedsReview: Bool { pendingSection != nil }
    private var lifetimes: [any Sendable]

    init(engine: RecoverableFileOperations, retaining lifetime: (any Sendable)? = nil,
         selectedHistoricalRecordID: UUID? = nil) {
        self.engine = engine; self.selectedHistoricalRecordID = selectedHistoricalRecordID
        self.lifetimes = lifetime.map { [$0] } ?? []
    }
    var isWorking: Bool { work != nil }
    var currentURL: URL? { source?.url }
    var binding: TextDocumentBinding? { source?.binding }
    var savedTextToken: LocalTextReadToken? { closed || work != nil || sourceNeedsReload ? nil : source?.token }
    var requiresUnchangedCheckpoint: Bool { explicitReloadPending }
    var mustReloadBeforeOriginalSave: Bool { sourceNeedsReload }

    func retainAccess(_ lifetime: any Sendable) throws {
        guard !closed else { throw EditorFileSessionFailure.closed }
        guard lifetimes.count < 64 else { throw EditorFileSessionFailure.busy }
        lifetimes.append(lifetime)
    }

    /// Reading and explicit Reload never initialize or upgrade operation history.
    func open(_ url: URL, matching selection: LocalTextOpenSelection? = nil) async throws -> EditorOpenedDocument {
        guard source == nil, selectedHistoricalRecordID == nil else { throw EditorFileSessionFailure.staleBinding }
        return try await read(url, isReload: false, matching: selection)
    }
    func reload() async throws -> EditorOpenedDocument {
        guard let source else { throw EditorFileSessionFailure.noDocument }
        return try await read(source.url, isReload: true)
    }

    /// A comparison owns its read and joins it at close. Keep the original
    /// access alive through the read without adopting the new Save token.
    func diskSnapshot(at url: URL) async throws -> TextDocumentValue {
        guard !closed, work == nil, let source, source.url == url else { throw EditorFileSessionFailure.staleBinding }
        let retainedAccess = lifetimes
        defer { withExtendedLifetime(retainedAccess) {} }
        let read = try await engine.readLocalTextDocument(at: url)
        try Task.checkCancellation()
        guard !closed, work == nil, self.source?.binding == source.binding else { throw EditorFileSessionFailure.staleBinding }
        return read.contents
    }

    private func read(_ url: URL, isReload: Bool, matching selection: LocalTextOpenSelection? = nil) async throws -> EditorOpenedDocument {
        let ticket = try begin()
        defer { finish(ticket) }
        let read = try await engine.readLocalTextDocument(at: url, matching: selection)
        // The window owner deliberately keeps the old buffer until this real
        // read succeeds. It cannot acknowledge a task cancellation as Reload.
        try Task.checkCancellation()
        let binding = TextDocumentBinding()
        source = .init(url: url, token: read.token, binding: binding)
        explicitReloadPending = isReload
        sourceNeedsReload = false
        return .init(contents: read.contents, binding: binding, url: url)
    }

    func historyReadiness() async throws -> OperationHistoryReadiness {
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectExistingHistory().readiness
    }
    func upgradeHistoryAfterConsent() async throws -> LocalTextHistoryUpgradeResult {
        let ticket = try begin(); defer { finish(ticket) }
        return await engine.upgradeLocalTextHistory()
    }
    func revisions(after: UUID? = nil) async throws -> LocalTextDocumentRevisionPage {
        guard let source else { throw EditorFileSessionFailure.noDocument }
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectLocalTextDocumentRevisions(from: source.token, after: after, limit: 64)
    }
    func inspectRevision(_ id: UUID) async throws -> LocalTextRevisionInspection {
        try requireSelectedRecord(id)
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectLocalTextRevision(recordID: id)
    }
    func compareRevision(_ id: UUID, attempt: UUID) async throws -> TextComparisonDocuments {
        try requireSelectedRecord(id)
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.readLocalTextRevisionComparison(recordID: id, attemptID: attempt)
    }
    func readRevision(_ id: UUID, attempt: UUID, version: LocalTextRecoveryVersion) async throws -> TextDocumentValue {
        try requireSelectedRecord(id)
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.readLocalTextRevisionVersion(recordID: id, attemptID: attempt, version: version)
    }
    func inspectExports(_ id: UUID) async throws -> [LocalTextRecoveryExportInspection] {
        try requireSelectedRecord(id)
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectLocalTextRecoveryExports(recordID: id)
    }
    func recoveryExportPage(_ id: UUID, after: Int? = nil) async throws -> LocalTextRecoveryExportPage {
        try requireSelectedRecord(id)
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectLocalTextRecoveryExportPage(recordID: id, afterOrdinal: after, limit: 64)
    }
    func historySummaries() async throws -> OperationRecoveryInspection {
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectExistingHistory(limit: 64)
    }
    func copyVersions(recordID: UUID, attemptID: UUID?, directory: URL,
                      beforeName: String, submittedName: String) async throws -> LocalTextRecoveryResult {
        try requireSelectedRecord(recordID)
        let ticket = try begin(); defer { finish(ticket) }
        let plan = try await engine.prepareLocalTextRecoveryCopies(recordID: recordID,
            destinationDirectory: directory, beforeName: beforeName, submittedName: submittedName, attemptID: attemptID)
        return await engine.performLocalTextRecoveryCopies(plan)
    }
    func writeCapacity() async throws -> LocalTextCapacityInspection {
        guard let source, selectedHistoricalRecordID == nil else { throw EditorFileSessionFailure.noDocument }
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.inspectLocalTextWriteCapacity(from: source.token)
    }
    func prepareUndoSection() async throws -> EditorUndoSectionPlan {
        guard let source, selectedHistoricalRecordID == nil else { throw EditorFileSessionFailure.noDocument }
        guard !sourceNeedsReload else { throw LocalTextCapacityReason.sourceChanged }
        guard pendingSection == nil else { throw LocalTextCapacityReason.pendingMaintenance }
        let ticket = try begin(); defer { finish(ticket) }
        let plan: LocalTextCheckpointPlan
        if explicitReloadPending { plan = try await engine.prepareLocalTextCheckpointAdoptingExternalBaseline(from: source.token) }
        else { plan = try await engine.prepareLocalTextCheckpoint(from: source.token) }
        try Task.checkCancellation()
        return .init(plan: plan, binding: source.binding, url: source.url)
    }
    func startUndoSection(_ prepared: EditorUndoSectionPlan) async throws -> LocalTextCheckpointResult {
        guard source?.binding == prepared.binding, source?.url == prepared.url, selectedHistoricalRecordID == nil,
              pendingSection == nil else { return .refused(.stalePlan) }
        let ticket = try begin(); defer { finish(ticket) }
        let result = await engine.performLocalTextCheckpoint(prepared.plan)
        switch result {
        case .completed(let receipt):
            lastConfirmedSectionID = receipt.checkpointID
            explicitReloadPending = false
        case .uncertain(let id):
            pendingSection = .init(id: id, binding: prepared.binding, url: prepared.url)
        case .refused: break
        }
        return result
    }
    /// An exact metadata read can establish the section; it never acknowledges
    /// a Save or marks the document's visible edit generation clean.
    func reconcileUndoSection() async throws -> LocalTextCheckpointInspection? {
        guard let pendingSection else { return nil }
        let ticket = try begin(); defer { finish(ticket) }
        let result = try await engine.inspectLocalTextCheckpoint(checkpointID: pendingSection.id)
        try Task.checkCancellation()
        guard result.metadataIsDurable, result.receipt.checkpointID == pendingSection.id else { return result }
        if source?.binding == pendingSection.binding {
            lastConfirmedSectionID = result.receipt.checkpointID; explicitReloadPending = false
        }
        self.pendingSection = nil
        return result
    }
    func prepareRetirement(_ record: UUID) async throws -> LocalTextRetirementPlan {
        try requireSelectedRecord(record)
        let ticket = try begin(); defer { finish(ticket) }
        return try await engine.prepareLocalTextRetirement(recordID: record)
    }
    func retire(_ plan: LocalTextRetirementPlan,
                progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> LocalTextRetirementResult {
        try requireSelectedRecord(plan.recordID)
        let ticket = try begin(); defer { finish(ticket) }
        return await engine.performLocalTextRetirement(plan, progress: progress)
    }
    func undoSavedOperation(_ record: UUID,
                            progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> RecoverableOperationResult {
        try requireSelectedRecord(record)
        let ticket = try begin(); defer { finish(ticket) }
        let inspection = try await engine.inspectLocalTextRevision(recordID: record)
        guard source.map({ $0.url == inspection.targetURL }) == true || selectedHistoricalRecordID == record else {
            throw EditorFileSessionFailure.staleBinding
        }
        let result = await engine.undo(recordID: record, progress: progress)
        // Even a failed acknowledgement can follow a native change. Keep the
        // visible buffer and require an explicit read rather than guessing it.
        sourceNeedsReload = true
        return result
    }

    func saveOriginal(_ snapshot: TextSaveSnapshot,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> EditorFileSaveReply {
        guard snapshot.intent == .original, let current = source,
              current.binding == snapshot.sourceBinding else { return .refused(.failed(.invalidRequest), recordID: nil) }
        guard !sourceNeedsReload else { return .refused(.failed(.sourceChanged), recordID: nil) }
        guard pendingSection?.url != current.url else { return .historyReviewRequired(.pendingMaintenance) }
        let ticket: UUID
        do { ticket = try begin() }
        catch { return .refused(.failed(.unavailable), recordID: nil) }
        defer { finish(ticket) }
        do {
            let plan: LocalTextSavePlan
            if explicitReloadPending {
                plan = try await engine.prepareLocalTextSaveAdoptingExternalBaseline(from: current.token,
                    bytes: snapshot.value.encoded, generation: snapshot.id)
            } else {
                guard !snapshot.checkpointsUnchangedOriginal else {
                    return .refused(.failed(.invalidRequest), recordID: nil)
                }
                plan = try await engine.prepareLocalTextSave(from: current.token,
                    bytes: snapshot.value.encoded, generation: snapshot.id)
            }
            let result = await engine.performLocalTextSave(plan, progress: progress)
            switch result {
            case .saved(let receipt), .unchanged(let receipt):
                guard receipt.generation == snapshot.id else {
                    return .uncertain(recordID: receipt.recordID, intendedURL: current.url, isFreshCopy: false)
                }
                let fresh = TextDocumentBinding()
                source = .init(url: current.url, token: receipt.token, binding: fresh)
                explicitReloadPending = false
                return .confirmed(generation: receipt.generation, binding: fresh, url: current.url,
                    recordID: receipt.recordID, baselineAdopted: receipt.baselineAdopted)
            case .capacityRequired(let capacity):
                return .historyReviewRequired(explicitReloadPending ? capacity.baselineSaveRefusal ?? .checkpointRequired
                    : capacity.saveRefusal ?? .checkpointRequired)
            case .refused(let status, let record): return .refused(status, recordID: record)
            case .uncertain(let inspection):
                return .uncertain(recordID: inspection.recordID, intendedURL: current.url, isFreshCopy: false)
            }
        } catch is CancellationError { return .refused(.cancelled, recordID: nil) }
        catch let reason as LocalTextCapacityReason { return .historyReviewRequired(reason) }
        catch let failure as FileOperationFailure { return .refused(.failed(failure), recordID: nil) }
        catch { return .refused(.failed(.ioFailure), recordID: nil) }
    }

    func saveAs(_ snapshot: TextSaveSnapshot, directory: URL, name: String,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> EditorFileSaveReply {
        guard case .freshCopy(let freshBinding) = snapshot.intent,
              selectedHistoricalRecordID == nil,
              snapshot.sourceBinding == source?.binding else { return .refused(.failed(.invalidRequest), recordID: nil) }
        let ticket: UUID
        do { ticket = try begin() }
        catch { return .refused(.failed(.unavailable), recordID: nil) }
        defer { finish(ticket) }
        do {
            let plan = try await engine.prepareLocalTextSaveAs(contents: snapshot.value, generation: snapshot.id,
                destinationDirectory: directory, name: name)
            switch await engine.performLocalTextSaveAs(plan, progress: progress) {
            case .saved(let receipt):
                guard receipt.generation == snapshot.id, receipt.document.contents == snapshot.value else {
                    return .publishedNeedsReload(recordID: receipt.recordID, intendedURL: plan.destination)
                }
                source = .init(url: plan.destination, token: receipt.document.token, binding: freshBinding)
                explicitReloadPending = false; sourceNeedsReload = false
                return .confirmed(generation: receipt.generation, binding: freshBinding, url: plan.destination,
                    recordID: receipt.recordID, baselineAdopted: false)
            case .publishedNeedsReload(let publication):
                return .publishedNeedsReload(recordID: publication.recordID, intendedURL: publication.intendedURL)
            case .refused(let publication): return .refused(publication.status, recordID: publication.recordID)
            case .uncertain(let publication):
                return .uncertain(recordID: publication.recordID, intendedURL: publication.intendedURL, isFreshCopy: true)
            }
        } catch is CancellationError { return .refused(.cancelled, recordID: nil) }
        catch let failure as FileOperationFailure { return .refused(.failed(failure), recordID: nil) }
        catch { return .refused(.failed(.ioFailure), recordID: nil) }
    }

    /// A detached publication of already prepared visible text. This does not
    /// acknowledge an original Save or follow the copy as this document. The
    /// captured binding is UI/session affinity; it is not source-read authority.
    func saveTextCopy(value: TextDocumentValue, generation: UUID, expectedBinding: TextDocumentBinding,
                      directory: URL, name: String, access: any Sendable,
                      progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> LocalTextSaveAsResult {
        // Retain only this chosen destination grant, including throwing/late
        // cancellation paths. It never consumes the persistent lifetime array.
        defer { withExtendedLifetime(access) {} }
        guard selectedHistoricalRecordID == nil, let current = source else {
            throw EditorFileSessionFailure.noDocument
        }
        guard current.binding == expectedBinding else { throw EditorFileSessionFailure.staleBinding }
        guard directory.appendingPathComponent(name) != current.url else { throw FileOperationFailure.invalidRequest }
        let ticket = try begin()
        defer { finish(ticket) }
        try Task.checkCancellation()
        let plan = try await engine.prepareLocalTextSaveAs(contents: value, generation: generation,
            destinationDirectory: directory, name: name)
        // The core consumes its own plan and reports actual publication/readback.
        // Do not replace it with a post-await cancellation acknowledgement.
        return await engine.performLocalTextSaveAs(plan, progress: progress)
    }

    /// The owner calls this only after joining read/Save/recovery and preparation
    /// tasks. It cannot release a still-owned grant by merely dismissing a view.
    func closeAfterDrain() throws {
        guard work == nil else { throw EditorFileSessionFailure.busy }
        closed = true; source = nil; lifetimes = []
    }
    private func begin() throws -> UUID {
        guard !closed else { throw EditorFileSessionFailure.closed }
        guard work == nil else { throw EditorFileSessionFailure.busy }
        let id = UUID(); work = id; return id
    }
    private func requireSelectedRecord(_ id: UUID) throws {
        if let selectedHistoricalRecordID, selectedHistoricalRecordID != id { throw EditorFileSessionFailure.staleBinding }
    }
    private func finish(_ id: UUID) {
        precondition(work == id)
        work = nil
        withExtendedLifetime(lifetimes) {}
    }
}
