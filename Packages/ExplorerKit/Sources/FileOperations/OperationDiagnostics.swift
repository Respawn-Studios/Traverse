import Foundation

/// Fixed catch boundaries only; never a path, error description or SQL text.
public enum OperationDiagnosticCheckpoint: Sendable, Equatable {
    case textRecordStart
    case textRecordAdmission, textRecordProjection, textRecordHead, textRecordTransaction, textRecordSQLite
    case textManifestLocation, textManifestArea, textManifestBinding, textManifestSlot, textManifestRead, textManifestBaseline
    case nativeTrashReturnedParent, nativeTrashReturnedIdentity, nativeTrashTreeRead
    case nativeTrashParentValidation, nativeTrashFingerprint
    case nativeTrashInversePreflight, nativeTrashInversePostWalk, nativeTrashInverseTransition
    case nativeTrashInverseSync, nativeTrashInverseJournal, nativeTrashInverseObservedChange
    case nativeTrashDeletePreflight, nativeTrashDeleteStageRename, nativeTrashDeleteStagePostWalk
    case nativeTrashDeleteStageTransition, nativeTrashDeleteStageJournal, nativeTrashDeleteUnlink
    case downloadStageMark, downloadTransitionShape, downloadSourceMark
    case downloadSourceProvenance, downloadStageProvenance, downloadMarkReplace
    case downloadStageRecheck, downloadSourceRecheck, downloadProvenanceRecheck
    case downloadAdoptionPathBinding, downloadAdoptionRawQuarantine
    case downloadAdoptionProvenance, downloadAdoptionPublicProperties
    case downloadAdoptionAdmission, downloadAdoptionArea, downloadAdoptionIntent
    case downloadAdoptionMove, downloadAdoptionStage, downloadAdoptionPublication
    case downloadAdoptionCommit
    case copyMetadataComparison, copyReceiptCardinality, copyReceiptValidation
}

/// Closed projection of the error actually caught at a named boundary. Unlike
/// nativeError, this is not an observation from an optional absence probe.
public enum OperationDiagnosticFailure: Sendable {
    case operation(FileOperationFailure), capacity(LocalTextCapacityReason)
    case sqlite(Int32)
    case malformedValue, changedWitness, invalidTransition, valueQuota
    case cancelled, other

    internal init(error: Error) {
        if let value = error as? FileOperationFailure { self = .operation(value) }
        else if let value = error as? LocalTextCapacityReason { self = .capacity(value) }
        else if let value = error as? TextRevisionValueFailure {
            switch value {
            case .malformed: self = .malformedValue
            case .changedWitness: self = .changedWitness
            case .invalidTransition: self = .invalidTransition
            case .quota: self = .valueQuota
            }
        } else if error is CancellationError { self = .cancelled }
        else { self = .other }
    }
}

/// Metadata-only stage observation. No source, destination, item name, file data,
/// error text or recovery path is exposed through this interface.
public struct OperationDiagnosticStage: Sendable {
    public let jobID: UUID
    public let ordinal: UInt64
    public let phase: OperationProgressPhase
    public let success: Bool?
    public let nativeError: Int32?
    public let checkpoint: OperationDiagnosticCheckpoint?
    public let failure: OperationDiagnosticFailure?
    /// Closed transient finding from a complete stable native Trash comparison.
    /// No paths, values, hashes or file bytes cross this diagnostic seam.
    public let nativeTrashFinding: NativeTrashFamilyFinding?
    /// Opaque history identity for correlation; never a location or description.
    public let recordID: UUID?
}

public enum FileOperationDiagnostics {
    private static let channel = DiagnosticChannel()
    /// One application-owned nonblocking sink. Logging is optional and has no
    /// authority over operations. A sink must never wait for I/O or UI work.
    public static func install(_ sink: (@Sendable (OperationDiagnosticStage) -> Void)?) {
        channel.set(sink)
    }
    static func emit(jobID: UUID, ordinal: UInt64, phase: OperationProgressPhase, success: Bool? = nil,
                     nativeError: Int32? = nil, checkpoint: OperationDiagnosticCheckpoint? = nil,
                     failure: OperationDiagnosticFailure? = nil, recordID: UUID? = nil,
                     nativeTrashFinding: NativeTrashFamilyFinding? = nil) {
        channel.emit(.init(jobID: jobID, ordinal: ordinal, phase: phase, success: success,
            nativeError: nativeError, checkpoint: checkpoint, failure: failure,
            nativeTrashFinding: nativeTrashFinding, recordID: recordID))
    }
    static var hasSink: Bool { channel.hasSink }
    private static let scopeKey = "local.MacExplorer.operation-diagnostic-scope"
    /// The engine closure is synchronous on its serial worker. Bind only that
    /// closure's reporter, restoring a nested scope and never carrying it to a
    /// different asynchronous job or a shared worker's next operation.
    static func withScope<T>(_ reporter: OperationProgressReporter?, _ operation: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary, previous = dictionary[scopeKey]
        if let reporter { dictionary[scopeKey] = reporter } else { dictionary.removeObject(forKey: scopeKey) }
        defer {
            if let previous { dictionary[scopeKey] = previous } else { dictionary.removeObject(forKey: scopeKey) }
        }
        return try operation()
    }
    static func nativeFailure(_ code: Int32) {
        (Thread.current.threadDictionary[scopeKey] as? OperationProgressReporter)?.observeNativeError(code)
    }
    /// A received-file producer reports only its closed metadata boundary and
    /// an actual failing syscall status. It never exports attribute bytes or paths.
    @_spi(ArchiveProduction) public static func receivedFileMetadataFailure(
        _ checkpoint: OperationDiagnosticCheckpoint, nativeError: Int32? = nil
    ) {
        switch checkpoint {
        case .downloadStageMark, .downloadTransitionShape, .downloadSourceMark,
             .downloadSourceProvenance, .downloadStageProvenance, .downloadMarkReplace,
             .downloadStageRecheck, .downloadSourceRecheck, .downloadProvenanceRecheck: break
        default: return
        }
        if let nativeError, (1...4095).contains(nativeError) { nativeFailure(nativeError) }
        caughtFailure(checkpoint, FileOperationFailure.copyMetadataMismatch)
    }
    static func caughtFailure(_ checkpoint: OperationDiagnosticCheckpoint, _ error: Error, recordID: UUID? = nil) {
        (Thread.current.threadDictionary[scopeKey] as? OperationProgressReporter)?
            .observeCaughtFailure(checkpoint, error: error, recordID: recordID)
    }
    static func sqliteFailure(_ code: Int32) {
        (Thread.current.threadDictionary[scopeKey] as? OperationProgressReporter)?.observeSQLiteFailure(code)
    }
}

private final class DiagnosticChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (OperationDiagnosticStage) -> Void)?
    var hasSink: Bool { lock.withLock { sink != nil } }
    func set(_ value: (@Sendable (OperationDiagnosticStage) -> Void)?) { lock.withLock { sink = value } }
    func emit(_ value: OperationDiagnosticStage) {
        let callback = lock.withLock { sink }
        callback?(value)
    }
}
