import Darwin
import Foundation

public struct LocalTextReadToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal let engine: UUID, url: URL, parent: EntrySnapshot, witness: RevisionWitness
    public var description: String { "Local text read token (private evidence omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextDocumentRead: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let contents: TextDocumentValue
    public var bytes: Data { contents.encoded }
    public let token: LocalTextReadToken
    public var description: String { "Local text document (private contents omitted)" }
    public var debugDescription: String { description }
}
internal final class TextPlanClaimV2: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func claim() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}
public struct LocalTextSavePlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UUID
    internal let token: LocalTextReadToken, bytes: Data, base: TextRevisionHeadV2
    internal let claim: TextPlanClaimV2
    internal let baseline: TextRevisionBaselineV3?
    internal let settlements: [TextPreparationSettlementV3]
    internal let epochStamp: TextEpochStamp10?
    internal let manifestVersion: Int
    public var description: String { "Local text save plan (private snapshot omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextSaveReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UUID, recordID: UUID?
    public let token: LocalTextReadToken
    public let baselineAdopted: Bool
    internal init(generation: UUID, recordID: UUID?, token: LocalTextReadToken, baselineAdopted: Bool = false) {
        self.generation = generation; self.recordID = recordID; self.token = token; self.baselineAdopted = baselineAdopted
    }
    public var description: String { "Local text save receipt (private observations omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextRevisionInspection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordID: UUID, generation: UUID
    public let state: LocalTextRevisionState
    public let canUndo: Bool, beforeVersionAvailable: Bool, submittedVersionAvailable: Bool
    public let recoveryLocation: URL
    /// Recorded display observation, never authority to open or mutate the path.
    public let targetURL: URL
    public let attempts: [LocalTextRevisionAttemptInspection]
    public let baselineAdopted: Bool?
    public let metadataIsDurable: Bool, retention: LocalTextRetentionState
    public let undoDisposition: LocalTextUndoDisposition
    public var description: String { "Local text revision inspection (private observations omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextRevisionAttemptInspection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let attemptID: UUID, direction: LocalTextRevisionDirection
    public let preparationAborted: Bool, nativeIntentRecorded: Bool
    public let beforeVersionAvailable: Bool, submittedVersionAvailable: Bool
    public var description: String { "Local text revision attempt (private observations omitted)" }
    public var debugDescription: String { description }
}
public enum LocalTextSaveResult: Sendable {
    case saved(LocalTextSaveReceipt), unchanged(LocalTextSaveReceipt)
    case refused(FileOperationStatus, recordID: UUID?)
    case uncertain(LocalTextRevisionInspection)
    case capacityRequired(LocalTextCapacityInspection)
}
public struct LocalTextHistoryUpgradeResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let status: FileOperationStatus
    public let backupLocation: URL?
    public let catalogVersion: Int?
    public let backupLocations: [URL]
    internal init(status:FileOperationStatus,backupLocation:URL?,catalogVersion:Int?,backupLocations:[URL]? = nil) {
        self.status=status;self.backupLocation=backupLocation;self.catalogVersion=catalogVersion
        self.backupLocations=backupLocations ?? [backupLocation].compactMap{$0}
    }
    public var description: String { "Local text history upgrade (private locations omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextRecoveryPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordID: UUID
    public let attemptID: UUID, direction: LocalTextRevisionDirection
    internal let engine: UUID, destination: URL, parent: EntrySnapshot
    internal let names: [String], sources: [URL], expected: [RevisionWitness]
    internal let claim: TextPlanClaimV2
    internal let epochStamp: TextEpochStamp10?
    public var description: String { "Local text recovery plan (private evidence omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextRecoveryResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordID: UUID
    public let status: FileOperationStatus
    public let copiedURLs: [URL]
    public let originalOutcome: LocalTextRevisionState
    public let outcomes: [LocalTextRecoveryCopyOutcome]
    public var description: String { "Local text recovery result (private locations omitted)" }
    public var debugDescription: String { description }
}
public enum LocalTextRecoveryVersion: String, Codable, Sendable { case before, submitted }
public enum LocalTextRecoveryCopyState: String, Codable, Sendable {
    case notAttempted, publicationUnconfirmed, verified
}
public struct LocalTextRecoveryCopyOutcome: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let version: LocalTextRecoveryVersion, intendedURL: URL
    public let state: LocalTextRecoveryCopyState, status: FileOperationStatus
    /// Current witness availability is independent of stored publication proof.
    public let currentlyAvailable: Bool?
    public var description: String { "Local text recovery version (private location omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextRecoveryExportInspection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let exportID: UUID, recordID: UUID, attemptID: UUID
    public let direction: LocalTextRevisionDirection
    public let outcomes: [LocalTextRecoveryCopyOutcome]
    public var description: String { "Local text recovery export (private observations omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextDocumentRevisionSummary: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordID: UUID, generation: UUID, targetURL: URL
    public let state: LocalTextRevisionState, retention: LocalTextRetentionState
    public let isCurrentHead: Bool, attemptCount: Int
    public let createdAt: Date
    public let undoDisposition: LocalTextUndoDisposition
    public var description: String { "Local text revision summary (private observations omitted)" }
    public var debugDescription: String { description }
}
public struct LocalTextDocumentRevisionPage: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let records: [LocalTextDocumentRevisionSummary], nextRecordID: UUID?
    public var description: String { "Local text revision page (private observations omitted)" }
    public var debugDescription: String { description }
}
internal struct TextEditorHooksV2: Sendable {
    var retirementObserved: (@Sendable (NativeRetirementDiagnosticV4) -> Void)? = nil
    var retirementRawCall: (@Sendable (URL) -> NativeRetirementCallV4)? = nil
    var boundary: (@Sendable (String, UUID) throws -> Void)? = nil
    var preparationReady: (@Sendable (UUID, URL, LocalTextRevisionDirection) throws -> Void)? = nil
}

extension RecoverableFileOperations {
    public func readLocalTextDocument(at url: URL) async throws -> LocalTextDocumentRead {
        try await worker { cancellation in
            try withoutMaterialization {
                try self.textRequireSource(url, cancellation: cancellation)
                let file = try TextPinnedFileV2(url, cancellation: cancellation)
                let contents = try TextDocumentValue.original(file.bytes)
                try file.validate(cancellation: cancellation)
                return LocalTextDocumentRead(contents: contents, token: self.textToken(file))
            }
        }
    }

    public func prepareLocalTextSave(from token: LocalTextReadToken, bytes: Data, generation: UUID) async throws -> LocalTextSavePlan {
        try await prepareLocalTextSaveV3(from: token, bytes: bytes, generation: generation, adoptingExternalBaseline: false)
    }
    public func prepareLocalTextSaveAdoptingExternalBaseline(from token: LocalTextReadToken,
        bytes: Data, generation: UUID) async throws -> LocalTextSavePlan {
        try await prepareLocalTextSaveV3(from: token, bytes: bytes, generation: generation, adoptingExternalBaseline: true)
    }
    private func prepareLocalTextSaveV3(from token: LocalTextReadToken, bytes: Data, generation: UUID,
        adoptingExternalBaseline: Bool) async throws -> LocalTextSavePlan {
        guard bytes.count <= 1_048_576 else { throw FileOperationFailure.unsupported }
        return try await worker { cancellation in
            try withoutMaterialization {
                guard token.engine == self.continuationSession else { throw FileOperationFailure.invalidRequest }
                _ = try TextDocumentValue.original(bytes)
                try self.textRequireSource(token.url, cancellation: cancellation)
                let file = try TextPinnedFileV2(token.url, cancellation: cancellation)
                try self.textValidate(token, file: file)
                let choice = try self.textSelectedSlot(url: token.url, parent: file.parent.identity,
                    witness: file.witness, cancellation: cancellation)
                let slot = choice.slot
                guard let planning = try OperationHistoryInspector.textSavePlanningV3(self.directory, slot: slot, cancellation: cancellation) else {
                    throw FileOperationFailure.unsupported
                }
                var base = planning.head ?? TextRevisionHeadV2(slot: slot, lineage: UUID(), sequence: 0, job: nil, witness: token.witness)
                var baseline: TextRevisionBaselineV3?
                let sameHead = choice.manifestVersion == 4
                    ? base.witness.samePersistentObservation(token.witness, qualifiedVolume: file.volume)
                    : base.witness == token.witness
                if !sameHead {
                    guard adoptingExternalBaseline else { throw FileOperationFailure.sourceChanged }
                    guard base.sequence < 128 else {throw LocalTextCapacityReason.checkpointRequired}
                    let next = TextRevisionHeadV2(slot: slot, lineage: UUID(), sequence: base.sequence + 1, job: nil, witness: token.witness)
                    let change = TextRevisionBaselineV3(before: base, after: next); try change.validate()
                    baseline = change; base = next
                }
                if bytes != file.bytes || baseline != nil {
                    if let reason=planning.storeRefusal {throw reason}
                    guard planning.records < 64,planning.edges + (baseline == nil ? 1:2) <= 128 else {
                        throw LocalTextCapacityReason.checkpointRequired
                    }
                }
                return LocalTextSavePlan(generation: generation, token: token, bytes: bytes, base: base,
                    claim: TextPlanClaimV2(), baseline: baseline, settlements: planning.settlements,
                    epochStamp:planning.stamp, manifestVersion: choice.manifestVersion)
            }
        }
    }

    public func performLocalTextSave(_ plan: LocalTextSavePlan, progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> LocalTextSaveResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: LocalTextSaveResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                try withoutMaterialization {
                    guard plan.token.engine == self.continuationSession, plan.claim.claim() else { throw FileOperationFailure.invalidRequest }
                    try self.textRequireSource(plan.token.url, cancellation: cancellation)
                    let file = try TextPinnedFileV2(plan.token.url, cancellation: cancellation)
                    try self.textValidate(plan.token, file: file)
                    let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                    let choice = try journal.textSelectedSlotV4(target: file.url, parent: file.parent.identity, witness: file.witness)
                    guard choice.slot == plan.base.slot, choice.manifestVersion == plan.manifestVersion else {
                        throw FileOperationFailure.sourceChanged
                    }
                    let expected = plan.baseline?.before ?? plan.base
                    let fresh = try journal.textSavePlanningV3(slot: plan.base.slot)
                    guard fresh.stamp == plan.epochStamp,fresh.settlements == plan.settlements, fresh.head ?? expected == expected else { throw FileOperationFailure.sourceChanged }
                    // Metadata-only negative proof: the complete authoritative
                    // slot set was sealed at preparation, contains no unresolved
                    // native intent, and still matches exactly under this lease.
                    for settlement in plan.settlements {
                        let old = try journal.textRecordV2(settlement.id)
                        guard old.manifest.slot == plan.base.slot, try old.prefix == settlement.prefix,
                              try old.project().intent == nil else { throw FileOperationFailure.recoveryUncertain }
                    }
                    for settlement in plan.settlements { _ = try self.textSettleBeforeIntent(settlement.id, journal: journal) }
                    let current = try journal.textHeadV2(slot: plan.base.slot) ?? expected
                    guard current == expected else { throw FileOperationFailure.sourceChanged }
                    if plan.bytes == file.bytes && plan.baseline == nil {
                        return .unchanged(LocalTextSaveReceipt(generation: plan.generation, recordID: nil, token: self.textToken(file)))
                    }
                    try journal.reserveTextV2(slot:plan.base.slot,edges:plan.baseline == nil ? 1:2); try cancellation.check()
                    let id = UUID(), parent = file.parent
                    let area = try textCreatePrivateDirectory(parent: parent,
                        name: ".traverse-text-" + id.uuidString, owner: journal.owner)
                    let manifest = TextRevisionManifestV2(version: plan.manifestVersion, owner: journal.owner, id: id, generation: plan.generation,
                        createdAt: Date(), target: file.url, parent: parent.identity, area: area.url,
                        areaIdentity: area.identity, slot: plan.base.slot, base: plan.base, read: file.witness,
                        baseline: plan.baseline, persistentVolume: plan.manifestVersion == 4 ? file.volumeBinding.uuid : nil)
                    var record = TextRevisionRecordV2(manifest: manifest, events: [])
                    do {
                        do { record = try journal.beginTextV2(manifest) }
                        catch {
                            reporter.observeCaughtFailure(.textRecordStart, error: error)
                            throw error
                        }
                        if plan.bytes == file.bytes {
                            _ = try journal.appendTextV2(record, event: .stoppedBeforeEntry)
                            try file.validate(cancellation: cancellation.draining())
                            return .unchanged(LocalTextSaveReceipt(generation: plan.generation, recordID: id,
                                token: self.textToken(file), baselineAdopted: true))
                        }
                        record = try self.textBeginAttempt(record, journal: journal, read: file.witness,
                            restoring: file.witness, direction: .forward, cancellation: cancellation)
                        let custody = try self.textPrepareCustody(record: record, source: file.url, submittedSource: file.url,
                            bytes: plan.bytes, direction: .forward, cancellation: cancellation)
                        record = try journal.appendTextV2(record, event: .custody(custody))
                        record = try self.textPerformNative(record, journal: journal, currentHead: plan.base, cancellation: cancellation)
                        let saved = try TextPinnedFileV2(file.url, cancellation: cancellation.draining())
                        guard try record.project().forward?.output == saved.witness else { throw FileOperationFailure.recoveryUncertain }
                        return .saved(LocalTextSaveReceipt(generation: plan.generation, recordID: id, token: self.textToken(saved), baselineAdopted: plan.baseline != nil))
                    } catch {
                        guard let settled = try? self.textSettleBeforeIntent(id, journal: journal),
                              try settled.project().state == .notApplied else {
                            let authoritative = try? journal.textRecordV2(id)
                            return .uncertain(self.textInspection(authoritative ?? record, state: .uncertain,
                                journal: authoritative == nil ? nil : journal, durableRecord: authoritative != nil))
                        }
                        return .refused(operationStatus(error), recordID: id)
                    }
                }
            }
        } catch let reason as LocalTextCapacityReason where [.checkpointRequired,.storeCapacity].contains(reason) {
            result = .capacityRequired((try? await inspectLocalTextWriteCapacity(from:plan.token)) ?? .unavailable10)
        } catch { result = .refused(operationStatus(error), recordID: nil) }
        let success: Bool
        switch result { case .saved, .unchanged: success = true; default: success = false }
        reporter.finish(success: success); return result
    }

    public func inspectLocalTextRevision(recordID: UUID) async throws -> LocalTextRevisionInspection {
        try await worker { cancellation in
            guard let value = try OperationHistoryInspector.textInspectionV2(self.directory, id: recordID, cancellation: cancellation) else { throw FileOperationFailure.notFound }
            return try withoutMaterialization { self.textInspection(value.record, state: try value.record.project().state, journal: nil, resolvedHead: value.head,resolvedUndo:value.undo) }
        }
    }

    /// Selected-token, metadata-only discovery. No source/retained body reads,
    /// implicit history creation, index collection or mutation authority.
    public func inspectLocalTextDocumentRevisions(from token: LocalTextReadToken, after: UUID? = nil,
        limit: Int = 64) async throws -> LocalTextDocumentRevisionPage {
        guard (1...64).contains(limit) else { throw FileOperationFailure.invalidRequest }
        return try await worker { cancellation in
            try withoutMaterialization {
                guard token.engine == self.continuationSession else { throw FileOperationFailure.invalidRequest }
                try self.textRequireSource(token.url, cancellation: cancellation)
                let parent = try DirectoryAnchor(token.url.deletingLastPathComponent(), resolve: false)
                guard parent.identity.sameObject(as: token.parent) else { throw FileOperationFailure.sourceChanged }
                let slot = try self.textSelectedSlot(url: token.url, parent: token.parent,
                    witness: token.witness, cancellation: cancellation).slot
                guard let page = try OperationHistoryInspector.textDocumentRevisionsV3(self.directory, slot: slot,
                    after: after, limit: limit, cancellation: cancellation,metrics:self.hooks.journalHooks.metrics) else {
                    return LocalTextDocumentRevisionPage(records: [], nextRecordID: nil)
                }
                let records = try page.records.map { record in
                    let state = try record.project()
                    guard let undo=page.undo[record.id] else {throw FileOperationFailure.recoveryUncertain}
                    return LocalTextDocumentRevisionSummary(recordID: record.id, generation: record.manifest.generation,
                        targetURL: record.manifest.target, state: state.state,
                        retention: state.retirementConfirmed ? .retired : state.retirement == nil ? .retained : .pending,
                        isCurrentHead: page.head?.job == record.id, attemptCount: state.attempts.count,createdAt:record.manifest.createdAt,
                        undoDisposition:undo)
                }
                return LocalTextDocumentRevisionPage(records: records, nextRecordID: page.next)
            }
        }
    }

    public func prepareLocalTextRecoveryCopies(recordID: UUID, destinationDirectory: URL,
                                               beforeName: String, submittedName: String,
                                               attemptID: UUID? = nil) async throws -> LocalTextRecoveryPlan {
        try await worker { cancellation in
            try withoutMaterialization {
                try validateName(beforeName); try validateName(submittedName)
                guard beforeName != submittedName else { throw FileOperationFailure.invalidRequest }
                let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                let record = try journal.textRecordV2(recordID)
                let attempts = try record.project().attempts
                guard let attempt = attempts.last(where: { $0.custody != nil && (attemptID == nil || $0.preparation.id == attemptID) }),
                      let custody = attempt.custody else { throw FileOperationFailure.recoveryUncertain }
                let area = try self.textAttemptArea(record, attempt: attempt)
                let destination = try DirectoryAnchor(destinationDirectory, resolve: false)
                let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
                try protection.requireDirectory(destination)
                let names = [beforeName, submittedName]
                for name in names {
                    try protection.requireEntry(parent: destination, name: name)
                    guard try NativeRenameEntry.optional(parent: destination, name: name) == nil else { throw FileOperationFailure.conflict }
                }
                guard destination.identity.device == area.identity.device else { throw FileOperationFailure.unsupported }
                let sources = [area.url.appendingPathComponent("before"), area.url.appendingPathComponent("submitted")]
                let expected = [custody.before.copy, custody.submitted.edited]
                for (url, witness) in zip(sources, expected) {
                    let file = try TextPinnedFileV2(url, cancellation: cancellation)
                    guard record.manifest.matchesPersisted(witness, file: file) else { throw FileOperationFailure.recoveryUncertain }
                }
                _ = try journal.textNextExportOrdinal10(recordID)
                return LocalTextRecoveryPlan(recordID: recordID, attemptID: attempt.preparation.id,
                    direction: attempt.preparation.direction, engine: self.continuationSession, destination: destination.url,
                    parent: destination.identity, names: names, sources: sources, expected: expected, claim: TextPlanClaimV2(),
                    epochStamp:try journal.textStamp10(slot:record.manifest.slot))
            }
        }
    }

    public func performLocalTextRecoveryCopies(_ plan: LocalTextRecoveryPlan) async -> LocalTextRecoveryResult {
        do {
            return try await worker { cancellation in
                try withoutMaterialization {
                    guard plan.engine == self.continuationSession, plan.claim.claim() else { throw FileOperationFailure.invalidRequest }
                    let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                    let record = try journal.textRecordV2(plan.recordID), originalState = try record.project().state
                    guard try journal.textStamp10(slot:record.manifest.slot) == plan.epochStamp else {throw LocalTextCapacityReason.stalePlan}
                    guard let attempt = try record.project().attempts.first(where: { $0.preparation.id == plan.attemptID }),
                          let custody = attempt.custody, attempt.preparation.direction == plan.direction,
                          plan.sources == [attempt.preparation.directory(in: record).appendingPathComponent("before"), attempt.preparation.directory(in: record).appendingPathComponent("submitted")],
                          plan.expected == [custody.before.copy, custody.submitted.edited] else { throw FileOperationFailure.recoveryUncertain }
                    _ = try self.textAttemptArea(record, attempt: attempt)
                    let destination = try DirectoryAnchor(plan.destination, resolve: false)
                    guard destination.identity.sameObject(as: plan.parent) else { throw FileOperationFailure.destinationChanged }
                    let protection = try HistoryProtection(self.directory, cancellation: cancellation, protecting: self.protectedLocations)
                    try protection.requireDirectory(destination)
                    for name in plan.names {
                        try protection.requireEntry(parent: destination, name: name)
                        guard try NativeRenameEntry.optional(parent: destination, name: name) == nil else { throw FileOperationFailure.conflict }
                    }
                    for (url, witness) in zip(plan.sources, plan.expected) {
                        let file = try TextPinnedFileV2(url, cancellation: cancellation)
                        guard record.manifest.matchesPersisted(witness, file: file) else { throw FileOperationFailure.recoveryUncertain }
                    }
                    let ordinal = try journal.textNextExportOrdinal10(plan.recordID)
                    var export = TextRecoveryExportV2(id: UUID(), job: plan.recordID, ordinal: ordinal,
                        attemptID: plan.attemptID, direction: plan.direction,
                        destination: destination.url, parent: destination.identity, names: plan.names,
                        sources: plan.sources, expected: plan.expected, completed: [], states: [.notAttempted, .notAttempted])
                    let stageName = ".traverse-text-export-" + export.id.uuidString
                    do {
                        try journal.writeTextExportV2(export, replacing: nil)
                        let stage = try textCreatePrivateDirectory(parent: destination, name: stageName, owner: journal.owner)
                        for index in plan.names.indices {
                            try cancellation.check()
                            let name = "version-" + String(index)
                            let copied = try textPrivateCopy(plan.sources[index], stage.url.appendingPathComponent(name), cancellation: cancellation)
                            guard record.manifest.matchesRecorded(plan.expected[index], copied.source) else {
                                throw FileOperationFailure.recoveryUncertain
                            }
                            try self.hooks.textEditor.boundary?("beforeRecoveryPublish", record.id)
                            try cancellation.check(); try destination.validate(); try textRequirePrivateDirectory(stage)
                            // Durable intent precedes publication. A crash or lost
                            // acknowledgement can only leave this version unconfirmed.
                            var states = export.states; states[index] = .publicationUnconfirmed
                            let pending = TextRecoveryExportV2(id: export.id, job: export.job, ordinal: export.ordinal,
                                attemptID: export.attemptID, direction: export.direction,
                                destination: export.destination, parent: export.parent, names: export.names,
                                sources: export.sources, expected: export.expected, completed: export.completed, states: states)
                            try journal.writeTextExportV2(pending, replacing: export); export = pending
                            try cancellation.check(); try destination.validate(); try textRequirePrivateDirectory(stage)
                            try exclusiveRename(from: stage.fd, name: name, to: destination.fd, name: plan.names[index])
                            try self.hooks.textEditor.boundary?("afterRecoveryPublish", record.id)
                            let url = destination.url.appendingPathComponent(plan.names[index])
                            let file = try TextPinnedFileV2(url, cancellation: cancellation.draining())
                            guard file.witness.sameObject(copied.copy), file.witness.body == copied.copy.body,
                                  file.witness.metadata == copied.copy.metadata, file.witness.security == copied.copy.security else { throw FileOperationFailure.recoveryUncertain }
                            try textSync(file.fd); try syncDirectory(destination); try syncDirectory(stage)
                            states[index] = .verified
                            let next = TextRecoveryExportV2(id: export.id, job: export.job, ordinal: export.ordinal,
                                attemptID: export.attemptID, direction: export.direction,
                                destination: export.destination, parent: export.parent, names: export.names,
                                sources: export.sources, expected: export.expected, completed: export.completed + [file.witness], states: states)
                            try journal.writeTextExportV2(next, replacing: export); export = next
                        }
                        return self.textRecoveryResult(plan, export: export, status: .succeeded, state: originalState)
                    } catch {
                        // Reconciliation may find a committed proof, but this
                        // operation does not turn a lost acknowledgement into success.
                        let exact = try? journal.textExport10(plan.recordID,ordinal:export.ordinal)
                        let authoritative = exact?.id == export.id ? exact!:export
                        if !authoritative.states.contains(.publicationUnconfirmed),authoritative.states.contains(.notAttempted) {
                            try? journal.abortTextExportBeforeNative10(authoritative)
                        }
                        let status: FileOperationStatus = authoritative.states.contains(.publicationUnconfirmed)
                            ? .failed(.recoveryUncertain) : operationStatus(error)
                        return self.textRecoveryResult(plan, export: authoritative, status: status, state: originalState)
                    }
                }
            }
        } catch {
            let state = (try? await inspectLocalTextRevision(recordID: plan.recordID).state) ?? .uncertain
            return textRecoveryResult(plan, export: nil, status: operationStatus(error), state: state)
        }
    }

    public func inspectLocalTextRecoveryExports(recordID: UUID) async throws -> [LocalTextRecoveryExportInspection] {
        try await worker { cancellation in
            guard let value = try OperationHistoryInspector.textInspectionV2(self.directory, id: recordID, cancellation: cancellation) else {
                throw FileOperationFailure.notFound
            }
            return try withoutMaterialization {
                try value.exports.map { item in
                    try item.validate()
                    return LocalTextRecoveryExportInspection(exportID: item.id, recordID: recordID,
                        attemptID: item.attemptID, direction: item.direction,
                        outcomes: self.textExportOutcomes(item, manifest: value.record.manifest))
                }
            }
        }
    }

    internal func textExportOutcomes(_ item: TextRecoveryExportV2,
                                     manifest: TextRevisionManifestV2? = nil) -> [LocalTextRecoveryCopyOutcome] {
        item.names.indices.map { index in
            let url = item.destination.appendingPathComponent(item.names[index]), state = item.states[index]
            let available: Bool?
            if item.completed.indices.contains(index) {
                if let file = try? TextPinnedFileV2(url) {
                    available = manifest.map { $0.matchesPersisted(item.completed[index], file: file) }
                        ?? (file.witness == item.completed[index])
                } else { available = false }
            } else { available = nil }
            let status: FileOperationStatus = state == .verified ? .succeeded : state == .notAttempted ? .notStarted : .failed(.recoveryUncertain)
            return LocalTextRecoveryCopyOutcome(version: index == 0 ? .before : .submitted,
                intendedURL: url, state: state, status: status, currentlyAvailable: available)
        }
    }
    private func textRecoveryResult(_ plan: LocalTextRecoveryPlan, export: TextRecoveryExportV2?,
                                    status: FileOperationStatus, state: LocalTextRevisionState) -> LocalTextRecoveryResult {
        let outcomes = export.map { textExportOutcomes($0) } ?? plan.names.indices.map { index in
            LocalTextRecoveryCopyOutcome(version: index == 0 ? .before : .submitted,
                intendedURL: plan.destination.appendingPathComponent(plan.names[index]), state: .notAttempted,
                status: .notStarted, currentlyAvailable: nil)
        }
        return LocalTextRecoveryResult(recordID: plan.recordID, status: status,
            copiedURLs: outcomes.filter { $0.state == .verified }.map(\.intendedURL), originalOutcome: state, outcomes: outcomes)
    }

    public func upgradeLocalTextHistory() async -> LocalTextHistoryUpgradeResult {
        let backup = directory.deletingLastPathComponent().appendingPathComponent("operation-history-backup-" + UUID().uuidString)
        let successorBackup = directory.deletingLastPathComponent().appendingPathComponent("operation-history-backup-" + UUID().uuidString)
        do {
            let backups = try await worker { cancellation -> [URL] in
                let parent = try DirectoryAnchor(self.directory.deletingLastPathComponent(), resolve: false)
                var protected = false
                for root in self.protectedLocations {
                    let guardPolicy = try HistoryProtection(root, cancellation: cancellation)
                    if try guardPolicy.protects(parent: parent, name: self.directory.lastPathComponent),
                       try guardPolicy.protects(parent: parent, name: backup.lastPathComponent) { protected = true; break }
                }
                guard protected else { throw FileOperationFailure.protectedLocation }
                let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                if journal.inspectionReadiness == .available(catalogVersion:10) {return []}
                var backups:[URL] = []
                if journal.inspectionReadiness != .available(catalogVersion:9) {
                    try journal.upgradeForTextV2(backup:backup);backups.append(backup)
                }
                let final = backups.isEmpty ? backup:successorBackup
                try journal.upgradeForEpoch10(backup:final);backups.append(final);return backups
            }
            return LocalTextHistoryUpgradeResult(status:.succeeded,backupLocation:backups.last,catalogVersion:10,backupLocations:backups)
        } catch {
            let inspection = try? await inspectExistingHistory()
            let version: Int?
            if let inspection, case .available(let value) = inspection.readiness { version = value } else { version = nil }
            let retained = try? await worker(ignoringCancellation: true) { _ -> [URL] in
                let parent = try DirectoryAnchor(backup.deletingLastPathComponent(), resolve: false)
                return try [backup,successorBackup].filter {try NativeRenameEntry.optional(parent:parent,name:$0.lastPathComponent) != nil}
            }
            return LocalTextHistoryUpgradeResult(status:operationStatus(error),backupLocation:retained?.last,catalogVersion:version,backupLocations:retained ?? [])
        }
    }

    internal func textRequireSource(_ url: URL, cancellation: OperationCancellation) throws {
        if case .generatedFixture = copyExecutionAuthorization { throw FileOperationFailure.unsupported }
        let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
        try protection.requireEntry(url)
        guard !url.pathComponents.contains(where: { $0.hasPrefix(".traverse-text-") || $0.hasPrefix(".traverse-text-export-") }) else { throw FileOperationFailure.protectedLocation }
    }
    internal func textToken(_ file: TextPinnedFileV2) -> LocalTextReadToken {
        LocalTextReadToken(engine: continuationSession, url: file.url, parent: file.parent.identity, witness: file.witness)
    }
    private func textValidate(_ token: LocalTextReadToken, file: TextPinnedFileV2) throws {
        guard token.engine == continuationSession, file.url == token.url,
              token.parent.sameObject(as: file.parent.identity), token.witness == file.witness else { throw FileOperationFailure.sourceChanged }
    }
    internal func textSelectedSlot(url: URL, parent: EntrySnapshot, witness: RevisionWitness,
        cancellation: OperationCancellation) throws -> TextSlotSelectionV4 {
        if let choice = try OperationHistoryInspector.textSelectedSlotV4(directory, target: url,
            parent: parent, witness: witness, cancellation: cancellation) { return choice }
        return TextSlotSelectionV4(slot: try textRevisionSlotV4(target: url, parent: parent,
            volume: witness.volume), manifestVersion: 4)
    }
    internal func textArea(_ record: TextRevisionRecordV2) throws -> DirectoryAnchor {
        let area = try DirectoryAnchor(record.manifest.area, resolve: false)
        try textRequirePrivateDirectory(area)
        guard try record.manifest.matchesPersisted(record.manifest.areaIdentity, current: area.identity, in: area),
              try OperationJournal.read(name: ".traverse-text-owner", anchor: area) == Data(record.manifest.owner.uuidString.utf8) else { throw FileOperationFailure.recoveryUncertain }
        return area
    }
    internal func textAttemptArea(_ record: TextRevisionRecordV2, attempt: TextRevisionAttemptV2) throws -> DirectoryAnchor {
        _ = try textArea(record)
        guard let ready = attempt.ready else { throw FileOperationFailure.recoveryUncertain }
        let area = try DirectoryAnchor(attempt.preparation.directory(in: record), resolve: false)
        try textRequirePrivateDirectory(area)
        guard try record.manifest.matchesPersisted(ready.identity, current: area.identity, in: area),
              try OperationJournal.read(name: ".traverse-text-owner", anchor: area) == Data(record.manifest.owner.uuidString.utf8) else { throw FileOperationFailure.recoveryUncertain }
        return area
    }
    private func textBeginAttempt(_ initial: TextRevisionRecordV2, journal: OperationJournal, read: RevisionWitness,
                                  restoring: RevisionWitness, direction: RevisionDirection,
                                  cancellation: OperationCancellation) throws -> TextRevisionRecordV2 {
        let preparation = TextRevisionPreparationV2(id: UUID(), direction: direction, read: read, restoring: restoring)
        var record = try journal.appendTextV2(initial, event: .preparation(preparation))
        try cancellation.check()
        let parent = try textArea(record)
        let area = try textCreatePrivateDirectory(parent: parent, name: preparation.directory(in: record).lastPathComponent, owner: record.manifest.owner)
        record = try journal.appendTextV2(record, event: .ready(TextRevisionReadyV2(attemptID: preparation.id, identity: area.identity)))
        try hooks.textEditor.preparationReady?(preparation.id, area.url, direction)
        return record
    }
    private func textSettleBeforeIntent(_ id: UUID, journal: OperationJournal) throws -> TextRevisionRecordV2 {
        let record = try journal.textRecordV2(id), state = try record.project()
        guard state.intent == nil, [.preparing, .prepared, .undoPrepared].contains(state.state) else { return record }
        return try journal.appendTextV2(record, event: .stoppedBeforeEntry)
    }
    private func textPrepareCustody(record: TextRevisionRecordV2, source: URL, submittedSource: URL, bytes: Data?,
                                    direction: RevisionDirection, cancellation: OperationCancellation) throws -> TextRevisionCustodyV2 {
        guard let attempt = try record.project().attempts.last, attempt.preparation.direction == direction else { throw FileOperationFailure.recoveryUncertain }
        let area = try textAttemptArea(record, attempt: attempt)
        let before = try textPrivateCopy(source, area.url.appendingPathComponent("before"), cancellation: cancellation)
        let submittedURL = area.url.appendingPathComponent("submitted")
        let initial = try textPrivateCopy(submittedSource, submittedURL, cancellation: cancellation)
        if let bytes { try textWriteEdited(bytes, to: submittedURL) }
        let edited = try TextPinnedFileV2(submittedURL, cancellation: cancellation)
        let result = TextRevisionCustodyV2(attemptID: attempt.preparation.id, direction: direction, before: before,
            submitted: RevisionStagedEdit(origin: initial, edited: edited.witness))
        try result.validate(); try syncDirectory(area); return result
    }
    private func textPerformNative(_ initial: TextRevisionRecordV2, journal: OperationJournal, currentHead: TextRevisionHeadV2,
                                   cancellation: OperationCancellation) throws -> TextRevisionRecordV2 {
        var record = initial
        guard let custody = try record.project().custody else { throw FileOperationFailure.recoveryUncertain }
        guard let attempt = try record.project().attempts.last else { throw FileOperationFailure.recoveryUncertain }
        let area = try textAttemptArea(record, attempt: attempt), names = ["before", "submitted", "native-candidate"]
        let beforeURL = area.url.appendingPathComponent(names[0]), submittedURL = area.url.appendingPathComponent(names[1])
        let candidateURL = area.url.appendingPathComponent(names[2])
        try cancellation.check()
        let candidate = try textPrivateCopy(submittedURL, candidateURL, cancellation: cancellation)
        let original = try TextPinnedFileV2(record.manifest.target, cancellation: cancellation)
        guard try record.manifest.matchesPersisted(record.manifest.parent, current: original.parent.identity, in: original.parent),
              record.manifest.matchesPersisted(currentHead.witness, file: original),
              custody.before.source == original.witness else { throw FileOperationFailure.sourceChanged }
        let pinnedCandidate = try TextPinnedFileV2(candidateURL, cancellation: cancellation)
        let retained = try TextPinnedFileV2(beforeURL, cancellation: cancellation)
        let submitted = try TextPinnedFileV2(submittedURL, cancellation: cancellation)
        let intent = TextRevisionIntentV2(direction: custody.direction, read: original.witness, candidate: candidate)
        try intent.validate(custody: custody)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?, operationError: Error?, entered = false
        coordinator.coordinate(writingItemAt: original.url, options: .forReplacing, error: &coordinationError) { accessor in
            do {
                guard OperationJournal.sameURLRepresentation(accessor, original.url),
                      try journal.textHeadV2(slot: record.manifest.slot, allowing: record.id) ?? record.manifest.base == currentHead else { throw FileOperationFailure.sourceChanged }
                try original.validate(); try pinnedCandidate.validate(candidate.copy); try retained.validate(custody.before.copy); try submitted.validate(custody.submitted.edited)
                try cancellation.check()
                try self.hooks.textEditor.boundary?("beforeIntent", record.id)
                try cancellation.check()
                record = try journal.appendTextV2(record, event: .intent(intent))
                try self.hooks.textEditor.boundary?("beforeNative", record.id)
                try cancellation.check()
                try original.validate(); try pinnedCandidate.validate(); try retained.validate(); try submitted.validate()
                entered = true
                _ = try FileManager().replaceItemAt(accessor, withItemAt: candidateURL, backupItemName: nil, options: [.usingNewMetadataOnly])
                try self.hooks.textEditor.boundary?("afterNative", record.id)
                let draining = cancellation.draining()
                let output = try TextPinnedFileV2(original.url, cancellation: draining)
                let proof = TextRevisionAppliedV2(output: output.witness,
                    originalPinnedAfter: try textProjection(original.fd, volume: original.volume, cancellation: draining),
                    candidatePinnedAfter: try textProjection(pinnedCandidate.fd, volume: original.volume, cancellation: draining),
                    beforeAfter: try TextPinnedFileV2(beforeURL, cancellation: draining).witness,
                    submittedAfter: try TextPinnedFileV2(submittedURL, cancellation: draining).witness)
                try proof.validate(intent: intent, custody: custody)
                try original.parent.validate(); try area.validate()
                guard try NativeRenameEntry.optional(parent: area, name: names[2]) == nil else { throw FileOperationFailure.recoveryUncertain }
                try textSync(output.fd); try syncDirectory(original.parent); try syncDirectory(area)
                let next = try record.appending(.applied(proof))
                let head = TextRevisionHeadV2(slot: currentHead.slot, lineage: currentHead.lineage,
                    sequence: currentHead.sequence + 1, job: custody.direction == .forward ? record.id : record.manifest.predecessor, witness: proof.output)
                let transition = TextRevisionTransitionV2(slot: currentHead.slot, ordinal: currentHead.sequence,
                    job: record.id, recordRevision: next.revision, prefix: try next.prefix,
                    direction: custody.direction, before: currentHead, after: head)
                record = try journal.appendTextV2(record, event: .applied(proof), transition: transition)
                try self.hooks.textEditor.boundary?("afterOutcome", record.id)
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError {
            // Once intent is durable, an unacknowledged native segment remains
            // uncertain even if this process locally observed no native entry.
            if try record.project().intent == nil { record = try textSettleBeforeIntent(record.id, journal: journal) }
            else { _ = try? journal.appendTextV2(record, event: .uncertain) }
            throw error
        }
        guard entered else { throw FileOperationFailure.recoveryUncertain }; return record
    }

    internal func reverseLocalTextV2(_ initial: TextRevisionRecordV2, journal: OperationJournal,
                                    cancellation: OperationCancellation) -> RecoverableOperationResult {
        let id = initial.id
        do {
            if case .endedByCheckpoint = try journal.textUndoDisposition10(id) {throw FileOperationFailure.undoEndedByCheckpoint}
            if case .epochCapacityReached = try journal.textUndoDisposition10(id) {throw FileOperationFailure.textUndoCapacityReached}
            let state = try initial.project()
            guard state.canPrepareInverse,
                  let head = try journal.textHeadV2(slot: initial.manifest.slot), head.job == id else { throw FileOperationFailure.recoveryUncertain }
            try textRequireSource(initial.manifest.target, cancellation: cancellation)
            let current = try TextPinnedFileV2(initial.manifest.target, cancellation: cancellation)
            guard initial.manifest.matchesPersisted(head.witness, file: current) else { throw FileOperationFailure.sourceChanged }
            // The validated append-only slot chain supplies the exact current
            // physical observation, including a newer revision's recorded Undo.
            // Do not weaken witness equality or infer continuity from matching bytes.
            guard let forward = state.attempts.first, let forwardCustody = forward.custody else { throw FileOperationFailure.recoveryUncertain }
            let area = try textAttemptArea(initial, attempt: forward)
            let retained = try TextPinnedFileV2(area.url.appendingPathComponent("before"))
            guard initial.manifest.matchesPersisted(forwardCustody.before.copy, file: retained) else { throw FileOperationFailure.recoveryUncertain }
            try journal.reserveTextV2(slot:initial.manifest.slot,newJob: false); try cancellation.check()
            let attempt = try textBeginAttempt(initial, journal: journal, read: current.witness,
                restoring: retained.witness, direction: .inverse, cancellation: cancellation)
            let custody = try textPrepareCustody(record: attempt, source: initial.manifest.target,
                submittedSource: area.url.appendingPathComponent("before"), bytes: nil, direction: .inverse, cancellation: cancellation)
            let prepared = try journal.appendTextV2(attempt, event: .custody(custody))
            _ = try textPerformNative(prepared, journal: journal, currentHead: head, cancellation: cancellation)
            return RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: initial.manifest.target,
                destination: initial.manifest.target, status: .succeeded, recoveryURLs: [initial.manifest.area])], cancellationRequested: cancellation.isCancelled), recordID: id)
        } catch {
            if let failure = error as? FileOperationFailure,[.undoEndedByCheckpoint,.textUndoCapacityReached].contains(failure) {
                return RecoverableOperationResult(result:.init(items:[.init(source:initial.manifest.target,destination:initial.manifest.target,
                    status:.failed(failure),recoveryURLs:[initial.manifest.area])],cancellationRequested:false),recordID:id)
            }
            let settled = try? textSettleBeforeIntent(id, journal: journal)
            let status: FileOperationStatus
            if let settled, let state = try? settled.project(), state.intent == nil || state.state == .committed || state.state == .undone {
                status = operationStatus(error)
            } else { status = .failed(.recoveryUncertain) }
            return RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: initial.manifest.target,
                destination: initial.manifest.target, status: status, recoveryURLs: [initial.manifest.area])],
                cancellationRequested: error is CancellationError), recordID: id)
        }
    }

    private func textInspection(_ record: TextRevisionRecordV2, state: LocalTextRevisionState, journal: OperationJournal?,
        resolvedHead: TextRevisionHeadV2? = nil, durableRecord: Bool = true,
        resolvedUndo:LocalTextUndoDisposition? = nil) -> LocalTextRevisionInspection {
        let projection = try? record.project()
        let attempts: [LocalTextRevisionAttemptInspection] = projection?.attempts.map { attempt in
            let area = try? textAttemptArea(record, attempt: attempt)
            let before = area.flatMap { try? TextPinnedFileV2($0.url.appendingPathComponent("before")).witness }
            let submitted = area.flatMap { try? TextPinnedFileV2($0.url.appendingPathComponent("submitted")).witness }
            return LocalTextRevisionAttemptInspection(attemptID: attempt.preparation.id, direction: attempt.preparation.direction,
                preparationAborted: attempt.aborted, nativeIntentRecorded: attempt.intent != nil,
                beforeVersionAvailable: before != nil && attempt.custody.map { record.manifest.matchesRecorded(before!, $0.before.copy) } == true,
                submittedVersionAvailable: submitted != nil && attempt.custody.map { record.manifest.matchesRecorded(submitted!, $0.submitted.edited) } == true)
        } ?? []
        let latest = attempts.last(where: { $0.beforeVersionAvailable && $0.submittedVersionAvailable })
        let head = resolvedHead ?? (try? journal?.textHeadV2(slot: record.manifest.slot))
        let undo = resolvedUndo ?? (try? journal?.textUndoDisposition10(record.id)) ?? .unavailable
        return LocalTextRevisionInspection(recordID: record.id, generation: record.manifest.generation, state: state,
            canUndo: undo == .available && state == .committed && projection?.canPrepareInverse == true && head?.job == record.id
                && attempts.first?.beforeVersionAvailable == true && attempts.first?.submittedVersionAvailable == true,
            beforeVersionAvailable: latest?.beforeVersionAvailable == true,
            submittedVersionAvailable: latest?.submittedVersionAvailable == true,
            recoveryLocation: record.manifest.area, targetURL: record.manifest.target, attempts: attempts,
            baselineAdopted: durableRecord ? record.manifest.baseline != nil : nil, metadataIsDurable: durableRecord,
            retention: !durableRecord ? .unknown : projection?.retirementConfirmed == true ? .retired : projection?.retirement != nil ? .pending : .retained,
            undoDisposition:durableRecord ? undo:.unavailable)
    }
}
