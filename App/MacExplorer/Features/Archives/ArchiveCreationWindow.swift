import AppKit
import Combine
import ExplorerCore
import FileOperations
import LocalStorage
import SwiftUI

enum ArchiveCreationActivation {
    static let enabled = true
    static var commandTitle: String { "Compress…" }
    static var available: Bool {
        if GeneratedSandboxReview.publicationOnlyReviewAdmitted || GeneratedSandboxReview.archiveInternalAdmitted { return false }
        #if DEBUG
        return enabled || ProcessInfo.processInfo.arguments.contains("--check-zip-creation")
        #else
        return enabled
        #endif
    }
}

enum ArchiveCreationFormat: String, Sendable {
    case zip, tar, tarGzip = "tar.gz", tarBzip2 = "tar.bz2"
    var displayName: String {
        switch self { case .tarGzip: "TAR.gz"; case .tarBzip2: "TAR.bz2"; default: rawValue.uppercased() }
    }
}
enum TARGzipCreationFeature {
    static var available: Bool {
        AppFeatureAvailability.policy.edition == .development && AppFeatureAvailability.allows(.tarCreation)
            && !GeneratedSandboxReview.admitted
    }
}

enum ZIPMemberRenameFeature {
    static var available: Bool {
        if GeneratedSandboxReview.nativeTARCreateAdmitted { return false }
        if GeneratedSandboxReview.publicationOnlyReviewAdmitted || GeneratedSandboxReview.archiveInternalAdmitted { return false }
        if GeneratedSandboxReview.localFileReviewAdmitted {
            return NativeLocalProtectionPolicy.authoredZIPCreateCopyAvailable && InlineArchiveFeature.available
        }
        if GeneratedSandboxReview.admitted { return InlineArchiveFeature.available }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy") { return true }
        #endif
        return (NativeLocalProtectionPolicy.authoredZIPCreateCopyAvailable
            || AppFeatureAvailability.allows(.archiveMemberChanges)) && InlineArchiveFeature.available
    }
    static var directoriesAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            && ProcessInfo.processInfo.arguments.contains("--rename-folder") { return true }
        #endif
        return available
    }
}

@MainActor final class ArchiveCreationModel: ObservableObject, ArchiveAutomaticActionModel {
    @Published private(set) var outputFormat: ArchiveCreationFormat = .zip
    @Published var name: String { didSet { if !installingAutomaticName && !oldValue.utf8.elementsEqual(name.utf8) { requestPreview() } } }
    @Published var memberName = "" { didSet { if !oldValue.utf8.elementsEqual(memberName.utf8) { requestPreview() } } }
    @Published var batchOptions = BatchRenameOptions() { didSet { if oldValue != batchOptions { requestPreview() } } }
    @Published var compression: ZIPCompression = .balanced { didSet { if oldValue != compression { requestPreview() } } }
    @Published var tarCompression = TARCompression.gzipBalanced { didSet { if oldValue != tarCompression { requestPreview() } } }
    @Published var keepsCurrentTARCompression = true { didSet { if oldValue != keepsCurrentTARCompression { requestPreview() } } }
    var tarCompressionChoices: [TARCompression] {
        outputFormat == .tarBzip2 ? [.bzip2Balanced, .bzip2Fast, .bzip2Smallest] : [.gzipBalanced, .gzipFast, .gzipSmallest]
    }
    @Published var additionCollisions = ZIPMemberAdditionCollisionPolicy.keepBoth {
        didSet { if oldValue != additionCollisions { requestPreview() } }
    }
    @Published private(set) var parent: URL
    @Published private(set) var plan: ArchiveWritePlan?
    @Published private(set) var updatesOriginal: Bool
    @Published private(set) var summary: (files: Int, folders: Int, bytes: UInt64)?
    @Published private(set) var isPreparing = false
    @Published private(set) var isChoosing = false
    @Published private(set) var isRunning = false
    @Published private(set) var offersFinderFallback = false
    @Published private(set) var outcome: RecoverableOperationResult?
    @Published private(set) var undoOutcome: RecoverableOperationResult?
    @Published private(set) var notice = "Checking the selection and destination…"
    @Published private(set) var sources: [URL]
    @Published private(set) var preparedAdditions: [ArchiveAddedItemPreview] = []
    private let memberEdit: ArchiveMemberCopyEdit?
    var isMemberCopy: Bool { memberEdit != nil }
    var formatName: String { memberEdit?.formatName ?? outputFormat.displayName }
    var memberSelectionPreview: (paths: [String], folders: [String], covered: Int)? { memberEdit?.selectionPreview }
    var isMemberGrouping: Bool { memberEdit?.isGrouping == true }
    var isMemberRename: Bool { memberEdit?.isRename == true }
    var isMemberBatchRename: Bool { memberEdit?.isBatchRename == true }
    var batchNames: [BatchRenameName] {
        let paths: [String], folders: [String]
        switch memberEdit {
        case .batchRename(let selected): paths = selected.archivePaths; folders = selected.folderPaths
        case .tar(.batchRename(let selected, _)): paths = selected.archivePaths; folders = selected.folderPaths
        default: return []
        }
        return paths.map { path in
            .init(name: path.split(separator: "/").last.map(String.init) ?? "",
                  isDirectory: folders.contains(path))
        }
    }
    var batchRows: [BatchRenamePreviewRow] {
        (try? batchOptions.preview(batchNames)) ?? batchNames.enumerated().map {
            .init(id: $0.offset, before: $0.element.name, after: "—", status: "Check rule", changed: false)
        }
    }
    var isMemberRemoval: Bool { memberEdit?.isRemoval == true }
    var isMemberDuplicate: Bool { memberEdit?.isDuplicate == true }
    var isMemberMove: Bool { memberEdit?.isMove == true }
    var isMemberAddition: Bool { memberEdit?.isAddition == true }
    var isMemberNewFolder: Bool { memberEdit?.isNewFolder == true }
    var groupedSelection: ZIPMemberSetSelection? {
        if case .group(let value) = memberEdit { value } else { nil }
    }
    var isMemberNewFile: Bool { memberEdit?.isNewFile == true }
    var isMemberCreation: Bool { isMemberNewFolder || isMemberNewFile }
    var addedSources: [URL] { isMemberAddition ? Array(sources.dropFirst()) : [] }
    private func additionLabel(_ item: ArchiveAddedItemPreview) -> String {
        item.replacesExistingFile ? item.finalName + " · Replace existing file"
            : item.renamed ? "\(item.originalName) → \(item.finalName)" : item.finalName
    }
    var replacedFileCount: Int { preparedAdditions.filter(\.replacesExistingFile).count }
    var additionReviewTitle: String {
        let count = addedSources.count
        if replacedFileCount == count && count > 0 {
            return "\(count.formatted()) \(count == 1 ? "file" : "files") to replace"
        }
        return "\(count.formatted()) \(count == 1 ? "item" : "items") to "
            + (replacedFileCount > 0 ? "add or replace" : "add")
    }
    var additionExplanation: String {
        if additionCollisions == .replaceFiles {
            return "Matching files use the added files’ contents, dates and permissions. Folders are never merged; local items stay unchanged."
                + (updatesOriginal ? "" : " Your original archive stays unchanged.")
        }
        return "Existing archive items and local originals stay unchanged. Names already in use get a number."
            + (updatesOriginal ? "" : " Your original archive stays unchanged.")
    }
    var addedNames: [String] {
        preparedAdditions.isEmpty ? addedSources.map(\.lastPathComponent) : preparedAdditions.map(additionLabel)
    }
    var addedFolderNames: [String] {
        if !preparedAdditions.isEmpty { return preparedAdditions.filter(\.isDirectory).map(additionLabel) }
        let directories = plan?.directorySources ?? addedSources.filter(\.hasDirectoryPath)
        return directories.filter { addedSources.contains($0) }.map(\.lastPathComponent)
    }
    var additionFolder: String {
        switch memberEdit {
        case .add(let selected), .newFolder(let selected), .newFile(let selected):
            selected.virtualFolder.isEmpty ? selected.archiveURL.lastPathComponent : selected.virtualFolder
        case .tar(let selected):
            selected.folderPath.isEmpty ? selected.archiveURL.lastPathComponent : selected.folderPath
        case .group(let selected):
            selected.archivePaths.first.map { String($0.split(separator: "/").dropLast().joined(separator: "/")) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? selected.archiveURL.lastPathComponent
        default: ""
        }
    }
    var isDirectoryRename: Bool {
        switch memberEdit {
        case .rename(let selected): selected.isDirectory
        case .tar(.rename(let selected, _)): selected.folderPaths.count == 1
        default: false
        }
    }
    var memberPath: String? { isMemberRename ? memberEdit?.paths.first : nil }
    var removedPaths: [String] { isMemberRemoval ? memberEdit?.paths ?? [] : [] }
    var removedFolderPaths: [String] {
        isMemberRemoval ? memberEdit?.selectionPreview?.folders ?? [] : []
    }
    var coveredRemovedSelections: Int {
        isMemberRemoval ? memberEdit?.selectionPreview?.covered ?? 0 : 0
    }
    var title: String {
        if isMemberGrouping { return updatesOriginal ? "New Folder with Selection" : "Group in \(formatName) Copy" }
        if isMemberBatchRename { return updatesOriginal ? "Rename Items in \(formatName)" : "Rename Items in \(formatName) Copy" }
        if isMemberDuplicate {
            if copyDestination != nil { return updatesOriginal ? "Copy in \(formatName)" : "Copy in \(formatName) Copy" }
            return updatesOriginal ? "Duplicate in \(formatName)" : "Duplicate in \(formatName) Copy"
        }
        if isMemberMove { return updatesOriginal ? "Move in \(formatName)" : "Move in \(formatName) Copy" }
        if isMemberNewFolder { return updatesOriginal ? "New Folder in \(formatName)" : "New Folder in \(formatName) Copy" }
        if isMemberNewFile { return updatesOriginal ? "Create File in \(formatName)" : "Create File in \(formatName) Copy" }
        if updatesOriginal { return isMemberAddition ? "Add to \(formatName)" : isMemberRemoval ? "Remove from \(formatName)" : "Rename in \(formatName)" }
        return isMemberAddition ? "Add to \(formatName) Copy" : isMemberRemoval ? "Remove from \(formatName) Copy" : isMemberRename ? "Rename in \(formatName) Copy" : "Create \(outputFormat.displayName)"
    }
    var createTitle: String {
        if updatesOriginal {
            if isMemberBatchRename { return "Rename Items" }
            if isMemberGrouping { return "Create Folder" }
            if isMemberNewFile { return "Create File" }
            if isMemberDuplicate { return copyDestination == nil ? "Duplicate" : "Copy" }
            if isMemberMove { return "Move" }
            return "Update \(formatName)"
        }
        return isMemberCopy ? "Save \(formatName) Copy" : "Create \(outputFormat.displayName)"
    }
    var offersOutputFormats: Bool {
        !isMemberCopy && !GeneratedSandboxReview.nativeTARCreateAdmitted && AppFeatureAvailability.allows(.tarCreation)
    }
    func chooseOutputFormat(_ value: ArchiveCreationFormat) {
        guard !closed, !isRunning, !isChoosing, outcome == nil, offersOutputFormats, outputFormat != value else { return }
        guard value != .tarGzip || TARGzipCreationFeature.available else { return }
        guard value != .tarBzip2 || TARBzip2Feature.available else { return }
        let previousSuffix = "." + outputFormat.rawValue
        outputFormat = value; window?.title = title
        if value == .tarGzip { tarCompression = .gzipBalanced }
        if value == .tarBzip2 { tarCompression = .bzip2Balanced }
        if name.lowercased().hasSuffix(previousSuffix) {
            name = String(name.dropLast(previousSuffix.count)) + "." + value.rawValue
        } else { requestPreview() }
    }
    var duplicateSelection: ZIPMemberSetSelection? {
        if case .duplicate(let selection, _) = memberEdit { return selection }
        return nil
    }
    var copyDestination: String? {
        if case .duplicate(_, let folder) = memberEdit { return folder?.virtualFolder }
        if case .tar(.duplicate(_, let folder)) = memberEdit { return folder?.virtualFolder }
        return nil
    }
    var moveDestinationPath: String? {
        switch memberEdit { case .move(_, let folder): folder.virtualFolder; case .tar(.move(_, let folder)): folder.virtualFolder; default: nil }
    }
    var moveSelection: (items: ZIPMemberSetSelection, folder: String)? {
        if case .move(let selection, let folder) = memberEdit { return (selection, folder.virtualFolder) }
        return nil
    }
    let settings: BrowserSettings
    weak var window: NSWindow?
    private weak var browser: BrowserViewController?
    private let engine: RecoverableFileOperations
    private let coordinator: ApplicationOperationCoordinator
    private let onMemberCreated: ((URL, String) -> Void)?
    private let onOriginalUpdated: (() -> Void)?
    private let chooser = FolderAccessController(stateDirectory: nil)
    private var customPicker: AnalysisFolderPickerController?
    private let automatic: Bool
    private let initiatingTab: UUID, initiatingVisit: UUID
    private let initiatingDirectory: URL?
    private var automaticNameRequested = false, installingAutomaticName = false, debouncesPreview = true
    private var generation = UUID(), pending = false, closed = false, undoAttempted = false
    private var preparation: UUID?
    private var observation: FileOperationSelection?
    private var lifetime: FileAccessLifetimes?
    private var prepareWork: Task<Void, Never>?, previewWork: Task<ArchiveWritePlan, Error>?
    private var choiceWork: Task<Void, Never>?, runningWork: Task<Void, Never>?
    private var changes: AnyCancellable?
    private var sourcePanel: NSOpenPanel?
    private var selectedSourceAccess: FileAccessLifetimes?
    var canReview: Bool { !closed && !isPreparing && !isChoosing && !isRunning && outcome == nil && coordinator.activeOwner == nil && coordinator.preparationOwner == nil && coordinator.transfers.canRunExclusiveCommand && !ApplicationFileActivity.gate.isClosed }
    var canCreate: Bool { canReview && plan != nil }
    var canUndo: Bool { !closed && !isRunning && !undoAttempted && outcome?.result.disposition == .succeeded && outcome?.recordID != nil && browser?.canRunExclusiveFileCommand == true }
    var canViewResults: Bool { !isRunning && outcome?.recordID != nil && browser?.canRunExclusiveFileCommand == true }
    #if DEBUG
    var chooseSourcesForVerification: ((NSOpenPanel) async -> [URL]?)?
    var undoAttemptedForVerification: Bool { undoAttempted }
    var previewIsPendingForVerification: Bool { pending || prepareWork != nil || previewWork != nil }
    #endif
    init(sources: [URL], browser: BrowserViewController, engine: RecoverableFileOperations,
         memberEdit: ArchiveMemberCopyEdit? = nil, updateOriginal: Bool = false,
         onMemberCreated: ((URL, String) -> Void)? = nil, onOriginalUpdated: (() -> Void)? = nil,
         automatic: Bool = false) {
        self.automatic = automatic
        initiatingTab = browser.activeID; initiatingVisit = browser.sessionID
        initiatingDirectory = browser.location.directoryURL
        let nativeTARReview = memberEdit == nil && GeneratedSandboxReview.nativeTARCreateAdmitted
        self.memberEdit = memberEdit
        self.onMemberCreated = onMemberCreated
        self.onOriginalUpdated = onOriginalUpdated
        updatesOriginal = updateOriginal
        let chosenSources = memberEdit.map { [$0.archiveURL] } ?? sources
        self.sources = chosenSources
        parent = chosenSources[0].deletingLastPathComponent()
        if let memberEdit {
            name = ArchiveActionNames.editedCopyName(memberEdit.archiveURL)
        } else if nativeTARReview {
            name = sources.count == 1 ? sources[0].lastPathComponent + ".tar" : "Archive.tar"
        } else { name = sources.count == 1 ? sources[0].lastPathComponent + ".zip" : "Archive.zip" }
        self.browser = browser; self.engine = engine; coordinator = browser.operationCoordinator; settings = browser.settings
        if case .rename(let selected) = memberEdit { memberName = selected.currentName }
        if memberEdit?.isNewFolder == true { memberName = "New Folder" }
        if case .newFile = memberEdit { memberName = "New File.txt" }
        if case .tar(let mutation) = memberEdit { memberName = mutation.draftName }
        changes = Publishers.Merge(coordinator.objectWillChange, coordinator.transfers.objectWillChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
        if nativeTARReview || memberEdit?.formatName == "TAR" { outputFormat = .tar }
        if memberEdit?.formatName == "TAR.gz" { outputFormat = .tarGzip }
        if memberEdit?.formatName == "TAR.bz2" { outputFormat = .tarBzip2; tarCompression = .bzip2Balanced }
    }
    func requestPreview() {
        requestPreview(debounced: true)
    }
    private func requestPreview(debounced: Bool) {
        guard !closed, !isRunning, outcome == nil else { return }
        generation = UUID(); pending = true; debouncesPreview = debounced; plan = nil; summary = nil; preparedAdditions = []; previewWork?.cancel()
        offersFinderFallback = false
        if isMemberAddition, sources.count == 1 {
            pending = false; notice = "Choose files or folders to add. Existing archive items will be kept."; return
        }
        notice = "Checking the selection and destination…"
        if prepareWork == nil { prepareWork = Task { [self] in await previewLoop() } }
    }
    var automaticActionCanSubmit: Bool {
        guard let browser else { return false }
        return !closed && !browser.isBrowserSuspended && browser.recoverableFileOperations === engine
            && browser.activeID == initiatingTab && browser.sessionID == initiatingVisit
    }
    var automaticActionShouldReveal: Bool {
        guard let browser else { return false }
        return !closed && !browser.isBrowserSuspended && browser.recoverableFileOperations === engine
            && browser.activeID == initiatingTab && browser.location.directoryURL == initiatingDirectory
    }
    var automaticActionSucceeded: Bool { outcome?.result.disposition == .succeeded }
    func prepareAutomaticAction() async -> Bool {
        guard automatic, !isMemberCopy, outputFormat == .zip, automaticActionCanSubmit else { return false }
        automaticNameRequested = true
        requestPreview(debounced: false)
        let token = generation
        if let prepareWork { await prepareWork.value }
        return !Task.isCancelled && token == generation && automaticActionCanSubmit && canCreate
    }
    func performAutomaticAction() { create() }
    func waitForOperation() async { if let runningWork { await runningWork.value } }
    private func previewLoop() async {
        isPreparing = true
        defer { prepareWork = nil; previewWork = nil; isPreparing = false; releasePreparation() }
        while !closed, pending {
            pending = false
            let token = generation, chosenParent = parent, chosenFormat = outputFormat, chosenCompression = compression
            let chosenTARCompression = tarCompression
            let keepCurrentTARCompression = keepsCurrentTARCompression && chosenFormat == .tarBzip2 && isMemberCopy
            let suffix = "." + chosenFormat.rawValue
            let requestedName = name.lowercased().hasSuffix(suffix) ? name : name + suffix
            let choosesAutomaticName = automaticNameRequested; automaticNameRequested = false
            let chosenSources = sources, retainedSelectionAccess = selectedSourceAccess
            let originalUpdate = updatesOriginal
            let chosenMemberName = memberName
            let chosenBatch = batchOptions, chosenBatchNames = batchNames
            let chosenCollisions = additionCollisions
            if debouncesPreview { try? await Task.sleep(for: .milliseconds(160)) }
            guard token == generation else { continue }
            if case .rename(let selected) = memberEdit,
               chosenMemberName.isEmpty || chosenMemberName.utf8.elementsEqual(selected.currentName.utf8) {
                notice = originalUpdate ? "Enter a new name for this item." : "Enter a new name for this item. The changed archive will be saved as a separate archive."; continue
            }
            if isMemberBatchRename {
                do {
                    guard try chosenBatch.preview(chosenBatchNames).contains(where: \.changed) else {
                        notice = "Choose a rename rule. The preview shows every new name before saving."; continue
                    }
                } catch { notice = Self.message(error); continue }
            }
            let owner = UUID()
            guard let browser, !browser.isBrowserSuspended, coordinator.beginPreparation(owner: owner) else {
                notice = "Finish other file work, then choose Review Again."; continue
            }
            preparation = owner
            let sourceAccess = await browser.accessLifetime(for: chosenSources + [chosenParent])
            let parentAccess = await chooser.acquireAccess(to: chosenParent)
            let access = FileAccessLifetimes(leases: sourceAccess.leases + (parentAccess.map { [$0] } ?? []) + (retainedSelectionAccess?.leases ?? []))
            let diagnostic = ApplicationDiagnostics.shared.begin(.archiveCreate)
            ApplicationDiagnostics.shared.event(.archiveCreate, .preparing, trace: diagnostic)
            do {
                let chosenName: String
                if choosesAutomaticName {
                    chosenName = try await LocalAvailableName.available(in: chosenParent,
                        preferredName: requestedName, extension: chosenFormat.rawValue)
                    guard !closed, token == generation, automaticActionCanSubmit else { throw CancellationError() }
                    installingAutomaticName = true; name = chosenName; installingAutomaticName = false
                } else { chosenName = requestedName }
                let captured: FileOperationSelection
                if let observation { captured = observation }
                else { captured = try await engine.observeSelection(chosenSources) }
                guard !closed, token == generation else {
                    ApplicationDiagnostics.shared.event(.archiveCreate, .cancelled, trace: diagnostic)
                    releasePreparation(); continue
                }
                observation = captured
                if originalUpdate { try await requireUnreferencedOriginal(retaining: access) }
                let work = Task { [engine, sources = chosenSources, memberEdit] () async throws -> ArchiveWritePlan in
                    switch memberEdit {
                    case .tar(let mutation):
                        let change: TARMemberMutation
                        if case .batchRename(let selected, _) = mutation {
                            change = .batchRename(selected, to: try chosenBatch.rule.names(for: chosenBatchNames))
                        } else { change = mutation.reviewed(name: chosenMemberName, addedSources: Array(sources.dropFirst())) }
                        let encoding: TARCompression? = change.isCompressed && !keepCurrentTARCompression ? chosenTARCompression : nil
                        if originalUpdate { return .update(try await engine.prepareTARMemberMutationOriginal(change, compression: encoding,
                            additionCollisions: chosenCollisions, observing: captured)) }
                        return .create(try await engine.prepareTARMemberMutationCopy(change, outputName: chosenName, compression: encoding,
                            additionCollisions: chosenCollisions, observing: captured))
                    case .batchRename(let selected):
                        let names = try chosenBatch.rule.names(for: chosenBatchNames)
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberBatchRenameOriginal(selected, to: names, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberBatchRenameCopy(selected, to: names,
                            outputName: chosenName, observing: captured))
                    case .rename(let selected):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberRenameOriginal(selected, to: chosenMemberName, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberRenameCopy(selected, to: chosenMemberName,
                            outputName: chosenName, observing: captured))
                    case .remove(let selected):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberRemovalOriginal(selected, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberRemovalCopy(selected,
                            outputName: chosenName, observing: captured))
                    case .duplicate(let selected, let folder):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberDuplicateOriginal(selected, into: folder, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberDuplicateCopy(selected, into: folder,
                            outputName: chosenName, observing: captured))
                    case .move(let selected, let folder):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberMoveOriginal(selected, into: folder, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberMoveCopy(selected, into: folder,
                            outputName: chosenName, observing: captured))
                    case .add(let selected):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberAdditionOriginal(selected, sources: Array(sources.dropFirst()),
                                compression: chosenCompression, collisions: chosenCollisions, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberAdditionCopy(selected, sources: Array(sources.dropFirst()),
                            outputName: chosenName, compression: chosenCompression, collisions: chosenCollisions, observing: captured))
                    case .newFolder(let selected):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberNewFolderOriginal(selected,
                                name: chosenMemberName, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberNewFolderCopy(selected,
                            name: chosenMemberName, outputName: chosenName, observing: captured))
                    case .newFile(let selected):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPMemberNewFileOriginal(selected,
                                name: chosenMemberName, observing: captured))
                        }
                        return .create(try await engine.prepareZIPMemberNewFileCopy(selected,
                            name: chosenMemberName, outputName: chosenName, observing: captured))
                    case .group(let selected):
                        if originalUpdate {
                            return .update(try await engine.prepareZIPFolderWithSelectionOriginal(selected,
                                name: chosenMemberName, observing: captured))
                        }
                        return .create(try await engine.prepareZIPFolderWithSelectionCopy(selected,
                            name: chosenMemberName, outputName: chosenName, observing: captured))
                    case nil: break
                    }
                    if chosenFormat != .zip {
                        guard AppFeatureAvailability.allows(.tarCreation) else { throw FileOperationFailure.unsupported }
                        guard chosenFormat != .tarGzip || TARGzipCreationFeature.available else { throw FileOperationFailure.unsupported }
                        guard chosenFormat != .tarBzip2 || TARBzip2Feature.available else { throw FileOperationFailure.unsupported }
                        return .create(try await engine.prepareTARCreation(sources: sources, parent: chosenParent,
                            name: chosenName, compression: chosenFormat == .tar ? .none : chosenTARCompression, observing: captured))
                    }
                    return .create(try await engine.prepareZIPCreation(sources: sources, parent: chosenParent, name: chosenName, compression: chosenCompression, observing: captured))
                }
                previewWork = work
                let prepared = try await work.value
                guard !closed, token == generation else {
                    ApplicationDiagnostics.shared.event(.archiveCreate, .cancelled, trace: diagnostic)
                    releasePreparation(); continue
                }
                lifetime = access; plan = prepared; summary = (prepared.files, prepared.folders, prepared.logicalBytes)
                preparedAdditions = prepared.addedItems
                if isMemberMove {
                    notice = "Ready to move the selected items. Existing names will be kept."
                } else if isMemberDuplicate {
                    notice = copyDestination == nil ? "Copies will use available names beside the selected items."
                        : "Existing items are kept. Copies get a numbered name when needed."
                } else if isMemberCreation {
                    notice = originalUpdate ? "Ready to create “\(chosenMemberName)”."
                        : "Ready to create “\(chosenMemberName)” in “\(prepared.destination.lastPathComponent)”."
                } else {
                    notice = originalUpdate ? "Ready to update “\(prepared.destination.lastPathComponent)”. The earlier archive is kept for Undo."
                        : "Ready to create “\(prepared.destination.lastPathComponent)”. Originals stay untouched."
                }
                ApplicationDiagnostics.shared.event(.archiveCreate, .completed, trace: diagnostic, count: UInt64(prepared.files))
            } catch {
                ApplicationDiagnostics.shared.event(.archiveCreate, error is CancellationError ? .cancelled : .failed,
                    trace: diagnostic, error: DiagnosticErrors.project(error))
                if !closed, token == generation {
                    notice = originalUpdate && (error as? FileOperationFailure) == .unsupported
                        ? "Update \(formatName) is unavailable for this file. Save an archive copy instead." : Self.message(error)
                    offersFinderFallback = !isMemberCopy && (error is ZIPCreationFailure || error is ZIPExtractionFailure || error is ZIPArchiveFailure || error is TARCreationFailure)
                }
            }
            previewWork = nil; releasePreparation(); withExtendedLifetime(access) {}
        }
    }
    func reviewAgain() {
        guard canReview else { return }
        observation = nil; lifetime = nil; requestPreview()
    }
    func saveCopyInstead() {
        guard updatesOriginal, canReview else { return }
        updatesOriginal = false; window?.title = title; requestPreview()
    }
    private func requireUnreferencedOriginal(retaining access: FileAccessLifetimes?) async throws {
        guard updatesOriginal, let original = memberEdit?.archiveURL, let browser else { throw FileOperationFailure.invalidRequest }
        try await ArchiveOriginalReferences.requireUnreferenced([original], names: browser.privateNames, retaining: access)
    }
    func chooseAdditions() {
        guard isMemberAddition, canReview, let window, window.attachedSheet == nil else { return }
        isChoosing = true
        choiceWork = Task { [self] in
            defer { sourcePanel = nil; choiceWork = nil; isChoosing = false }
            let panel = NSOpenPanel()
            panel.title = updatesOriginal ? "Add to \(formatName)" : "Add to \(formatName) Copy"; panel.prompt = "Add Items"
            panel.message = updatesOriginal ? "Choose files or folders to add. Review the archive update before saving; local items stay unchanged."
                : "Choose files or folders to add. The original archive and selected items stay unchanged."
            panel.canChooseFiles = true; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true; panel.resolvesAliases = false
            sourcePanel = panel
            let selected: [URL]?
            #if DEBUG
            if let chooseSourcesForVerification { selected = await chooseSourcesForVerification(panel) }
            else { selected = await choose(panel, in: window) }
            #else
            selected = await choose(panel, in: window)
            #endif
            guard !closed, !Task.isCancelled else { return }
            guard let selected else {
                if addedSources.isEmpty { window.performClose(nil) }
                return
            }
            await selectAddedSources(selected)
        }
    }
    private func choose(_ panel: NSOpenPanel, in window: NSWindow) async -> [URL]? {
        await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.urls : nil)
            }
        }
    }
    /// Retain the exact chooser URLs for the real worker lifetime. Selecting
    /// another set does not revoke scopes still held by an earlier preview.
    func selectAddedSources(_ selected: [URL]) async {
        await selectAddedSources(selected, retaining: nil)
    }
    func receiveAddedSources(_ source: ArchiveAdditionInput) {
        guard isMemberAddition, canReview else { return }
        isChoosing = true
        choiceWork = Task { [self] in
            defer { choiceWork = nil; isChoosing = false }
            await selectAddedSources(source.urls, retaining: source.access, requiringCurrent: source.isCurrent)
        }
    }
    private func selectAddedSources(_ selected: [URL], retaining retainedAccess: FileAccessLifetimes?,
                                    requiringCurrent: @MainActor () -> Bool = { true }) async {
        guard isMemberAddition, !closed, !isRunning, outcome == nil else { return }
        generation = UUID(); pending = false; plan = nil; summary = nil; preparedAdditions = []; previewWork?.cancel()
        guard requiringCurrent() else {
            notice = "The clipboard changed. Choose the items to add, or copy and paste again."; return
        }
        guard isMemberAddition, !closed, !isRunning, outcome == nil,
              !selected.isEmpty, selected.count <= 511, selected.allSatisfy(\.isFileURL),
              let archive = memberEdit?.archiveURL, !selected.contains(archive),
              Set(selected).count == selected.count else {
            notice = "Choose up to 511 different local files or folders. Leave the source archive out of the selection."; return
        }
        let access = await Task.detached(priority: .userInitiated) {
            FileAccessLifetimes(leases: selected.map { FolderAccessLease(url: $0, backend: SystemFolderAccessBackend()) })
        }.value
        guard !closed, !Task.isCancelled else { return }
        guard requiringCurrent() else {
            notice = "The clipboard changed. Choose the items to add, or copy and paste again."; return
        }
        selectedSourceAccess = .init(leases: access.leases + (retainedAccess?.leases ?? [])); sources = [archive] + selected
        observation = nil; lifetime = nil; requestPreview()
    }
    func chooseDestination() {
        guard canReview, let browser, let window, window.attachedSheet == nil else { return }
        isChoosing = true
        choiceWork = Task { [self] in
            defer { choiceWork = nil; isChoosing = false }
            let selected: URL?
            if isMemberCopy || settings.analysisFolderPicker == .system {
                selected = await chooser.chooseFolder(in: window, initialDirectory: parent)?.selection.url
            } else {
                let model = AnalysisFolderPickerModel(initialDirectory: parent, volumes: browser.volumes,
                    access: chooser, showsHidden: settings.showsHiddenFiles)
                let picker = AnalysisFolderPickerController(model: model, settings: settings, style: settings.analysisFolderPicker,
                    title: "Choose Archive Destination")
                customPicker = picker; selected = await picker.choose(in: window); customPicker = nil
            }
            guard !closed, !Task.isCancelled, let selected else { return }
            if isMemberCopy {
                guard selected.standardizedFileURL == parent.standardizedFileURL else {
                    notice = updatesOriginal ? "Choose the folder shown above to allow this archive update."
                        : "Choose the folder shown above to allow an archive copy beside the original."; return
                }
                requestPreview(); return
            }
            parent = selected; requestPreview()
        }
    }
    func create() {
        guard canCreate, let browser, let plan, browser.recoverableFileOperations === engine,
              browser.operationTask == nil, browser.startOperationPresentation(updatesOriginal ? "Updating \(formatName)…" : isMemberCopy ? "Saving \(formatName) copy…" : "Creating \(outputFormat.displayName)…") else { return }
        isRunning = true; self.plan = nil
        notice = updatesOriginal ? "Preparing and verifying the updated archive…" : isMemberCopy ? "Creating and checking the archive copy…" : "Creating and verifying the \(outputFormat.displayName)…"
        let access = lifetime
        let createdPath: String?
        if case .newFile(let selection) = memberEdit {
            createdPath = (selection.virtualFolder.isEmpty ? "" : selection.virtualFolder + "/") + memberName
        } else if case .newFolder(let selection) = memberEdit {
            createdPath = (selection.virtualFolder.isEmpty ? "" : selection.virtualFolder + "/") + memberName
        } else if let selected = groupedSelection, let first = selected.archivePaths.first {
            let prefix = first.split(separator: "/").dropLast().joined(separator: "/")
            createdPath = (prefix.isEmpty ? "" : prefix + "/") + memberName
        } else if case .tar(let mutation) = memberEdit, isMemberCreation {
            let prefix = mutation.folderPath
            createdPath = (prefix.isEmpty ? "" : prefix + "/") + memberName
        } else { createdPath = nil }
        let work = Task { [self, browser] in
            defer {
                runningWork = nil; isRunning = false; browser.finishOperationPresentation()
                withExtendedLifetime(access) {}; if closed { lifetime = nil }
                if !closed, outcome?.result.disposition == .succeeded, let createdPath {
                    onMemberCreated?(plan.destination, createdPath)
                }
            }
            do {
                try await coordinator.prepareOperationState(for: engine); try Task.checkCancellation()
                if updatesOriginal { try await requireUnreferencedOriginal(retaining: access) }
                // The click admitted this immutable plan and its retained
                // access. Closing retires the review, not the accepted work.
                // Explicit Stop still cancels the actual operation task.
                try Task.checkCancellation()
                let result = await plan.perform(using: engine, progress: browser.operationProgressSink)
                outcome = result.recordID == nil && result.result.disposition != .succeeded ? nil : result
                notice = result.result.disposition == .succeeded ? (updatesOriginal
                    ? "Updated “\(plan.destination.lastPathComponent)”. The earlier archive is kept for Undo."
                    : "Created “\(plan.destination.lastPathComponent)”. Originals are unchanged.")
                    : result.recordID != nil ? "The archive operation did not finish. Retained work is protected; View Results shows the exact operation."
                    : OperationResultDescription(result: result.result).summary
                if updatesOriginal, result.result.disposition == .succeeded { onOriginalUpdated?() }
                publish(result, browser: browser)
            } catch { notice = error is CancellationError ? "Stopped before changing the archive." : Self.message(error) }
        }
        runningWork = work; browser.operationTask = work
    }
    func undo() {
        guard canUndo, let browser, let id = outcome?.recordID, browser.recoverableFileOperations === engine,
              browser.startOperationPresentation(updatesOriginal ? "Undoing \(formatName) update…" : "Undoing \(outputFormat.displayName) creation…") else { return }
        undoAttempted = true; isRunning = true; notice = "Checking the archive before Undo…"
        let access = lifetime
        let work = Task { [self, browser] in
            defer { runningWork = nil; isRunning = false; browser.finishOperationPresentation(); withExtendedLifetime(access) {}; if closed { lifetime = nil } }
            if updatesOriginal {
                do {
                    guard let locations = try await engine.archiveUpdateReferenceLocations(recordID: id),
                          let browser = self.browser else { throw ArchiveOriginalReferences.Failure.unavailable }
                    try await ArchiveOriginalReferences.requireUnreferenced(locations, names: browser.privateNames,
                                                                            retaining: access)
                }
                catch { notice = Self.message(error); undoAttempted = false; return }
            }
            let result = await engine.undo(recordID: id, progress: browser.operationProgressSink); undoOutcome = result
            notice = result.result.disposition == .succeeded ? (updatesOriginal
                ? "The earlier archive is restored. The edited version remains in recovery."
                : "\(outputFormat.displayName) creation undone. Its unchanged archive is retained in recovery; originals are untouched.")
                : "Undo could not finish. Changed or uncertain items are preserved; View Results has the details."
            publish(result, browser: browser)
        }
        runningWork = work; browser.operationTask = work
    }
    func stop() {
        if isRunning { browser?.cancelFileOperation(nil) }
        else if isPreparing {
            generation = UUID(); pending = false; previewWork?.cancel(); prepareWork?.cancel()
            plan = nil; summary = nil; notice = "Stopped before creating the archive. Your files are unchanged."
        }
    }
    func showSourcesInFinder() {
        guard offersFinderFallback, !closed, !isRunning, browser?.isControlledVerification != true else { return }
        NSWorkspace.shared.activateFileViewerSelecting(sources)
    }
    func viewResults() { if canViewResults, let id = outcome?.recordID { browser?.openOperationRecovery(recordID: id) } }
    func showInExplorer() {
        guard !isRunning, undoOutcome == nil, outcome?.result.disposition == .succeeded,
              let destination = outcome?.result.items.first?.destination, let browser, !browser.isBrowserSuspended else { return }
        browser.navigate(to: .directory(destination.deletingLastPathComponent()))
        browser.tabs[browser.activeIndex].state.selection = [destination]
        browser.view.window?.makeKeyAndOrderFront(nil)
    }
    func closeAndDrain() async {
        closed = true; generation = UUID(); pending = false; previewWork?.cancel()
        customPicker?.cancel(); chooser.invalidatePendingRequests(); choiceWork?.cancel()
        sourcePanel?.cancel(nil)
        if let prepareWork { await prepareWork.value }; if let choiceWork { await choiceWork.value }
        if let runningWork { await runningWork.value }
        releasePreparation(); lifetime = nil; selectedSourceAccess = nil; observation = nil; plan = nil
    }
    private func releasePreparation() { if let preparation { coordinator.finishPreparation(owner: preparation); self.preparation = nil } }
    private func publish(_ result: RecoverableOperationResult, browser: BrowserViewController) {
        browser.lastOperationResult = result.result; browser.lastRecoveryRecordID = result.recordID; browser.lastRecoveryAction = nil
        browser.lastTransferContinuation = nil; browser.continuationMoveClipboard = nil
        browser.status.stringValue = OperationResultDescription(result: result.result).summary; browser.operationResultsButton.isHidden = false
        for current in coordinator.liveBrowsers where !current.isBrowserSuspended {
            if current.location.directoryURL == parent { current.loadLocation() }
        }
        if updatesOriginal, let original = memberEdit?.archiveURL {
            ArchiveOriginalReferences.refresh(original, in: coordinator)
        }
        browser.inspectOperationRecovery()
    }
    static func message(_ error: Error) -> String {
        if let failure = error as? LocalAvailableName.Failure {
            switch failure {
            case .invalidName: return "Choose a shorter name without path separators."
            case .exhausted: return "Many names are already in use. Choose a different name."
            case .fileSystem: return "This destination could not be checked. Choose an accessible folder and review again."
            }
        }
        if let failure = error as? BatchRenameValidation { return failure.message }
        if let failure = error as? TARCreationFailure { return failure.userMessage }
        if let refusal = error as? ArchiveOriginalReferences.Failure { return refusal.message }
        if let failure = error as? TARMemberEditFailure { return failure.userMessage }
        if error is TARArchiveFailure { return TARBrowserModel.message(error) }
        if let failure = error as? ZIPMemberNewFolderFailure { return failure.userMessage }
        if let failure = error as? ZIPMemberAdditionFailure { return failure.userMessage }
        if let failure = error as? ZIPMemberRemovalFailure { return failure.userMessage }
        if let failure = error as? ZIPMemberRenameFailure {
            switch failure {
            case .unsupportedSecurity: return "This ZIP has download or file information Traverse can’t preserve yet. Your original is unchanged."
            case .unsupportedArchive: return "This ZIP includes information Traverse can’t preserve when editing it yet. Your original is unchanged."
            case .sourceChanged: return "The ZIP changed. Reopen it and select the item again."
            default: return failure.userMessage
            }
        }
        if let failure = error as? ZIPCreationFailure { return failure.userMessage }
        if let failure = error as? ZIPExtractionFailure {
            return failure == .quarantinedOrUncertain ? "A selected item has download-security metadata that portable ZIP cannot yet preserve. Use the system Compress action for this selection."
                : "This source or destination is outside the currently qualified ZIP scope. Use a local APFS location."
        }
        if let failure = error as? FileOperationFailure { return failure.userMessage }
        return ArchiveBrowserModel.message(error)
    }
}

private struct ArchiveCreationView: View {
    @ObservedObject var model: ArchiveCreationModel
    @State private var batchSelection = Set<Int>()
    @FocusState private var memberNameFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { details.padding(22) }
            Divider()
            footer.padding(.horizontal, 22).padding(.vertical, 16)
        }.frame(minWidth: 620, minHeight: 480)
            .onAppear { if model.isMemberRename || model.isMemberCreation { memberNameFocused = true } }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").interfaceFont(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).interfaceFont(.title2.weight(.semibold))
                    Text(model.isMemberCopy || model.sources.count == 1 ? model.sources[0].lastPathComponent : "\(model.sources.count.formatted()) selected items")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(); if model.isPreparing || model.isRunning { ProgressView().controlSize(.small) }
            }
            Divider()
            if model.isMemberAddition {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add inside").interfaceFont(.caption).foregroundStyle(.secondary)
                        Label(model.additionFolder, systemImage: "folder")
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    Button(model.addedSources.isEmpty ? "Choose Items…" : "Change Items…", action: model.chooseAdditions)
                        .disabled(!model.canReview).accessibilityIdentifier("zip-copy-choose-items")
                }
                if !model.addedSources.isEmpty {
                    Picker("Existing names", selection: $model.additionCollisions) {
                        Text("Keep Both").tag(ZIPMemberAdditionCollisionPolicy.keepBoth)
                        Text("Replace Files").tag(ZIPMemberAdditionCollisionPolicy.replaceFiles)
                    }.pickerStyle(.segmented).disabled(!model.canReview)
                    ArchiveCopyMemberList(paths: model.addedNames,
                        folderPaths: model.addedFolderNames,
                        coveredSelectionCount: 0, title: model.additionReviewTitle,
                        accessibilityID: "zip-copy-added-members")
                    if model.preparedAdditions.contains(where: \.renamed) {
                        Text("Names already in use get a number. The existing items stay in the archive.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if model.isMemberBatchRename {
                    Text("\(model.batchNames.count.formatted()) selected items").interfaceFont(.callout).foregroundStyle(.secondary)
                    if let covered = model.memberSelectionPreview?.covered, covered > 0 {
                        Text("\(covered.formatted()) nested \(covered == 1 ? "item follows its folder" : "items follow their folders") and keep their names.")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    BatchRenameRuleFields(options: $model.batchOptions, settings: model.settings)
                    BatchRenamePreviewTable(rows: model.batchRows, selection: $batchSelection).frame(height: 220)
                }
                if model.isMemberCreation || model.memberPath != nil {
                    let path = model.isMemberCreation ? model.additionFolder : model.memberPath ?? ""
                    let folderName = model.isDirectoryRename || model.isMemberNewFolder
                    Label(model.isMemberCreation ? "Inside \(path)" : path, systemImage: model.isMemberCreation || folderName ? "folder" : "doc")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(path)
                    Text(folderName ? "New folder name" : model.isMemberNewFile ? "File name" : "New item name")
                        .interfaceFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField(folderName ? "New folder name" : model.isMemberNewFile ? "File name" : "New item name", text: $model.memberName)
                        .textFieldStyle(ToolTextEntryStyle())
                        .focused($memberNameFocused).accessibilityIdentifier("zip-member-new-name")
                        .help(model.isMemberNewFile ? "Include a file extension, such as notes.txt or settings.json. The new file starts empty."
                            : model.isMemberNewFolder ? "Choose an unused folder name without / or other folder separators."
                            : model.outputFormat == .tar ? "Use a name without folder separators. Unicode names are supported."
                            : "Use a name without folder separators. Some older ZIPs require basic Latin characters, numbers and punctuation.")
                }
                if !model.updatesOriginal {
                    Text(model.isMemberCopy ? "Copy name" : "Archive name")
                        .interfaceFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Archive name", text: $model.name).textFieldStyle(ToolTextEntryStyle())
                        .accessibilityIdentifier("zip-copy-name")
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Destination").interfaceFont(.caption).foregroundStyle(.secondary)
                            Text(model.parent.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer()
                        Button(model.isMemberCopy ? "Allow Folder Access…" : "Choose Folder…", action: model.chooseDestination)
                            .disabled(!model.canReview).fixedSize()
                    }
                } else if model.plan == nil, !model.isPreparing, model.outcome == nil {
                    Button("Allow Folder Access…", action: model.chooseDestination)
                        .disabled(!model.canReview).help(model.parent.path)
                }
                if !model.isMemberCreation && !model.isMemberDuplicate && !model.isMemberMove && !model.isMemberBatchRename {
                    Group {
                        if let summary = model.summary {
                            Text("\(model.updatesOriginal ? "Updated \(model.formatName)" : model.isMemberCopy ? "New copy" : "Selection"): \(summary.files.formatted()) \(summary.files == 1 ? "file" : "files") · \(summary.folders.formatted()) \(summary.folders == 1 ? "folder" : "folders") · \(ArchiveBrowserModel.size(summary.bytes))")
                        } else { Text(" ") }
                    }.interfaceFont(.callout).foregroundStyle(.secondary)
                        .frame(minHeight: 20, alignment: .leading)
                }
            }.disabled(model.isRunning || model.outcome != nil || model.isChoosing)
            if model.isMemberRemoval {
                ArchiveCopyMemberList(paths: model.removedPaths, folderPaths: model.removedFolderPaths,
                    coveredSelectionCount: model.coveredRemovedSelections)
                if let summary = model.summary, summary.files == 0, summary.folders == 0 {
                    Text(model.updatesOriginal ? "The \(model.formatName) will be empty after this update." : "The new archive will be empty.").interfaceFont(.callout.weight(.semibold))
                }
            }
            if model.isMemberDuplicate, let selection = model.memberSelectionPreview {
                let count = selection.paths.count
                let copying = model.copyDestination != nil
                if let path = model.copyDestination {
                    let folder = path.isEmpty ? "Archive root" : path
                    Label("Copy into \(folder)", systemImage: "folder")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(folder)
                }
                ArchiveCopyMemberList(paths: selection.paths, folderPaths: selection.folders,
                    coveredSelectionCount: selection.covered,
                    title: "\(count.formatted()) \(count == 1 ? "item" : "items") to \(copying ? "copy" : "duplicate")",
                    accessibilityID: "zip-copy-duplicate-members")
            }
            if model.isMemberMove, let selection = model.memberSelectionPreview, let path = model.moveDestinationPath {
                let folder = path.isEmpty ? "Archive root" : path
                Label("Move into \(folder)", systemImage: "folder")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(folder)
                ArchiveCopyMemberList(paths: selection.paths, folderPaths: selection.folders,
                    coveredSelectionCount: selection.covered, title: "Items to move",
                    accessibilityID: "zip-move-members")
            }
            if model.isMemberGrouping, let selected = model.memberSelectionPreview {
                ArchiveCopyMemberList(paths: selected.paths, folderPaths: selected.folders,
                    coveredSelectionCount: selected.covered,
                    title: "Items for the new folder", accessibilityID: "zip-group-members")
            }
            if model.offersOutputFormats {
                Picker("Format", selection: Binding(get: { model.outputFormat }, set: model.chooseOutputFormat)) {
                    Text("ZIP").tag(ArchiveCreationFormat.zip)
                    Text("TAR (uncompressed)").tag(ArchiveCreationFormat.tar)
                    if TARGzipCreationFeature.available { Text("TAR + gzip").tag(ArchiveCreationFormat.tarGzip) }
                    if TARBzip2Feature.available { Text("TAR + bzip2").tag(ArchiveCreationFormat.tarBzip2) }
                }.pickerStyle(.segmented).disabled(model.isRunning || model.outcome != nil || model.isChoosing)
            }
            if model.outputFormat == .zip && (!model.isMemberCopy || model.isMemberAddition) { Picker("Compression", selection: $model.compression) {
                Text("Balanced").tag(ZIPCompression.balanced)
                Text("Fast").tag(ZIPCompression.fast)
                Text("Store only").tag(ZIPCompression.store)
            }.pickerStyle(.segmented).disabled(model.isRunning || model.outcome != nil || model.isChoosing) }
            if model.outputFormat == .tarGzip || model.outputFormat == .tarBzip2 {
                Picker("Compression", selection: Binding<TARCompression?>(get: {
                    model.outputFormat == .tarBzip2 && model.isMemberCopy && model.keepsCurrentTARCompression ? nil : model.tarCompression
                }, set: { value in
                    if let value { model.keepsCurrentTARCompression = false; model.tarCompression = value }
                    else { model.keepsCurrentTARCompression = true }
                })) {
                    if model.outputFormat == .tarBzip2 && model.isMemberCopy { Text("Keep current").tag(Optional<TARCompression>.none) }
                    ForEach(model.tarCompressionChoices, id: \.self) { choice in
                        Text(choice == .gzipBalanced || choice == .bzip2Balanced ? "Balanced"
                            : choice == .gzipFast || choice == .bzip2Fast ? "Fast" : "Smallest").tag(Optional.some(choice))
                    }
                }.pickerStyle(.segmented).disabled(model.isRunning || model.outcome != nil || model.isChoosing)
                Text("Up to 128 MiB before and after compression, including the TAR headers.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Text(model.notice).interfaceFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Text(model.isMemberBatchRename ? (model.updatesOriginal
                ? "Folders keep all their contents. One Undo restores every earlier name; existing names are never merged or replaced."
                : "The archive copy has the reviewed names. Folders keep their contents and your original stays unchanged.")
                : model.isMemberMove ? (model.updatesOriginal
                ? "Undo restores the items to their earlier locations."
                : "The new archive has the moved items. Your original archive stays unchanged.")
                : model.isMemberDuplicate ? (model.updatesOriginal
                ? "Selected folders are copied with their contents. Undo restores the earlier archive."
                : "Selected folders are copied with their contents. Your original archive stays unchanged.")
                : model.isMemberNewFile ? (model.updatesOriginal
                ? "The new file starts empty. Other items in the archive are kept, and Undo restores the earlier archive."
                : "The new archive copy includes this empty file. Your original archive and all existing items stay unchanged.")
                : model.isMemberGrouping ? (model.updatesOriginal
                ? "These items move into the new folder together. Existing folders are never merged; one Undo restores the earlier archive."
                : "The archive copy groups these items in the new folder. Your original archive stays unchanged.")
                : model.isMemberNewFolder ? (model.updatesOriginal
                ? "The new folder starts empty. Other items in the archive are kept, and Undo restores the earlier archive."
                : "The new archive copy includes this empty folder. Your original archive and all existing items stay unchanged.")
                : model.updatesOriginal ? (model.isMemberAddition
                ? model.additionExplanation
                : model.isMemberRemoval ? "These items and everything inside each selected folder are removed from this archive. The earlier archive is kept for Undo."
                : "This item keeps its contents under its new name. The earlier archive is kept for Undo.")
                : model.isMemberAddition ? model.additionExplanation
                : model.isMemberRemoval ? (model.removedFolderPaths.isEmpty
                    ? "Your original archive stays unchanged. The new copy leaves out the selected files. Folders that existed only through these files may also disappear from the copy; stored empty folders are kept."
                    : "Your original archive stays unchanged. The new copy leaves out these items, including everything inside each selected folder. Other items are kept.")
                : model.isDirectoryRename ? "Your original archive stays unchanged. The new copy keeps this folder and everything inside it together, with its new name. Other items are kept."
                : model.isMemberRename ? "Your original archive stays unchanged. The new copy keeps this item in the same folder with its new name. Archives that cannot be copied safely are left untouched."
                : model.outputFormat == .tar ? "Uncompressed TAR with portable names, contents, dates and basic permissions. Your originals stay unchanged."
                : model.outputFormat == .tarGzip || model.outputFormat == .tarBzip2 ? "Compressed TAR for sharing between devices. Your originals stay unchanged."
                : "Standard ZIP for sharing between devices.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help(model.updatesOriginal ? "The updated archive is checked before it replaces the original. The earlier archive is kept for Undo."
                    : model.isMemberRemoval ? "The archive source and output are checked before saving. Items inside a selected folder are included in that selection; the review lists each selected root once."
                    : model.isMemberCopy ? "Unchanged entries keep their original metadata. Added local items use portable contents, dates and basic permissions; unsupported Mac-specific data is refused."
                    : "The archive keeps names, file contents, basic dates and permissions. Ownership, Finder tags and other Mac-specific metadata are excluded. Items with resource-fork data are refused, and your originals stay unchanged.")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var completedActions: some View {
        Group {
            Button("View Results…", action: model.viewResults).disabled(!model.canViewResults)
            Button(model.updatesOriginal ? "Undo \(model.formatName) Update" : model.isMemberCopy ? "Undo Copy" : "Undo \(model.outputFormat.displayName) Creation", action: model.undo).disabled(!model.canUndo)
            if model.undoOutcome == nil, model.outcome?.result.disposition == .succeeded { Button("Show in Explorer", action: model.showInExplorer) }
        }
    }
    private var footer: some View {
        ArchiveReviewFooter(showsCompleted: !model.isRunning && model.outcome != nil) {
            completedActions
        } auxiliary: { reviewActions } primary: { primaryActions }
    }
    @ViewBuilder private var reviewActions: some View {
        if model.isRunning || model.isPreparing {
            Button("Stop", action: model.stop)
        } else if model.outcome == nil {
            if model.updatesOriginal {
                Button("Save \(model.formatName) Copy Instead…", action: model.saveCopyInstead).disabled(!model.canReview)
            }
            if model.plan == nil, !model.isPreparing {
                Button("Review Again", action: model.reviewAgain).disabled(!model.canReview)
            }
            if model.offersFinderFallback {
                Button("Show Sources in Finder", action: model.showSourcesInFinder)
            }
        }
    }
    @ViewBuilder private var primaryActions: some View {
        Button(model.outcome == nil && !model.isRunning ? "Cancel" : "Close") {
            model.window?.performClose(nil)
        }.keyboardShortcut(.cancelAction)
        if !model.isRunning, model.outcome == nil {
            Button(model.createTitle, action: model.create).disabled(!model.canCreate).keyboardShortcut(.defaultAction)
        }
    }
}
@MainActor final class ArchiveCreationWindowController: NSWindowController, NSWindowDelegate {
    let model: ArchiveCreationModel
    var onClose: (() -> Void)?
    init(model: ArchiveCreationModel) {
        self.model = model
        let compactHeight: CGFloat? = model.updatesOriginal
            ? (model.isMemberCreation ? 500 : model.isMemberMove || model.copyDestination != nil ? 560 : model.isMemberDuplicate ? 520 : nil) : nil
        let size = NSSize(width: model.isMemberBatchRename ? 860 : 720,
                          height: model.isMemberBatchRename ? 740 : compactHeight ?? (model.isMemberAddition ? 720 : model.isMemberCopy ? 620 : 540))
        let minimum = NSSize(width: 650, height: compactHeight.map { $0 - 20 } ?? (model.isMemberCopy ? 580 : 500))
        let viewport = ToolWindowChrome.initialViewport(size: size, minimum: minimum, scale: model.settings.interfaceSize.scale)
        let window = ToolWindowChrome.makeWindow(title: model.title, size: viewport.size, minimumSize: viewport.minimum)
        window.contentViewController = InterfaceHostingController(rootView: ArchiveCreationView(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        ToolWindowChrome.install(in: window, settings: model.settings)
        // Installing a replacement content controller can apply its fitting
        // size. Set the actual content geometry after the shared chrome exists.
        window.contentMinSize = viewport.minimum
        window.setContentSize(viewport.size)
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
@MainActor final class ApplicationArchiveCreation {
    static let shared = ApplicationArchiveCreation()
    private(set) var controller: ArchiveCreationWindowController?
    private var retirement: Task<Void, Never>?
    private var automaticCreation: Task<Void, Never>?
    func show(sources: [URL], from browser: BrowserViewController, memberEdit: ArchiveMemberCopyEdit? = nil,
              updateOriginal: Bool = false, addedSource: ArchiveAdditionInput? = nil,
              onMemberCreated: ((URL, String) -> Void)? = nil, onOriginalUpdated: (() -> Void)? = nil,
              automatic: Bool = false) {
        guard ArchiveCreationActivation.available, retirement == nil, browser.canStartArchiveCreation, !sources.isEmpty, sources.count <= 512,
              memberEdit == nil || memberEdit?.available == true,
              !automatic || memberEdit == nil && !GeneratedSandboxReview.nativeTARCreateAdmitted,
              !updateOriginal || memberEdit?.canUpdateOriginal == true,
              let engine = browser.recoverableFileOperations else { return }
        if let controller {
            if controller.model.isRunning { controller.window?.makeKeyAndOrderFront(nil); return }
            Task { [weak self, weak browser] in
                guard let self else { return }; await closeAndDrain()
                guard let browser, !browser.isBrowserSuspended else { return }
                show(sources: sources, from: browser, memberEdit: memberEdit, updateOriginal: updateOriginal,
                     addedSource: addedSource, onMemberCreated: onMemberCreated, onOriginalUpdated: onOriginalUpdated,
                     automatic: automatic)
            }
            return
        }
        let model = ArchiveCreationModel(sources: sources, browser: browser, engine: engine,
            memberEdit: memberEdit, updateOriginal: updateOriginal, onMemberCreated: onMemberCreated,
            onOriginalUpdated: onOriginalUpdated, automatic: automatic)
        let created = ArchiveCreationWindowController(model: model)
        created.onClose = { [weak self, weak model] in
            guard let self, let model else { return }
            automaticCreation?.cancel()
            retirement = Task { [self] in await model.closeAndDrain(); controller = nil; retirement = nil }
        }
        controller = created
        if browser.isControlledVerification { created.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
        else if let window = created.window { ToolWindowChrome.position(window, relativeTo: browser.view.window) }
        if automatic {
            browser.status.stringValue = "Preparing ZIP…"
            automaticCreation = Task { [self, created] in
                defer { automaticCreation = nil }
                await ArchiveAutomaticAction.run(model, isCurrent: { [weak self, weak created] in
                    guard let self, let created else { return false }
                    return controller === created && retirement == nil
                }, reveal: { [weak self, weak created] in
                    guard let self, let created else { return }; reveal(created)
                }, close: { [weak created] in created?.close() })
            }
        } else {
            reveal(created)
            if let addedSource, model.isMemberAddition { model.receiveAddedSources(addedSource) }
            else if model.isMemberAddition, !browser.isControlledVerification { model.chooseAdditions() }
            else { model.requestPreview() }
        }
    }
    private func reveal(_ created: ArchiveCreationWindowController) {
        guard controller === created, retirement == nil, let window = created.window, !window.isVisible else { return }
        created.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
    func closeAndDrain() async {
        let automaticCreation = automaticCreation
        controller?.close()
        if let automaticCreation { await automaticCreation.value }
        if let retirement { await retirement.value }
    }
    func closeIdleWindow() { if controller?.model.isRunning == false { controller?.close() } }
}
@MainActor extension BrowserViewController {
    var canStartArchiveCreation: Bool { ArchiveCreationActivation.available && !isBrowserSuspended && !isReadOnlyFileSession && recoverableFileOperations != nil && canRunExclusiveFileCommand }
    var canCreateZIP: Bool {
        canStartArchiveCreation && canModifyCurrentFolder && (1...512).contains(orderedSelectedURLs.count)
            && orderedSelectedURLs.allSatisfy { url in
                guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
                return [.file, .directory, .package].contains(displayedEntries[row].kind)
            }
    }
    @objc func createZIP(_ sender: Any?) {
        if canCreateZIP { ApplicationArchiveCreation.shared.show(sources: orderedSelectedURLs, from: self) }
    }
    var canCompressSelection: Bool { canCreateZIP && !GeneratedSandboxReview.nativeTARCreateAdmitted }
    @objc func compressSelection(_ sender: Any?) {
        if canCompressSelection { ApplicationArchiveCreation.shared.show(sources: orderedSelectedURLs, from: self, automatic: true) }
    }
}
