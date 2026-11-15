import AppKit
import Combine
import ExplorerCore
import FileOperations
import LocalStorage
import SwiftUI

enum ArchiveExtractionActivation {
    static var wholeArchiveAvailable: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.archivePublicAccessAdmitted || GeneratedSandboxReview.archivePromiseAdmitted || GeneratedSandboxReview.archiveInternalAdmitted
        #else
        // Whole and multi-root extraction publish one v16 wrapper tree. The
        // legacy presentation gate cannot select an unqualified producer.
        qualifiesPublicZIPTree && qualifiesPublicTARTree
        #endif
    }
    /// One ZIP file uses v15; trees and TAR files have independent contracts.
    /// Neither direct extraction capability admits clipboard or native promises.
    static var qualifiedZIPFileAvailable: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.zipOneFileExtractionAdmitted || GeneratedSandboxReview.archivePublicAccessAdmitted || GeneratedSandboxReview.archivePromiseAdmitted || GeneratedSandboxReview.archiveInternalAdmitted
        #else
        AppFeatureAvailability.allows(.archiveSingleFileExtraction)
        #endif
    }
    static var available: Bool { wholeArchiveAvailable || qualifiedZIPFileAvailable }
    static var limitsToSingleZIPFile: Bool { !wholeArchiveAvailable && qualifiedZIPFileAvailable }
    static var qualifiesPublicTARTree: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.archivePublicAccessAdmitted || GeneratedSandboxReview.archiveInternalAdmitted
        #else
        AppFeatureAvailability.allows(.archiveTARTreeExtraction)
        #endif
    }
    static var qualifiesPublicTARFile: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.archivePublicAccessAdmitted || GeneratedSandboxReview.archiveInternalAdmitted
        #else
        AppFeatureAvailability.allows(.archiveTARSingleFileExtraction)
        #endif
    }
    static var qualifiesPublicZIPTree: Bool {
        #if TRAVERSE_SFTP_EDITOR_QA
        GeneratedSandboxReview.archivePublicAccessAdmitted || GeneratedSandboxReview.archivePromiseAdmitted || GeneratedSandboxReview.archiveInternalAdmitted
        #else
        AppFeatureAvailability.allows(.archiveZIPTreeExtraction)
        #endif
    }
}

enum ArchivePaneDestinationActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-archive-pane-destination")
        #else
        enabled
        #endif
    }
}

@MainActor final class ArchiveExtractionModel: ObservableObject, ArchiveAutomaticActionModel {
    enum Presentation { case extract, direct, paste }
    @Published var name: String { didSet { if !installingAutomaticName && !oldValue.utf8.elementsEqual(name.utf8) { requestPreview() } } }
    @Published private(set) var parent: URL
    @Published private(set) var plan: ArchiveWritePlan?
    @Published private(set) var summary: (files: Int, folders: Int, bytes: UInt64)?
    @Published private(set) var isPreparing = false
    @Published private(set) var isChoosing = false
    @Published private(set) var isRunning = false
    @Published private(set) var outcome: RecoverableOperationResult?
    @Published private(set) var undoOutcome: RecoverableOperationResult?
    @Published private(set) var notice = "Checking the archive and destination…"
    let source: URL, settings: BrowserSettings
    let members: ZIPExtractionSelection?
    private let zipRoot: ZIPRootExportSelection?
    private(set) var tarMembers:TARExtractionSelection?
    let selectedCount: Int?
    private let isTARExtraction: Bool
    private let ownsWholeTARSelection: Bool
    var selectedExtraction:Bool { selectedCount != nil }
    let isFileExtraction: Bool
    let presentation: Presentation
    var title: String {
        if presentation == .paste { return "Paste from \(isTARExtraction ? "TAR" : "ZIP")" }
        if isFileExtraction { return "Extract File" }
        if zipRoot != nil || tarMembers?.singleFolderName != nil { return "Extract Folder" }
        return selectedExtraction ? "Extract Selected to New Folder" : "Extract to New Folder"
    }
    var actionTitle: String { presentation == .paste ? "Paste" : "Extract" }
    var undoTitle: String { presentation == .paste ? "Undo Paste" : "Undo Extraction" }
    var explanation:String {
        if isFileExtraction {
            return "Places this file directly in the chosen folder and keeps the archive unchanged. Existing items are never replaced."
        }
        if zipRoot != nil || tarMembers?.singleFolderName != nil {
            return "Copies this folder and its contents directly into the chosen folder. The archive and existing items stay unchanged."
        }
        if isTARExtraction {
            return selectedExtraction ? "Copies \(selectedCount ?? 0) selected items into a new folder, keeping their archive paths and download-security information. Other files stay in the archive. Links and archived permissions aren’t restored."
                : "Copies this archive into a new folder and preserves its download-security information. Links and archived permissions aren’t restored. The original archive stays unchanged."
        }
        return members == nil ? "Creates files and folders with verified contents and preserves existing download-security information. Archive permissions, links and other extended metadata are not restored. Nothing is indexed."
            : "Extracts \(members?.count ?? 0) selected \(members?.count == 1 ? "item" : "items"), keeping their archive paths and download-security information. Other payloads remain packed. Links and other extended metadata are not restored. Nothing is indexed."
    }
    weak var window: NSWindow?
    private weak var browser: BrowserViewController?
    private let engine: RecoverableFileOperations
    private let coordinator: ApplicationOperationCoordinator
    private let chooser = FolderAccessController(stateDirectory: nil)
    private var customPicker: AnalysisFolderPickerController?
    private var generation = UUID(), pending = false, closed = false, undoAttempted = false
    private var debouncesPreview = true
    private var automaticNameRequested = false, installingAutomaticName = false
    private let initiatingTab: UUID, initiatingVisit: UUID
    private let initiatingDirectory: URL?
    private var ownedTARReader: TARArchiveReader?
    private var ownedTARSession: TARArchiveSession?
    private var sourcePreparationWork: Task<TARArchiveSession, Error>?
    private var preparation: UUID?
    private var observation: FileOperationSelection?
    private var lifetime: FileAccessLifetimes?
    private var destinationAccess: FileAccessLifetimes?
    private var destinationObservation: FileOperationSelection?
    private var incomingSourceAccess: FileAccessLifetimes?
    private var prepareWork: Task<Void, Never>?, previewWork: Task<ArchiveWritePlan, Error>?
    private var choiceWork: Task<Void, Never>?, runningWork: Task<Void, Never>?
    private var changes: AnyCancellable?
    private var windowChanges: AnyCancellable?
    var openPaneDestinations: [LocalPaneDestination] {
        guard ArchiveExtractionActivation.wholeArchiveAvailable,
              ArchivePaneDestinationActivation.available, let browser else { return [] }
        return LocalPaneDestination.available(from: browser)
    }
    var canReview: Bool { !closed && !isPreparing && !isChoosing && !isRunning && outcome == nil && coordinator.activeOwner == nil && coordinator.preparationOwner == nil && coordinator.transfers.canRunExclusiveCommand && !ApplicationFileActivity.gate.isClosed }
    var canExtract: Bool { canReview && plan != nil }
    let offersAutomaticPaste: Bool
    var canUndo: Bool { !closed && !isRunning && !undoAttempted && outcome?.result.disposition == .succeeded && outcome?.recordID != nil && browser?.canRunExclusiveFileCommand == true }
    var canViewResults: Bool { !isRunning && outcome?.recordID != nil && browser?.canRunExclusiveFileCommand == true }
    #if DEBUG
    var undoAttemptedForVerification: Bool { undoAttempted }
    var destinationAcquiredForQualification: (() async -> Void)?
    #endif
    #if TRAVERSE_SFTP_EDITOR_QA
    private(set) var previewFailureForQualification: DiagnosticErrorCode?
    #endif
    init(source: URL, browser: BrowserViewController, engine: RecoverableFileOperations, members: ZIPExtractionSelection? = nil,
         tarMembers:TARExtractionSelection?=nil, zipRoot: ZIPRootExportSelection? = nil,
         destination: ArchiveExtractionDestination? = nil, sourceAccess: FileAccessLifetimes? = nil,
         presentation: Presentation = .extract) {
        self.source = source; parent = destination?.directory ?? source.deletingLastPathComponent()
        self.presentation = presentation
        initiatingTab = browser.activeID; initiatingVisit = browser.sessionID
        initiatingDirectory = browser.location.directoryURL
        destinationAccess = destination?.access; destinationObservation = destination?.observation; incomingSourceAccess = sourceAccess
        precondition(members==nil || tarMembers==nil)
        precondition(zipRoot == nil || members == nil && tarMembers == nil)
        let extractedName = zipRoot?.name ?? tarMembers?.singleFileName ?? tarMembers?.singleFolderName
        // Capture the preference with the committed Paste/drop gesture. A
        // later Settings change applies to the next gesture, not this owner.
        offersAutomaticPaste = presentation == .paste && destination != nil && extractedName != nil
            && !browser.settings.alwaysReviewArchiveCopies
        isFileExtraction = zipRoot?.kind == .file || tarMembers?.singleFileName != nil
        let base = ArchiveActionNames.extractionFolder(for: source)
        name = extractedName ?? base + (members != nil || tarMembers?.isWholeArchive == false ? " Selected":"")
        self.members = members
        self.zipRoot = zipRoot
        self.tarMembers=tarMembers
        isTARExtraction = tarMembers != nil || ArchiveActionNames.isTAR(source)
        ownsWholeTARSelection = tarMembers == nil && ArchiveActionNames.isTAR(source)
        selectedCount = zipRoot != nil ? 1 : tarMembers.map { $0.isWholeArchive ? nil : $0.count } ?? members?.count
        self.browser = browser; self.engine = engine; coordinator = browser.operationCoordinator; settings = browser.settings
        changes = Publishers.Merge(coordinator.objectWillChange, coordinator.transfers.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
        windowChanges = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func requestPreview() {
        requestPreview(debounced: true)
    }
    private func requestPreview(debounced: Bool) {
        guard !closed, !isRunning, outcome == nil else { return }
        guard !isTARExtraction || tarMembers != nil || ownsWholeTARSelection else {
            notice = "Reopen the archive and choose the items to extract again."; return
        }
        generation = UUID(); pending = true; debouncesPreview = debounced; plan = nil; summary = nil; previewWork?.cancel(); sourcePreparationWork?.cancel()
        #if TRAVERSE_SFTP_EDITOR_QA
        previewFailureForQualification = nil
        #endif
        notice = "Checking the archive and destination…"
        if prepareWork == nil { prepareWork = Task { [self] in await previewLoop() } }
    }
    /// Await the existing preparation owner, including its lease release. A
    /// valid Paste/drop handoff is the gesture; its clipboard/drag can end now.
    func prepareAutomaticPaste() async -> Bool {
        guard offersAutomaticPaste else { return false }
        return await prepareAutomaticAction()
    }
    var offersAutomaticAction: Bool { offersAutomaticPaste || presentation == .direct }
    var automaticActionCanSubmit: Bool {
        guard !closed, let browser, !browser.isBrowserSuspended, browser.recoverableFileOperations === engine else { return false }
        return presentation != .direct || browser.activeID == initiatingTab && browser.sessionID == initiatingVisit
    }
    var automaticActionShouldReveal: Bool {
        guard !closed, let browser, !browser.isBrowserSuspended, browser.recoverableFileOperations === engine else { return false }
        return presentation != .direct || browser.activeID == initiatingTab && browser.location.directoryURL == initiatingDirectory
    }
    var automaticActionSucceeded: Bool { outcome?.result.disposition == .succeeded }
    func prepareAutomaticAction() async -> Bool {
        guard offersAutomaticAction, automaticActionCanSubmit else { return false }
        automaticNameRequested = presentation == .direct
        requestPreview(debounced: false)
        let token = generation
        if let prepareWork { await prepareWork.value }
        return !Task.isCancelled && !closed && token == generation
            && automaticActionCanSubmit && browser?.canStartArchiveExtraction == true && canExtract
    }
    func performAutomaticAction() { extract() }
    func waitForOperation() async { if let runningWork { await runningWork.value } }
    private func previewLoop() async {
        isPreparing = true
        defer { prepareWork = nil; previewWork = nil; isPreparing = false; releasePreparation() }
        while !closed, pending {
            pending = false; let token = generation, chosenParent = parent, chosenName = name, chosenAccess = destinationAccess,
                chosenObservation = destinationObservation
            let choosesAutomaticName = automaticNameRequested
            automaticNameRequested = false
            if debouncesPreview { try? await Task.sleep(for: .milliseconds(160)) }
            guard token == generation else { continue }
            let owner = UUID()
            guard let browser, !browser.isBrowserSuspended, coordinator.beginPreparation(owner: owner) else {
                notice = "Finish other file work, then choose Review Again."; continue
            }
            preparation = owner
            let sourceAccess = await browser.accessLifetime(for: [source, chosenParent])
            let parentAccess = await chooser.acquireAccess(to: chosenParent)
            let access = FileAccessLifetimes(leases: sourceAccess.leases + (incomingSourceAccess?.leases ?? [])
                + (parentAccess.map { [$0] } ?? []) + (chosenAccess?.leases ?? []))
            do {
                guard !closed, token == generation, !Task.isCancelled else { throw CancellationError() }
                let outputName: String
                if choosesAutomaticName {
                    outputName = try await LocalAvailableName.available(in: chosenParent, preferredName: chosenName)
                    guard !closed, token == generation, automaticActionCanSubmit else { throw CancellationError() }
                    installingAutomaticName = true; name = outputName; installingAutomaticName = false
                } else { outputName = chosenName }
                if observation == nil { observation = try await engine.observeSelection([source]) }
                guard !closed, token == generation, let observation else { releasePreparation(); continue }
                if ownsWholeTARSelection {
                    await closeOwnedTAR()
                    guard !closed, token == generation, !Task.isCancelled else { throw CancellationError() }
                    let reader = ApplicationCompressedArchives.shared.reader(excluding:
                        (browser.developmentStateDirectory.map { [$0] } ?? []) + AppStorageLocations.protectedDirectories)
                    ownedTARReader = reader
                    let compressed = source.lastPathComponent.lowercased().hasSuffix(".gz") || source.pathExtension.lowercased() == "tgz"
                    let work = Task { [source] in
                        try await ArchiveMetadataAdmission.shared.withAdmission {
                            if compressed {
                                try await ApplicationCompressedArchives.shared.prepareStorage()
                                return try await reader.prepareCompressed(source, retaining: access,
                                    publicQuarantineSource: ArchiveExtractionActivation.qualifiesPublicTARFile
                                        || ArchiveExtractionActivation.qualifiesPublicTARTree)
                            }
                            return try await reader.open(source, retaining: access)
                        }
                    }
                    sourcePreparationWork = work
                    let opened = try await work.value
                    sourcePreparationWork = nil
                    guard !closed, token == generation, !Task.isCancelled else {
                        await opened.close(); await reader.drain(); releasePreparation(); continue
                    }
                    ownedTARSession = opened
                    tarMembers = try await opened.selectionForWholeExtraction()
                }
                guard !closed, token == generation else { releasePreparation(); continue }
                let work = Task { [engine, source, members, tarMembers, zipRoot] () async throws -> ArchiveWritePlan in
                    if ArchiveExtractionActivation.limitsToSingleZIPFile, zipRoot?.kind != .file {
                        throw FileOperationFailure.unsupported
                    }
                    if let zipRoot {
                        let destination = zipRoot.kind == .file
                            ? try await engine.checkReceivedFileDestination(parent: chosenParent, name: outputName, observing: chosenObservation)
                            : try await engine.checkReceivedDirectoryDestination(parent: chosenParent, name: outputName, observing: chosenObservation)
                        return .export(try await ZIPRootExtractionPreparation.prepare(zipRoot, engine: engine,
                            parent: chosenParent, name: outputName, observing: destination,
                            publicFile: ArchiveExtractionActivation.qualifiedZIPFileAvailable,
                            publicTree: ArchiveExtractionActivation.qualifiesPublicZIPTree))
                    }
                    if let tarMembers {
                        if tarMembers.singleFileName != nil {
                            let destination = try await engine.checkReceivedFileDestination(parent: chosenParent,
                                name: outputName, observing: chosenObservation)
                            if ArchiveExtractionActivation.qualifiesPublicTARFile {
                                return .extractFile(try await engine.prepareTARFilePublicExtraction(tarMembers,
                                    parent: chosenParent, name: outputName, observing: destination))
                            }
                            return .extractFile(try await engine.prepareTARFileExtraction(tarMembers, parent: chosenParent,
                                name: outputName, observing: destination))
                        }
                        return .extract(try await engine.prepareTARExtraction(source: source, parent: chosenParent,
                            name: outputName, observing: observation, members: tarMembers, observingParent: chosenObservation,
                            directly: tarMembers.singleFolderName != nil,
                            publicQuarantineTreeV16: ArchiveExtractionActivation.qualifiesPublicTARTree))
                    }
                    return .extract(try await engine.prepareZIPExtraction(source: source, parent: chosenParent, name: outputName, observing: observation,
                        members: members, observingParent: chosenObservation,
                        publicQuarantineTreeV16: ArchiveExtractionActivation.qualifiesPublicZIPTree))
                }
                previewWork = work
                let prepared = try await work.value
                guard !closed, token == generation else { releasePreparation(); continue }
                lifetime = access; plan = prepared; summary = (prepared.files, prepared.folders, prepared.logicalBytes)
                notice = "Ready to \(actionTitle.lowercased()) “\(prepared.destination.lastPathComponent)”."
            } catch {
                sourcePreparationWork = nil
                if !closed, token == generation {
                    #if TRAVERSE_SFTP_EDITOR_QA
                    previewFailureForQualification = DiagnosticErrors.project(error)
                    #endif
                    if selectedExtraction && ((error as? FileOperationFailure) == .sourceChanged || (error as? ZIPArchiveFailure) == .changed || (error as? TARArchiveFailure) == .changed) {
                        notice = "The archive changed. Close this review, refresh its directory and select the items again."
                    } else { notice = Self.message(error) }
                }
            }
            previewWork = nil; releasePreparation(); withExtendedLifetime(access) {}
        }
    }
    func reviewAgain() {
        guard canReview else { return }
        observation = nil; lifetime = nil; requestPreview()
    }
    func chooseDestination() {
        guard canReview, let browser, let window, window.attachedSheet == nil else { return }
        isChoosing = true
        choiceWork = Task { [self] in
            defer { choiceWork = nil; isChoosing = false }
            let selected: URL?
            if settings.analysisFolderPicker == .system {
                selected = await chooser.chooseFolder(in: window, initialDirectory: parent)?.selection.url
            } else {
                let model = AnalysisFolderPickerModel(initialDirectory: parent, volumes: browser.volumes,
                    access: chooser, showsHidden: settings.showsHiddenFiles)
                let picker = AnalysisFolderPickerController(model: model, settings: settings, style: settings.analysisFolderPicker,
                    title: "Choose Extraction Destination")
                customPicker = picker; selected = await picker.choose(in: window); customPicker = nil
            }
            guard !closed, !Task.isCancelled, let selected else { return }
            destinationAccess = nil; destinationObservation = nil; parent = selected; requestPreview()
        }
    }
    func chooseDestination(_ destination: LocalPaneDestination) {
        guard ArchivePaneDestinationActivation.available, canReview, let browser,
              let peer = destination.currentBrowser(from: browser) else {
            notice = "That pane changed. Choose its current folder again."; return
        }
        let token = generation
        isChoosing = true
        choiceWork = Task { [self, peer] in
            defer { choiceWork = nil; isChoosing = false }
            let access = await peer.accessLifetime(for: [destination.directory])
            #if DEBUG
            if let destinationAcquiredForQualification { await destinationAcquiredForQualification() }
            #endif
            guard !closed, !Task.isCancelled else { return }
            guard generation == token, destination.currentBrowser(from: browser) === peer else {
                notice = "That pane changed. Choose its current folder again."; return
            }
            destinationAccess = access; destinationObservation = nil; parent = destination.directory; requestPreview()
        }
    }
    func extract() {
        guard canExtract, let browser, !browser.isBrowserSuspended, let plan, browser.recoverableFileOperations === engine,
              browser.operationTask == nil,
              browser.startOperationPresentation(presentation == .paste ? "Pasting from archive…" : "Extracting archive…") else { return }
        let action = presentation == .paste ? "Pasting" : "Extracting"
        isRunning = true; self.plan = nil; notice = "\(action) and verifying the \(isFileExtraction ? "file" : "new folder")…"
        let access = lifetime
        let work = Task { [self, browser] in
            defer { runningWork = nil; isRunning = false; browser.finishOperationPresentation(); withExtendedLifetime(access) {}; if closed { lifetime = nil } }
            do {
                try await coordinator.prepareOperationState(for: engine); try Task.checkCancellation()
                let result = await plan.perform(using: engine, progress: browser.operationProgressSink)
                outcome = result.recordID == nil && result.result.disposition != .succeeded ? nil : result
                // Once the engine has returned a durable outcome, Undo uses
                // that output/history. The review no longer needs spool data.
                if outcome != nil { tarMembers = nil }
                let verb = presentation == .paste ? "Pasted" : "Extracted"
                notice = result.result.disposition == .succeeded ? "\(verb) “\(plan.destination.lastPathComponent)”. The archive is unchanged."
                    : result.recordID != nil ? "\(actionTitle) did not finish. Retained work is protected; View Results shows the exact operation."
                    : OperationResultDescription(result: result.result).summary
                publish(result, browser: browser)
            } catch { notice = error is CancellationError ? "Stopped before \(action.lowercased()). No output was created." : Self.message(error) }
        }
        runningWork = work; browser.operationTask = work
    }
    func undo() {
        guard canUndo, let browser, let id = outcome?.recordID, browser.recoverableFileOperations === engine,
              browser.startOperationPresentation(presentation == .paste ? "Undoing Paste…" : "Undoing archive extraction…") else { return }
        undoAttempted = true; isRunning = true; notice = isFileExtraction ? "Checking the extracted file before Undo…" : "Checking the extracted folder before Undo…"
        let access = lifetime
        let work = Task { [self, browser] in
            defer { runningWork = nil; isRunning = false; browser.finishOperationPresentation(); withExtendedLifetime(access) {}; if closed { lifetime = nil } }
            let result = await engine.undo(recordID: id, progress: browser.operationProgressSink); undoOutcome = result
            notice = result.result.disposition == .succeeded ? "Extraction undone. Its unchanged output is retained in recovery; the archive is untouched."
                : "Undo could not finish. Changed or uncertain items are preserved; View Results has the details."
            publish(result, browser: browser, afterUndo: true)
        }
        runningWork = work; browser.operationTask = work
    }
    func stop() {
        if isRunning { browser?.cancelFileOperation(nil) }
        else if isPreparing {
            generation = UUID(); pending = false; previewWork?.cancel(); sourcePreparationWork?.cancel(); prepareWork?.cancel()
            plan = nil; summary = nil; notice = "Stopped. The archive is unchanged."
        }
    }
    func viewResults() { if canViewResults, let id = outcome?.recordID { browser?.openOperationRecovery(recordID: id) } }
    func openFolder() {
        guard !isRunning, undoOutcome == nil, outcome?.result.disposition == .succeeded,
              let destination = outcome?.result.items.first?.destination, let browser, !browser.isBrowserSuspended else { return }
        browser.navigate(to: .directory(isFileExtraction ? destination.deletingLastPathComponent() : destination))
        if isFileExtraction { browser.tabs[browser.activeIndex].state.selection = [destination] }
        browser.view.window?.makeKeyAndOrderFront(nil)
    }
    func closeAndDrain() async {
        // Closing the presentation keeps an accepted operation owned until it
        // finishes. Stop is the explicit cancellation action, as for Extract.
        closed = true; generation = UUID(); pending = false; previewWork?.cancel(); sourcePreparationWork?.cancel(); prepareWork?.cancel()
        customPicker?.cancel(); chooser.invalidatePendingRequests(); choiceWork?.cancel()
        if let prepareWork { await prepareWork.value }; if let choiceWork { await choiceWork.value }
        if let runningWork { await runningWork.value }
        releasePreparation(); lifetime = nil; destinationAccess = nil; destinationObservation = nil; incomingSourceAccess = nil; observation = nil; plan = nil
        tarMembers = nil // A compressed selection owns its private spool lease.
        await closeOwnedTAR()
    }
    private func closeOwnedTAR() async {
        guard ownsWholeTARSelection else { return }
        tarMembers = nil
        if let ownedTARSession { await ownedTARSession.close(); self.ownedTARSession = nil }
        if let ownedTARReader { await ownedTARReader.drain(); self.ownedTARReader = nil }
    }
    private func releasePreparation() { if let preparation { coordinator.finishPreparation(owner: preparation); self.preparation = nil } }
    private func publish(_ result: RecoverableOperationResult, browser: BrowserViewController, afterUndo: Bool = false) {
        browser.lastOperationResult = result.result; browser.lastRecoveryRecordID = result.recordID; browser.lastRecoveryAction = nil
        browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
        browser.status.stringValue = OperationResultDescription(result: result.result).summary; browser.operationResultsButton.isHidden = false
        for current in coordinator.liveBrowsers where !current.isBrowserSuspended {
            if afterUndo, result.result.disposition == .succeeded, let extracted = outcome?.result.items.first?.destination,
               let location = current.location.directoryURL,
               location.path == extracted.path || location.path.hasPrefix(extracted.path + "/") { current.navigate(to: .directory(parent)) }
            else if current.location.directoryURL == parent { current.loadLocation() }
        }
        browser.inspectOperationRecovery()
    }
    static func message(_ error: Error) -> String {
        if error is LocalAvailableName.Failure { return ArchiveCreationModel.message(error) }
        if error is TARArchiveFailure{return TARBrowserModel.message(error)}
        if let failure = error as? ZIPExtractionFailure {
            return failure == .quarantinedOrUncertain ? "This archive’s download-security information could not be preserved safely. The source was left unchanged. Use Open With → Archive Utility."
                : "This source or destination is outside the currently qualified extraction scope. Use a local APFS location."
        }
        if let failure = error as? FileOperationFailure { return failure.userMessage }
        return ArchiveBrowserModel.message(error)
    }
}

private struct ArchiveExtractionView: View {
    @ObservedObject var model: ArchiveExtractionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").interfaceFont(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).interfaceFont(.title2.weight(.semibold))
                    Text(model.source.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).help(model.source.path)
                }
                Spacer(); if model.isPreparing || model.isRunning { ProgressView().controlSize(.small) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField(model.isFileExtraction ? "File name" : "New folder name", text: $model.name).textFieldStyle(ToolTextEntryStyle())
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Destination").interfaceFont(.caption).foregroundStyle(.secondary)
                        Text(model.parent.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            .toolPageEntrance(model.parent, enabled: model.settings.motion.allows(.pages), mode: model.settings.motion.mode)
                            .help(model.parent.path)
                    }
                    Spacer()
                    let destinations = model.openPaneDestinations
                    if !destinations.isEmpty {
                        Menu {
                            ForEach(destinations) { destination in
                                Button(destination.title) { model.chooseDestination(destination) }.help(destination.directory.path)
                            }
                        } label: { Label("Use Open Pane", systemImage: "rectangle.split.2x1") }
                            .disabled(!model.canReview)
                            .help("Choose a local folder already open in another pane. Review it before extracting.")
                    }
                    Button("Choose Folder…", action: model.chooseDestination).disabled(!model.canReview).fixedSize()
                }
                Text(model.summary.map { summary in
                    model.isFileExtraction ? ArchiveBrowserModel.size(summary.bytes)
                        : "\(model.selectedExtraction ? "Selection":"Archive") contains \(summary.files.formatted()) files · \(summary.folders.formatted()) folders · \(ArchiveBrowserModel.size(summary.bytes))"
                } ?? " ")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                    .frame(minHeight: 16, alignment: .leading).accessibilityHidden(model.summary == nil)
            }.disabled(model.isRunning || model.outcome != nil || model.isChoosing)
            Text(model.notice).interfaceFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Text(model.explanation)
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ArchiveReviewFooter(showsCompleted: !model.isRunning && model.outcome != nil) {
                Button("View Results…", action: model.viewResults).disabled(!model.canViewResults)
                Button(model.undoTitle, action: model.undo).disabled(!model.canUndo)
                if model.undoOutcome == nil, model.outcome?.result.disposition == .succeeded {
                    Button(model.isFileExtraction ? "Show in Explorer" : "Open Folder", action: model.openFolder)
                }
            } auxiliary: {
                if model.isRunning || model.isPreparing { Button("Stop", action: model.stop) }
                else if model.outcome == nil, model.plan == nil, !model.isPreparing {
                    Button("Review Again", action: model.reviewAgain).disabled(!model.canReview)
                }
            } primary: {
                Button(model.outcome == nil && !model.isRunning ? "Cancel" : "Close") { model.window?.performClose(nil) }
                    .keyboardShortcut(.cancelAction)
                    .help(model.isRunning ? "Close this window and keep copying. Use Stop to cancel the operation." : "Close this review.")
                if !model.isRunning, model.outcome == nil {
                    Button(model.actionTitle, action: model.extract).disabled(!model.canExtract).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(22).frame(minWidth: 620, minHeight: model.selectedExtraction ? 460 : 440)
    }
}
@MainActor final class ArchiveExtractionWindowController: NSWindowController, NSWindowDelegate {
    let model: ArchiveExtractionModel
    var onClose: (() -> Void)?
    init(model: ArchiveExtractionModel) {
        self.model = model
        let viewport = ToolWindowChrome.initialViewport(
            size: .init(width: 700, height: model.selectedExtraction ? 520 : 500),
            minimum: .init(width: 650, height: model.selectedExtraction ? 480 : 460),
            scale: model.settings.interfaceSize.scale)
        let window = ToolWindowChrome.makeWindow(title: model.title,
            size: viewport.size, minimumSize: viewport.minimum,
            content: InterfaceHostingController(rootView: ArchiveExtractionView(model: model)))
        super.init(window: window); window.delegate = self; model.window = window
        ToolWindowChrome.install(in: window, settings: model.settings)
        window.contentMinSize = viewport.minimum
        window.setContentSize(viewport.size)
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
@MainActor final class ApplicationArchiveExtraction {
    static let shared = ApplicationArchiveExtraction()
    private(set) var controller: ArchiveExtractionWindowController?
    private var retirement: Task<Void, Never>?
    private var automaticAction: Task<Void, Never>?
    var canAcceptPreparedSelection: Bool { controller == nil && retirement == nil && automaticAction == nil }
    @discardableResult func showSelection(source: URL, from browser: BrowserViewController, selection: ArchivePreparedSelection,
        destination: ArchiveExtractionDestination? = nil, sourceAccess: FileAccessLifetimes? = nil,
        presentation: ArchiveExtractionModel.Presentation = .extract) -> Bool {
        // A supplied pane destination is an internal drag/Paste handoff. An
        // explicit Extract review arrives without one and has its own gate.
        if destination != nil, !ArchiveMemberDragActivation.available { return false }
        if case .paste = presentation, !ArchiveMemberDragActivation.available { return false }
        if ArchiveExtractionActivation.limitsToSingleZIPFile {
            guard case .zipRoot(let root) = selection, root.kind == .file,
                  destination == nil else { return false }
            if case .paste = presentation { return false }
        }
        guard SelectedArchiveExtractionActivation.available, browser.canStartArchiveExtraction,
              destination == nil || canAcceptPreparedSelection && destination?.matchesObservedDirectory == true else { return false }
        switch selection {
        case .zipMembers(let members):
            show(source: source, from: browser, members: members, destination: destination, sourceAccess: sourceAccess, presentation: presentation)
        case .zipRoot(let root):
            show(source: source, from: browser, zipRoot: root, destination: destination, sourceAccess: sourceAccess, presentation: presentation)
        case .tar(let members):
            guard !members.isWholeArchive else { return false }
            show(source: source, from: browser, tarMembers: members, destination: destination, sourceAccess: sourceAccess, presentation: presentation)
        }
        return controller != nil
    }
    func show(source: URL, from browser: BrowserViewController, members: ZIPExtractionSelection? = nil,
        tarMembers:TARExtractionSelection?=nil, zipRoot: ZIPRootExportSelection? = nil,
        destination: ArchiveExtractionDestination? = nil, sourceAccess: FileAccessLifetimes? = nil,
        presentation: ArchiveExtractionModel.Presentation = .extract) {
        if ArchiveExtractionActivation.limitsToSingleZIPFile {
            guard zipRoot?.kind == .file, members == nil, tarMembers == nil,
                  destination == nil else { return }
            if case .paste = presentation { return }
        }
        guard ArchiveExtractionActivation.available, retirement == nil, browser.canStartArchiveExtraction,
              zipRoot == nil || (zipRoot?.archiveURL == source && members == nil && tarMembers == nil),
              let engine = browser.recoverableFileOperations else { return }
        if destination != nil, !canAcceptPreparedSelection { return }
        if let controller {
            if controller.model.isRunning { controller.window?.makeKeyAndOrderFront(nil); return }
            Task { [weak self, weak browser] in
                guard let self else { return }; await closeAndDrain()
                guard let browser, !browser.isBrowserSuspended else { return }
                show(source: source, from: browser, members: members, tarMembers: tarMembers, zipRoot: zipRoot,
                     destination: destination, sourceAccess: sourceAccess, presentation: presentation)
            }
            return
        }
        let model = ArchiveExtractionModel(source: source, browser: browser, engine: engine, members: members, tarMembers: tarMembers, zipRoot: zipRoot,
            destination: destination, sourceAccess: sourceAccess, presentation: presentation)
        let created = ArchiveExtractionWindowController(model: model)
        created.onClose = { [weak self, weak model] in
            guard let self, let model else { return }
            automaticAction?.cancel()
            retirement = Task { [self] in await model.closeAndDrain(); controller = nil; retirement = nil }
        }
        controller = created
        if browser.isControlledVerification { created.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
        else if let window = created.window { ToolWindowChrome.position(window, relativeTo: browser.view.window) }
        if model.offersAutomaticAction { startAutomaticAction(created) }
        else { reveal(created); model.requestPreview() }
    }
    private func reveal(_ created: ArchiveExtractionWindowController) {
        guard controller === created, retirement == nil, let window = created.window, !window.isVisible else { return }
        created.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    private func startAutomaticAction(_ created: ArchiveExtractionWindowController) {
        automaticAction = Task { [self, created] in
            defer { automaticAction = nil }
            await ArchiveAutomaticAction.run(created.model, isCurrent: { [weak self, weak created] in
                guard let self, let created else { return false }
                return controller === created && retirement == nil
            }, reveal: { [weak self, weak created] in
                guard let self, let created else { return }; reveal(created)
            }, close: { [weak created] in created?.close() })
        }
    }
    func closeAndDrain() async {
        let automaticAction = automaticAction
        controller?.close()
        if let automaticAction { await automaticAction.value }
        if let retirement { await retirement.value }
    }
    func closeIdleWindow() { if controller?.model.isRunning == false { controller?.close() } }
}
@MainActor extension BrowserViewController {
    var canStartArchiveExtraction: Bool { ArchiveExtractionActivation.available && !isBrowserSuspended && !isReadOnlyFileSession && recoverableFileOperations != nil && canRunExclusiveFileCommand }
    var canExtractArchive: Bool { ArchiveExtractionActivation.wholeArchiveAvailable && canStartArchiveExtraction && canModifyCurrentFolder && selectedArchiveURL != nil }
    var canExtractArchiveDirect: Bool { canExtractArchive }
    @objc func extractArchive(_ sender: Any?) {
        guard canExtractArchive else{return}
        if let source = selectedArchiveURL { ApplicationArchiveExtraction.shared.show(source: source, from: self) }
    }
    @objc func extractArchiveDirect(_ sender: Any?) {
        guard canExtractArchiveDirect, let source = selectedArchiveURL else { return }
        status.stringValue = "Preparing extraction…"
        ApplicationArchiveExtraction.shared.show(source: source, from: self, presentation: .direct)
    }
}
