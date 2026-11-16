import AppKit
import Combine
@_spi(ArchiveProduction) @_spi(ApplicationOwnership) import FileOperations
import ExplorerCore
import LocalStorage

/// Process-wide worker admission; ownership is independent of windows and tabs.
enum ApplicationFileActivity {
    static let gate = FileActivityGate()
    static func beginOperation() throws -> any Sendable {
        do { return try gate.begin() }
        catch { throw FileOperationFailure.unavailable }
    }
}

/// Application ownership is independent of a tab visit. One mutation remains active
/// while its worker drains; closing the progress panel does not cancel the work.
@MainActor
final class ApplicationOperationCoordinator: ObservableObject {
    static let shared = ApplicationOperationCoordinator()
    @Published private(set) var activeOwner: UUID?
    @Published private(set) var preparationOwner: UUID?
    @Published private(set) var copyPreviewOwner: UUID?
    @Published private(set) var copyPreviewStopRequested = false
    @Published private(set) var copyPreviewAwaitingChoice = false
    @Published private(set) var inspectionCount = 0
    private var inspections = Set<UUID>()
    @Published var copyPreviewTask: Task<Void, Never>?
    var attemptedCopyPreviewRestore = false
    private var engines: [URL: RecoverableFileOperations] = [:]
    #if DEBUG
    private var nativeAnalyzerHistoryForVerification: URL?
    /// Use the ordinary factory and lazy state owner for the already-admitted
    /// generated Analyzer flow. A cached engine must never silently change policy.
    func nativeAnalyzerEngineForVerification(at directory: URL) -> RecoverableFileOperations? {
        let arguments = ProcessInfo.processInfo.arguments
        guard directory.isFileURL,
              ["--verify-ui", "--check-location-actions", "--ordinary-location-actions", "--qualify-selected-trash"]
                .allSatisfy(arguments.contains), engines[directory] == nil,
              nativeAnalyzerHistoryForVerification == nil,
              let sourceIndex = arguments.firstIndex(of: "--analysis-source"), arguments.indices.contains(sourceIndex + 1),
              directory.path == URL(fileURLWithPath: arguments[sourceIndex + 1])
                .appendingPathComponent("PrivateState/operation-recovery").path else { return nil }
        nativeAnalyzerHistoryForVerification = directory
        defer { nativeAnalyzerHistoryForVerification = nil }
        return engine(at: directory)
    }
    #endif
    private var statePreparations: [URL: PrivateStateDirectorySequence] = [:]
    let dock = OperationDockProgress()
    lazy var transfers = ApplicationTransferQueue(coordinator: self)
    lazy var drives = ApplicationVolumeCoordinator(operations: self)
    @Published private(set) var volumeBarrierOwner: UUID?
    private let browsers = NSHashTable<BrowserViewController>.weakObjects()
    func register(_ browser: BrowserViewController) { browsers.add(browser) }
    var liveBrowsers: [BrowserViewController] { browsers.allObjects }
    /// Folder URL formatting is not a reason to leave a completed transfer
    /// invisible. This refresh is presentation only; it grants no file access.
    func reloadLocalDirectory(_ directory: URL) {
        guard directory.isFileURL else { return }
        for browser in liveBrowsers where browser.isViewLoaded && !browser.isBrowserSuspended {
            guard let current = browser.location.directoryURL, current.isFileURL,
                  current.path.utf8.elementsEqual(directory.path.utf8) else { continue }
            browser.loadLocation()
        }
    }
    var protectedStorageLocations: [URL] {
        Array(Set(engines.keys).union(liveBrowsers.compactMap(\.developmentStateDirectory))
            .union(liveBrowsers.compactMap { $0.privateNames.directory })
            .union(ApplicationSMBConnections.protectedStorageLocations).union(AppStorageLocations.protectedDirectories))
    }
    var canBeginVolumeBarrier: Bool {
        volumeBarrierOwner == nil && activeOwner == nil && preparationOwner == nil && copyPreviewOwner == nil
            && inspections.isEmpty && transfers.isIdleForVolumeAction
    }
    func beginVolumeBarrier(_ owner: UUID) -> Bool {
        guard canBeginVolumeBarrier else { return false }; volumeBarrierOwner = owner; return true
    }
    func finishVolumeBarrier(_ owner: UUID) {
        guard volumeBarrierOwner == owner else { return }
        volumeBarrierOwner = nil
        for browser in liveBrowsers where browser.isViewLoaded && !browser.isBrowserSuspended { browser.loadLocation() }
        transfers.startIfPossible()
    }

    func engine(at directory: URL) -> RecoverableFileOperations {
        let archiveQA = GeneratedArchiveDriveReview.archiveAdmitted
        let archiveFixturePhase: ArchiveFixturePhase? = switch GeneratedArchiveDriveReview.selection?.phase {
        case .archiveWarm: .warmForward
        case .archiveCold: .coldInverse
        default: nil
        }
        if GeneratedArchiveDriveReview.requested {
            guard archiveQA, directory == GeneratedArchiveDriveReview.selection?.journalDirectory else {
                fatalError("Archive/drive QA refused an unselected operation history")
            }
        }
        if let engine = engines[directory] { return engine }
        let engine: RecoverableFileOperations
        #if DEBUG
        let markedArchiveReview = ArchiveCreationVerification.markedSourceCaseAdmitted(at: directory)
        #else
        let markedArchiveReview = false
        #endif
        // Native ZIP Create and Copy retain their ordinary operation gates.
        // Eligible signed Preview and private beta share the qualified authored
        // policy. Original Update has its own reviewed admission; extraction
        // and received Download keep their independent gates.
        let zipMetadata: AuthoredZIPMetadataPolicy =
            archiveQA || markedArchiveReview || NativeLocalProtectionPolicy.authoredZIPCreateCopyAvailable
                ? .nativeCreate
                : GeneratedSandboxReview.admitted && !GeneratedSandboxReview.publicationOnlyReviewAdmitted
                    && !GeneratedSandboxReview.nativeTARCreateAdmitted
                    ? .exactSourceCloneQualification : .exactSource
        let downloadAdoption: DownloadAdoptionPolicy = !archiveQA && RemoteDownloadPublicationFeature.qualifiesSingleFileAdoption
            ? .sourceQualification : .held
        let publicDownload: ReceivedDownloadPublicQuarantinePolicy =
            !archiveQA && (RemoteDownloadPublicationFeature.qualifiesPublicQuarantineDownload
                || RemoteDownloadPublicationFeature.qualifiesSMBPublicQuarantineDownload
                )
            ? .sourceQualification : .held
        let zipOneFileExtraction: ZIPOneFilePublicExtractionPolicy =
            !archiveQA && ArchiveExtractionActivation.qualifiedZIPFileAvailable ? .sourceQualification : .held
        let receivedFolder: ReceivedFolderPublicQuarantinePolicy =
            !archiveQA && RemoteDownloadPublicationFeature.qualifiesPublicQuarantineFolderDownload ? .sourceQualification : .held
        let zipTree: ZIPTreePublicExtractionPolicy =
            !archiveQA && ArchiveExtractionActivation.qualifiesPublicZIPTree ? .sourceQualification : .held
        let tarTree: TARTreePublicExtractionPolicy =
            !archiveQA && ArchiveExtractionActivation.qualifiesPublicTARTree ? .sourceQualification : .held
        let tarFile: TAROneFilePublicExtractionPolicy =
            !archiveQA && ArchiveExtractionActivation.qualifiesPublicTARFile ? .sourceQualification : .held
        let zipOriginalUpdate: AuthoredZIPOriginalUpdateNativePolicy =
            archiveQA || NativeLocalProtectionPolicy.authoredZIPOriginalUpdateAvailable ? .qualifiedNativeStage : .held
        #if DEBUG
        let nativeTrashPolicy: NativeTrashMutationPolicy = nativeAnalyzerHistoryForVerification == directory
            ? .regularFilesAndDirectories : NativeLocalProtectionPolicy.trashPolicy
        #else
        let nativeTrashPolicy: NativeTrashMutationPolicy = archiveQA ? .held : NativeLocalProtectionPolicy.trashPolicy
        #endif
        let ordinaryHistory = AppStorageLocations.stateDirectory.map {
            $0.appendingPathComponent("operation-recovery", isDirectory: true).standardizedFileURL.path
                == directory.standardizedFileURL.path
        } == true
        let localTextRetirementPolicy: LocalTextRetirementPolicy = archiveQA ? .held
            : NativeLocalProtectionPolicy.localTextRetirementPolicy(ordinaryHistory: ordinaryHistory)
        let portableTAR: StrictPortableTARCreationPolicy
        if archiveQA || markedArchiveReview || GeneratedSandboxReview.nativeTARCreateAdmitted
            || NativeLocalProtectionPolicy.nativeTARCreateAvailable || TARArchiveEditingFeature.available {
            portableTAR = .nativeCreateQualification
        } else if AppFeatureAvailability.policy.edition == .development
                    && AppFeatureAvailability.allows(.tarCreation) && zipMetadata == .exactSource {
            portableTAR = .developmentExactSource
        } else { portableTAR = .held }
        let authoredPublicMark: NativeAuthoredCreatePublicMarkPolicy =
            archiveQA || markedArchiveReview || NativeLocalProtectionPolicy.nativeAuthoredCreatePublicMarkAvailable
                || TARArchiveEditingFeature.available
                ? .sourceQualification : .held
        let authoredUpdatePublicMark: NativeAuthoredUpdatePublicMarkPolicy = TARArchiveEditingFeature.available
            ? .sourceQualification : .held
        // The cold signed visit needs these native policies to recognize and
        // Undo committed updates. The fixture phase still rejects forward work.
        let tarOriginalUpdate: AuthoredTAROriginalUpdatePolicy = archiveQA || TARArchiveEditingFeature.available
            ? .developmentNativeStage : .held
        let tarGzipUpdate: AuthoredTARGzipOriginalUpdatePolicy = archiveQA || TARGzipEditingFeature.available
            ? .developmentNativeStage : .held
        let tarGzipCreate: TARGzipCreationPolicy = TARGzipCreationFeature.available ? .developmentNativeCreate : .held
        let tarBzip2Create: TARBzip2CreationPolicy = TARBzip2Feature.available ? .developmentNativeCreate : .held
        let tarBzip2Update: AuthoredTARBzip2OriginalUpdatePolicy = archiveQA || TARBzip2Feature.available
            ? .developmentNativeStage : .held
        let protectedNames = [directory.deletingLastPathComponent(),
                              directory.deletingLastPathComponent().appendingPathComponent("private-names", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("drive-protection", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("folder-views", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("smb-servers", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("smb-browsing", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("sftp-servers", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("sftp-upload-history", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("sftp-remote-actions", isDirectory: true),
                              directory.deletingLastPathComponent().appendingPathComponent("remote-downloads", isDirectory: true)]
            + AppStorageLocations.protectedDirectories
        if GeneratedSandboxReview.nativeAuthoredOriginalUpdateAdmitted {
            #if TRAVERSE_SFTP_EDITOR_QA
            engine = RecoverableFileOperations(journalDirectory: directory,
                qualifyingNativeZIPRetainedOriginalCheckpoint: GeneratedZIPRetainedCheckpoint.shared.afterRetainedOriginal,
                qualifiedCopyPreview: DevelopmentCopyPreviewQualification.scope,
                protecting: protectedNames, activity: ApplicationFileActivity.beginOperation,
                authoredZIPMetadataPolicy: zipMetadata, nativeTrashPolicy: nativeTrashPolicy)
            #else
            fatalError("unreachable generated qualification branch")
            #endif
        } else if let qa = additiveRootTrashQAEngine(at: directory, protecting: protectedNames) {
            engine = qa
        } else if GeneratedSandboxReview.v7DownloadAdmitted {
            #if TRAVERSE_SFTP_EDITOR_QA
            engine = RecoverableFileOperations(journalDirectory: directory,
                qualifyingAdoptionCheckpoint: GeneratedV7Checkpoint.shared.afterMove,
                qualifiedCopyPreview: DevelopmentCopyPreviewQualification.scope,
                protecting: protectedNames, activity: ApplicationFileActivity.beginOperation,
                authoredZIPMetadataPolicy: zipMetadata)
            #else
            fatalError("unreachable generated qualification branch")
            #endif
        } else if let preview = releasePreviewAdditiveRootEngine(at: directory, protecting: protectedNames,
                                                                 authoredZIPMetadataPolicy: zipMetadata,
                                                                 strictPortableTARCreationPolicy: portableTAR,
                                                                 nativeAuthoredCreatePublicMarkPolicy: authoredPublicMark,
                                                                 authoredZIPOriginalUpdateNativePolicy: zipOriginalUpdate,
                                                                 receivedDownloadPublicQuarantinePolicy: publicDownload,
                                                                 zipOneFilePublicExtractionPolicy: zipOneFileExtraction,
                                                                 receivedFolderPublicQuarantinePolicy: receivedFolder,
                                                                 zipTreePublicExtractionPolicy: zipTree,
                                                                 tarTreePublicExtractionPolicy: tarTree,
                                                                 tarOneFilePublicExtractionPolicy: tarFile) {
            engine = preview
        } else if !archiveQA, let scope = DevelopmentCopyPreviewQualification.scope {
            engine = RecoverableFileOperations(journalDirectory: directory, qualifiedCopyPreview: scope,
                protecting: protectedNames, activity: ApplicationFileActivity.beginOperation,
                authoredZIPMetadataPolicy: zipMetadata,
                strictPortableTARCreationPolicy: portableTAR,
                tarGzipCreationPolicy: tarGzipCreate,
                tarBzip2CreationPolicy: tarBzip2Create,
                nativeAuthoredCreatePublicMarkPolicy: authoredPublicMark,
                nativeAuthoredUpdatePublicMarkPolicy: authoredUpdatePublicMark,
                authoredZIPOriginalUpdateNativePolicy: zipOriginalUpdate,
                authoredTAROriginalUpdatePolicy: tarOriginalUpdate,
                authoredTARGzipOriginalUpdatePolicy: tarGzipUpdate,
                authoredTARBzip2OriginalUpdatePolicy: tarBzip2Update,
                downloadAdoptionPolicy: downloadAdoption,
                receivedDownloadPublicQuarantinePolicy: publicDownload,
                zipOneFilePublicExtractionPolicy: zipOneFileExtraction, tarOneFilePublicExtractionPolicy: tarFile,
                receivedFolderPublicQuarantinePolicy: receivedFolder, zipTreePublicExtractionPolicy: zipTree,
                tarTreePublicExtractionPolicy: tarTree,
                nativeTrashPolicy: nativeTrashPolicy,
                localTextRetirementPolicy: localTextRetirementPolicy)
        } else {
            engine = RecoverableFileOperations(journalDirectory: directory, protecting: protectedNames,
                activity: ApplicationFileActivity.beginOperation, authoredZIPMetadataPolicy: zipMetadata,
                strictPortableTARCreationPolicy: portableTAR,
                tarGzipCreationPolicy: tarGzipCreate,
                tarBzip2CreationPolicy: tarBzip2Create,
                nativeAuthoredCreatePublicMarkPolicy: authoredPublicMark,
                nativeAuthoredUpdatePublicMarkPolicy: authoredUpdatePublicMark,
                authoredZIPOriginalUpdateNativePolicy: zipOriginalUpdate,
                authoredTAROriginalUpdatePolicy: tarOriginalUpdate,
                authoredTARGzipOriginalUpdatePolicy: tarGzipUpdate,
                authoredTARBzip2OriginalUpdatePolicy: tarBzip2Update,
                downloadAdoptionPolicy: downloadAdoption, receivedDownloadPublicQuarantinePolicy: publicDownload,
                zipOneFilePublicExtractionPolicy: zipOneFileExtraction, tarOneFilePublicExtractionPolicy: tarFile,
                receivedFolderPublicQuarantinePolicy: receivedFolder, zipTreePublicExtractionPolicy: zipTree,
                tarTreePublicExtractionPolicy: tarTree,
                nativeTrashPolicy: nativeTrashPolicy,
                localTextRetirementPolicy: localTextRetirementPolicy,
                archiveFixtureRoot: archiveQA ? GeneratedArchiveDriveReview.selection?.fixtureRoot : nil,
                archiveFixturePhase: archiveFixturePhase)
        }
        engines[directory] = engine
        return engine
    }

    func ownsReleasePreviewAdditiveRootEngine(_ engine: RecoverableFileOperations) -> Bool {
        engines.contains { entry in
            entry.value === engine && OwnedTrashFeature.releasePreviewAdditiveRootEnabled(at: entry.key)
        }
    }

    private func releasePreviewAdditiveRootEngine(at directory: URL,
                                                  protecting locations: [URL],
                                                  authoredZIPMetadataPolicy: AuthoredZIPMetadataPolicy,
                                                  strictPortableTARCreationPolicy: StrictPortableTARCreationPolicy,
                                                  nativeAuthoredCreatePublicMarkPolicy: NativeAuthoredCreatePublicMarkPolicy,
                                                  authoredZIPOriginalUpdateNativePolicy: AuthoredZIPOriginalUpdateNativePolicy,
                                                  receivedDownloadPublicQuarantinePolicy: ReceivedDownloadPublicQuarantinePolicy,
                                                  zipOneFilePublicExtractionPolicy: ZIPOneFilePublicExtractionPolicy,
                                                  receivedFolderPublicQuarantinePolicy: ReceivedFolderPublicQuarantinePolicy,
                                                  zipTreePublicExtractionPolicy: ZIPTreePublicExtractionPolicy,
                                                  tarTreePublicExtractionPolicy: TARTreePublicExtractionPolicy,
                                                  tarOneFilePublicExtractionPolicy: TAROneFilePublicExtractionPolicy) -> RecoverableFileOperations? {
        #if MAC_EXPLORER_DISTRIBUTION
        return nil
        #else
        guard OwnedTrashFeature.releasePreviewAdditiveRootEnabled(at: directory) else { return nil }
        return RecoverableFileOperations(localPreviewAdditiveRootDirectoryTrashAt: directory,
            qualifiedCopyPreview: DevelopmentCopyPreviewQualification.scope,
            protecting: locations, activity: ApplicationFileActivity.beginOperation,
            authoredZIPMetadataPolicy: authoredZIPMetadataPolicy,
            strictPortableTARCreationPolicy: strictPortableTARCreationPolicy,
            nativeAuthoredCreatePublicMarkPolicy: nativeAuthoredCreatePublicMarkPolicy,
            authoredZIPOriginalUpdateNativePolicy: authoredZIPOriginalUpdateNativePolicy,
            receivedDownloadPublicQuarantinePolicy: receivedDownloadPublicQuarantinePolicy,
            zipOneFilePublicExtractionPolicy: zipOneFilePublicExtractionPolicy,
            tarOneFilePublicExtractionPolicy: tarOneFilePublicExtractionPolicy,
            receivedFolderPublicQuarantinePolicy: receivedFolderPublicQuarantinePolicy,
            zipTreePublicExtractionPolicy: zipTreePublicExtractionPolicy,
            tarTreePublicExtractionPolicy: tarTreePublicExtractionPolicy)
        #endif
    }

    private func additiveRootTrashQAEngine(at directory: URL, protecting locations: [URL]) -> RecoverableFileOperations? {
        #if TRAVERSE_SFTP_EDITOR_QA && TRAVERSE_OWNED_TRASH_ROOT_ADD_QA
        guard GeneratedSandboxReview.additiveRootTrashCaseAdmitted else { return nil }
        return RecoverableFileOperations(qualifyingAdditiveRootDirectoryTrashAt: directory,
            protecting: locations, activity: ApplicationFileActivity.beginOperation)
        #else
        return nil
        #endif
    }

    /// Explicit mutations only. Merely acquiring/inspecting an engine must
    /// never prepare, create or upgrade its state/history. Injected verification
    /// engines retain their existing generated-parent fixture contract.
    func prepareOperationState(for engine: RecoverableFileOperations) async throws {
        guard let entry = engines.first(where: { $0.value === engine }) else { return }
        let root = entry.key.deletingLastPathComponent()
        let preparation: PrivateStateDirectorySequence
        if let existing = statePreparations[root] { preparation = existing }
        else {
            preparation = try AppStoragePreparation.owner(for: root)
            statePreparations[root] = preparation
        }
        try await preparation.prepare()
    }

    func begin(owner: UUID, preparation: UUID? = nil) -> Bool {
        guard volumeBarrierOwner == nil, copyPreviewOwner == nil, activeOwner == nil, transfers.canRunExclusiveCommand,
              preparationOwner == nil || preparationOwner == preparation,
              drives.admitNewWork(fileSystemIDs: nil) else { return false }
        preparationOwner = nil
        activeOwner = owner
        return true
    }

    func beginPreparation(owner: UUID) -> Bool {
        guard volumeBarrierOwner == nil, copyPreviewOwner == nil, activeOwner == nil, preparationOwner == nil,
              transfers.canRunExclusiveCommand, drives.admitNewWork(fileSystemIDs: nil) else { return false }
        preparationOwner = owner
        return true
    }

    func finishPreparation(owner: UUID) {
        guard preparationOwner == owner else { return }
        preparationOwner = nil
        transfers.startIfPossible()
        drives.workDidChange()
    }

    func finish(owner: UUID) {
        guard activeOwner == owner else { return }
        ApplicationStorageAnalysis.shared.clearCachedSummaries()
        dock.restore()
        activeOwner = nil
        transfers.startIfPossible()
        drives.workDidChange()
    }

    func beginInspection() -> UUID? {
        guard volumeBarrierOwner == nil, copyPreviewOwner == nil else { return nil }
        let token = UUID(); inspections.insert(token); inspectionCount = inspections.count; return token
    }
    func finishInspection(_ token: UUID) { inspections.remove(token); inspectionCount = inspections.count; drives.workDidChange() }

    func beginCopyPreview(owner: UUID) -> Bool {
        guard volumeBarrierOwner == nil, !drives.isBusy, copyPreviewOwner == nil, activeOwner == nil, preparationOwner == nil,
              inspections.isEmpty, transfers.isIdleForCopyPreview,
              engines.values.allSatisfy(\.isIdleForCopyPreview) else { return false }
        copyPreviewStopRequested = false; copyPreviewAwaitingChoice = false; copyPreviewOwner = owner; return true
    }
    func finishCopyPreview(owner: UUID) {
        guard copyPreviewOwner == owner else { return }
        copyPreviewOwner = nil; copyPreviewStopRequested = false; copyPreviewAwaitingChoice = false; transfers.startIfPossible()
        drives.workDidChange()
    }

    func setCopyPreviewAwaitingChoice(_ value: Bool, owner: UUID) {
        guard copyPreviewOwner == owner else { return }
        copyPreviewAwaitingChoice = value
    }

    func cancelCopyPreviewSetup(settings: BrowserSettings) {
        guard copyPreviewOwner != nil, let copyPreviewTask, !copyPreviewStopRequested else { return }
        copyPreviewStopRequested = true
        settings.copyPreviewStatus = "Stopping setup… Waiting for the current macOS or disk request to finish."
        copyPreviewTask.cancel()
    }

    func watchCopyPreviewDelay(owner: UUID, settings: BrowserSettings, delay: Duration = .seconds(2)) -> Task<Void, Never> {
        Task { [weak self] in
            while true {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.copyPreviewOwner == owner, !self.copyPreviewStopRequested else { return }
                if self.copyPreviewAwaitingChoice { continue }
                settings.copyPreviewStatus = "Waiting for macOS or the disk… Respond to any folder-access prompt. Cancel Setup stops after the current system request finishes."
                return
            }
        }
    }
}

/// A running-app tile built using public NSDockTile.contentView/display. The
/// original view and icon remain intact; no installation overlay or private API.
@MainActor
final class OperationDockProgress {
    private var previousView: NSView?
    private var tileView: OperationDockTileView?
    private var lastDisplay: TimeInterval = -.infinity
    var isVisible: Bool { tileView != nil }

    func update(_ presentation: OperationProgressPresentation, enabled: Bool) {
        guard enabled, !presentation.terminal else { restore(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard tileView == nil || now - lastDisplay >= 0.25 else { return }
        let tile = NSApplication.shared.dockTile
        if tileView == nil {
            previousView = tile.contentView
            let view = OperationDockTileView(frame: NSRect(origin: .zero, size: tile.size))
            view.autoresizingMask = [.width, .height]
            view.icon = NSApplication.shared.applicationIconImage
            tileView = view
            tile.contentView = view
        }
        tileView?.presentation = presentation
        tileView?.needsDisplay = true
        tile.display()
        lastDisplay = now
    }

    func restore() {
        guard tileView != nil else { return }
        let tile = NSApplication.shared.dockTile
        // Restore only our view; do not replace another owner of the Dock tile.
        if tile.contentView === tileView { tile.contentView = previousView; tile.display() }
        tileView = nil
        previousView = nil
        lastDisplay = -.infinity
    }
}

@MainActor
private final class OperationDockTileView: NSView {
    var icon: NSImage?
    var presentation: OperationProgressPresentation?

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        guard let presentation else { return }
        let bar = NSRect(x: bounds.width * 0.12, y: bounds.height * 0.10,
                         width: bounds.width * 0.76, height: max(7, bounds.height * 0.075))
        let shape = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
        NSColor.black.withAlphaComponent(0.8).setFill(); shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let fraction = presentation.boundedPercentage {
            NSColor.systemBlue.setFill()
            NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height).fill()
        } else {
            // Static unknown-total indication respects Reduce Motion.
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSRect(x: bar.minX + bar.width * 0.35, y: bar.minY, width: bar.width * 0.3, height: bar.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.85).setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}
