import Darwin
import Dispatch
import Foundation

/// Held by default. The App supplies the explicit policy for its qualified
/// SFTP regular-file composition or a counted generated review. Concrete
/// transport/storage admission remains independent of this engine policy.
public enum ReceivedDownloadPublicQuarantinePolicy: Sendable, Equatable {
    case held, sourceQualification
}

/// Independent gate for one selected regular ZIP member. The App may compose
/// it only for its separately qualified narrow path; Download stays separate.
public enum ZIPOneFilePublicExtractionPolicy: Sendable, Equatable {
    case held, sourceQualification
}
public enum TAROneFilePublicExtractionPolicy: Sendable, Equatable {
    case held, sourceQualification
}

/// Independent v16 directory gates. Declaring one never enables the other,
/// the v14/v15 single-file paths, or an ordinary App composition by default.
public enum ReceivedFolderPublicQuarantinePolicy: Sendable, Equatable {
    case held, sourceQualification
}
public enum ZIPTreePublicExtractionPolicy: Sendable, Equatable {
    case held, sourceQualification
}
public enum TARTreePublicExtractionPolicy: Sendable, Equatable {
    case held, sourceQualification
}

/// Opt-in, serial off-main operations with explicit retention and manual recovery.
/// Recovery folders are never automatically deleted. Undo is a guarded reverse rename sequence.
public final class RecoverableFileOperations: @unchecked Sendable {
    internal let directory: URL
    internal let protectedLocations: [URL]
    internal let continuationSession = UUID()
    private let queue: OperationQueue
    private let activity: (@Sendable () throws -> any Sendable)?
    private let admissionLock = NSLock()
    private var submissions = 0
    private var previewReservation: UUID?
    private var enabledCopyPreview: ProductionCopySession?
    internal let qualifiedCopyPreview: QualifiedCopyPreviewScope?
    internal var pendingWorkerCount: Int { admissionLock.withLock { submissions } }
    public var isIdleForCopyPreview: Bool { admissionLock.withLock { submissions == 0 && previewReservation == nil } }
    public var isCopyPreviewEnabled: Bool { admissionLock.withLock { enabledCopyPreview != nil } }
    internal var productionCopySession: ProductionCopySession? { admissionLock.withLock { enabledCopyPreview } }

    internal func reserveCopyPreview() -> UUID? {
        admissionLock.withLock {
            guard submissions == 0, previewReservation == nil else { return nil }
            let token = UUID(); previewReservation = token; return token
        }
    }
    internal func finishCopyPreviewReservation(_ token: UUID) {
        admissionLock.withLock { if previewReservation == token { previewReservation = nil } }
    }
    internal func installCopyPreview(_ session: ProductionCopySession?, reservation: UUID) throws {
        try admissionLock.withLock {
            guard previewReservation == reservation else { throw FileOperationFailure.unavailable }
            enabledCopyPreview = session
        }
    }
    public func disableCopyPreview() { admissionLock.withLock { enabledCopyPreview = nil } }
    internal let legacy: LocalFileOperations
    internal let hooks: RecoveryHooks
    internal let copyExecutionAuthorization: CopyExecutionAuthorization
    internal let authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy
    internal let strictPortableTARCreationPolicy: StrictPortableTARCreationPolicy
    internal let tarGzipCreationPolicy: TARGzipCreationPolicy
    internal let nativeAuthoredCreatePublicMarkPolicy: NativeAuthoredCreatePublicMarkPolicy
    internal let authoredZIPOriginalUpdateNativePolicy: AuthoredZIPOriginalUpdateNativePolicy
    internal let authoredTAROriginalUpdatePolicy: AuthoredTAROriginalUpdatePolicy
    @_spi(ArchiveProduction) public var nativeZIPCreationAcceptsMarkedSources: Bool {
        authoredZIPMetadataPolicy == .nativeCreate
    }
    @_spi(ArchiveProduction) public var nativeTARCreationAcceptsMarkedSources: Bool {
        strictPortableTARCreationPolicy == .nativeCreateQualification
    }
    @_spi(ArchiveProduction) public var nativeTARGzipCreationAcceptsMarkedSources: Bool {
        tarGzipCreationPolicy == .developmentNativeCreate
    }
    internal let downloadAdoptionPolicy: DownloadAdoptionPolicy
    internal let receivedDownloadPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy
    internal let zipOneFilePublicExtractionPolicy: ZIPOneFilePublicExtractionPolicy
    internal let tarOneFilePublicExtractionPolicy: TAROneFilePublicExtractionPolicy
    internal let receivedFolderPublicQuarantinePolicy: ReceivedFolderPublicQuarantinePolicy
    internal let zipTreePublicExtractionPolicy: ZIPTreePublicExtractionPolicy
    internal let tarTreePublicExtractionPolicy: TARTreePublicExtractionPolicy
    internal let nativeTrashDirectoryAdmission: NativeTrashDirectoryAdmission
    /// App-owned admission. The narrow policy cannot create or reverse an
    /// older directory/mixed Trash record while leaving it readable.
    internal let nativeTrashPolicy: NativeTrashMutationPolicy
    /// Retained editor-copy retirement has its own record and mutation gate.
    internal let localTextRetirementPolicy: LocalTextRetirementPolicy
    #if DEBUG
    // Installed exactly once before this engine escapes its DEBUG factory.
    // Worker closures retain self until actual drain, including cancellation.
    private var generatedResponsivenessCapability: GeneratedCopyResponsivenessCapability?

    internal func installGeneratedResponsivenessCapability(_ capability: GeneratedCopyResponsivenessCapability) throws {
        try admissionLock.withLock {
            guard generatedResponsivenessCapability == nil, submissions == 0,
                  case .generatedFixture = copyExecutionAuthorization,
                  directory == capability.journal else { throw FileOperationFailure.invalidRequest }
            generatedResponsivenessCapability = capability
        }
    }

    private func validateGeneratedResponsivenessCapability(sources: [URL], destination: URL, move: Bool,
        metadataPolicy: TransferMetadataPolicy, cancellation: OperationCancellation) throws {
        let capability = admissionLock.withLock { generatedResponsivenessCapability }
        try capability?.validateCopy(sources: sources, destination: destination, move: move,
                                     metadataPolicy: metadataPolicy, cancellation: cancellation)
    }
    #endif

    public convenience init(journalDirectory: URL, protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil,
                            authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy = .exactSource,
                            strictPortableTARCreationPolicy: StrictPortableTARCreationPolicy = .held,
                            tarGzipCreationPolicy: TARGzipCreationPolicy = .held,
                            nativeAuthoredCreatePublicMarkPolicy: NativeAuthoredCreatePublicMarkPolicy = .held,
                            authoredZIPOriginalUpdateNativePolicy: AuthoredZIPOriginalUpdateNativePolicy = .held,
                            authoredTAROriginalUpdatePolicy: AuthoredTAROriginalUpdatePolicy = .held,
                            downloadAdoptionPolicy: DownloadAdoptionPolicy = .held,
                            receivedDownloadPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy = .held,
                            zipOneFilePublicExtractionPolicy: ZIPOneFilePublicExtractionPolicy = .held,
                            tarOneFilePublicExtractionPolicy: TAROneFilePublicExtractionPolicy = .held,
                            receivedFolderPublicQuarantinePolicy: ReceivedFolderPublicQuarantinePolicy = .held,
                            zipTreePublicExtractionPolicy: ZIPTreePublicExtractionPolicy = .held,
                            tarTreePublicExtractionPolicy: TARTreePublicExtractionPolicy = .held,
                            nativeTrashPolicy: NativeTrashMutationPolicy = .existingVerifiedPaths,
                            localTextRetirementPolicy: LocalTextRetirementPolicy = .legacyVerifiedPaths) {
        self.init(journalDirectory: journalDirectory, hooks: RecoveryHooks(), copyExecutionAuthorization: .closed,
                  protecting: protecting, activity: activity, authoredZIPMetadataPolicy: authoredZIPMetadataPolicy,
                  strictPortableTARCreationPolicy: strictPortableTARCreationPolicy,
                  tarGzipCreationPolicy: tarGzipCreationPolicy,
                  nativeAuthoredCreatePublicMarkPolicy: nativeAuthoredCreatePublicMarkPolicy,
                  authoredZIPOriginalUpdateNativePolicy: authoredZIPOriginalUpdateNativePolicy,
                  authoredTAROriginalUpdatePolicy: authoredTAROriginalUpdatePolicy,
                  downloadAdoptionPolicy: downloadAdoptionPolicy,
                  receivedDownloadPublicQuarantinePolicy: receivedDownloadPublicQuarantinePolicy,
                  zipOneFilePublicExtractionPolicy: zipOneFilePublicExtractionPolicy,
                  tarOneFilePublicExtractionPolicy: tarOneFilePublicExtractionPolicy,
                  receivedFolderPublicQuarantinePolicy: receivedFolderPublicQuarantinePolicy,
                  zipTreePublicExtractionPolicy: zipTreePublicExtractionPolicy,
                  tarTreePublicExtractionPolicy: tarTreePublicExtractionPolicy,
                  nativeTrashPolicy: nativeTrashPolicy,
                  localTextRetirementPolicy: localTextRetirementPolicy)
    }
    public convenience init(journalDirectory: URL, qualifiedCopyPreview: QualifiedCopyPreviewScope,
                            protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil,
                            authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy = .exactSource,
                            strictPortableTARCreationPolicy: StrictPortableTARCreationPolicy = .held,
                            tarGzipCreationPolicy: TARGzipCreationPolicy = .held,
                            nativeAuthoredCreatePublicMarkPolicy: NativeAuthoredCreatePublicMarkPolicy = .held,
                            authoredZIPOriginalUpdateNativePolicy: AuthoredZIPOriginalUpdateNativePolicy = .held,
                            authoredTAROriginalUpdatePolicy: AuthoredTAROriginalUpdatePolicy = .held,
                            downloadAdoptionPolicy: DownloadAdoptionPolicy = .held,
                            receivedDownloadPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy = .held,
                            zipOneFilePublicExtractionPolicy: ZIPOneFilePublicExtractionPolicy = .held,
                            tarOneFilePublicExtractionPolicy: TAROneFilePublicExtractionPolicy = .held,
                            receivedFolderPublicQuarantinePolicy: ReceivedFolderPublicQuarantinePolicy = .held,
                            zipTreePublicExtractionPolicy: ZIPTreePublicExtractionPolicy = .held,
                            tarTreePublicExtractionPolicy: TARTreePublicExtractionPolicy = .held,
                            nativeTrashPolicy: NativeTrashMutationPolicy = .existingVerifiedPaths,
                            localTextRetirementPolicy: LocalTextRetirementPolicy = .legacyVerifiedPaths) {
        self.init(journalDirectory: journalDirectory, hooks: RecoveryHooks(), copyExecutionAuthorization: .closed,
                  qualifiedCopyPreview: qualifiedCopyPreview, protecting: protecting, activity: activity,
                  authoredZIPMetadataPolicy: authoredZIPMetadataPolicy,
                  strictPortableTARCreationPolicy: strictPortableTARCreationPolicy,
                  tarGzipCreationPolicy: tarGzipCreationPolicy,
                  nativeAuthoredCreatePublicMarkPolicy: nativeAuthoredCreatePublicMarkPolicy,
                  authoredZIPOriginalUpdateNativePolicy: authoredZIPOriginalUpdateNativePolicy,
                  authoredTAROriginalUpdatePolicy: authoredTAROriginalUpdatePolicy,
                  downloadAdoptionPolicy: downloadAdoptionPolicy,
                  receivedDownloadPublicQuarantinePolicy: receivedDownloadPublicQuarantinePolicy,
                  zipOneFilePublicExtractionPolicy: zipOneFilePublicExtractionPolicy,
                  tarOneFilePublicExtractionPolicy: tarOneFilePublicExtractionPolicy,
                  receivedFolderPublicQuarantinePolicy: receivedFolderPublicQuarantinePolicy,
                  zipTreePublicExtractionPolicy: zipTreePublicExtractionPolicy,
                  tarTreePublicExtractionPolicy: tarTreePublicExtractionPolicy,
                  nativeTrashPolicy: nativeTrashPolicy,
                  localTextRetirementPolicy: localTextRetirementPolicy)
    }
    /// The signed generated Download review may pause only after v7's first
    /// exclusive rename. The callback observes cancellation; it cannot change
    /// the operation's quarantine, identity, or publication checks.
    @_spi(ArchiveProduction) public convenience init(journalDirectory: URL,
                            qualifyingAdoptionCheckpoint: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> Void,
                            qualifiedCopyPreview: QualifiedCopyPreviewScope? = nil,
                            protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil,
                            authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy = .exactSource) {
        var hooks = RecoveryHooks()
        hooks.afterAdoptionMove = qualifyingAdoptionCheckpoint
        self.init(journalDirectory: journalDirectory, hooks: hooks, copyExecutionAuthorization: .closed,
                  qualifiedCopyPreview: qualifiedCopyPreview, protecting: protecting, activity: activity,
                  authoredZIPMetadataPolicy: authoredZIPMetadataPolicy,
                  downloadAdoptionPolicy: .sourceQualification)
    }
    /// Generated QA may report one interruption only after v13 has durably
    /// qualified the retained original. The callback receives no file URL or
    /// descriptor and grants no authority to change the recovery area.
    @_spi(ArchiveProduction) public convenience init(journalDirectory: URL,
                            qualifyingNativeZIPRetainedOriginalCheckpoint: @escaping @Sendable () throws -> Void,
                            qualifiedCopyPreview: QualifiedCopyPreviewScope? = nil,
                            protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil,
                            authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy = .exactSource,
                            nativeTrashPolicy: NativeTrashMutationPolicy = .existingVerifiedPaths) {
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, _ in
            if stage == .originalRetained { try qualifyingNativeZIPRetainedOriginalCheckpoint() }
        }
        self.init(journalDirectory: journalDirectory, hooks: hooks, copyExecutionAuthorization: .closed,
                  qualifiedCopyPreview: qualifiedCopyPreview, protecting: protecting, activity: activity,
                  authoredZIPMetadataPolicy: authoredZIPMetadataPolicy,
                  authoredZIPOriginalUpdateNativePolicy: .qualifiedNativeStage,
                  downloadAdoptionPolicy: .held, nativeTrashPolicy: nativeTrashPolicy)
    }
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    /// A distinct generated QA composition. Every performed adoption stops
    /// inside its private recovery area before the public rename, regardless
    /// of whether the native mark was unchanged, restored or refused.
    @_spi(ArchiveProduction) public convenience init(journalDirectory: URL,
                            qualifyingPrivateMarkProbe: @escaping @Sendable (DownloadPrivateMarkProbeResult) -> Void,
                            protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil) {
        var hooks = RecoveryHooks()
        hooks.privateDownloadMarkProbe = qualifyingPrivateMarkProbe
        self.init(journalDirectory: journalDirectory, hooks: hooks, copyExecutionAuthorization: .closed,
                  protecting: protecting, activity: activity, downloadAdoptionPolicy: .sourceQualification)
    }
    #endif
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    /// A compile-gated composition for a separately admitted signed QA case.
    /// The app must select it through its exact case/identity/command gate;
    /// this initializer performs no fixture-path inference or runtime grant.
    /// ZIP and Download retain their exact-source/held policies here.
    @_spi(ArchiveProduction) public convenience init(
        qualifyingAdditiveRootDirectoryTrashAt journalDirectory: URL,
        protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil
    ) {
        self.init(journalDirectory: journalDirectory, hooks: RecoveryHooks(),
                  copyExecutionAuthorization: .closed, protecting: protecting,
                  activity: activity, authoredZIPMetadataPolicy: .exactSource,
                  downloadAdoptionPolicy: .held,
                  nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    }
    #endif
    #if !MAC_EXPLORER_DISTRIBUTION
    /// A separate ordinary local Preview composition. The application owns
    /// identity and journal-path admission; this SPI grants no fixture or
    /// command-line authority. ZIP uses the separately selected authored-file
    /// policy. Received Download has its own explicit policy, held by default.
    @_spi(ApplicationOwnership) public convenience init(
        localPreviewAdditiveRootDirectoryTrashAt journalDirectory: URL,
        qualifiedCopyPreview: QualifiedCopyPreviewScope? = nil,
        protecting: [URL] = [], activity: (@Sendable () throws -> any Sendable)? = nil,
        authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy = .exactSource,
        strictPortableTARCreationPolicy: StrictPortableTARCreationPolicy = .held,
        tarGzipCreationPolicy: TARGzipCreationPolicy = .held,
        nativeAuthoredCreatePublicMarkPolicy: NativeAuthoredCreatePublicMarkPolicy = .held,
        authoredZIPOriginalUpdateNativePolicy: AuthoredZIPOriginalUpdateNativePolicy = .held,
        authoredTAROriginalUpdatePolicy: AuthoredTAROriginalUpdatePolicy = .held,
        receivedDownloadPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy = .held,
        zipOneFilePublicExtractionPolicy: ZIPOneFilePublicExtractionPolicy = .held,
        tarOneFilePublicExtractionPolicy: TAROneFilePublicExtractionPolicy = .held,
        receivedFolderPublicQuarantinePolicy: ReceivedFolderPublicQuarantinePolicy = .held,
        zipTreePublicExtractionPolicy: ZIPTreePublicExtractionPolicy = .held,
        tarTreePublicExtractionPolicy: TARTreePublicExtractionPolicy = .held
    ) {
        self.init(journalDirectory: journalDirectory, hooks: RecoveryHooks(),
                  copyExecutionAuthorization: .closed, qualifiedCopyPreview: qualifiedCopyPreview,
                  protecting: protecting, activity: activity,
                  authoredZIPMetadataPolicy: authoredZIPMetadataPolicy,
                  strictPortableTARCreationPolicy: strictPortableTARCreationPolicy,
                  tarGzipCreationPolicy: tarGzipCreationPolicy,
                  nativeAuthoredCreatePublicMarkPolicy: nativeAuthoredCreatePublicMarkPolicy,
                  authoredZIPOriginalUpdateNativePolicy: authoredZIPOriginalUpdateNativePolicy,
                  authoredTAROriginalUpdatePolicy: authoredTAROriginalUpdatePolicy,
                  downloadAdoptionPolicy: .held,
                  receivedDownloadPublicQuarantinePolicy: receivedDownloadPublicQuarantinePolicy,
                  zipOneFilePublicExtractionPolicy: zipOneFilePublicExtractionPolicy,
                  tarOneFilePublicExtractionPolicy: tarOneFilePublicExtractionPolicy,
                  receivedFolderPublicQuarantinePolicy: receivedFolderPublicQuarantinePolicy,
                  zipTreePublicExtractionPolicy: zipTreePublicExtractionPolicy,
                  tarTreePublicExtractionPolicy: tarTreePublicExtractionPolicy,
                  nativeTrashDirectoryAdmission: .additiveRootOnlyCandidate)
    }
    #endif
    internal init(journalDirectory: URL, hooks: RecoveryHooks, legacy: LocalFileOperations = LocalFileOperations(),
                  copyExecutionAuthorization: CopyExecutionAuthorization? = nil,
                  qualifiedCopyPreview: QualifiedCopyPreviewScope? = nil,
                  protecting: [URL] = [],
                  activity: (@Sendable () throws -> any Sendable)? = nil,
                  authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy = .exactSource,
                  strictPortableTARCreationPolicy: StrictPortableTARCreationPolicy = .held,
                  tarGzipCreationPolicy: TARGzipCreationPolicy = .held,
                  nativeAuthoredCreatePublicMarkPolicy: NativeAuthoredCreatePublicMarkPolicy = .held,
                  authoredZIPOriginalUpdateNativePolicy: AuthoredZIPOriginalUpdateNativePolicy = .held,
                  authoredTAROriginalUpdatePolicy: AuthoredTAROriginalUpdatePolicy = .held,
                  downloadAdoptionPolicy: DownloadAdoptionPolicy = .held,
                  receivedDownloadPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy = .held,
                  zipOneFilePublicExtractionPolicy: ZIPOneFilePublicExtractionPolicy = .held,
                  tarOneFilePublicExtractionPolicy: TAROneFilePublicExtractionPolicy = .held,
                  receivedFolderPublicQuarantinePolicy: ReceivedFolderPublicQuarantinePolicy = .held,
                  zipTreePublicExtractionPolicy: ZIPTreePublicExtractionPolicy = .held,
                  tarTreePublicExtractionPolicy: TARTreePublicExtractionPolicy = .held,
                  nativeTrashDirectoryAdmission: NativeTrashDirectoryAdmission = .strict,
                  nativeTrashPolicy: NativeTrashMutationPolicy = .existingVerifiedPaths,
                  localTextRetirementPolicy: LocalTextRetirementPolicy = .legacyVerifiedPaths) {
        directory = journalDirectory
        protectedLocations = protecting
        self.legacy = legacy
        self.activity = activity
        self.hooks = hooks
        self.qualifiedCopyPreview = qualifiedCopyPreview
        self.copyExecutionAuthorization = copyExecutionAuthorization ?? (hooks.groupedCopy.qualification == nil ? .closed : .legacyQualification)
        self.authoredZIPMetadataPolicy = authoredZIPMetadataPolicy
        self.strictPortableTARCreationPolicy = strictPortableTARCreationPolicy
        self.tarGzipCreationPolicy = tarGzipCreationPolicy
        self.nativeAuthoredCreatePublicMarkPolicy = nativeAuthoredCreatePublicMarkPolicy
        self.authoredZIPOriginalUpdateNativePolicy = authoredZIPOriginalUpdateNativePolicy
        self.authoredTAROriginalUpdatePolicy = authoredTAROriginalUpdatePolicy
        self.downloadAdoptionPolicy = downloadAdoptionPolicy
        self.receivedDownloadPublicQuarantinePolicy = receivedDownloadPublicQuarantinePolicy
        self.zipOneFilePublicExtractionPolicy = zipOneFilePublicExtractionPolicy
        self.tarOneFilePublicExtractionPolicy = tarOneFilePublicExtractionPolicy
        self.receivedFolderPublicQuarantinePolicy = receivedFolderPublicQuarantinePolicy
        self.zipTreePublicExtractionPolicy = zipTreePublicExtractionPolicy
        self.tarTreePublicExtractionPolicy = tarTreePublicExtractionPolicy
        self.nativeTrashDirectoryAdmission = nativeTrashDirectoryAdmission
        self.nativeTrashPolicy = nativeTrashPolicy
        self.localTextRetirementPolicy = localTextRetirementPolicy
        queue = OperationQueue()
        queue.name = "MacExplorer.RecoverableOperations"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public func observeSelection(_ urls: [URL]) async throws -> FileOperationSelection {
        try await worker { cancellation in
            guard !urls.isEmpty, urls.count <= OperationJournal.maximumInputs else { throw FileOperationFailure.invalidRequest }
            let observed = try urls.map { url in try cancellation.check(); return try observeObject(url) }
            return FileOperationSelection(urls: observed.map(\.url), identities: observed.map(\.snapshot))
        }
    }
    public func observeDirectory(_ url: URL) async throws -> FileOperationSelection {
        try await worker { cancellation in
            try cancellation.check()
            let anchor = try DirectoryAnchor(url)
            return FileOperationSelection(urls: [anchor.url], identities: [anchor.identity])
        }
    }

    public func prepareTransfer(sources: [URL], destinationDirectory: URL, move: Bool,
                                observing selection: FileOperationSelection? = nil,
                                metadataPolicy: TransferMetadataPolicy = .strict,
                                copyExecution: CopyExecutionRequest = .standard,
                                progress: (@Sendable (OperationProgress) -> Void)? = nil) async throws -> TransferPlan {
        let reporter = OperationProgressReporter(callback: progress)
        do {
            let plan = try await worker(progress: reporter) { cancellation in
                try self.prepare(sources: sources, destination: destinationDirectory, move: move, observing: selection, metadataPolicy: metadataPolicy, copyExecution: copyExecution, cancellation: cancellation)
            }
            reporter.flush(); return plan
        } catch { reporter.finish(success: false); throw error }
    }

    public func perform(_ plan: TransferPlan, resolutions: [UUID: TransferConflictResolution] = [:],
                        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = plan.progressReporter.next(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                #if DEBUG
                try self.validateGeneratedResponsivenessCapability(sources: plan.sources,
                    destination: plan.destinationDirectory, move: plan.isMove,
                    metadataPolicy: plan.metadataPolicy, cancellation: cancellation)
                #endif
                try self.validateCopyExecutionSession(locations: plan.entries.flatMap { [$0.source, $0.destination] },
                                                      directories: [plan.destinationDirectory])
                return self.execute(plan, resolutions: resolutions, cancellation: cancellation)
            }
        }
        catch { result = failure(error, sources: plan.sources) }
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }

    public func perform(_ request: FileOperationRequest, observing selection: FileOperationSelection? = nil,
                        metadataPolicy: TransferMetadataPolicy = .strict,
                        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result: RecoverableOperationResult
        do {
            result = try await worker(progress: reporter) { cancellation in
                let locations: [URL]
                let directories: [URL]
                switch request {
                case .copy(let sources, let destination), .move(let sources, let destination): locations = sources + [destination]; directories = [destination]
                case .moveObserved(let selection, let destination): locations = selection.urls + [destination]; directories = [destination]
                case .createFolder(let parent, _): locations = [parent]; directories = [parent]
                case .rename(let source, _): locations = [source]; directories = []
                case .trash(let sources): locations = sources; directories = []
                }
                if case .generatedFixture = self.copyExecutionAuthorization {
                    switch request {
                    case .copy, .move, .moveObserved: break
                    default: throw FileOperationFailure.unsupported
                    }
                }
                try self.validateCopyExecutionSession(locations: locations, directories: directories)
                switch request {
                case .copy(let sources, let destination), .move(let sources, let destination):
                    let moving: Bool = if case .move = request { true } else { false }
                    let plan = try self.prepare(sources: sources, destination: destination, move: moving, observing: selection, metadataPolicy: metadataPolicy, cancellation: cancellation)
                    return self.execute(plan, resolutions: [:], cancellation: cancellation)
                case .moveObserved(let cut, let destination):
                    let plan = try self.prepare(sources: cut.urls, destination: destination, move: true, observing: selection.map { cut.combining($0) } ?? cut, metadataPolicy: metadataPolicy, cancellation: cancellation)
                    return self.execute(plan, resolutions: [:], cancellation: cancellation)
                case .createFolder(let parent, let name):
                    return self.simple(source: nil, parent: parent, name: name, observing: selection, cancellation: cancellation)
                case .rename(let source, let name):
                    return self.sameParentRename(source: source, name: name, observing: selection, cancellation: cancellation)
                        ?? self.simple(source: source, parent: source.deletingLastPathComponent(), name: name, observing: selection, cancellation: cancellation)
                case .trash(let sources):
                    guard self.nativeTrashPolicy != .held else { throw FileOperationFailure.unsupported }
                    return self.trash(sources, observing: selection, cancellation: cancellation)
                }
            }
        } catch { result = failure(error, sources: request.sources) }
        // A verified exact-spelling Rename no-op has no journal mutation or Undo.
        let renameNoOp: Bool = if case .rename = request { result.recordID == nil && result.result.disposition == .succeeded } else { false }
        reporter.finish(success: result.result.disposition == .succeeded && (result.recordID != nil || renameNoOp))
        return result
    }

    /// Passive inspection never creates, imports, upgrades or recovers storage.
    public func inspectExistingHistory(after: UUID? = nil, limit: Int = 64) async throws -> OperationRecoveryInspection {
        try await worker { cancellation in
            let adoptionUndoHint: Bool
            switch self.downloadAdoptionPolicy {
            case .held: adoptionUndoHint = false
            case .sourceQualification: adoptionUndoHint = true
            }
            return try OperationHistoryInspector.inspect(self.directory, after: after, limit: limit,
                cancellation: cancellation, allowDownloadAdoptionUndoHint: adoptionUndoHint,
                allowNativeOriginalUpdateUndoHint: self.authoredZIPOriginalUpdateNativePolicy == .qualifiedNativeStage,
                allowNativeTARUpdateUndoHint: self.authoredTAROriginalUpdatePolicy == .developmentNativeStage,
                allowPublicDownloadUndoHint: self.receivedDownloadPublicQuarantinePolicy == .sourceQualification,
                allowPublicZIPExtractionUndoHint: self.zipOneFilePublicExtractionPolicy == .sourceQualification,
                allowPublicTARExtractionUndoHint: self.tarOneFilePublicExtractionPolicy == .sourceQualification,
                allowReceivedFolderUndoHint: self.receivedFolderPublicQuarantinePolicy == .sourceQualification,
                allowZIPTreeUndoHint: self.zipTreePublicExtractionPolicy == .sourceQualification,
                allowTARTreeUndoHint: self.tarTreePublicExtractionPolicy == .sourceQualification)
        }
    }

    /// Explicit writable history preparation. Passive callers use inspectExistingHistory.
    public func recoveryRecords(after: UUID? = nil, limit: Int = 64) async throws -> OperationRecoveryInspection {
        try await worker { cancellation in
            let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
            let page = try journal.inspectSummaries(after: after, limit: limit,
                allowNativeOriginalUpdateUndoHint: self.authoredZIPOriginalUpdateNativePolicy == .qualifiedNativeStage,
                allowNativeTARUpdateUndoHint: self.authoredTAROriginalUpdatePolicy == .developmentNativeStage,
                allowPublicDownloadUndoHint: self.receivedDownloadPublicQuarantinePolicy == .sourceQualification,
                allowPublicZIPExtractionUndoHint: self.zipOneFilePublicExtractionPolicy == .sourceQualification,
                allowPublicTARExtractionUndoHint: self.tarOneFilePublicExtractionPolicy == .sourceQualification,
                allowReceivedFolderUndoHint: self.receivedFolderPublicQuarantinePolicy == .sourceQualification,
                allowZIPTreeUndoHint: self.zipTreePublicExtractionPolicy == .sourceQualification,
                allowTARTreeUndoHint: self.tarTreePublicExtractionPolicy == .sourceQualification)
            let unfinished = try? journal.unfinishedCount()
            return OperationRecoveryInspection(records: page.records, refusedEntries: page.refused,
                nextCursor: page.next, unfinishedCount: unfinished ?? 0,
                readiness: journal.inspectionReadiness, unfinishedCountIsComplete: unfinished != nil)
        }
    }

    /// A validated committed single-output record identifies the exact output
    /// parent whose folder scope may be needed for cold Undo. Authored Create
    /// ZIP/TAR uses only its v3 private-payload publication shape here.
    /// This passive read neither opens that destination nor changes history;
    /// Undo repeats all live checks.
    public func undoAccessRequirement(recordID: UUID) async throws -> OperationUndoAccessRequirement? {
        try await worker { cancellation in
            let catalog = try OperationHistoryInspector.record(self.directory, id: recordID,
                                                               cancellation: cancellation)
            let record: JournalRecord
            switch catalog {
            case .treeV3(let value) where value.operation == "Create ZIP" || value.operation == "Create TAR" || value.operation == "Create TAR.gz":
                // v3 also records other file work. The title alone is not a
                // sufficient reason to ask the user for destination access.
                let prefix = ".mac-explorer-recovery-"
                guard value.areas.count == 1, value.steps.count == 1,
                      value.trashIntents.isEmpty,
                      let area = value.areas.first, area.stagingProof == nil,
                      area.url.lastPathComponent.hasPrefix(prefix),
                      UUID(uuidString: String(area.url.lastPathComponent.dropFirst(prefix.count)))?.uuidString
                          == String(area.url.lastPathComponent.dropFirst(prefix.count)),
                      let step = value.steps.first, let after = step.after,
                      step.before.identity.type == S_IFREG, after.identity.type == S_IFREG,
                      step.before.identity.sameObject(as: after.identity),
                      step.sourceParent.sameObject(as: area.identity),
                      step.destinationParent.device == area.identity.device,
                      OperationJournal.sameURLRepresentation(step.source, area.url.appendingPathComponent("payload")),
                      OperationJournal.sameURLRepresentation(step.destination.deletingLastPathComponent(),
                          area.url.deletingLastPathComponent()),
                      value.locations.contains(where: { OperationJournal.sameURLRepresentation($0, area.url) }),
                      value.locations.contains(where: { OperationJournal.sameURLRepresentation($0, step.destination) })
                else { throw FileOperationFailure.recoveryUncertain }
                record = value
            case .receivedPublicDownloadV14(let value):
                guard self.receivedDownloadPublicQuarantinePolicy == .sourceQualification else {
                    throw FileOperationFailure.unsupported
                }
                record = value
            case .publicZIPExtractionFileV15(let value):
                guard self.zipOneFilePublicExtractionPolicy == .sourceQualification else {
                    throw FileOperationFailure.unsupported
                }
                record = value
            case .publicTARExtractionFileV17(let value):
                guard self.tarOneFilePublicExtractionPolicy == .sourceQualification else {
                    throw FileOperationFailure.unsupported
                }
                record = value
            case .publicProducedTreeV16(let value):
                guard let purpose = value.producedTreeV16 else { throw FileOperationFailure.recoveryUncertain }
                switch purpose {
                case .receivedFolder:
                    guard self.receivedFolderPublicQuarantinePolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                case .zipExtraction:
                    guard self.zipTreePublicExtractionPolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                case .tarExtraction:
                    guard self.tarTreePublicExtractionPolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                }
                record = value
            default: return nil
            }
            guard record.state == "committed", record.steps.count == 1,
                  let step = record.steps.first, step.after != nil, !step.undone else {
                throw FileOperationFailure.recoveryUncertain
            }
            return OperationUndoAccessRequirement(recordID: recordID,
                directory: step.destination.deletingLastPathComponent())
        }
    }

    public func undo(recordID: UUID, progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await reverse(recordID: recordID, recovering: false, progress: progress)
    }
    public func recover(recordID: UUID, progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await reverse(recordID: recordID, recovering: true, progress: progress)
    }
    /// Restore only a v13 old ZIP whose first rename and native-security checks
    /// were durably acknowledged before any replacement intent existed.
    public func restoreInterruptedOriginalZIP(recordID: UUID,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await restoreInterruptedOriginalArchive(recordID: recordID, progress: progress)
    }
    /// Format admission is checked against the persisted v13 ZIP or v18 TAR
    /// record, before any retained original can be restored.
    public func restoreInterruptedOriginalArchive(recordID: UUID,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        await reverse(recordID: recordID, recovering: true,
            restoringInterruptedOriginalZIP: true, progress: progress)
    }
    private func reverse(recordID: UUID, recovering: Bool,
        restoringInterruptedOriginalZIP: Bool = false,
        progress: (@Sendable (OperationProgress) -> Void)?) async -> RecoverableOperationResult {
        let reporter = OperationProgressReporter(callback: progress)
        let result = await reverseWorker(recordID: recordID, recovering: recovering,
            restoringInterruptedOriginalZIP: restoringInterruptedOriginalZIP, reporter: reporter)
        reporter.finish(success: result.result.disposition == .succeeded && result.recordID != nil)
        return result
    }
    private func reverseWorker(recordID: UUID, recovering: Bool,
        restoringInterruptedOriginalZIP: Bool, reporter: OperationProgressReporter) async -> RecoverableOperationResult {
        do {
            return try await worker(progress: reporter) { cancellation in
                reporter.begin(.verifying)
                let journal = try OperationJournal(self.directory, hooks: self.hooks.journalHooks, cancellation: cancellation)
                if case .textRevisionV3(let record)? = try journal.inspectCatalogRecord(recordID) {
                    guard !recovering else { throw FileOperationFailure.unsupported }
                    return self.reverseLocalTextV2(record, journal: journal, cancellation: cancellation)
                }
                if case .groupedCopyV1? = try journal.inspectCatalogRecord(recordID) {
                    // Restore Original State is the legacy inverse action, never
                    // authority to confirm or replay grouped Copy recovery.
                    guard !recovering, let edit = try journal.openGroupedEdit(recordID) else { throw FileOperationFailure.unsupported }
                    return self.reverseGroupedCopy(edit, journal: journal, cancellation: cancellation)
                }
                guard let record = try journal.openEdit(recordID) else { throw FileOperationFailure.recoveryUncertain }
                if record.snapshot.version == 14 {
                    guard !recovering,
                          self.receivedDownloadPublicQuarantinePolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                }
                if record.snapshot.version == 15 {
                    guard !recovering,
                          self.zipOneFilePublicExtractionPolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                }
                if record.snapshot.version == 17 {
                    guard !recovering,
                          self.tarOneFilePublicExtractionPolicy == .sourceQualification else {
                        throw FileOperationFailure.unsupported
                    }
                }
                if record.snapshot.version == 16 {
                    guard !recovering, let purpose = record.snapshot.producedTreeV16 else {
                        throw FileOperationFailure.unsupported
                    }
                    switch purpose {
                    case .receivedFolder:
                        guard self.receivedFolderPublicQuarantinePolicy == .sourceQualification else {
                            throw FileOperationFailure.unsupported
                        }
                    case .zipExtraction:
                        guard self.zipTreePublicExtractionPolicy == .sourceQualification else {
                            throw FileOperationFailure.unsupported
                        }
                    case .tarExtraction:
                        guard self.tarTreePublicExtractionPolicy == .sourceQualification else {
                            throw FileOperationFailure.unsupported
                        }
                    }
                }
                if restoringInterruptedOriginalZIP {
                    guard recovering,
                          self.nativeArchiveUpdateEnabled(version: record.snapshot.version),
                          OperationJournal.hasRecordedNativeArchiveOriginalOnly(record.snapshot) else {
                        throw FileOperationFailure.unsupported
                    }
                    let step = record.steps[0]
                    let originalParent = try DirectoryAnchor(step.source.deletingLastPathComponent(), resolve: false)
                    let retainedParent = try DirectoryAnchor(step.destination.deletingLastPathComponent(), resolve: false)
                    guard try record.matchesPersisted(step.sourceParent, originalParent.identity, in: originalParent),
                          try record.matchesPersisted(step.destinationParent, retainedParent.identity, in: retainedParent) else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                    try requireAbsent(step.source.lastPathComponent, in: originalParent.fd)
                    try originalParent.validate(); try retainedParent.validate()
                }
                if record.snapshot.operation == "Move to Trash" {
                    switch self.nativeTrashPolicy {
                    case .held: throw FileOperationFailure.unsupported
                    case .regularFilesOnly:
                        guard record.snapshot.version == 11 else { throw FileOperationFailure.unsupported }
                    case .regularFilesAndDirectories:
                        guard [11, 12].contains(record.snapshot.version) else { throw FileOperationFailure.unsupported }
                    case .existingVerifiedPaths: break
                    }
                }
                guard ![8, 10].contains(record.snapshot.version) else { throw FileOperationFailure.unsupported }
                // V13 generic reconciliation cannot infer an unacknowledged
                // native mark change; only the explicit one-step action proceeds.
                guard (record.snapshot.version != 12 || !recovering),
                      (![13, 18].contains(record.snapshot.version) || !recovering || restoringInterruptedOriginalZIP) else {
                    throw FileOperationFailure.unsupported
                }
                if record.nameRename != nil {
                    return self.reverseNameRename(record, journal: journal, recovering: recovering, cancellation: cancellation)
                }
                guard
                      recovering ? ["preparing", "mutating", "needsReview", "undoing"].contains(record.state) : record.state == "committed",
                      !record.steps.isEmpty,
                      record.trashIntents.allSatisfy({ intent in record.steps.contains { $0.source == intent.source && $0.after != nil } }) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                // V5 does not identify its producer; only the native-stage
                // qualification may undo its changed backup. V6 identifies the
                // strict cloned producer and requires that qualification before
                // any inverse mutation. Both require the exact recorded image.
                let archiveUpdate = [5, 6, 13, 18].contains(record.snapshot.version)
                let adoptedDownload = record.snapshot.version == 7 ? record.downloadAdoption : nil
                if record.snapshot.version == 7 {
                    guard !recovering, record.state == "committed", record.steps.count == 1,
                          let adoptedDownload, let finalAfter = record.steps[0].after,
                          case .sourceQualification = self.downloadAdoptionPolicy else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                    let final = record.steps[0].destination
                    let finalParent = try DirectoryAnchor(final.deletingLastPathComponent(), resolve: false)
                    let pin = try pinEntry(parent: finalParent.fd,
                        name: final.lastPathComponent, matching: finalAfter.identity)
                    defer { close(pin) }
                    try adoptedDownload.security.require(pin, at: final)
                }
                let nativeZIPDisplacement: Bool = archiveUpdate
                    && record.snapshot.operation == (record.snapshot.version == 18 ? "Update TAR" : "Update ZIP")
                    && record.steps.count == 2
                    && record.areas.contains { record.steps[0].destination == $0.url.appendingPathComponent("displaced") }
                    && record.steps[1].source == record.steps[0].destination.deletingLastPathComponent().appendingPathComponent("payload")
                    && record.steps[1].destination == record.steps[0].source
                    && record.steps[0].after.map { !record.steps[0].before.matches($0)
                        && record.steps[0].before.identity.sameObject(as: $0.identity) } == true
                let retainedNativeZIPTransition = restoringInterruptedOriginalZIP
                    && record.steps[0].after.map { !record.steps[0].before.matches($0)
                        && record.steps[0].before.identity.sameObject(as: $0.identity) } == true
                let candidateZIPPolicy: Bool
                if [13, 18].contains(record.snapshot.version) {
                    candidateZIPPolicy = self.nativeArchiveUpdateEnabled(version: record.snapshot.version)
                } else {
                    switch (record.snapshot.version, self.authoredZIPMetadataPolicy) {
                    case (5, .nativeStageQualification), (6, .exactSourceCloneQualification):
                        candidateZIPPolicy = true
                    default: candidateZIPPolicy = false
                    }
                }
                // V6 and v13 identify their producer policy. Neither may borrow
                // the v5 inverse or another candidate's authority.
                guard ![6, 13, 18].contains(record.snapshot.version) || candidateZIPPolicy else {
                    throw FileOperationFailure.recoveryUncertain
                }
                guard !nativeZIPDisplacement || (!recovering && candidateZIPPolicy) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                var outcomes: [FileOperationOutcome] = []
                var inverseCheckpoint: OperationDiagnosticCheckpoint?
                var inverseFinding: NativeTrashFamilyFinding?
                var activeReverseStep: Int?
                var activeReverseRenamed = false
                var inverseIntentAttempted = false
                do {
                    if record.snapshot.operation == "Move to Trash",
                       record.steps.contains(where: { $0.before.identity.isDirectory &&
                           (record.snapshot.version == 12 || record.snapshot.version == 9
                               && $0.nativeTrashRootAddition != nil) }) {
                        inverseCheckpoint = .nativeTrashInversePreflight
                    }
                    if recovering && !restoringInterruptedOriginalZIP {
                        try self.reconcile(record, cancellation: cancellation)
                    }
                    // Check every final occupant before the first reverse mutation. Earlier steps
                    // can share paths with later steps; only currently exposed occupants are checked.
                    var hidden = Set<String>()
                    var relocations: [(URL, URL)] = []
                    func currentLocation(_ original: URL) throws -> URL {
                        var url = original
                        var visited = Set<String>()
                        for _ in 0..<OperationLimits.maximumDepth {
                            guard visited.insert(url.path).inserted else { throw FileOperationFailure.recoveryUncertain }
                            guard let mapping = relocations.filter({ url.path == $0.0.path || url.path.hasPrefix($0.0.path + "/") })
                                .max(by: { $0.0.path.count < $1.0.path.count }) else { return url }
                            let suffix = String(url.path.dropFirst(mapping.0.path.count))
                            url = URL(fileURLWithPath: mapping.1.path + suffix)
                        }
                        throw FileOperationFailure.recoveryUncertain
                    }
                    for step in record.steps.reversed() where !step.undone {
                        if !hidden.contains(step.destination.path) {
                            guard let after = step.after else { throw FileOperationFailure.recoveryUncertain }
                            let location = try currentLocation(step.destination)
                            let parent = try DirectoryAnchor(location.deletingLastPathComponent(), resolve: false)
                            #if DEBUG
                            let synthetic = (record.snapshot.version == 9 && step.nativeTrashRootAddition != nil
                                || record.snapshot.version == 12 && step.before.identity.isDirectory)
                                ? self.hooks.nativeTrashSyntheticRootMetadata : nil
                            #else
                            let synthetic: NativeTrashSyntheticRootMetadata? = nil
                            #endif
                            let preflightFamilies = record.snapshot.version == 12 && step.before.identity.isDirectory
                                ? NativeTrashFamilyCollector() : nil
                            let observed = try verifiedTree(parent: parent.fd, name: location.lastPathComponent,
                                                            cancellation: cancellation,
                                                            rootURL: location,
                                                            requiresMaterialized: record.snapshot.version == 12
                                                                && step.before.identity.isDirectory,
                                                            nativeTrashFamilyCollector: preflightFamilies,
                                                            nativeTrashSyntheticRootMetadata: synthetic,
                                                            osManagedSecurityV1: [14, 15, 16, 17].contains(record.snapshot.version),
                                                            publicTreeRequiresEveryNode: record.snapshot.producedTreeV16?.requiresMarkOnEveryNode)
                            if record.snapshot.version == 14 || step.publicZIPExtractionMarkRequired == true
                                || step.publicTARExtractionMarkRequired == true {
                                let pin = try pinEntry(parent: parent.fd, name: location.lastPathComponent,
                                    matching: observed.identity)
                                defer { close(pin) }
                                try requireReceivedPublicQuarantine(parent: parent, name: location.lastPathComponent,
                                    descriptor: pin, identity: observed.identity)
                            }
                            let directoryIdentityMatches = preflightFamilies == nil
                                || preflightFamilies?.snapshot()?.directoryDescendantIdentityWitness
                                    == step.nativeTrashDirectoryDescendantIdentity
                            guard try record.matchesPersisted(after, observed, in: parent),
                                  directoryIdentityMatches else {
                                throw FileOperationFailure.sourceChanged
                            }
                        }
                        hidden.insert(step.source.path)
                        if step.before.identity.isDirectory { relocations.append((step.source, step.destination)) }
                    }
                    if inverseCheckpoint != nil { inverseCheckpoint = .nativeTrashInverseJournal }
                    inverseIntentAttempted = true
                    record.setState("undoing"); try journal.save(record)
                    let inverseCancellation = archiveUpdate ? cancellation.segment() : cancellation
                    for index in record.steps.indices.reversed() where !record.steps[index].undone {
                        try inverseCancellation.check()
                        activeReverseStep = index
                        activeReverseRenamed = false
                        let step = record.steps[index]
                        let additiveDirectoryStep = record.snapshot.version == 9
                            && record.snapshot.operation == "Move to Trash"
                            && step.before.identity.isDirectory
                            && step.nativeTrashRootAddition != nil
                        let nativeDirectoryInverse = record.snapshot.version == 12
                            && record.snapshot.operation == "Move to Trash"
                            && step.before.identity.isDirectory
                            && record.trashIntents.contains { $0.source == step.source && $0.before == step.before }
                        inverseCheckpoint = additiveDirectoryStep || nativeDirectoryInverse
                            ? .nativeTrashInversePreflight : nil
                        inverseFinding = nil
                        let source = try DirectoryAnchor(step.destination.deletingLastPathComponent(), resolve: false)
                        let destination = try DirectoryAnchor(step.source.deletingLastPathComponent(), resolve: false)
                        let beforeSecurity = NativeRenameSecurityProjection()
                        let ordinaryTrashInverse = [11, 12].contains(record.snapshot.version)
                            && record.snapshot.operation == "Move to Trash"
                            && step.before.identity.type == S_IFREG
                            && record.trashIntents.contains { $0.source == step.source && $0.before == step.before }
                        #if DEBUG
                        let synthetic = (record.snapshot.version == 9 && step.nativeTrashRootAddition != nil
                            || nativeDirectoryInverse)
                            ? self.hooks.nativeTrashSyntheticRootMetadata : nil
                        #else
                        let synthetic: NativeTrashSyntheticRootMetadata? = nil
                        #endif
                        let beforeFamilies = ordinaryTrashInverse || additiveDirectoryStep || nativeDirectoryInverse
                            ? NativeTrashFamilyCollector() : nil
                        let origin = NativeProcessSecurityOrigin.current
                        let currentAfter = try verifiedTree(parent: source.fd, name: step.destination.lastPathComponent,
                                                            cancellation: inverseCancellation,
                                                            rootURL: step.destination,
                                                            requiresMaterialized: nativeDirectoryInverse, nativeRename: beforeSecurity,
                                                            nativeTrashFamilyCollector: beforeFamilies,
                                                            nativeTrashSyntheticRootMetadata: synthetic,
                                                            osManagedSecurityV1: [14, 15, 16, 17].contains(record.snapshot.version),
                                                            publicTreeRequiresEveryNode: record.snapshot.producedTreeV16?.requiresMarkOnEveryNode)
                        guard try record.matchesPersisted(step.destinationParent, source.identity, in: source),
                              try record.matchesPersisted(step.sourceParent, destination.identity, in: destination),
                              let after = step.after,
                              try record.matchesPersisted(after, currentAfter, in: source),
                              !nativeDirectoryInverse || beforeFamilies?.snapshot()?.directoryDescendantIdentityWitness
                                  == step.nativeTrashDirectoryDescendantIdentity else {
                            throw FileOperationFailure.sourceChanged
                        }
                        // The proof binds the saved full Trash image. The fresh
                        // walk above separately binds its current object and digest;
                        // ctime alone is not a new metadata authority.
                        let qualifiedDirectoryInverse = additiveDirectoryStep && !recovering
                            && self.nativeTrashDirectoryAdmission == .additiveRootOnlyCandidate
                            && step.nativeTrashRootAddition?.validatesAdditiveRoot(
                                before: step.before, after: after) == true
                        let pinned = try pinEntry(parent: source.fd, name: step.destination.lastPathComponent,
                                                  matching: currentAfter.identity)
                        defer { close(pinned) }
                        if record.snapshot.version == 14 || step.publicZIPExtractionMarkRequired == true
                            || step.publicTARExtractionMarkRequired == true {
                            try requireReceivedPublicQuarantine(parent: source, name: step.destination.lastPathComponent,
                                descriptor: pinned, identity: currentAfter.identity)
                        }
                        let originalMetadata = archiveUpdate && index == 0
                            ? try ArchiveOriginalRootMetadata.observe(step.destination) : nil
                        try requireAbsent(step.source.lastPathComponent, in: destination.fd)
                        try source.validate(); try destination.validate()
                        reporter.begin(.publishing, source: step.destination, destination: step.source)
                        if additiveDirectoryStep || nativeDirectoryInverse { inverseCheckpoint = .nativeTrashInverseTransition }
                        if archiveUpdate { try inverseCancellation.beginMutation() }
                        self.hooks.beforeRename?()
                        try inverseCancellation.check()
                        try self.hooks.beforeExclusiveRename?(step.destination, step.source)
                        if [14, 15, 16, 17].contains(record.snapshot.version) {
                            guard currentAfter.matches(try verifiedTree(parent: source.fd,
                                name: step.destination.lastPathComponent, cancellation: inverseCancellation,
                                rootURL: step.destination, osManagedSecurityV1: true,
                                publicTreeRequiresEveryNode: record.snapshot.producedTreeV16?.requiresMarkOnEveryNode))
                            else { throw FileOperationFailure.sourceChanged }
                            if record.snapshot.version == 14 || step.publicZIPExtractionMarkRequired == true
                                || step.publicTARExtractionMarkRequired == true {
                                try requireReceivedPublicQuarantine(parent: source, name: step.destination.lastPathComponent,
                                    descriptor: pinned, identity: currentAfter.identity)
                            }
                        }
                        try exclusiveRename(from: source.fd, name: step.destination.lastPathComponent, to: destination.fd, name: step.source.lastPathComponent)
                        activeReverseRenamed = true
                        self.hooks.afterRename?()
                        if qualifiedDirectoryInverse || nativeDirectoryInverse {
                            // The inverse moves this same object out of Trash.
                            // No other object may appear under its old name.
                            try requireAbsent(step.destination.lastPathComponent, in: source.fd)
                        }
                        let known = [source.currentURL?.appendingPathComponent(step.destination.lastPathComponent),
                                     destination.currentURL?.appendingPathComponent(step.source.lastPathComponent),
                                     entryURL(for: pinned, matching: currentAfter.identity)].compactMap { $0 }
                        try record.appendNewLocations(known)
                        let afterSecurity = NativeRenameSecurityProjection()
                        let afterFamilies = ordinaryTrashInverse || additiveDirectoryStep || nativeDirectoryInverse
                            ? NativeTrashFamilyCollector() : nil
                        #if DEBUG
                        let restoredSynthetic = additiveDirectoryStep || nativeDirectoryInverse
                            ? self.hooks.nativeTrashInverseRestoredSyntheticRootMetadata ?? synthetic : synthetic
                        #else
                        let restoredSynthetic = synthetic
                        #endif
                        if additiveDirectoryStep || nativeDirectoryInverse { inverseCheckpoint = .nativeTrashInversePostWalk }
                        let restored = try verifiedTree(parent: destination.fd, name: step.source.lastPathComponent,
                            cancellation: inverseCancellation.draining(),
                            rootURL: step.source,
                            requiresMaterialized: nativeDirectoryInverse, nativeRename: afterSecurity,
                            nativeTrashFamilyCollector: afterFamilies,
                            nativeTrashSyntheticRootMetadata: restoredSynthetic,
                            osManagedSecurityV1: [14, 15, 16, 17].contains(record.snapshot.version),
                            publicTreeRequiresEveryNode: record.snapshot.producedTreeV16?.requiresMarkOnEveryNode)
                        if record.snapshot.version == 14 || step.publicZIPExtractionMarkRequired == true
                            || step.publicTARExtractionMarkRequired == true {
                            try requireReceivedPublicQuarantine(parent: destination, name: step.source.lastPathComponent,
                                descriptor: pinned, identity: restored.identity)
                        }
                        if additiveDirectoryStep || nativeDirectoryInverse { try source.validate(); try destination.validate() }
                        let boundedTrashUndo: Bool
                        if ordinaryTrashInverse,
                           let prior = beforeFamilies?.snapshot(), let later = afterFamilies?.snapshot() {
                            boundedTrashUndo = prior.permitsOrdinaryTrashUndoRootQuarantineRewrite(
                                comparedWith: later, before: currentAfter, restored: restored)
                        } else {
                            boundedTrashUndo = false
                        }
                        if additiveDirectoryStep || nativeDirectoryInverse, !currentAfter.matches(restored) {
                            if let prior = beforeFamilies?.snapshot(), let later = afterFamilies?.snapshot() {
                                inverseFinding = prior.finding(comparedWith: later,
                                    before: currentAfter, returned: restored)
                            } else { inverseFinding = .unavailable }
                        }
                        let qualifiedNamespaceMove: Bool
                        if qualifiedDirectoryInverse {
                            let pinnedIdentity = try EntrySnapshot(fd: pinned)
                            qualifiedNamespaceMove = currentAfter.identity.sameObject(as: restored.identity)
                                && pinnedIdentity.sameObject(as: restored.identity)
                        } else { qualifiedNamespaceMove = false }
                        let verifiedDirectoryUndo: Bool
                        if nativeDirectoryInverse {
                            let pinnedIdentity = try EntrySnapshot(fd: pinned)
                            let exactOrBounded: Bool
                            if let prior = beforeFamilies?.snapshot(), let later = afterFamilies?.snapshot() {
                                exactOrBounded = prior.matchesPreMutationRewalk(later,
                                    before: currentAfter, current: restored)
                                    || prior.permitsDirectoryRootSecurityRewrite(
                                        comparedWith: later, before: currentAfter, renamed: restored)
                            } else { exactOrBounded = false }
                            verifiedDirectoryUndo = currentAfter.identity.sameObject(as: restored.identity)
                                && pinnedIdentity.sameObject(as: restored.identity) && exactOrBounded
                        } else { verifiedDirectoryUndo = false }
                        // The v9 additive-root witness and explicit qualification
                        // admit an exclusive namespace move of the current directory
                        // object. They make no promise to restore historical opaque
                        // metadata. Other inverses retain their existing rules.
                        guard (nativeDirectoryInverse ? verifiedDirectoryUndo :
                            currentAfter.matches(restored) || (step.nativeTrashRootAddition == nil
                            && beforeSecurity.permitsNativeTransition(to: afterSecurity,
                                before: currentAfter, after: restored, origin: origin))
                            || boundedTrashUndo
                            || qualifiedNamespaceMove)
                        else { throw FileOperationFailure.recoveryUncertain }
                        if let adoptedDownload {
                            try adoptedDownload.security.require(pinned, at: step.source)
                            guard restored.identity.sameObject(as: adoptedDownload.sourceIdentity) else {
                                throw FileOperationFailure.recoveryUncertain
                            }
                        }
                        if archiveUpdate && !step.before.matches(restored) {
                            // A qualified ZIP Update may have gained a native
                            // mark during the first forward rename. Its exact
                            // recorded after-image is the cold Undo authority;
                            // the reverse rename must retain that entire image.
                            guard (nativeZIPDisplacement || retainedNativeZIPTransition), index == 0,
                                  (!recovering || restoringInterruptedOriginalZIP), candidateZIPPolicy,
                                  currentAfter.matches(restored),
                                  step.before.identity.sameObject(as: restored.identity) else {
                                throw FileOperationFailure.recoveryUncertain
                            }
                        }
                        try originalMetadata?.requireMatch(step.source)
                        reporter.begin(.syncing, source: step.destination, destination: step.source)
                        if additiveDirectoryStep || nativeDirectoryInverse { inverseCheckpoint = .nativeTrashInverseSync }
                        try source.validate(); try destination.validate(); try self.hooks.beforeSync?(step.source); try syncDirectory(source); try syncDirectory(destination)
                        let settled: VerifiedTree
                        if nativeDirectoryInverse {
                            let syncedFamilies = NativeTrashFamilyCollector()
                            let synced = try verifiedTree(parent: destination.fd, name: step.source.lastPathComponent,
                                cancellation: inverseCancellation.draining(), requiresMaterialized: true,
                                nativeTrashFamilyCollector: syncedFamilies,
                                nativeTrashSyntheticRootMetadata: restoredSynthetic)
                            try source.validate(); try destination.validate()
                            try requireAbsent(step.destination.lastPathComponent, in: source.fd)
                            guard let renamedFamilies = afterFamilies?.snapshot(),
                                  let finalFamilies = syncedFamilies.snapshot(),
                                  renamedFamilies.matchesPreMutationRewalk(finalFamilies,
                                      before: restored, current: synced) else {
                                throw FileOperationFailure.sourceChanged
                            }
                            settled = synced
                        } else { settled = restored }
                        // Persist the complete latest materialized image together with
                        // the inverse bit. Recovery never infers a missing transition.
                        try record.bindPersistentVolume(in: destination)
                        try record.setStepOutcome(settled, at: index)
                        try record.markStepUndone(at: index)
                        if additiveDirectoryStep || nativeDirectoryInverse { inverseCheckpoint = .nativeTrashInverseJournal }
                        try journal.save(record)
                        if (qualifiedDirectoryInverse || nativeDirectoryInverse), let inverseFinding {
                            reporter.observeNativeTrashInverseChange(inverseFinding, recordID: record.id)
                        }
                        outcomes.append(FileOperationOutcome(source: step.destination, destination: step.source, status: .succeeded, recoveryURLs: []))
                        activeReverseStep = nil
                    }
                    if inverseCheckpoint != nil { inverseCheckpoint = .nativeTrashInverseJournal }
                    record.setState("undone"); try journal.save(record)
                    if outcomes.isEmpty { outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: .succeeded, recoveryURLs: [], role: .job)) }
                } catch {
                    if let inverseCheckpoint {
                        reporter.observeCaughtFailure(inverseCheckpoint, error: error,
                            recordID: record.id, nativeTrashFinding: inverseFinding)
                    }
                    let status = operationStatus(error)
                    // No inverse intent or filesystem change has begun. A cold
                    // public Download or one-file ZIP folder denial must not
                    // strand the committed output before parent reselection.
                    let preflightAccessDenied = [14, 15, 16, 17].contains(record.snapshot.version) && !recovering
                        && !inverseIntentAttempted && status == .failed(.accessDenied)
                    if !preflightAccessDenied {
                        record.setState("needsReview"); try? journal.save(record)
                    }
                    outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: status, recoveryURLs: record.locations, role: .job))
                    if let activeReverseStep {
                        let step = record.steps[activeReverseStep]
                        outcomes.append(FileOperationOutcome(source: step.destination,
                            destination: step.source,
                            status: activeReverseRenamed ? .failed(.recoveryUncertain) : status,
                            recoveryURLs: activeReverseRenamed ? record.locations : []))
                    }
                    outcomes += record.steps.enumerated().filter {
                        $0.offset != activeReverseStep && !$0.element.undone
                    }.map {
                        FileOperationOutcome(source: $0.element.destination, destination: $0.element.source,
                            status: .notStarted, recoveryURLs: [])
                    }
                }
                if archiveUpdate {
                    // The two durable renames are one user-visible ZIP update.
                    // Keep their exact locations in the journal, not two public
                    // Undo units that invite an independent second action.
                    let status: FileOperationStatus = record.snapshot.state == "undone" ? .succeeded
                        : outcomes.first(where: { $0.role == .job })?.status ?? .failed(.recoveryUncertain)
                    let original = record.steps.first?.source
                    outcomes = [.init(source: nil, destination: original, status: status,
                                      recoveryURLs: status == .succeeded ? [] : record.locations)]
                }
                return RecoverableOperationResult(result: FileOperationResult(items: outcomes, cancellationRequested: cancellation.isCancelled), recordID: record.id)
            }
        } catch { return failure(error) }
    }

    /// Reconciles only an unambiguous last rename intent, or an interrupted reverse rename.
    /// No filesystem changes occur here. Unknown occupants and unavailable parents fail closed.
    private func reconcile(_ record: JournalEditSession, cancellation: OperationCancellation) throws {
        guard ![8, 10].contains(record.snapshot.version) else { throw FileOperationFailure.unsupported }
        for index in record.steps.indices.reversed() {
            let step = record.steps[index]
            if step.undone { continue }
            let from = try DirectoryAnchor(step.source.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(step.destination.deletingLastPathComponent(), resolve: false)
            let parentsMatch: Bool
            if step.after != nil {
                let sourceMatch = try record.matchesPersisted(step.sourceParent, from.identity, in: from)
                let destinationMatch = try record.matchesPersisted(step.destinationParent, to.identity, in: to)
                parentsMatch = sourceMatch && destinationMatch
            } else {
                // An unacknowledged rename has no durable after-image. Device
                // drift must not make its unknown outcome newly recoverable.
                parentsMatch = from.identity.sameObject(as: step.sourceParent) &&
                    to.identity.sameObject(as: step.destinationParent)
            }
            guard parentsMatch else {
                throw FileOperationFailure.recoveryUncertain
            }
            func observed(_ url: URL) throws -> VerifiedTree? {
                do {
                    let image = try verifiedTree(url, cancellation: cancellation,
                        osManagedSecurityV1: [14, 15, 16, 17].contains(record.snapshot.version),
                        publicTreeRequiresEveryNode: record.snapshot.producedTreeV16?.requiresMarkOnEveryNode)
                    if record.snapshot.version == 14 || step.publicZIPExtractionMarkRequired == true
                        || step.publicTARExtractionMarkRequired == true {
                        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
                        let pin = try pinEntry(parent: parent.fd, name: url.lastPathComponent,
                            matching: image.identity)
                        defer { close(pin) }
                        try requireReceivedPublicQuarantine(parent: parent, name: url.lastPathComponent,
                            descriptor: pin, identity: image.identity)
                    }
                    return image
                }
                catch FileOperationFailure.notFound { return nil }
            }
            let source = try observed(step.source)
            let destination = try observed(step.destination)
            if step.after == nil {
                if let destination, source == nil, step.before.matches(destination) {
                    try record.setStepOutcome(destination, at: index)
                } else if let source, destination == nil, step.before.matches(source) {
                    // No completed after-image exists: the durable intent never renamed.
                    try record.markStepUndone(at: index)
                } else { throw FileOperationFailure.recoveryUncertain }
            } else if record.state == "undoing" || record.state == "needsReview" {
                if let source, destination == nil, let after = step.after,
                   try record.matchesPersisted(after, source, in: from) {
                    try record.markStepUndone(at: index)
                }
            }
            // Earlier steps can be concealed by this later committed step. Their checks run
            // after reversal exposes them; do not interpret their present paths as intentions.
            if !record.steps[index].undone { break }
        }
    }

    internal func worker<T: Sendable>(progress: OperationProgressReporter? = nil,
                                      activation: UUID? = nil, ignoringCancellation: Bool = false,
                                      _ action: @escaping @Sendable (OperationCancellation) throws -> T) async throws -> T {
        let admitted = admissionLock.withLock { () -> Bool in
            guard activation == previewReservation else { return false }
            if activation != nil, submissions != 0 { return false }
            guard submissions < OperationLimits.maximumSubmissions else { return false }
            submissions += 1; return true
        }
        guard admitted else { throw FileOperationFailure.unavailable }
        let cancellation = OperationCancellation(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    let result: Result<T, Error>
                    do {
                        try cancellation.check()
                        let activity = try self.activity?()
                        defer { withExtendedLifetime(activity) {} }
                        result = .success(try FileOperationDiagnostics.withScope(progress) {
                            try autoreleasepool(invoking: {
                                let value = try action(cancellation)
                                if let outcome = value as? RecoverableOperationResult, let recordID = outcome.recordID {
                                    progress?.observeHistoryRecord(recordID)
                                }
                                return value
                            })
                        })
                    }
                    catch { result = .failure(error) }
                    // Admission ends after synchronous work and temporary objects
                    // drain, before an awaiting activation can inspect quiescence.
                    self.admissionLock.withLock { self.submissions -= 1 }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { if !ignoringCancellation { cancellation.cancel() } }
    }

    private func prepare(sources: [URL], destination: URL, move: Bool, observing selection: FileOperationSelection?, metadataPolicy: TransferMetadataPolicy,
                         copyExecution: CopyExecutionRequest = .standard, cancellation: OperationCancellation) throws -> TransferPlan {
        guard !sources.isEmpty, sources.count <= OperationJournal.maximumInputs else { throw FileOperationFailure.invalidRequest }
        #if DEBUG
        try validateGeneratedResponsivenessCapability(sources: sources, destination: destination,
            move: move, metadataPolicy: metadataPolicy, cancellation: cancellation)
        #endif
        try validateCopyExecutionSession(locations: sources + [destination], directories: [destination])
        cancellation.progress?.begin(.planning, destination: destination, count: sources.count, items: sources.count)
        let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
        let target = try DirectoryAnchor(destination)
        try protection.requireDirectory(target)
        var conflicts: [TransferConflict] = []
        var count = 0
        func entry(_ source: URL, _ destination: URL, _ depth: Int) throws -> TransferEntry {
            try cancellation.check(); count += 1
            guard depth < OperationLimits.maximumDepth, count <= OperationLimits.maximumNodes else { throw FileOperationFailure.unsupported }
            try validateName(source.lastPathComponent)
            let parent = try DirectoryAnchor(source.deletingLastPathComponent())
            let source = parent.url.appendingPathComponent(source.lastPathComponent)
            let sourceSnapshot = try EntrySnapshot(parent: parent.fd, name: source.lastPathComponent)
            try protection.requireEntry(parent: parent, name: source.lastPathComponent, snapshot: sourceSnapshot)
            guard [S_IFREG, S_IFDIR, S_IFLNK].contains(sourceSnapshot.type), sourceSnapshot.device == parent.identity.device else { throw FileOperationFailure.unsupported }
            let destinationParent = try DirectoryAnchor(destination.deletingLastPathComponent(), resolve: false)
            guard (!move || source != destination), !destination.path.hasPrefix(source.path + "/") else { throw FileOperationFailure.invalidRequest }
            let destinationSnapshot: EntrySnapshot?
            do { destinationSnapshot = try EntrySnapshot(parent: destinationParent.fd, name: destination.lastPathComponent) }
            catch FileOperationFailure.notFound { destinationSnapshot = nil }
            let id = UUID()
            var children: [TransferEntry]?
            let protectedDestination = try protection.protects(parent: destinationParent,
                name: destination.lastPathComponent, snapshot: destinationSnapshot)
            if let existing = destinationSnapshot {
                let kind = try TransferConflictKind.observe(source: source, destination: destination,
                    sourceIdentity: sourceSnapshot, destinationIdentity: existing)
                let canMerge = !protectedDestination && source != destination && kind == .folders
                var conflict = TransferConflict(id: id, source: source, destination: destination, canMerge: canMerge)
                conflict.kind = kind
                conflict.destinationHistoryProtected = protectedDestination
                conflicts.append(conflict)
                if canMerge {
                    let anchor = try DirectoryAnchor(source, resolve: false)
                    let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw posixFailure() }
                    defer { close(fd) }
                    children = try childNames(in: fd, cancellation: cancellation, limit: OperationLimits.maximumNodes - count).map {
                        try entry(source.appendingPathComponent($0), destination.appendingPathComponent($0), depth + 1)
                    }
                }
            } else if protectedDestination { throw FileOperationFailure.operationHistoryProtected }
            return TransferEntry(id: id, source: source, destination: destination, sourceIdentity: sourceSnapshot,
                                 sourceParent: parent.identity, destinationIdentity: destinationSnapshot,
                                 destinationParent: destinationParent.identity, children: children)
        }
        var names = Set<String>()
        let entries = try sources.map { source in
            let name = source.lastPathComponent
            let folded = fpathconf(target.fd, _PC_CASE_SENSITIVE) == 1 ? name : name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(folded).inserted else { throw FileOperationFailure.invalidRequest }
            let value = try entry(source, target.url.appendingPathComponent(name), 0)
            cancellation.progress?.advance(items: 1)
            return value
        }
        for a in entries { for b in entries where a.id != b.id {
            guard !b.source.path.hasPrefix(a.source.path + "/"), !a.sourceIdentity.sameObject(as: b.sourceIdentity) else { throw FileOperationFailure.invalidRequest }
        } }
        if let selection {
            for (url, identity) in zip(selection.urls, selection.identities) {
                if let entry = entries.first(where: { $0.source.path == url.path }) {
                    guard identity == entry.sourceIdentity else { throw FileOperationFailure.sourceChanged }
                } else if url.path == target.url.path {
                    guard identity.sameObject(as: target.identity) else { throw FileOperationFailure.destinationChanged }
                } else { throw FileOperationFailure.invalidRequest }
            }
        }
        try validateCopyExecutionSession(locations: entries.flatMap { [$0.source, $0.destination] })
        let reporter = cancellation.progress ?? OperationProgressReporter(callback: nil)
        var plan = TransferPlan(jobID: reporter.jobID, progressReporter: reporter, conflicts: conflicts, sources: entries.map(\.source), destinationDirectory: target.url, isMove: move, metadataPolicy: metadataPolicy, entries: entries)
        if move { plan.moveReservation = MoveRecordReservation(owner: continuationSession) }
        let production = productionCopySession
        let attemptsGrouped: Bool
        switch copyExecutionAuthorization {
        case .closed: attemptsGrouped = production != nil && copyExecution == .previewIfAvailable
        case .legacyQualification: attemptsGrouped = true
        case .generatedFixture: attemptsGrouped = copyExecution == .previewIfAvailable
        }
        plan.executionDecision = .standard(copyExecution == .standard ? .previewOff : .qualificationPending)
        var qualification = hooks.groupedCopy.qualification
        if attemptsGrouped, let production {
            if move { plan.executionDecision = .standard(.move); return plan }
            if !conflicts.isEmpty { plan.executionDecision = .standard(.destinationConflict); return plan }
            if entries.contains(where: { $0.sourceIdentity.type != S_IFREG || $0.children != nil }) {
                plan.executionDecision = .standard(.unsupportedInput); return plan
            }
            var total: Int64 = 0
            let inBounds = (16...1024).contains(entries.count) && entries.allSatisfy {
                guard $0.sourceIdentity.size >= 0, $0.sourceIdentity.size <= 67_108_864 else { return false }
                let (sum, overflow) = total.addingReportingOverflow($0.sourceIdentity.size)
                total = sum; return !overflow && sum <= 134_217_728
            }
            if !inBounds { plan.executionDecision = .standard(.outsidePreviewLimits); return plan }
            do { _ = try production.checkedHistory(); qualification = GroupedCopyQualification(production: production) }
            catch { plan.executionDecision = .standard(.historyUnavailable); return plan }
        }
        if attemptsGrouped, let qualification {
            plan.groupedCopy = try GroupedCopyAdmission.prepare(entries: entries, move: move, conflicts: conflicts,
                policy: metadataPolicy, qualification: qualification, journal: directory, cancellation: cancellation)
            if plan.groupedCopy != nil { plan.executionDecision = .groupedCopy(maximumMembersPerGroup: qualification.groupSize) }
            else if move { plan.executionDecision = .standard(.move) }
            else if !conflicts.isEmpty { plan.executionDecision = .standard(.destinationConflict) }
            else if entries.contains(where: { $0.sourceIdentity.type != S_IFREG || $0.children != nil }) { plan.executionDecision = .standard(.unsupportedInput) }
            else { plan.executionDecision = .standard(.unqualifiedLocation) }
        }
        return plan
    }

    private func execute(_ plan: TransferPlan, resolutions: [UUID: TransferConflictResolution], cancellation: OperationCancellation) -> RecoverableOperationResult {
        if plan.isMove {
            do {
                guard let reservation = plan.moveReservation else { throw FileOperationFailure.invalidRequest }
                try reservation.claim(owner: continuationSession)
            } catch { return failure(error, sources: plan.sources) }
        }
        if let admission = plan.groupedCopy { return executeGroupedCopy(plan, admission: admission, resolutions: resolutions, cancellation: cancellation) }
        var current: JournalRecord?
        var journal: OperationJournal?
        var outcomes: [FileOperationOutcome] = []
        var referenceReceipts: [MoveReferenceReceipt] = []
        var referenceReceiptBytes = 0
        let referenceMembers = Dictionary(grouping: plan.referenceMembers, by: \.unitID)
        var entries: [TransferEntry] = []
        var mergedContainers: [TransferEntry] = []
        var skippedEntries: [TransferEntry] = []
        var continuationUnits: [UUID: ContinuationUnit] = [:]
        var roots: [UUID: (id: UUID, source: URL)] = [:]
        var resolved = false
        var activeContainer: TransferEntry?
        let inheritedContainers = plan.continuation?.containers ?? []
        let inheritedUnits = Dictionary(uniqueKeysWithValues: (plan.continuation?.units ?? []).map { ($0.entry.source.path, $0) })
        func inheritedUnit(for source: URL) -> ContinuationUnit? {
            guard !inheritedUnits.isEmpty else { return nil }
            var path = source
            for _ in 0...OperationLimits.maximumDepth {
                if let unit = inheritedUnits[path.path] { return unit }
                let parent = path.deletingLastPathComponent()
                if parent == path { break }
                path = parent
            }
            return nil
        }
        if let inherited = plan.continuation {
            roots = inherited.roots.mapValues { (id: $0.id, source: $0.source) }
        }
        func outcome(_ entry: TransferEntry, _ status: FileOperationStatus,
                     role: FileOperationOutcomeRole = .transfer, recovery: [URL] = []) -> FileOperationOutcome {
            let root = roots[entry.id] ?? (id: entry.id, source: entry.source)
            return FileOperationOutcome(source: entry.source, destination: entry.destination, status: status,
                recoveryURLs: recovery, role: role, itemID: entry.id, rootID: root.id, rootSource: root.source)
        }
        func appendRemaining() {
            let reported = Set(outcomes.compactMap(\.itemID))
            outcomes += entries.filter { !reported.contains($0.id) }.map { outcome($0, .notStarted) }
            outcomes += (mergedContainers + inheritedContainers).filter { !reported.contains($0.id) }.map {
                outcome($0, .notStarted, role: .mergeContainer)
            }
        }
        func completed(_ record: JournalRecord?) -> RecoverableOperationResult {
            let eligible = Set(outcomes.filter { $0.role == .transfer && ($0.status == .skipped || $0.status == .notStarted) }.compactMap(\.itemID))
            let units = (entries + skippedEntries).filter { eligible.contains($0.id) }.compactMap { continuationUnits[$0.id] }
            var dependencies = plan.continuation?.records ?? []
            if let record { dependencies.append(ContinuationRecord(id: record.id, revision: record.revision)) }
            let pendingContainers = Set(outcomes.filter { $0.role == .mergeContainer && $0.status != .succeeded }.compactMap(\.itemID))
            let retained = (mergedContainers + inheritedContainers).filter { pendingContainers.contains($0.id) }
            let token = units.isEmpty || dependencies.count > OperationJournal.maximumInputs ? nil : TransferContinuation(id: UUID(), previousJobID: plan.jobID,
                previousRecordID: record?.id, remainingSources: units.map { $0.entry.source },
                destinationDirectory: plan.destinationDirectory, isMove: plan.isMove, metadataPolicy: plan.metadataPolicy,
                session: continuationSession, units: units, records: dependencies, containers: retained,
                roots: roots.mapValues { ContinuationRoot(id: $0.id, source: $0.source) }, use: ContinuationUse(),
                groupedRecords: plan.continuation?.groupedRecords ?? [])
            return RecoverableOperationResult(result: FileOperationResult(items: outcomes,
                cancellationRequested: cancellation.isCancelled), recordID: record?.id, continuation: token,
                referenceReceipts: referenceReceipts)
        }
        do {
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            for entry in plan.entries { try protection.requireEntry(entry.source) }
            let known = Set(plan.conflicts.map(\.id))
            guard resolutions.keys.allSatisfy(known.contains) else { throw FileOperationFailure.invalidRequest }
            let destinationAnchor = try DirectoryAnchor(plan.destinationDirectory, resolve: false)
            let caseSensitive = fpathconf(destinationAnchor.fd, _PC_CASE_SENSITIVE) == 1
            var reservedDestinations = Set<String>()
            var keptBoth = Set<UUID>()
            func reserve(_ entry: TransferEntry) {
                reservedDestinations.insert(DuplicateDestination.key(entry.destination, caseSensitive: caseSensitive))
                entry.children?.forEach(reserve)
            }
            plan.entries.forEach(reserve)
            var resolvedOutcomes: [FileOperationOutcome] = []
            func flatten(_ entry: TransferEntry, root: TransferEntry) throws -> [TransferEntry] {
                roots[entry.id] = plan.continuation?.roots[root.id].map { (id: $0.id, source: $0.source) } ?? (id: root.id, source: root.source)
                guard entry.destinationIdentity != nil else { try protection.requireEntry(entry.destination); return [entry] }
                guard let resolution = resolutions[entry.id] else { throw FileOperationFailure.conflict }
                switch resolution {
                case .skip:
                    skippedEntries.append(entry)
                    resolvedOutcomes.append(outcome(entry, .skipped))
                    return []
                case .replace:
                    try protection.requireEntry(entry.destination)
                    guard entry.source != entry.destination else { throw FileOperationFailure.invalidRequest }
                    return [entry]
                case .keepBoth:
                    try validate(entry)
                    let redirected = try DuplicateDestination.choose(entry, reserved: &reservedDestinations,
                        caseSensitive: caseSensitive, cancellation: cancellation)
                    try protection.requireEntry(redirected.destination)
                    keptBoth.insert(entry.id)
                    return [redirected]
                case .merge:
                    try protection.requireEntry(entry.destination)
                    guard let children = entry.children else { throw FileOperationFailure.unsupported }
                    try validate(entry)
                    let flattened = try children.flatMap { try flatten($0, root: root) }
                    if plan.isMove { mergedContainers.append(entry) }
                    else if children.isEmpty {
                        resolvedOutcomes.append(outcome(entry, .succeeded))
                    }
                    return flattened
                }
            }
            entries = try plan.entries.flatMap { try flatten($0, root: $0) }
            outcomes = resolvedOutcomes
            resolved = true
            if !entries.isEmpty || !mergedContainers.isEmpty || !(plan.continuation?.records.isEmpty ?? true) {
                journal = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation)
                try journal?.validateWritableCatalog()
                if let journal { try protection.historyOpened(journal.anchor) }
            }
            if let token = plan.continuation { try validateContinuation(token, journal: journal, cancellation: cancellation) }
            cancellation.progress?.begin(.planning, count: entries.count)
            let budget = TraversalBudget()
            var originals: [UUID: VerifiedTree] = [:]
            var sizes: [UUID: (Int64, Int)] = [:]
            var steps = mergedContainers.count
            var areas = mergedContainers.count
            let transferIDs = Set(entries.map(\.id))
            for entry in entries + skippedEntries {
                try cancellation.check(); try validate(entry)
                let oldBytes = budget.bytes, oldNodes = budget.nodes
                let sourceGuard = try ContinuationGuard.observe(entry.source, cancellation: cancellation, budget: budget)
                let tree = sourceGuard.tree
                guard tree.identity == entry.sourceIdentity else { throw FileOperationFailure.sourceChanged }
                originals[entry.id] = tree; sizes[entry.id] = (budget.bytes - oldBytes, budget.nodes - oldNodes)
                let destinationTree = try entry.destinationIdentity.map { _ in
                    try ContinuationGuard.observe(entry.destination, cancellation: cancellation, budget: budget)
                }
                if let destinationTree, destinationTree.tree.identity != entry.destinationIdentity {
                    throw FileOperationFailure.destinationChanged
                }
                if let inherited = inheritedUnit(for: entry.source) {
                    let suffix = String(entry.source.path.dropFirst(inherited.entry.source.path.count))
                    let relative = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
                    let source = try inherited.source.projecting(relative, onto: sourceGuard, failure: .sourceChanged)
                    let destination: ContinuationGuard?
                    if keptBoth.contains(entry.id) {
                        // validateContinuation checks the original conflict on
                        // both sides of admission. This unit uses the separately
                        // observed absent name for this attempt and later Stop.
                        guard destinationTree == nil else { throw FileOperationFailure.destinationChanged }
                        destination = nil
                    } else if let observed = destinationTree {
                        guard let original = inherited.destination else { throw FileOperationFailure.destinationChanged }
                        destination = try original.projecting(relative, onto: observed, failure: .destinationChanged)
                    } else {
                        guard inherited.destination?.identities[relative] == nil else { throw FileOperationFailure.destinationChanged }
                        destination = nil
                    }
                    continuationUnits[entry.id] = ContinuationUnit(entry: entry, source: source, destination: destination)
                } else {
                    guard plan.continuation == nil else { throw FileOperationFailure.invalidRequest }
                    continuationUnits[entry.id] = ContinuationUnit(entry: entry, source: sourceGuard, destination: destinationTree)
                }
                guard transferIDs.contains(entry.id) else { continue }
                let cross = plan.isMove && entry.sourceIdentity.device != entry.destinationParent.device
                steps += 1 + (entry.destinationIdentity == nil ? 0 : 1) + (cross ? 1 : 0)
                let needsDestinationArea = !plan.isMove || cross || entry.destinationIdentity != nil
                areas += (needsDestinationArea ? 1 : 0) + (cross ? 1 : 0)
            }
            guard budget.nodes + 2 * areas + mergedContainers.count <= OperationLimits.maximumNodes else { throw FileOperationFailure.unsupported }
            let pathBytes = (entries + mergedContainers).map { $0.source.path.utf8.count + $0.destination.path.utf8.count }.reduce(0, +)
            try journal?.reserveCapacity(steps: steps, areas: areas, locations: areas + 2 * steps, trashIntents: 0,
                estimatedBytes: 16_384 + steps * 4096 + areas * 1024 + pathBytes * 16)
            hooks.afterAdmission?()
            try cancellation.check()
            for entry in entries + mergedContainers {
                try protection.requireEntry(entry.source); try protection.requireEntry(entry.destination)
            }
            if let token = plan.continuation { try validateContinuation(token, journal: journal, cancellation: cancellation) }
            try plan.continuation?.use.claim()
            guard !entries.isEmpty || !mergedContainers.isEmpty else {
                appendRemaining()
                return completed(nil)
            }
            guard let store = journal else { throw FileOperationFailure.invalidRequest }
            let record = try store.beginEdit(operation: plan.isMove ? "Move" : "Copy", reservedID: plan.moveReservation?.recordID)
            try store.save(record); current = record.snapshot
            for (entryIndex, entry) in entries.enumerated() {
                if cancellation.isCancelled {
                    appendRemaining()
                    record.setState("committed"); try store.save(record); current = record.snapshot
                    return completed(record.snapshot)
                }
                do {
                    try cancellation.check(); try validate(entry)
                    guard let original = originals[entry.id], let size = sizes[entry.id],
                          let unit = continuationUnits[entry.id] else { throw FileOperationFailure.invalidRequest }
                    cancellation.progress?.begin(.verifying, source: entry.source, destination: entry.destination,
                        index: entryIndex + 1, count: entries.count, bytes: size.0, items: size.1)
                    guard unit.source.matches(try ContinuationGuard.observe(entry.source, cancellation: cancellation, budget: TraversalBudget())) else {
                        throw FileOperationFailure.sourceChanged
                    }
                    let destinationParent = try DirectoryAnchor(entry.destination.deletingLastPathComponent(), resolve: false)
                    let sameVolumeMove = plan.isMove && original.identity.device == destinationParent.identity.device
                    // A plain same-volume rename needs no staging or retained original.
                    let area = try (!sameVolumeMove || entry.destinationIdentity != nil)
                        ? recoveryArea(in: destinationParent, record: record, journal: store) : nil
                    var payload: URL = entry.source
                    var payloadTree = original
                    var memberReceipts: [MoveReferenceReceipt] = []
                    if !sameVolumeMove {
                        guard let area else { throw FileOperationFailure.invalidRequest }
                        payload = area.url.appendingPathComponent("payload")
                        let sourceParent = try DirectoryAnchor(entry.source.deletingLastPathComponent(), resolve: false)
                        cancellation.progress?.begin(.copying, source: entry.source, destination: entry.destination,
                            index: entryIndex + 1, count: entries.count, bytes: size.0, items: size.1)
                        let receipts = StagingCopyReceipts()
                        let securityReceipts = NativeCopyReceipts()
                        try copyVerifiedNode(sourceParent: sourceParent.fd, sourceName: entry.source.lastPathComponent, destinationParent: area.fd,
                                     destinationName: "payload", originalDevice: original.identity.device, cancellation: cancellation,
                                     faults: hooks.copyFaults, completed: { try receipts.completed($0, $1) },
                                     securityReceipt: { try securityReceipts.append($0) })
                        cancellation.progress?.begin(.verifying, source: entry.source, destination: entry.destination,
                            index: entryIndex + 1, count: entries.count, bytes: size.0 * 2, items: size.1 * 2)
                        // Revalidate the source independently before judging copy equivalence.
                        let sourceComparison = CopyComparison(), destinationComparison = CopyComparison()
                        guard original.matches(try verifiedTree(entry.source, cancellation: cancellation, copyComparison: sourceComparison)) else { throw FileOperationFailure.sourceChanged }
                        let copy = try verifiedTree(parent: area.fd, name: "payload", cancellation: cancellation, copyComparison: destinationComparison)
                        payloadTree = copy
                        try securityReceipts.validate(source: sourceComparison, destination: destinationComparison, policy: plan.metadataPolicy)
                        if plan.isMove {
                            memberReceipts = Self.memberReceipts(referenceMembers[entry.id] ?? [], entry: entry,
                                source: sourceComparison, destination: destinationComparison)
                        }
                        cancellation.progress?.begin(.syncing, source: entry.source, destination: entry.destination, items: size.1)
                        try hooks.beforeSync?(payload)
                        try syncTree(payload, cancellation: cancellation)
                        try syncDirectory(area)
                        try hooks.beforeStagingProof?(record.id)
                        let persistentVolume = try PersistentVolumeBinding.qualified(in: area)
                        try record.bindPersistentVolume(persistentVolume)
                        let proof = try receipts.proof(parent: area.fd, payload: copy,
                            stepCount: record.steps.count,
                            persistentVolume: persistentVolume,
                            cancellation: cancellation)
                        guard copy.matches(try verifiedTree(parent: area.fd, name: "payload", cancellation: cancellation)),
                              let areaIndex = record.areaIndex(for: area.url) else {
                            throw FileOperationFailure.sourceChanged
                        }
                        try record.setStagingProof(proof, at: areaIndex)
                        record.setFailureStage("staging-proof")
                        try store.save(record)
                        record.setFailureStage(nil)
                        try hooks.afterStagingProof?()
                    }
                    hooks.beforeCommit?(); try cancellation.check(); try validate(entry)
                    if sameVolumeMove { memberReceipts = Self.memberReceipts(referenceMembers[entry.id] ?? [], entry: entry) }
                    // Recheck the original unit immediately before publication,
                    // after earlier units and this unit's staging have finished.
                    guard unit.source.matches(try ContinuationGuard.observe(entry.source, cancellation: cancellation, budget: TraversalBudget())) else {
                        throw FileOperationFailure.sourceChanged
                    }
                    if let destination = unit.destination,
                       !destination.matches(try ContinuationGuard.observe(entry.destination, cancellation: cancellation, budget: TraversalBudget())) {
                        throw FileOperationFailure.destinationChanged
                    }
                    // Once the first publication rename starts, finish this item as one safe
                    // segment. Stop cannot strand Replace between displacement and publish.
                    let segment = cancellation.segment()
                    cancellation.progress?.begin(.publishing, source: entry.source, destination: entry.destination,
                        index: entryIndex + 1, count: entries.count)
                    if entry.destinationIdentity != nil {
                        guard let area else { throw FileOperationFailure.invalidRequest }
                        try renameStep(entry.destination, area.url.appendingPathComponent("displaced"), expectedIdentity: entry.destinationIdentity,
                            expectedGuard: unit.destination, guardFailure: .destinationChanged, record: record, journal: store, cancellation: segment, protection: protection)
                    }
                    try renameStep(payload, entry.destination, expectedTree: payloadTree,
                        expectedGuard: sameVolumeMove ? unit.source : nil, record: record, journal: store, cancellation: segment, protection: protection)
                    if plan.isMove && !sameVolumeMove {
                        // Native publication may add a root security mark. Its saved
                        // after-image, rather than the staged image, guards retention.
                        guard let publication = record.steps.last, publication.source == payload,
                              publication.destination == entry.destination, let published = publication.after else {
                            throw FileOperationFailure.recoveryUncertain
                        }
                        cancellation.progress?.begin(.retaining, source: entry.source, destination: entry.destination)
                        guard original.matches(try verifiedTree(entry.source, cancellation: segment)) else { throw FileOperationFailure.sourceChanged }
                        let sourceParent = try DirectoryAnchor(entry.source.deletingLastPathComponent(), resolve: false)
                        let backup = try recoveryArea(in: sourceParent, record: record, journal: store)
                        guard published.matches(try verifiedTree(entry.destination, cancellation: segment)) else { throw FileOperationFailure.recoveryUncertain }
                        try renameStep(entry.source, backup.url.appendingPathComponent("source"), expectedTree: original,
                            expectedGuard: unit.source, record: record, journal: store, cancellation: segment, protection: protection)
                        guard published.matches(try verifiedTree(entry.destination, cancellation: segment)) else { throw FileOperationFailure.recoveryUncertain }
                    }
                    outcomes.append(outcome(entry, .succeeded))
                    for receipt in memberReceipts {
                        if let size = try? receipt.encoded().count, referenceReceiptBytes + size <= 8_388_608 {
                            referenceReceipts.append(receipt); referenceReceiptBytes += size
                        }
                    }
                } catch {
                    outcomes.append(outcome(entry, operationStatus(error), recovery: record.locations))
                    // Active-item interruption can leave an unpublished staging payload.
                    // Keep it visible for review; safe between-item Stop commits above.
                    record.setState("needsReview")
                    try? store.save(record); current = record.snapshot
                    appendRemaining()
                    return RecoverableOperationResult(result: FileOperationResult(items: outcomes, cancellationRequested: cancellation.isCancelled),
                        recordID: record.id, referenceReceipts: referenceReceipts)
                }
            }
            for container in mergedContainers {
                if cancellation.isCancelled {
                    appendRemaining()
                    record.setState("committed"); try store.save(record); current = record.snapshot
                    return completed(record.snapshot)
                }
                activeContainer = container
                try cancellation.check()
                let parent = try DirectoryAnchor(container.source.deletingLastPathComponent(), resolve: false)
                guard parent.identity.sameObject(as: container.sourceParent) else { throw FileOperationFailure.sourceChanged }
                let anchor = try DirectoryAnchor(container.source, resolve: false)
                guard anchor.identity.sameObject(as: container.sourceIdentity) else { throw FileOperationFailure.sourceChanged }
                let fd = openat(anchor.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw posixFailure() }
                defer { close(fd) }
                let start = try EntrySnapshot(fd: fd)
                let names = try childNames(in: fd, cancellation: cancellation, limit: OperationLimits.maximumNodes)
                let knownAreas = record.areas.filter { $0.url.deletingLastPathComponent().path == container.source.path }
                let onlyRecoveryAreas = try names.allSatisfy { name in
                    guard let area = knownAreas.first(where: { $0.url.lastPathComponent == name }) else { return false }
                    return try EntrySnapshot(parent: fd, name: name).sameObject(as: area.identity)
                }
                guard try EntrySnapshot(fd: fd) == start else { throw FileOperationFailure.sourceChanged }
                if !onlyRecoveryAreas {
                    outcomes.append(outcome(container, .failed(.conflict), role: .mergeContainer))
                    activeContainer = nil
                    continue
                }
                let expected = try verifiedTree(container.source, cancellation: cancellation)
                guard expected.identity == start else { throw FileOperationFailure.sourceChanged }
                let area = try recoveryArea(in: parent, record: record, journal: store)
                try renameStep(container.source, area.url.appendingPathComponent("merged-source"), expectedTree: expected,
                               record: record, journal: store, cancellation: cancellation, protection: protection)
                outcomes.append(outcome(container, .succeeded, role: .mergeContainer))
                activeContainer = nil
            }
            record.setState("committed"); try store.save(record); current = record.snapshot
            appendRemaining()
            return completed(record.snapshot)
        } catch {
            if let id = current?.id, let journal, let latest = try? journal.openEdit(id) {
                latest.setState("needsReview"); try? journal.save(latest); current = latest.snapshot
            }
            if !resolved {
                // Resolution failed before any input mutation. Do not mix partially
                // resolved child choices with invented top-level transfer outcomes.
                entries = plan.entries; mergedContainers = []; outcomes = []
                for entry in plan.entries where roots[entry.id] == nil {
                    roots[entry.id] = (id: entry.id, source: entry.source)
                }
            }
            if let activeContainer {
                outcomes.append(outcome(activeContainer, operationStatus(error), role: .mergeContainer,
                    recovery: current?.locations ?? []))
            } else {
                outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error),
                    recoveryURLs: current?.locations ?? [], role: .job))
            }
            // These are the exact resolved units/retirements, not original roots
            // whose contents may already have moved in a partially completed merge.
            appendRemaining()
            return RecoverableOperationResult(result: FileOperationResult(items: outcomes, cancellationRequested: cancellation.isCancelled), recordID: current?.id)
        }
    }

    private func validate(_ entry: TransferEntry) throws {
        let source = try DirectoryAnchor(entry.source.deletingLastPathComponent(), resolve: false)
        let destination = try DirectoryAnchor(entry.destination.deletingLastPathComponent(), resolve: false)
        guard source.identity.sameObject(as: entry.sourceParent),
              try EntrySnapshot(parent: source.fd, name: entry.source.lastPathComponent) == entry.sourceIdentity else { throw FileOperationFailure.sourceChanged }
        guard destination.identity.sameObject(as: entry.destinationParent) else { throw FileOperationFailure.destinationChanged }
        if let expected = entry.destinationIdentity {
            guard try EntrySnapshot(parent: destination.fd, name: entry.destination.lastPathComponent) == expected else { throw FileOperationFailure.destinationChanged }
        } else { try requireAbsent(entry.destination.lastPathComponent, in: destination.fd) }
    }

    internal func recoveryArea(in parent: DirectoryAnchor, record: JournalEditSession, journal: OperationJournal) throws -> DirectoryAnchor {
        let name = ".mac-explorer-recovery-" + UUID().uuidString
        let url = parent.url.appendingPathComponent(name, isDirectory: true)
        try record.appendLocation(url); try journal.save(record)
        try parent.validate()
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw posixFailure() }
        let anchor = try DirectoryAnchor(url, resolve: false)
        try record.bindPersistentVolume(in: anchor)
        let fd = openat(anchor.fd, ".mac-explorer-recovery-v1", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        let marker = Data("MacExplorer recovery v1\n\(record.id.uuidString)\nRetained until explicit cleanup.\n".utf8)
        guard marker.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == marker.count, fsync(fd) == 0 else { throw posixFailure() }
        try syncDirectory(anchor); try syncDirectory(parent)
        try record.appendArea(JournalArea(url: url, identity: anchor.identity)); try journal.save(record)
        return anchor
    }

    internal func renameStep(_ source: URL, _ destination: URL, expectedIdentity: EntrySnapshot? = nil, expectedTree: VerifiedTree? = nil,
                            expectedQuarantines: [String: Data]? = nil,
                            expectedGuard: ContinuationGuard? = nil, guardFailure: FileOperationFailure = .sourceChanged,
                            record: JournalEditSession, journal: OperationJournal,
                            cancellation: OperationCancellation, protection: HistoryProtection? = nil,
                            osManagedSecurityV1: Bool = false,
                            publicZIPExtractionMarkRequired: Bool? = nil,
                            publicTARExtractionMarkRequired: Bool? = nil,
                            publicProducedTreeV16: PublicProducedTreePurposeV16? = nil) throws {
        try cancellation.check()
        guard (!osManagedSecurityV1 && publicZIPExtractionMarkRequired == nil
                && publicTARExtractionMarkRequired == nil && publicProducedTreeV16 == nil)
            || (osManagedSecurityV1 && [14, 15, 17].contains(record.snapshot.version)
                && (record.snapshot.version == 15) == (publicZIPExtractionMarkRequired != nil)
                && (record.snapshot.version == 17) == (publicTARExtractionMarkRequired != nil)
                && publicProducedTreeV16 == nil && expectedQuarantines == nil && expectedGuard == nil)
            || (osManagedSecurityV1 && record.snapshot.version == 16
                && record.snapshot.producedTreeV16 == publicProducedTreeV16
                && publicProducedTreeV16 != nil && expectedTree?.publicTreeQuarantineV16 != nil
                && publicZIPExtractionMarkRequired == nil && publicTARExtractionMarkRequired == nil
                && expectedQuarantines == nil && expectedGuard == nil) else {
            throw FileOperationFailure.invalidRequest
        }
        let publicMarkRequired = osManagedSecurityV1
            && (record.snapshot.version == 14 || publicZIPExtractionMarkRequired == true
                || publicTARExtractionMarkRequired == true)
        let from = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
        let to = try DirectoryAnchor(destination.deletingLastPathComponent(), resolve: false)
        let beforeSecurity = NativeRenameSecurityProjection()
        let origin = NativeProcessSecurityOrigin.current
        let before: VerifiedTree
        guard expectedQuarantines == nil || expectedGuard == nil else { throw FileOperationFailure.invalidRequest }
        if let expectedGuard {
            let observed = try ContinuationGuard.observe(parent: from.fd, name: source.lastPathComponent, cancellation: cancellation, nativeRename: beforeSecurity)
            guard expectedGuard.matches(observed) else { throw guardFailure }
            before = observed.tree
        } else { before = try verifiedTree(parent: from.fd, name: source.lastPathComponent, cancellation: cancellation,
            rootURL: source, expectedQuarantines: expectedQuarantines, nativeRename: beforeSecurity,
            osManagedSecurityV1: osManagedSecurityV1,
            publicTreeRequiresEveryNode: publicProducedTreeV16?.requiresMarkOnEveryNode) }
        if let expectedIdentity, before.identity != expectedIdentity { throw FileOperationFailure.sourceChanged }
        if let expectedTree, !expectedTree.matches(before) { throw FileOperationFailure.sourceChanged }
        let pinned = try pinEntry(parent: from.fd, name: source.lastPathComponent, matching: before.identity)
        defer { close(pinned) }
        if publicMarkRequired {
            try requireReceivedPublicQuarantine(parent: from, name: source.lastPathComponent,
                descriptor: pinned, identity: before.identity)
        }
        try requireAbsent(destination.lastPathComponent, in: to.fd)
        try record.bindPersistentVolume(in: from)
        try record.bindPersistentVolume(in: to)
        try record.appendNewLocations([source, destination])
        try record.appendStep(JournalStep(source: source, destination: destination, sourceParent: from.identity,
            destinationParent: to.identity, before: before,
            publicZIPExtractionMarkRequired: publicZIPExtractionMarkRequired,
            publicTARExtractionMarkRequired: publicTARExtractionMarkRequired))
        record.setState("mutating"); try journal.save(record)
        hooks.afterIntent?()
        try cancellation.check(); try from.validate(); try to.validate()
        if let expectedGuard {
            let observed = try ContinuationGuard.observe(parent: from.fd, name: source.lastPathComponent, cancellation: cancellation)
            guard expectedGuard.matches(observed) else { throw guardFailure }
        } else {
            guard before.matches(try verifiedTree(parent: from.fd, name: source.lastPathComponent, cancellation: cancellation,
                rootURL: source, expectedQuarantines: expectedQuarantines,
                osManagedSecurityV1: osManagedSecurityV1,
                publicTreeRequiresEveryNode: publicProducedTreeV16?.requiresMarkOnEveryNode))
            else { throw FileOperationFailure.sourceChanged }
        }
        if publicMarkRequired {
            try requireReceivedPublicQuarantine(parent: from, name: source.lastPathComponent,
                descriptor: pinned, identity: before.identity)
        }
        do {
            hooks.beforeRename?()
            try cancellation.beginMutation()
            try hooks.beforeExclusiveRename?(source, destination)
            try protection?.requireEntry(parent: from, name: source.lastPathComponent)
            try protection?.requireEntry(parent: to, name: destination.lastPathComponent)
            try exclusiveRename(from: from.fd, name: source.lastPathComponent, to: to.fd, name: destination.lastPathComponent)
            hooks.afterRename?()
            let afterSecurity = NativeRenameSecurityProjection()
            let after: VerifiedTree
            if let expectedGuard {
                let observed = try ContinuationGuard.observe(parent: to.fd, name: destination.lastPathComponent, cancellation: cancellation.draining(), nativeRename: afterSecurity)
                guard expectedGuard.matchesRelocatedIdentities(observed),
                      expectedGuard.tree.matches(observed.tree) || beforeSecurity.permitsNativeTransition(to: afterSecurity, before: before, after: observed.tree, origin: origin)
                else { throw FileOperationFailure.recoveryUncertain }
                after = observed.tree
            } else { after = try verifiedTree(parent: to.fd, name: destination.lastPathComponent, cancellation: cancellation.draining(),
                rootURL: destination, expectedQuarantines: expectedQuarantines, nativeRename: afterSecurity,
                osManagedSecurityV1: osManagedSecurityV1,
                publicTreeRequiresEveryNode: publicProducedTreeV16?.requiresMarkOnEveryNode) }
            if publicMarkRequired {
                try requireReceivedPublicQuarantine(parent: to, name: destination.lastPathComponent,
                    descriptor: pinned, identity: after.identity)
            }
            guard before.matches(after) || !osManagedSecurityV1
                && beforeSecurity.permitsNativeTransition(to: afterSecurity, before: before, after: after, origin: origin)
            else { throw FileOperationFailure.recoveryUncertain }
            cancellation.progress?.transition(.syncing)
            try from.validate(); try to.validate(); try hooks.beforeSync?(destination); try syncDirectory(from); try syncDirectory(to)
            try record.setStepOutcome(after, at: record.steps.count - 1)
            try journal.save(record)
        } catch {
            let known = [from.currentURL?.appendingPathComponent(source.lastPathComponent),
                         to.currentURL?.appendingPathComponent(destination.lastPathComponent), entryURL(for: pinned, matching: before.identity)].compactMap { $0 }
            try record.appendNewLocations(known)
            record.setState("needsReview"); try? journal.save(record)
            throw error
        }
    }

    /// macOS may finish adding native access metadata while the first post-Trash
    /// observation runs. Retry only unstable observations, with bounded off-main delay.
    /// Every attempt binds the same object and the final stable content/metadata guard.
    internal func verifyNativeTrashResult(_ target: URL, before: VerifiedTree, cancellation: OperationCancellation,
                                          requiresMaterialized: Bool = false, recordID: UUID? = nil,
                                          beforeFamilies: NativeTrashFamilySnapshot? = nil,
                                          ordinaryMode: NativeTrashVerificationMode = .strict,
                                          ordinaryDirectoryAdmission: NativeTrashDirectoryAdmission = .strict,
                                          verifiedRootMetadata: ((NativeTrashRootMetadataProofV4?) -> Void)? = nil,
                                          verifiedQuarantineChange: ((Bool) -> Void)? = nil) throws -> VerifiedTree {
        for attempt in 0..<3 {
            try cancellation.check()
            var checkpoint = OperationDiagnosticCheckpoint.nativeTrashReturnedParent
            var familyFinding: NativeTrashFamilyFinding?
            var rootMetadataProof: NativeTrashRootMetadataProofV4?
            do {
                let parent = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
                checkpoint = .nativeTrashReturnedIdentity
                guard try EntrySnapshot(parent: parent.fd, name: target.lastPathComponent).sameObject(as: before.identity) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                checkpoint = .nativeTrashTreeRead
                let families = beforeFamilies.map { _ in NativeTrashFamilyCollector() }
                #if DEBUG
                let syntheticRootMetadata = hooks.nativeTrashSyntheticRootMetadata
                #else
                let syntheticRootMetadata: NativeTrashSyntheticRootMetadata? = nil
                #endif
                let candidate = try verifiedTree(parent: parent.fd, name: target.lastPathComponent,
                                                 cancellation: cancellation, beforeRootValidation: hooks.duringNativeTrashVerification,
                                                 requiresMaterialized: requiresMaterialized,
                                                 nativeTrashFamilyCollector: families,
                                                 nativeTrashSyntheticRootMetadata: syntheticRootMetadata)
                checkpoint = .nativeTrashParentValidation
                try parent.validate()
                checkpoint = .nativeTrashFingerprint
                if !before.matchesNativeTrashTransition(candidate) {
                    let afterFamilies = families?.snapshot()
                    if let beforeFamilies {
                        if let afterFamilies {
                            familyFinding = beforeFamilies.finding(comparedWith: afterFamilies,
                                before: before, returned: candidate)
                        } else {
                            familyFinding = .unavailable
                        }
                    }
                    let admittedPair = (ordinaryMode == .ordinaryRegularFilePairCandidate
                        || ordinaryMode == .ordinaryRegularFileNativeMetadata)
                        && before.identity.type == S_IFREG && candidate.identity.type == S_IFREG
                        && before.identity.sameObject(as: candidate.identity)
                        && familyFinding == .complete(nativeChanged: [.provenance],
                            osAccessAttributeChanged: true)
                    let admittedOrdinaryMetadata = ordinaryMode == .ordinaryRegularFileNativeMetadata
                        && before.identity.type == S_IFREG && candidate.identity.type == S_IFREG
                        && before.identity.sameObject(as: candidate.identity)
                        && (familyFinding == .complete(nativeChanged: [.quarantine],
                                osAccessAttributeChanged: true)
                            || familyFinding == .complete(nativeChanged: [.quarantine],
                                osAccessAttributeChanged: false))
                        && beforeFamilies.flatMap { prior in
                            afterFamilies.map { later in
                                prior.permitsBoundedRootQuarantineChange(comparedWith: later,
                                    before: before, returned: candidate)
                            }
                        } == true
                    if ordinaryMode == .retainedTextDirectoryRootNativeMetadata,
                       let beforeFamilies, let afterFamilies {
                        rootMetadataProof = beforeFamilies.rootMetadataProof(comparedWith: afterFamilies,
                            before: before, returned: candidate)
                    } else if ordinaryDirectoryAdmission == .nativeRootMetadata,
                              before.identity.isDirectory, candidate.identity.isDirectory,
                              let beforeFamilies, let afterFamilies {
                        rootMetadataProof = beforeFamilies.rootMetadataProof(comparedWith: afterFamilies,
                            before: before, returned: candidate, nativeDirectoryV12: true)
                    } else if ordinaryDirectoryAdmission == .additiveRootOnlyCandidate,
                              before.identity.isDirectory, candidate.identity.isDirectory,
                              let beforeFamilies, let afterFamilies,
                              let proof = beforeFamilies.rootMetadataProof(comparedWith: afterFamilies,
                                  before: before, returned: candidate),
                              proof.validatesAdditiveRoot(before: before, after: candidate) {
                        rootMetadataProof = proof
                    }
                    guard admittedPair || admittedOrdinaryMetadata || rootMetadataProof != nil else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                } else if ordinaryDirectoryAdmission == .nativeRootMetadata,
                          before.identity.isDirectory {
                    guard let beforeFamilies, let afterFamilies = families?.snapshot(),
                          beforeFamilies.permitsExactNativeDirectoryTransition(comparedWith: afterFamilies,
                              before: before, returned: candidate) else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                }
                if let verifiedQuarantineChange {
                    guard let beforeFamilies, let afterFamilies = families?.snapshot(),
                          let changed = beforeFamilies.rootQuarantineChanged(comparedWith: afterFamilies,
                              before: before, returned: candidate) else {
                        throw FileOperationFailure.recoveryUncertain
                    }
                    verifiedQuarantineChange(changed)
                }
                verifiedRootMetadata?(rootMetadataProof)
                return candidate
            } catch {
                if error as? FileOperationFailure == .sourceChanged, checkpoint != .nativeTrashReturnedParent,
                   checkpoint != .nativeTrashReturnedIdentity, attempt < 2 {
                    try cancellation.check()
                    Thread.sleep(forTimeInterval: 0.01 * Double(attempt + 1))
                    continue
                }
                // Report only the final caught boundary. Retried unstable reads
                // are not terminal failures; diagnostics never settle a move.
                cancellation.progress?.observeCaughtFailure(checkpoint, error: error, recordID: recordID,
                    nativeTrashFinding: checkpoint == .nativeTrashFingerprint ? familyFinding : nil)
                throw error
            }
        }
        throw FileOperationFailure.sourceChanged
    }

    internal func trash(_ sources: [URL], observing selection: FileOperationSelection?, cancellation: OperationCancellation,
                        guarded: GuardedTrashPolicy? = nil) -> RecoverableOperationResult {
        #if DEBUG
        let requestedMode = hooks.nativeTrashQualificationMode ?? NativeTrashVerificationMode.ordinaryRegularFileNativeMetadata
        // The retained-text directory mode is never an ordinary Trash policy,
        // including when a DEBUG diagnostic sink collects directory families.
        let ordinaryMode: NativeTrashVerificationMode = requestedMode == .retainedTextDirectoryRootNativeMetadata
            ? .strict : requestedMode
        #else
        let ordinaryMode = NativeTrashVerificationMode.ordinaryRegularFileNativeMetadata
        #endif
        let nativeDirectoryContract = nativeTrashPolicy == .regularFilesAndDirectories
            && nativeTrashDirectoryAdmission == .strict
            && ordinaryMode == .ordinaryRegularFileNativeMetadata
        let directoryAdmission: NativeTrashDirectoryAdmission = nativeDirectoryContract
            ? .nativeRootMetadata : nativeTrashDirectoryAdmission
        var active: JournalRecord?
        var activeSession: JournalEditSession?
        var activeCheckpoint: JournalEditSession.Checkpoint?
        func remember(_ session: JournalEditSession) {
            active = session.snapshot; activeCheckpoint = session.checkpoint()
        }
        var store: OperationJournal?
        var outcomes: [FileOperationOutcome] = []
        var failureStage = "source-observation"
        do {
            guard !sources.isEmpty, sources.count <= OperationJournal.maximumInputs else { throw FileOperationFailure.invalidRequest }
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            for source in sources { try protection.requireEntry(source) }
            // Reuse the legacy batch preflight for overlap/type/access rules, but perform each
            // native Trash call through the same serial executor after its durable intent.
            cancellation.progress?.begin(.verifying, count: sources.count)
            let budget = TraversalBudget()
            let observations = try sources.map { source -> (URL, EntrySnapshot, EntrySnapshot, VerifiedTree, NativeTrashFamilySnapshot?) in
                let parent = try DirectoryAnchor(source.deletingLastPathComponent())
                let url = parent.url.appendingPathComponent(source.lastPathComponent)
                let needsBoundedProof: Bool
                if ordinaryMode.requiresRegularFilePreflight || directoryAdmission != .strict {
                    let observedIdentity = try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent)
                    needsBoundedProof = ordinaryMode.requiresRegularFilePreflight && observedIdentity.type == S_IFREG
                        || directoryAdmission != .strict && observedIdentity.isDirectory
                } else { needsBoundedProof = false }
                let families: NativeTrashFamilyCollector? = needsBoundedProof || cancellation.progress != nil && FileOperationDiagnostics.hasSink
                    ? NativeTrashFamilyCollector() : nil
                let tree = try verifiedTree(url, cancellation: cancellation, budget: budget, guarded: guarded,
                                            nativeTrashFamilyCollector: families)
                return (url, tree.identity, parent.identity, tree, families?.snapshot())
            }
            for a in observations { for b in observations where a.0 != b.0 {
                guard !b.0.path.hasPrefix(a.0.path + "/"), !a.1.sameObject(as: b.1) else { throw FileOperationFailure.invalidRequest }
            } }
            guard Set(observations.map { $0.0.path }).count == observations.count else { throw FileOperationFailure.invalidRequest }
            if let selection {
                for (url, identity) in zip(selection.urls, selection.identities) {
                    guard let observation = observations.first(where: { $0.0.path == url.path }), observation.1 == identity else { throw FileOperationFailure.sourceChanged }
                }
            }
            let nativeRegularFiles = nativeTrashDirectoryAdmission == .strict
                && ordinaryMode == .ordinaryRegularFileNativeMetadata
                && observations.allSatisfy { $0.1.type == S_IFREG && $0.4 != nil }
            let nativeDirectoryJob = nativeDirectoryContract
                && observations.contains { $0.1.isDirectory }
                && observations.allSatisfy { [S_IFREG, S_IFDIR].contains($0.1.type) && $0.4 != nil }
            switch nativeTrashPolicy {
            case .regularFilesOnly:
                guard nativeRegularFiles else { throw FileOperationFailure.unsupported }
            case .regularFilesAndDirectories:
                guard nativeRegularFiles || nativeDirectoryJob else { throw FileOperationFailure.unsupported }
            case .held, .existingVerifiedPaths: break
            }
            failureStage = "journal-open"
            let journal = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation); store = journal
            try protection.historyOpened(journal.anchor)
            try journal.reserveCapacity(steps: sources.count, areas: 0, locations: sources.count * 3, trashIntents: sources.count,
                estimatedBytes: 16_384 + sources.count * 8192 + sources.reduce(0) { $0 + $1.path.utf8.count * 16 })
            let record = try directoryAdmission == .additiveRootOnlyCandidate
                ? journal.beginAdditiveRootTrashEdit()
                : nativeDirectoryJob ? journal.beginNativeDirectoryTrashEdit()
                    : nativeRegularFiles ? journal.beginNativeTrashEdit()
                    : journal.beginEdit(operation: "Move to Trash")
            activeSession = record
            for observation in observations {
                let parent = try DirectoryAnchor(observation.0.deletingLastPathComponent(), resolve: false)
                guard parent.identity.sameObject(as: observation.2) else { throw FileOperationFailure.sourceChanged }
                try record.bindPersistentVolume(in: parent)
            }
            try record.appendLocations(observations.map { $0.0 }); record.setState("mutating")
            try journal.save(record); remember(record)
            for (index, observation) in observations.enumerated() {
                let (url, identity, parentIdentity, before, beforeFamilies) = observation
                if cancellation.isCancelled {
                    outcomes += observations.dropFirst(index).map { FileOperationOutcome(source: $0.0, destination: nil, status: .notStarted, recoveryURLs: []) }
                    break
                }
                try cancellation.check()
                try record.appendTrashIntent(JournalTrashIntent(source: url, sourceParent: parentIdentity, before: before))
                try journal.save(record); remember(record)
                cancellation.progress?.begin(.retaining, source: url)
                failureStage = "native-trash-call"
                let result = legacy.execute(.trash(sources: [url]), observing: FileOperationSelection(urls: [url], identities: [identity]),
                    cancellation: cancellation.draining(), beforeMutation: {
                        try protection.requireEntry(url)
                        try guarded?.validateRoot(index)
                        if ordinaryMode.requiresRegularFilePreflight && before.identity.type == S_IFREG
                            || directoryAdmission != .strict && before.identity.isDirectory {
                            #if DEBUG
                            try self.hooks.nativeTrashBeforeSourceRecheck?()
                            let measured = self.hooks.nativeTrashPreflightMeasured
                            let meter = measured == nil ? nil : NativeTrashWalkMeter()
                            let started = DispatchTime.now().uptimeNanoseconds
                            #else
                            let meter: NativeTrashWalkMeter? = nil
                            #endif
                            let candidateDirectory = directoryAdmission != .strict && before.identity.isDirectory
                            let rewalkFamilies = candidateDirectory ? NativeTrashFamilyCollector() : nil
                            let current = try verifiedTree(url, cancellation: cancellation, guarded: guarded,
                                                           requiresMaterialized: candidateDirectory,
                                                           nativeTrashFamilyCollector: rewalkFamilies,
                                                           nativeTrashWalkMeter: meter)
                            #if DEBUG
                            if let meter, let measured {
                                let proof = meter.snapshot
                                guard proof.valid else { throw FileOperationFailure.unsupported }
                                measured(proof.entries, proof.bodyBytes,
                                         DispatchTime.now().uptimeNanoseconds - started)
                            }
                            #endif
                            guard before.matches(current) else { throw FileOperationFailure.sourceChanged }
                            if candidateDirectory {
                                guard let beforeFamilies, let rewalk = rewalkFamilies?.snapshot(),
                                      beforeFamilies.matchesPreMutationRewalk(rewalk,
                                          before: before, current: current) else {
                                    throw FileOperationFailure.sourceChanged
                                }
                            }
                        }
                    })
                guard let item = result.items.first else { throw FileOperationFailure.recoveryUncertain }
                outcomes.append(item)
                let known = ([item.destination].compactMap { $0 } + item.recoveryURLs)
                try record.appendNewLocations(known)
                failureStage = "record-native-result"
                remember(record) // Keep the native returned location even when its durable save fails.
                try journal.save(record); remember(record)
                guard item.status == .succeeded, let destination = item.destination else { throw FileOperationFailure.recoveryUncertain }
                failureStage = "target-parent-anchor"
                let targetParent = try DirectoryAnchor(destination.deletingLastPathComponent())
                try record.bindPersistentVolume(in: targetParent)
                let target = targetParent.url.appendingPathComponent(destination.lastPathComponent)
                failureStage = "target-content-verification"
                var firstRootAddition: NativeTrashRootMetadataProofV4?
                var nativeMarkChanged: Bool?
                let after = try verifyNativeTrashResult(target, before: before, cancellation: cancellation.draining(),
                                                       requiresMaterialized: guarded != nil ||
                                                           directoryAdmission != .strict && before.identity.isDirectory,
                                                       recordID: record.id, beforeFamilies: beforeFamilies,
                                                       ordinaryMode: ordinaryMode,
                                                       ordinaryDirectoryAdmission: directoryAdmission,
                                                       verifiedRootMetadata: { firstRootAddition = $0 },
                                                       verifiedQuarantineChange: (nativeRegularFiles || nativeDirectoryJob)
                                                           && before.identity.type == S_IFREG
                                                           ? { nativeMarkChanged = $0 } : nil)
                failureStage = "source-parent-revalidation"
                let originalParent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
                guard originalParent.identity.sameObject(as: parentIdentity) else { throw FileOperationFailure.recoveryUncertain }
                try requireAbsent(url.lastPathComponent, in: originalParent.fd)
                let directoryPostSync = nativeDirectoryJob && before.identity.isDirectory
                if firstRootAddition == nil && !directoryPostSync {
                    try record.appendStep(JournalStep(source: url, destination: target, sourceParent: parentIdentity,
                                                    destinationParent: targetParent.identity, before: before, after: after,
                                                    nativeTrashMarkChanged: nativeMarkChanged))
                    try record.appendLocation(target)
                    remember(record)
                }
                failureStage = "source-parent-sync"
                if firstRootAddition != nil || directoryPostSync { try hooks.beforeSync?(target) }
                try syncDirectory(originalParent)
                failureStage = "target-parent-sync"
                try syncDirectory(targetParent)
                if firstRootAddition != nil || directoryPostSync {
                    failureStage = "target-post-sync-verification"
                    var finalRootAddition: NativeTrashRootMetadataProofV4?
                    let final = try verifyNativeTrashResult(target, before: before, cancellation: cancellation.draining(),
                        requiresMaterialized: true, recordID: record.id, beforeFamilies: beforeFamilies,
                        ordinaryMode: ordinaryMode, ordinaryDirectoryAdmission: directoryAdmission,
                        verifiedRootMetadata: { finalRootAddition = $0 })
                    guard after.matches(final), firstRootAddition == finalRootAddition else {
                        throw FileOperationFailure.sourceChanged
                    }
                    try record.appendStep(JournalStep(source: url, destination: target, sourceParent: parentIdentity,
                        destinationParent: targetParent.identity, before: before, after: final,
                        nativeTrashRootAddition: firstRootAddition,
                        nativeTrashDirectoryDescendantIdentity: nativeDirectoryJob
                            ? beforeFamilies?.directoryDescendantIdentityWitness : nil))
                    try record.appendLocation(target)
                    remember(record)
                }
                failureStage = "record-validated-result"
                try journal.save(record); remember(record)
            }
            failureStage = "record-completion"
            record.setState("committed"); try journal.save(record); remember(record)
        } catch {
            if let record = activeSession, let checkpoint = activeCheckpoint, let store {
                do {
                    try record.restore(checkpoint)
                    record.setState("needsReview"); record.setFailureStage(failureStage)
                    try? store.save(record); remember(record)
                } catch { /* A stale checkpoint grants no new persistence authority. */ }
            }
            outcomes.append(FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error),
                recoveryURLs: active?.locations ?? [], role: .job))
            let attempted = Set(outcomes.compactMap(\.source))
            outcomes += sources.filter { !attempted.contains($0) }.map { FileOperationOutcome(source: $0, destination: nil, status: .notStarted, recoveryURLs: []) }
        }
        return RecoverableOperationResult(result: FileOperationResult(items: outcomes, cancellationRequested: cancellation.isCancelled), recordID: active?.id)
    }

    private func simple(source: URL?, parent: URL, name: String, observing: FileOperationSelection?, cancellation: OperationCancellation) -> RecoverableOperationResult {
        var record: JournalRecord?
        var journal: OperationJournal?
        do {
            try validateName(name)
            let destination = try DirectoryAnchor(parent)
            let protection = try HistoryProtection(directory, cancellation: cancellation, protecting: protectedLocations)
            if let source { try protection.requireEntry(source) }
            try protection.requireEntry(parent: destination, name: name)
            if let observing {
                for (url, snapshot) in zip(observing.urls, observing.identities) {
                    if url.path == destination.url.path {
                        guard snapshot.sameObject(as: destination.identity) else { throw FileOperationFailure.destinationChanged }
                    } else if let source, url.path == source.path {
                        let anchor = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
                        guard try EntrySnapshot(parent: anchor.fd, name: source.lastPathComponent) == snapshot else { throw FileOperationFailure.sourceChanged }
                    } else { throw FileOperationFailure.invalidRequest }
                }
            }
            try requireAbsent(name, in: destination.fd)
            let originalSource = try source.map { try EntrySnapshot(parent: destination.fd, name: $0.lastPathComponent) }
            if let source, let observing, let originalSource {
                for (url, identity) in zip(observing.urls, observing.identities) where url.path == source.path {
                    guard identity == originalSource else { throw FileOperationFailure.sourceChanged }
                }
            }
            let store = try OperationJournal(directory, hooks: hooks.journalHooks, cancellation: cancellation); journal = store
            try protection.historyOpened(store.anchor)
            try store.validateWritableCatalog()
            cancellation.progress?.begin(.planning, source: source, destination: parent.appendingPathComponent(name))
            if let source { _ = try verifiedTree(source, cancellation: cancellation) }
            try store.reserveCapacity(steps: 1, areas: source == nil ? 1 : 0, locations: 3, trashIntents: 0,
                estimatedBytes: 16_384 + parent.path.utf8.count * 16 + name.utf8.count * 8)
            try cancellation.check()
            let value = try store.beginEdit(operation: source == nil ? "New Folder" : "Rename")
            try store.save(value); record = value.snapshot
            let input: URL
            if let source { input = destination.url.appendingPathComponent(source.lastPathComponent) }
            else {
                let area = try recoveryArea(in: destination, record: value, journal: store)
                guard mkdirat(area.fd, "payload", 0o755) == 0 else { throw posixFailure() }
                input = area.url.appendingPathComponent("payload")
            }
            try destination.validate()
            try renameStep(input, destination.url.appendingPathComponent(name), expectedIdentity: originalSource,
                record: value, journal: store, cancellation: cancellation, protection: protection)
            value.setState("committed"); try store.save(value); record = value.snapshot
            return RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: source, destination: destination.url.appendingPathComponent(name), status: .succeeded, recoveryURLs: [])], cancellationRequested: cancellation.isCancelled), recordID: value.id)
        } catch {
            // The newest durable revision remains authoritative even if an inout operation threw.
            if let journal, let id = record?.id, let latest = try? journal.openEdit(id) {
                latest.setState("needsReview"); try? journal.save(latest); record = latest.snapshot
            }
            return RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: source, destination: parent.appendingPathComponent(name), status: operationStatus(error), recoveryURLs: record?.locations ?? [])], cancellationRequested: cancellation.isCancelled), recordID: record?.id)
        }
    }

    private func failure(_ error: Error, sources: [URL] = []) -> RecoverableOperationResult {
        RecoverableOperationResult(result: FileOperationResult(items: [FileOperationOutcome(source: nil, destination: nil, status: operationStatus(error), recoveryURLs: [], role: .job)] + sources.map { FileOperationOutcome(source: $0, destination: nil, status: .notStarted, recoveryURLs: []) }, cancellationRequested: error is CancellationError), recordID: nil)
    }
}

internal struct RecoveryHooks: Sendable {
    var selectionGroup = SelectionGroupHooks()
    var textEditor = TextEditorHooksV2()
    var archiveProduction = ArchiveProductionHooks()
    var beforeStagingProof: (@Sendable (UUID) throws -> Void)?
    var afterStagingProof: (@Sendable () throws -> Void)?
    var beforeSync: (@Sendable (URL) throws -> Void)?
    var beforeExclusiveRename: (@Sendable (URL, URL) throws -> Void)?
    var journalHooks = JournalStorageHooks()
    var copyFaults = CopyFaultHooks()
    var groupedCopy = GroupedCopyHooks()
    var groupedRecovery = GroupedCopyRecoveryHooks()
    var groupedRetention = GroupedCopyRetentionHooks()
    var afterAdmission: (@Sendable () -> Void)?
    var retentionTrash: (@Sendable (URL) throws -> URL)?
    var duringNativeTrashVerification: (@Sendable () -> Void)?
    #if DEBUG
    var nativeTrashQualificationMode: NativeTrashVerificationMode?
    var nativeTrashSyntheticRootMetadata: NativeTrashSyntheticRootMetadata?
    /// Generated inverse-only postwalk metadata, never written to the filesystem.
    var nativeTrashInverseRestoredSyntheticRootMetadata: NativeTrashSyntheticRootMetadata?
    /// Generated Delete-stage postwalk metadata, never written to the filesystem.
    var nativeTrashDeleteStagedSyntheticRootMetadata: NativeTrashSyntheticRootMetadata?
    /// Generated-only stage boundary for descendant and journal fault controls.
    var nativeTrashDeleteAfterStageRename: (@Sendable (URL) throws -> Void)?
    var nativeTrashBeforeSourceRecheck: (@Sendable () throws -> Void)?
    /// entries, body bytes and elapsed monotonic nanoseconds of the extra walk.
    var nativeTrashPreflightMeasured: (@Sendable (Int, Int64, UInt64) -> Void)?
    #endif
    var beforeCommit: (@Sendable () -> Void)?
    var afterIntent: (@Sendable () -> Void)?
    var beforeRename: (@Sendable () -> Void)?
    var afterRename: (@Sendable () -> Void)?
    var afterAdoptionMove: (@Sendable (@escaping @Sendable () -> Bool) throws -> Void)?
    /// Generated owned-Trash fixtures only; production leaves these nil.
    var afterOwnedTrashUnlink: (@Sendable (Int) throws -> Void)?
    var afterOwnedTrashDeleteBeforeConfirm: (@Sendable () throws -> Void)?
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    var privateDownloadMarkProbe: (@Sendable (DownloadPrivateMarkProbeResult) -> Void)?
    #endif
}

internal func syncDirectory(_ anchor: DirectoryAnchor) throws {
    // Darwin supports fsync on O_SEARCH directory descriptors. Sync the pinned
    // directory without requesting read/list access to its children (notably Trash).
    guard fsync(anchor.fd) == 0 else { throw posixFailure() }
}

internal func syncTree(_ url: URL, cancellation: OperationCancellation) throws {
    let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
    let budget = TraversalBudget()
    func visit(_ parent: Int32, _ name: String, _ depth: Int) throws {
        try cancellation.check()
        let value = try EntrySnapshot(parent: parent, name: name)
        try budget.consume(value, depth: depth)
        if value.type == S_IFLNK { cancellation.progress?.advance(items: 1); return }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (value.isDirectory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        guard try EntrySnapshot(fd: fd) == value else { throw FileOperationFailure.sourceChanged }
        if value.isDirectory {
            for child in try childNames(in: fd, cancellation: cancellation, limit: budget.remaining) { try visit(fd, child, depth + 1) }
        }
        guard fsync(fd) == 0 else { throw posixFailure() }
        cancellation.progress?.advance(items: 1)
    }
    try visit(parent.fd, url.lastPathComponent, 0)
}

internal func pinEntry(parent: Int32, name: String, matching identity: EntrySnapshot) throws -> Int32 {
    let fd = openat(parent, name, O_EVTONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw posixFailure() }
    do {
        guard try EntrySnapshot(fd: fd).sameObject(as: identity) else { throw FileOperationFailure.sourceChanged }
        return fd
    } catch { close(fd); throw error }
}

internal func entryURL(for fd: Int32, matching identity: EntrySnapshot) -> URL? {
    var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard bytes.withUnsafeMutableBufferPointer({ fcntl(fd, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!)) }) == 0,
          let terminator = bytes.firstIndex(of: 0),
          let path = String(bytes: bytes[..<terminator].map { UInt8(bitPattern: $0) }, encoding: .utf8) else { return nil }
    let url = URL(fileURLWithPath: path)
    guard let parent = try? DirectoryAnchor(url.deletingLastPathComponent(), resolve: false),
          let entry = try? EntrySnapshot(parent: parent.fd, name: url.lastPathComponent), entry.sameObject(as: identity) else { return nil }
    return url
}
