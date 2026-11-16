import AppKit
import Combine
import ExplorerCore
import FileOperations
import LocalStorage
import SwiftUI

struct ZIPClipboardSource {
    let generation: UUID
    let folder: ZIPFolderID
    let ids: Set<ZIPItemID>
    let archiveURL: URL
    let archivePaths: [String]
    let memberSelection: ZIPMemberSetSelection?

    init(generation: UUID, folder: ZIPFolderID, ids: Set<ZIPItemID>, selection: ZIPMemberSetSelection) {
        self.generation = generation; self.folder = folder; self.ids = ids
        archiveURL = selection.archiveURL; archivePaths = selection.archivePaths
        memberSelection = selection
    }
    /// These are display metadata and live catalog IDs, never serialized file
    /// authority. Paste obtains its checked extraction selection from the owner.
    init(generation: UUID, folder: ZIPFolderID, ids: Set<ZIPItemID>, archiveURL: URL, paths: [String]) {
        self.generation = generation; self.folder = folder; self.ids = ids
        self.archiveURL = archiveURL; archivePaths = paths; memberSelection = nil
    }
}

enum ArchiveBrowseActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-zip-browser")
        #else
        enabled
        #endif
    }
}

enum ArchiveContentCheckActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-zip-contents")
        #else
        enabled
        #endif
    }
}
enum SelectedArchiveExtractionActivation {
    static var available: Bool { ArchiveExtractionActivation.available }
}

enum ArchiveNameScope: String, CaseIterable, Identifiable {
    case folder, archive
    var id: Self { self }
    var title: String { self == .folder ? "Folder" : "Entire Archive" }
}

enum ArchiveOrderingActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-archive-sorting")
        #else
        enabled
        #endif
    }
}

@MainActor final class ArchiveBrowserModel: ObservableObject {
    @Published private(set) var source: URL?
    @Published private(set) var page: ZIPDirectoryPage?
    @Published private(set) var searchPage: ZIPNameSearchPage?
    @Published private(set) var isQueryPending = false
    @Published private(set) var viewIsCurrent = false
    @Published private(set) var ordering = ZIPArchiveOrder()
    @Published var nameScope = ArchiveNameScope.folder { didSet { if nameScope != oldValue && !changingFilter { applyFilter() } } }
    @Published private(set) var summary: ZIPArchiveSummary?
    @Published private(set) var isLoading = false
    @Published private(set) var isPaging = false
    @Published private(set) var isChecking = false
    @Published private(set) var isPreparingSelection = false
    @Published private(set) var externalExportReady = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var contentProgress: ZIPContentProgress?
    @Published private(set) var contentReport: ZIPContentReport?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var suspended = false
    @Published private(set) var notice = ""
    @Published var filter = "" { didSet { scheduleFilter() } }
    @Published var selection = Set<ZIPItemID>() {
        didSet { if selection != oldValue { selectionWork?.cancel(); prepareExternalExport() } }
    }
    let settings: BrowserSettings
    private let reader: ZIPArchiveReader
    private let textPreview: ArchiveTextPreviewOwner
    private var session: ZIPArchiveSession?
    private var generation = UUID()
    private var closed = false
    private var work: Task<Void, Never>?
    private var readTask: Task<ZIPArchiveSession, Error>?
    private var openingGeneration: UUID?
    private var pageTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var checkingTask: Task<ZIPContentReport, Error>?
    private var checkingWork: Task<Void, Never>?
    private var checkingProgressTask: Task<Void, Never>?
    private var selectionWork: Task<Void, Never>?
    private let exportPreparation = ArchivePromisePreparation<Set<ZIPItemID>>()
    private var handedExports: [ArchivePromiseExport] = []
    private var pageGeneration = UUID()
    private struct Visit: Equatable {
        let folder: ZIPFolderID
        var ordering = ZIPArchiveOrder()
        var scope = ArchiveNameScope.folder
        var query = ""
        var offset = 0
    }
    private struct PageRequest {
        let visit: Visit, symbols: Bool, token: UUID
        var selected: ZIPItemID?
    }
    private var desiredPage: PageRequest?
    private var createdMemberToReveal: (archive: URL, path: String)?
    private var desired: Request?
    private var lastRequest: Request?
    private var history: [Visit] = []
    private var historyIndex = 0
    private var changingFilter = false
    private var matchingObservation: AnyCancellable?
    weak var window: NSWindow?
    var embeddedNavigate: (([String], ArchiveBrowseState) -> Void)?
    var embeddedBack: (() -> Void)?
    var embeddedForward: (() -> Void)?
    var embeddedUp: (() -> Void)?
    var embeddedIsPresented: (() -> Bool)?
    private var permitsEmbeddedAction: Bool { embeddedIsPresented?() ?? true }
    var embeddedScrollOffset: Double = 0
    private struct EmbeddedPresentation {
        let location: ArchiveLocation
        let state: ArchiveBrowseState
        let token: UUID
    }
    private var embeddedPresentation: EmbeddedPresentation?
    private var embeddedInstalledToken: UUID?
    private var desiredEmbedded: EmbeddedPresentation?
    private var desiredEmbeddedNavigation: (visit: Visit, paths: Set<String>, token: UUID)?
    private var embeddedSelectedPaths = Set<String>()
    private final class Request {
        let source: URL
        weak var browser: BrowserViewController?
        init(_ source: URL, browser: BrowserViewController) { self.source = source; self.browser = browser }
    }
    init(settings: BrowserSettings, reader: ZIPArchiveReader) {
        self.settings = settings; self.reader = reader
        textPreview = ArchiveTextPreviewOwner(reader: reader, settings: settings)
        textPreview.onBusy = { [weak self] in self?.isPreviewing = $0 }
        exportPreparation.changed = { [weak self] in
            guard let self else { return }
            externalExportReady = exportPreparation.offer(for: selection) != nil
        }
        exportPreparation.refreshRequested = { [weak self] in self?.prepareExternalExport() }
        matchingObservation = settings.$symbolTolerantNames.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyFilter() }
    }
    var visibleItems: [ZIPArchiveItem] { searchPage?.items ?? page?.items ?? [] }
    var visibleOffset: Int { searchPage?.offset ?? page?.offset ?? 0 }
    var visibleTotal: Int { searchPage?.total ?? page?.total ?? 0 }
    var hasNextPage: Bool { searchPage?.hasNext ?? page?.hasNext ?? false }
    var isSearchResults: Bool { searchPage != nil }
    var breadcrumbs: [ZIPBreadcrumb] { isSearchResults ? Array((page?.breadcrumbs ?? []).prefix(1)) : page?.breadcrumbs ?? [] }
    var canUp: Bool { !isLoading && (embeddedUp != nil || isSearchResults || (page?.breadcrumbs.count ?? 0) > 1) }
    var canShowInArchive: Bool { isSearchResults && viewIsCurrent && !isPaging && !isQueryPending && !isPreparingSelection && !suspended && !closed
        && selection.count == 1 && visibleItems.contains { selection.contains($0.id) } }
    var canBack: Bool { (embeddedBack != nil || historyIndex > 0) && !isLoading }
    var canOrder: Bool { ArchiveOrderingActivation.available && !closed && !suspended && !isLoading && !isChecking
        && !isPreparingSelection && !isPreviewing && history.indices.contains(historyIndex)
        && filter == history[historyIndex].query && nameScope == history[historyIndex].scope
        && (page != nil || searchPage != nil) }
    @discardableResult func order(by value: ZIPArchiveOrder) -> Bool {
        guard canOrder else { return false }
        if ordering == value && viewIsCurrent && !isPaging { return true }
        ordering = value; history[historyIndex].ordering = value; history[historyIndex].offset = 0
        filterTask?.cancel(); requestPage(history[historyIndex]); return true
    }
    @discardableResult func focusNameSearch() -> Bool {
        guard !closed, !suspended, let window, let content = window.contentView else { return false }
        var pending = [content], visited = 0
        while let view = pending.popLast(), visited < 4_096 {
            visited += 1
            if let field = view as? NSTextField, field.identifier?.rawValue == "archive-name-query", field.isEnabled {
                guard window.makeFirstResponder(field) else { return false }
                field.selectText(nil); return true
            }
            pending.append(contentsOf: view.subviews)
        }
        return false
    }
    var showsStop: Bool { isLoading || isChecking || isPreparingSelection || isPreviewing || isPaging || isQueryPending }
    var retainsPreviewPresentation: Bool { textPreview.retainsPresentation }
    var canForward: Bool { (embeddedForward != nil || historyIndex + 1 < history.count) && !isLoading }
    var canCheckContents: Bool {
        ArchiveContentCheckActivation.available && canPrepareArchiveOperation && viewIsCurrent
            && summary != nil && session != nil && !ApplicationFileActivity.gate.isClosed
    }
    private var canPrepareArchiveOperation: Bool {
        permitsEmbeddedAction && !closed && !suspended && !isLoading && !isChecking
            && !isPreviewing && !isPreparingSelection && (page != nil || searchPage != nil)
            && !isPaging && !isQueryPending
    }
    var canExtract: Bool {
        canPrepareArchiveOperation && lastRequest?.browser?.canStartArchiveExtraction == true
    }
    var canExtractWhole: Bool { canExtract && ArchiveExtractionActivation.wholeArchiveAvailable }
    private var canAuthorZIPCopy: Bool {
        canPrepareArchiveOperation && lastRequest?.browser?.canStartArchiveCreation == true
    }
    var canPreviewSelected: Bool { canPreviewSelection(selection) }
    var preferredPreview: ArchivePreviewMode {
        .preferred(for: visibleItems.first { selection.contains($0.id) }?.name)
    }
    func observedMember(_ ids: Set<ZIPItemID>) -> ArchiveMemberObservation? {
        guard permitsEmbeddedAction, !closed, !suspended, viewIsCurrent, !isLoading, !isPaging, !isQueryPending,
              ids == selection, ids.count == 1, let id = ids.first, let source,
              let item = visibleItems.first(where: { $0.id == id }) else { return nil }
        return .init(zip: item, source: source)
    }
    func showMemberProperties(_ ids: Set<ZIPItemID>, relativeTo parent: NSWindow?) {
        guard let member = observedMember(ids), let browser = lastRequest?.browser,
              !browser.isBrowserSuspended else { return }
        browser.showItemProperties(.archive(member), relativeTo: parent)
    }
    func canPreviewSelection(_ ids: Set<ZIPItemID>) -> Bool {
        ZIPTextPreviewFeature.available && permitsEmbeddedAction && !closed && !suspended && !isLoading && !isChecking && !isPreparingSelection
            && viewIsCurrent && !isPaging && !isQueryPending && ids.count == 1 && !ApplicationFileActivity.gate.isClosed
            && visibleItems.contains(where: { ids.contains($0.id) && $0.kind == .file })
    }
    func previewSelected() { previewSelection(selection) }
    var canEditSelectedText: Bool { canEditTextSelection(selection) }
    func canEditTextSelection(_ ids: Set<ZIPItemID>) -> Bool {
        lastRequest?.browser?.canOpenZIPTextEditor == true && canPreviewSelection(ids)
            && visibleItems.contains { ids.contains($0.id) && !$0.isEncrypted && !ArchiveImagePreview.supportsFilename($0.name)
                && ($0.method == 0 || $0.method == 8) && $0.logicalBytes <= ZIPTextPreview.maximumUTF8Bytes }
    }
    func editSelectedText() { editTextSelection(selection) }
    func editTextSelection(_ ids: Set<ZIPItemID>) {
        guard canEditTextSelection(ids), let id = ids.first, let session, let source,
              let item = visibleItems.first(where: { $0.id == id }),
              let browser = lastRequest?.browser, !browser.isBrowserSuspended else { return }
        let token = generation, pageToken = pageGeneration
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let chosen = try await session.selectionForTextPreview(id)
                let lifetime = await browser.accessLifetime(for: [source, source.deletingLastPathComponent()])
                guard permitsEmbeddedAction, !Task.isCancelled, !closed, !suspended,
                      token == generation, pageToken == pageGeneration, !browser.isBrowserSuspended else { return }
                ApplicationLocalTextEditors.shared.openArchiveText(chosen, source: source, path: item.path,
                    reader: reader, retaining: lifetime, from: browser)
            } catch {
                if !closed, !Task.isCancelled, token == generation { notice = ArchiveTextDocumentController.message(error) }
            }
        }
    }
    func previewSelectedAsBytes() { previewSelection(selection, mode: .hexadecimal) }
    func previewSelection(_ ids: Set<ZIPItemID>, mode explicitMode: ArchivePreviewMode? = nil) {
        guard canPreviewSelection(ids), let id = ids.first, let session, let source,
            let browser = lastRequest?.browser, !browser.isBrowserSuspended else { return }
        let mode = explicitMode ?? .preferred(for: visibleItems.first { $0.id == id }?.name)
        guard mode != .hexadecimal || ZIPBytePreviewFeature.available else { return }
        let token = generation, pageToken = pageGeneration
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let chosen = if mode == .image { try await session.selectionForImagePreview(id) }
                    else { try await session.selectionForTextPreview(id) }
                #if DEBUG
                    if let beforeSelectionForVerification { await beforeSelectionForVerification() }
                #endif
                guard permitsEmbeddedAction, !Task.isCancelled, !closed, !suspended, token == generation, pageToken == pageGeneration else { return }
                let lifetime = await browser.accessLifetime(for: [source])
                guard permitsEmbeddedAction, !Task.isCancelled, !closed, !suspended, token == generation, pageToken == pageGeneration,
                    !browser.isBrowserSuspended, !ApplicationFileActivity.gate.isClosed else { return }
                textPreview.open(chosen, retaining: lifetime, offscreen: browser.isControlledVerification, mode: mode)
            } catch {
                if !closed, !Task.isCancelled, token == generation { notice = ArchiveTextPreviewOwner.message(error, mode: mode) }
            }
        }
    }
    #if DEBUG
    var textPreviewForVerification: ArchiveTextPreviewOwner { textPreview }
    var beforePageForVerification: (@MainActor () async -> Void)?
    var beforeSelectionForVerification: (@MainActor () async -> Void)?
    private(set) var pageRequestsForVerification = 0
    var memberDragHandoffForVerification: ((ArchivePromiseExport) -> Void)?
    #endif
    #if DEBUG || TRAVERSE_SFTP_EDITOR_QA
    weak var rowsForVerification: ArchiveMetadataRows?
    var lastHandedExportForVerification: ArchivePromiseExport? { handedExports.last }
    #endif
    var canExtractSelected: Bool { canExtractSelection(selection) }
    var canRenameMemberInCopy: Bool { canRenameMemberInCopy(selection) }
    func canRenameMemberInCopy(_ ids: Set<ZIPItemID>) -> Bool {
        ZIPMemberRenameFeature.available && (ids.count == 1 || page != nil && !isSearchResults)
            && canCopyMembers(ids, maximum: 128,
            allowingFolders: ZIPMemberRenameFeature.directoriesAvailable)
    }
    var canRemoveMembersInCopy: Bool { canRemoveMembersInCopy(selection) }
    var canAddMembersInCopy: Bool {
        ZIPMemberAdditionFeature.available && source?.pathExtension.lowercased() == "zip"
            && canAuthorZIPCopy && viewIsCurrent && !isSearchResults && page != nil
    }
    func canAddLocalFiles(to folder: ZIPFolderID?) -> Bool {
        canAddMembersInCopy && (folder == nil || page?.items.contains(where: { $0.folder == folder }) == true)
    }
    var canCreateFolderInZIP: Bool { ZIPMemberCreationFeature.available && canAddMembersInCopy }
    var canCreateFileInZIP: Bool { canCreateFolderInZIP }
    var canGroupSelection: Bool {
        ZIPMemberCreationFeature.available && page != nil && !isSearchResults && canDuplicateMembers(selection)
    }
    func groupSelection(updateOriginal: Bool) {
        guard canGroupSelection else { return }
        prepareMemberCopy(selection, action: .group, updateOriginal: updateOriginal)
    }
    private enum ZIPDestinationAction {
        case add, newFolder, newFile
        func intent(_ selection: ZIPMemberAdditionSelection) -> ArchiveMemberCopyEdit {
            switch self {
            case .add: .add(selection)
            case .newFolder: .newFolder(selection)
            case .newFile: .newFile(selection)
            }
        }
    }
    @discardableResult func addMembersInCopy(_ addedSource: LocalFileDropSource? = nil, to folder: ZIPFolderID? = nil,
                                            updateOriginal: Bool = false) -> Bool {
        let input = addedSource.map { ArchiveAdditionInput(urls: $0.urls, access: $0.access) }
        return prepareZIPDestination(input, to: folder, updateOriginal: updateOriginal, action: .add)
    }
    @discardableResult func addCopiedFiles(_ input: ArchiveAdditionInput, updateOriginal: Bool) -> Bool {
        prepareZIPDestination(input, to: nil, updateOriginal: updateOriginal, action: .add)
    }
    @discardableResult func createFolderInZIP(updateOriginal: Bool) -> Bool {
        guard canCreateFolderInZIP else { return false }
        return prepareZIPDestination(nil, to: nil, updateOriginal: updateOriginal, action: .newFolder)
    }
    @discardableResult func createFileInZIP(updateOriginal: Bool) -> Bool {
        guard canCreateFileInZIP else { return false }
        return prepareZIPDestination(nil, to: nil, updateOriginal: updateOriginal, action: .newFile)
    }
    private func prepareZIPDestination(_ addedSource: ArchiveAdditionInput?, to folder: ZIPFolderID?,
                                       updateOriginal: Bool, action: ZIPDestinationAction) -> Bool {
        guard !updateOriginal || ZIPOriginalUpdateFeature.available,
              canAddLocalFiles(to: folder), let session, let source, let page,
              let browser = lastRequest?.browser else { return false }
        let token = generation, pageToken = pageGeneration
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let selected = try await session.selectionForMemberAddition(folder ?? page.folder)
                guard permitsEmbeddedAction, !Task.isCancelled, !closed, !suspended,
                      token == generation, pageToken == pageGeneration,
                      !browser.isBrowserSuspended, browser.canStartArchiveCreation,
                      !ApplicationFileActivity.gate.isClosed else { return }
                guard addedSource?.isCurrent() != false else {
                    notice = "The clipboard changed. Copy the items again before pasting."
                    return
                }
                let edit = action.intent(selected)
                ApplicationArchiveCreation.shared.show(sources: [source], from: browser, memberEdit: edit,
                    updateOriginal: updateOriginal, addedSource: addedSource,
                    onMemberCreated: { [weak self] archive, path in self?.revealCreatedMember(archive: archive, path: path) })
            } catch { if !closed, !Task.isCancelled, generation == token { notice = ArchiveCreationModel.message(error) } }
        }
        return true
    }
    /// Publication has finished through the operation owner. Wait for this
    /// view's fresh catalog, then reveal it and, for a supported file, mint the
    /// normal selected-member editor input.
    /// A filename is a reveal request, never a local URL or edit capability.
    private func revealCreatedMember(archive: URL, path: String) {
        guard source == archive, !closed, !suspended, permitsEmbeddedAction else { return }
        createdMemberToReveal = (archive, path)
        revealCreatedMemberIfReady()
    }
    private func revealCreatedMemberIfReady() {
        guard let created = createdMemberToReveal, !isLoading, !isPaging, viewIsCurrent else { return }
        createdMemberToReveal = nil
        guard source == created.archive, permitsEmbeddedAction,
              let item = visibleItems.first(where: { $0.path.utf8.elementsEqual(created.path.utf8) }) else { return }
        selection = [item.id]
        if canEditTextSelection(selection), settings.editorPreferences.route(forFilename: item.name, command: .ordinaryOpen) == .traverse {
            editTextSelection(selection)
        }
    }
    func canRemoveMembersInCopy(_ ids: Set<ZIPItemID>) -> Bool {
        ZIPMemberRemovalFeature.available && canCopyMembers(ids, maximum: 128,
            allowingFolders: ZIPMemberRemovalFeature.directoriesAvailable)
    }
    var canDuplicateMembers: Bool { canDuplicateMembers(selection) }
    func canDuplicateMembers(_ ids: Set<ZIPItemID>) -> Bool {
        ZIPMemberRenameFeature.available && canCopyMembers(ids, maximum: 128,
            allowingFolders: ZIPMemberRenameFeature.directoriesAvailable)
    }
    func canMoveMembers(_ ids: Set<ZIPItemID>) -> Bool {
        ZIPOriginalUpdateFeature.available && !isSearchResults && canDuplicateMembers(ids)
    }
    func canMoveMembers(_ ids: Set<ZIPItemID>, into folder: ZIPFolderID) -> Bool {
        canMoveMembers(ids) && visibleItems.contains { $0.folder == folder && !ids.contains($0.id) }
    }
    private func canCopyMembers(_ ids: Set<ZIPItemID>, maximum: Int, allowingFolders: Bool = false) -> Bool {
        source?.pathExtension.lowercased() == "zip" && canAuthorZIPCopy && viewIsCurrent
            && (1...maximum).contains(ids.count)
            && visibleItems.filter { item in
                ids.contains(item.id) && (allowingFolders && item.kind == .directory
                    || item.kind == .file && !item.isEncrypted && [0, 8].contains(item.method))
            }.count == ids.count
    }
    func renameMemberInCopy(_ ids: Set<ZIPItemID>, updateOriginal: Bool = false) {
        prepareMemberCopy(ids, action: .rename, updateOriginal: updateOriginal)
    }
    func removeMembersInCopy(_ ids: Set<ZIPItemID>, updateOriginal: Bool = false) {
        prepareMemberCopy(ids, action: .remove, updateOriginal: updateOriginal)
    }
    func duplicateMembers(_ ids: Set<ZIPItemID>, updateOriginal: Bool) {
        prepareMemberCopy(ids, action: .duplicate, updateOriginal: updateOriginal)
    }
    @discardableResult
    func moveMembers(_ offer: ArchiveMemberDragOffer, into folder: ZIPFolderID) -> Bool {
        guard isCurrentMemberDrag(offer) else { return false }
        return prepareMemberCopy(offer.ids, action: .move(folder), updateOriginal: true)
    }

    func canCaptureClipboardMembers(_ operation: TransferClipboardFeedback.Intent) -> Bool {
        guard page != nil else { return false }
        if operation == .move { return canMoveMembers(selection) }
        // Reading a selection for extraction does not require ZIP authoring.
        // Preserve same-ZIP Copy while the separate local export route is held.
        return canMoveMembers(selection)
            || ArchiveMemberDragActivation.available && canExtractSelection(selection)
                && visibleItems.filter { selection.contains($0.id) }.allSatisfy {
                    $0.kind == .directory || !$0.isEncrypted && [0, 8].contains($0.method)
                }
    }

    func captureClipboardMembers(_ operation: TransferClipboardFeedback.Intent,
        _ publish: @escaping @MainActor (ZIPClipboardSource) -> Void) {
        guard canCaptureClipboardMembers(operation), let session, let page, let source else { return }
        let token = generation, pageToken = pageGeneration, ids = selection
        if operation == .copy && !canMoveMembers(ids) {
            // Read-only ZIP-compatible files and larger extraction selections
            // do not inherit the smaller member-rewrite token's limits.
            let paths = visibleItems.filter { ids.contains($0.id) }.map(\.path)
            guard paths.count == ids.count else { return }
            publish(.init(generation: token, folder: page.folder, ids: ids, archiveURL: source, paths: paths))
            return
        }
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let selected = try await session.selectionForMemberChanges(ids)
                guard !Task.isCancelled, permitsEmbeddedAction, !closed, !suspended,
                      generation == token, pageGeneration == pageToken, selection == ids else { return }
                publish(.init(generation: token, folder: page.folder, ids: ids, selection: selected))
            } catch { if !closed, !Task.isCancelled, generation == token { notice = ArchiveCreationModel.message(error) } }
        }
    }

    func retainsClipboard(_ source: ZIPClipboardSource) -> Bool {
        !closed && !suspended && session != nil && generation == source.generation
    }

    func matchesClipboardSelection(_ source: ZIPClipboardSource) -> Bool {
        showsCut(source) && !isSearchResults && selection == source.ids
    }

    func showsCut(_ cut: ZIPClipboardSource) -> Bool {
        retainsClipboard(cut) && viewIsCurrent && (isSearchResults || page?.folder == cut.folder)
    }

    func canPasteMembers(_ source: ZIPClipboardSource, operation: TransferClipboardFeedback.Intent) -> Bool {
        guard retainsClipboard(source), let members = source.memberSelection,
              ZIPOriginalUpdateFeature.available, canAuthorZIPCopy,
              viewIsCurrent, !isSearchResults, let page,
              operation == .copy || page.folder != source.folder else { return false }
        let path = page.breadcrumbs.dropFirst().map(\.name)
        return !members.folderPaths.contains { path.starts(with: $0.split(separator: "/").map(String.init)) }
    }

    func pasteMembers(_ source: ZIPClipboardSource, context: ScopedItemPaste) {
        guard canPasteMembers(source, operation: context.intent.operation), let page else { return }
        _ = prepareMemberCopy(selection, action: .paste(source, page.folder, context), updateOriginal: true)
    }

    func canExportClipboard(_ source: ZIPClipboardSource) -> Bool {
        ArchiveExtractionActivation.wholeArchiveAvailable && retainsClipboard(source)
            && !isChecking && !isPreviewing && !isPreparingSelection && !isLoading
            && lastRequest?.browser?.isBrowserSuspended == false
    }

    func exportClipboard(_ copied: ZIPClipboardSource, context: ScopedItemPaste, to target: BrowserViewController) {
        guard canExportClipboard(copied), let session, let source, source == copied.archiveURL,
              let origin = lastRequest?.browser, let paste = ArchiveLocalPaste(context, to: target) else { return }
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let chosen = try await Self.extractionSelection(copied.ids, in: session, directRoot: copied.ids.count == 1)
                #if DEBUG
                if let beforeSelectionForVerification { await beforeSelectionForVerification() }
                #endif
                try await paste.present(chosen, source: source, from: origin)
            } catch { paste.report(error) }
        }
    }

    private enum ZIPSelectionAction {
        case rename, remove, duplicate, group, move(ZIPFolderID)
        case paste(ZIPClipboardSource, ZIPFolderID, ScopedItemPaste)
    }
    @discardableResult
    private func prepareMemberCopy(_ ids: Set<ZIPItemID>, action: ZIPSelectionAction, updateOriginal: Bool) -> Bool {
        let canPrepare = switch action {
        case .rename: canRenameMemberInCopy(ids)
        case .remove: canRemoveMembersInCopy(ids)
        case .duplicate: canDuplicateMembers(ids)
        case .group: canGroupSelection
        case .move(let folder): canMoveMembers(ids, into: folder)
        case .paste(let source, _, let context): context.isCurrent() && canPasteMembers(source, operation: context.intent.operation)
        }
        guard !updateOriginal || ZIPOriginalUpdateFeature.available,
              canPrepare, selection == ids,
              let session, let source, let browser = lastRequest?.browser else { return false }
        let token = generation, pageToken = pageGeneration
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let edit: ArchiveMemberCopyEdit
                var clipboard: ScopedItemPaste?
                switch action {
                case .rename:
                    if ids.count > 1 { edit = .batchRename(try await session.selectionForMemberChanges(ids)) }
                    else {
                        guard let id = ids.first else { return }
                        edit = .rename(try await session.selectionForMemberRename(id))
                    }
                case .remove: edit = .remove(try await session.selectionForMemberChanges(ids))
                case .duplicate: edit = .duplicate(try await session.selectionForMemberChanges(ids), nil)
                case .group: edit = .group(try await session.selectionForMemberChanges(ids))
                case .move(let folder):
                    let selected = try await session.selectionForMemberChanges(ids)
                    edit = .move(selected, try await session.selectionForMemberAddition(folder))
                case .paste(let source, let folder, let context):
                    guard let members = source.memberSelection else { return }
                    let destination = try await session.selectionForMemberAddition(folder)
                    edit = context.intent.operation == .move ? .move(members, destination) : .duplicate(members, destination)
                    clipboard = context
                }
                guard permitsEmbeddedAction, !Task.isCancelled, !closed, !suspended,
                      token == generation, pageToken == pageGeneration, selection == ids,
                      !browser.isBrowserSuspended, browser.canStartArchiveCreation,
                      !ApplicationFileActivity.gate.isClosed, edit.available,
                      clipboard?.isCurrent() != false else { return }
                ApplicationArchiveCreation.shared.show(sources: [source], from: browser, memberEdit: edit,
                    updateOriginal: updateOriginal,
                    onMemberCreated: { [weak self] archive, path in self?.revealCreatedMember(archive: archive, path: path) },
                    onOriginalUpdated: { [clipboard] in clipboard?.finish(confirmed: true) })
            } catch { if !closed, !Task.isCancelled, generation == token { notice = ArchiveCreationModel.message(error) } }
        }
        return true
    }
    func canExtractSelection(_ ids: Set<ZIPItemID>) -> Bool {
        if ArchiveExtractionActivation.limitsToSingleZIPFile {
            guard ids.count == 1, visibleItems.contains(where: { ids.contains($0.id) && $0.kind == .file }) else {
                return false
            }
        }
        guard SelectedArchiveExtractionActivation.available, canExtract, !isPaging, !ids.isEmpty, ids.count <= 1_024,
              viewIsCurrent, !isQueryPending, !ApplicationFileActivity.gate.isClosed else { return false }
        return visibleItems.filter { ids.contains($0.id) && [.file, .directory].contains($0.kind) }.count == ids.count
    }
    func extractSelected() { extractSelection(selection) }
    func captureMemberDrag(_ ids: Set<ZIPItemID>) -> ArchiveMemberDragOffer? {
        guard (1...ArchiveMemberDragSource.maximumItems).contains(ids.count), selection == ids,
              canStartMemberDrag(ids), visibleItems.filter({ ids.contains($0.id) }).allSatisfy({
                  !$0.isEncrypted && ($0.kind == .directory || $0.method == 0 || $0.method == 8)
              }) else { return nil }
        let export = ArchivePromiseExportFeature.available ? exportPreparation.offer(for: ids) : nil
        return ArchiveMemberDragOffer(model: self,generation: generation,page: pageGeneration,ids: ids,externalExport:export)
    }
    func canStartMemberDrag(_ ids: Set<ZIPItemID>) -> Bool {
        ((ArchiveMemberDragActivation.available ||
            (ArchivePromiseExportFeature.available && exportPreparation.offer(for: ids) != nil))
            && canExtractSelection(ids)) || canMoveMembers(ids)
    }
    /// Metadata/source-scope preparation only. At most one actor request runs;
    /// rapid selection changes replace the desired request and reject stale work.
    private func prepareExternalExport() {
        exportPreparation.invalidate()
        guard ArchivePromiseExportFeature.available, (1...128).contains(selection.count),
              canExtractSelection(selection), ApplicationArchiveExports.shared.canOffer,
              let session, let source, let browser = lastRequest?.browser else { return }
        let ids = selection, token = generation, currentPage = pageGeneration
        exportPreparation.request(ids, source: source, browser: browser, window: window,
            roots: { .zip(try await session.rootsForExport(ids)) },
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !closed && !suspended && generation == token && pageGeneration == currentPage
                    && selection == ids && viewIsCurrent && permitsEmbeddedAction
            }, canPrepare: { [weak self] in self?.canExtractSelection(ids) == true },
            notice: { [weak self] in if let self, !closed { notice = $0 } })
    }
    func memberDragDidHandOff(_ offer: ArchiveMemberDragOffer) {
        guard let export = offer.externalExport, export.handed else { return }
        handedExports.removeAll { $0.isTerminal }
        if !handedExports.contains(where: { $0 === export }) { handedExports.append(export) }
        #if DEBUG
        memberDragHandoffForVerification?(export)
        #endif
        externalExportReady = false
    }
    func memberDragDidEnd(_ offer: ArchiveMemberDragOffer) {
        if exportPreparation.prepared === offer.externalExport { prepareExternalExport() }
    }
    func isCurrentMemberDrag(_ offer: ArchiveMemberDragOffer) -> Bool {
        offer.model === self && !closed && !suspended && !isLoading && !isPaging && !isChecking && !isQueryPending
            && viewIsCurrent && generation == offer.generation && pageGeneration == offer.page && selection == offer.ids
            && visibleItems.filter { offer.ids.contains($0.id) && [.file,.directory].contains($0.kind) }.count == offer.ids.count
            && lastRequest?.browser?.isBrowserSuspended == false && !ApplicationFileActivity.gate.isClosed
    }
    @discardableResult func extractDropped(_ offer: ArchiveMemberDragOffer, to target: BrowserViewController,
        destination: ArchiveExtractionDestination, isCurrent: @escaping @MainActor () -> Bool) -> Bool {
        guard isCurrentMemberDrag(offer), canExtractSelection(offer.ids), let session, let source,
              let origin = lastRequest?.browser, target.canStartArchiveExtraction,
              ArchiveMemberDragActivation.available, ApplicationArchiveExtraction.shared.canAcceptPreparedSelection, isCurrent() else { return false }
        isPreparingSelection = true; notice = "Preparing the selected items for copying…"
        selectionWork = Task { [self,origin,target] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let chosen = try await Self.extractionSelection(offer.ids, in: session, directRoot: offer.ids.count == 1)
                #if DEBUG
                if let beforeSelectionForVerification { await beforeSelectionForVerification() }
                #endif
                guard !Task.isCancelled, isCurrentMemberDrag(offer) else { return }
                guard isCurrent() else { notice = "That destination changed. Drag the selected items to its current folder again."; return }
                let sourceAccess = await origin.accessLifetime(for: [source])
                guard !Task.isCancelled, isCurrentMemberDrag(offer) else { return }
                guard isCurrent(), target.canStartArchiveExtraction else {
                    notice = "That destination is no longer ready. Finish other file work, then drag the selected items again."; return
                }
                if !ApplicationArchiveExtraction.shared.showSelection(source: source, from: target, selection: chosen,
                    destination: destination, sourceAccess: sourceAccess, presentation: .paste) {
                    notice = "Finish the open extraction review, then drag these items again."
                } else { notice = "Checking the copy destination…" }
            } catch { if !closed, !Task.isCancelled, isCurrentMemberDrag(offer) { notice = Self.message(error) } }
        }
        return true
    }
    func reviewExtraction(_ ids: Set<ZIPItemID>) {
        extractSelection(ids, directRoot: ids.count == 1)
    }
    private static func extractionSelection(_ ids: Set<ZIPItemID>, in session: ZIPArchiveSession,
        directRoot: Bool) async throws -> ArchivePreparedSelection {
        if !directRoot { return .zipMembers(try await session.selectionForExtraction(ids)) }
        let roots = try await session.rootsForExport(ids)
        guard roots.count == 1, let root = roots.first else { throw ZIPArchiveFailure.invalidFolder }
        return .zipRoot(root)
    }
    func extractSelection(_ ids: Set<ZIPItemID>, directRoot: Bool = false) {
        guard canExtractSelection(ids), let session, let source, let browser = lastRequest?.browser else { return }
        let token = generation, pageToken = pageGeneration
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let chosen = try await Self.extractionSelection(ids, in: session, directRoot: directRoot)
                #if DEBUG
                    if let beforeSelectionForVerification { await beforeSelectionForVerification() }
                #endif
                guard permitsEmbeddedAction, !Task.isCancelled, !closed, !suspended, generation == token, pageGeneration == pageToken,
                      !browser.isBrowserSuspended, browser.canStartArchiveExtraction, !ApplicationFileActivity.gate.isClosed else { return }
                ApplicationArchiveExtraction.shared.showSelection(source: source, from: browser, selection: chosen)
            } catch { if !closed, !Task.isCancelled, generation == token { notice = Self.message(error) } }
        }
    }
    func extract() { if canExtractWhole, let source, let browser = lastRequest?.browser { ApplicationArchiveExtraction.shared.show(source: source, from: browser) } }
    var embeddedViewState: ArchiveBrowseState {
        if let embeddedPresentation, embeddedInstalledToken != embeddedPresentation.token {
            var state = embeddedPresentation.state; state.scrollOffset = embeddedScrollOffset; return state
        }
        return ArchiveBrowseState(query: filter, scope: nameScope == .archive ? .archive : .folder,
            sortField: Self.coreField(ordering.field), ascending: !ordering.descending,
            offset: viewIsCurrent ? visibleOffset : (history.indices.contains(historyIndex) ? history[historyIndex].offset : 0),
            selectedPaths: viewIsCurrent ? Set(visibleItems.filter { selection.contains($0.id) }.map(\.path)) : embeddedSelectedPaths,
            scrollOffset: embeddedScrollOffset)
    }
    private static func coreField(_ field: ZIPArchiveOrder.Field) -> ArchiveSortField {
        switch field { case .name: .name; case .logical: .size; case .modified: .modified; case .packed: .packedSize; case .method: .method }
    }
    private static func zipOrder(_ state: ArchiveBrowseState) -> ZIPArchiveOrder {
        let field: ZIPArchiveOrder.Field = switch state.sortField {
        case .name: .name; case .size: .logical; case .modified: .modified
        case .packedSize: .packed; case .method: .method; case .kind: .name
        }
        return ZIPArchiveOrder(field, descending: !state.ascending)
    }
    /// Value-only tab restoration obtains fresh catalog authority on a source
    /// change. Re-presenting a visit never appends private archive history.
    func presentEmbedded(_ location: ArchiveLocation, state: ArchiveBrowseState, from browser: BrowserViewController) {
        guard !closed, !suspended else { return }
        do { try location.validate(); try state.validate(format: .zip); guard location.format == .zip else { throw ZIPArchiveFailure.unsupported } }
        catch { notice = Self.message(error); viewIsCurrent = false; return }
        let presentation = EmbeddedPresentation(location: location, state: state, token: UUID())
        embeddedPresentation = presentation; embeddedSelectedPaths = state.selectedPaths; embeddedScrollOffset = state.scrollOffset
        changingFilter = true; filter = state.query; nameScope = state.scope == .archive ? .archive : .folder
        ordering = Self.zipOrder(state); changingFilter = false
        window = browser.view.window
        if source != location.source || session == nil || isLoading {
            // A pending source open already owns its actual reader task.
            if source != location.source || !isLoading || (desired == nil && openingGeneration != generation) { open(location.source, from: browser) }
            desiredEmbedded = presentation
        } else {
            lastRequest = Request(location.source, browser: browser)
            desiredEmbedded = presentation; desiredEmbeddedNavigation = nil
            pageGeneration = presentation.token; desiredPage = nil; filterTask?.cancel(); selectionWork?.cancel()
            viewIsCurrent = false; selection = []; isPaging = true; startPageLoop()
        }
    }
    func open(_ source: URL, from browser: BrowserViewController) {
        guard !closed, !suspended, !ApplicationFileActivity.gate.isClosed else { return }
        let request = Request(source, browser: browser)
        textPreview.stop(closeWindow: true)
        generation = UUID(); desired = request; lastRequest = request; self.source = source
        page = nil; searchPage = nil; viewIsCurrent = false; summary = nil; selection = []; history = []; historyIndex = 0
        contentReport = nil; checkedAt = nil; contentProgress = nil
        if embeddedPresentation == nil { window?.title = source.lastPathComponent + " — Archive" }
        readTask?.cancel(); filterTask?.cancel(); pageTask?.cancel(); pageGeneration = UUID(); desiredPage = nil
        desiredEmbedded = nil; desiredEmbeddedNavigation = nil
        checkingTask?.cancel(); checkingWork?.cancel()
        selectionWork?.cancel()
        isLoading = true; notice = "Reading archive directory…"
        if work == nil { work = Task { [self] in await loadLoop() } }
    }
    private func loadLoop() async {
        defer { work = nil; readTask = nil; openingGeneration = nil; isLoading = false; revealCreatedMemberIfReady() }
        while !closed, !suspended, let request = desired {
            desired = nil; let token = generation
            openingGeneration = token
            await textPreview.drain()
            if let checkingWork { await checkingWork.value }
            if let pageTask { pageTask.cancel(); await pageTask.value }
            if let session { await session.close(); self.session = nil }
            page = nil; searchPage = nil; summary = nil; selection = []; history = []; historyIndex = 0
            guard let browser = request.browser else { notice = "The source browser closed. Choose the archive again."; continue }
            let lifetime = await browser.accessLifetime(for: [request.source])
            guard !closed, !suspended, token == generation else { continue }
            let task = Task { [reader, source = request.source] in
                try await ArchiveMetadataAdmission.shared.withAdmission { try await reader.open(source, retaining: lifetime) }
            }; readTask = task
            let diagnostic = ApplicationDiagnostics.shared.begin(.archiveBrowse)
            do {
                let catalog = try await task.value
                ApplicationDiagnostics.shared.event(.archiveBrowse, .completed, trace: diagnostic)
                guard !closed, !suspended, token == generation else { await catalog.close(); continue }
                session = catalog; summary = catalog.summary; history = [Visit(folder: catalog.root,ordering:ordering)]; historyIndex = 0
                if embeddedPresentation == nil { changingFilter = true; filter = ""; nameScope = .folder; changingFilter = false }
                notice = ""
                if let embeddedPresentation { desiredEmbedded = embeddedPresentation; pageGeneration = embeddedPresentation.token; isPaging = true; startPageLoop() }
                else { requestPage(history[historyIndex]) }
            } catch {
                ApplicationDiagnostics.shared.event(.archiveBrowse, error is CancellationError ? .cancelled : .failed,
                    trace: diagnostic, error: DiagnosticErrors.project(error))
                if !closed, token == generation { notice = Self.message(error) }
            }
            readTask = nil
        }
    }
    func refresh() {
        guard let lastRequest, let browser = lastRequest.browser else { notice = "Choose the archive in Explorer again to refresh its directory."; return }
        if let embeddedPresentation {
            let state = embeddedViewState
            self.embeddedPresentation = EmbeddedPresentation(location: embeddedPresentation.location, state: state, token: UUID())
        }
        open(lastRequest.source, from: browser)
    }
    func stop() {
        createdMemberToReveal = nil
        let wasChecking = isChecking, wasQuerying = isPaging || isQueryPending
        generation = UUID(); desired = nil; readTask?.cancel(); filterTask?.cancel()
        desiredEmbedded = nil; desiredEmbeddedNavigation = nil
        checkingTask?.cancel(); checkingWork?.cancel(); checkingProgressTask?.cancel(); contentProgress = nil
        selectionWork?.cancel()
        exportPreparation.stop(); externalExportReady = false
        textPreview.stop()
        pageGeneration = UUID(); desiredPage = nil; pageTask?.cancel(); isQueryPending = false
        notice = wasChecking ? "Content check stopped. The archive listing remains available." : wasQuerying ? "Name search stopped. The previous view remains available." : "Archive read stopped. Refresh to try again."
    }
    func prepareForVolumeQuiescence() {
        suspended = true; stop(); handedExports.forEach { $0.retireUncalled() }; textPreview.prepareForVolumeQuiescence()
    }
    func resumeAfterVolumeQuiescence() { suspended = false; textPreview.resumeAfterVolumeQuiescence() }
    func closeAndDrain() async {
        closed = true; stop(); pageTask?.cancel()
        handedExports.forEach { $0.retireUncalled() }
        await textPreview.closeAndDrain()
        if let work { await work.value }; if let pageTask { await pageTask.value }; if let filterTask { await filterTask.value }
        if let checkingWork { await checkingWork.value }
        if let selectionWork { await selectionWork.value }
        await exportPreparation.drain()
        for export in handedExports { await export.drain() }; handedExports = []
        if let session { await session.close() }; session = nil
        await reader.drain(); page = nil; searchPage = nil; summary = nil; selection = []; history = []; lastRequest = nil
    }
    func drain() async {
        if let work { await work.value }; if let filterTask { await filterTask.value }
        if let checkingWork { await checkingWork.value }
        if let selectionWork { await selectionWork.value }
        await exportPreparation.drain()
        for export in handedExports { await export.drain() }
        if let pageTask { await pageTask.value }
        // Selection preparation may admit a preview child. Retire its parent
        // before awaiting that child, including its publication, not just I/O.
        await textPreview.drain()
        await reader.drain()
    }
    func checkContents() {
        guard canCheckContents, let source, let session, let browser = lastRequest?.browser else { return }
        let diagnostic = ApplicationDiagnostics.shared.begin(.archiveCheck)
        let token = generation
        let pair = AsyncStream<ZIPContentProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        isChecking = true; contentReport = nil; checkedAt = nil; contentProgress = nil
        notice = "Checking file contents locally. Nothing is extracted or indexed."
        checkingProgressTask = Task { [weak self] in
            for await progress in pair.stream {
                guard let self, !Task.isCancelled, !self.closed, self.generation == token else { return }
                self.contentProgress = progress
            }
        }
        checkingWork = Task { [self] in
            defer {
                pair.continuation.finish(); checkingProgressTask?.cancel(); checkingProgressTask = nil
                checkingTask = nil; checkingWork = nil; isChecking = false; contentProgress = nil
            }
            let lifetime = await browser.accessLifetime(for: [source])
            guard !closed, !Task.isCancelled, generation == token else {
                ApplicationDiagnostics.shared.event(.archiveCheck, .cancelled, trace: diagnostic); return
            }
            ApplicationDiagnostics.shared.event(.archiveCheck, .reading, trace: diagnostic)
            let task = Task { [reader] in try await reader.checkContents(in: session, retaining: lifetime,
                progress: { _ = pair.continuation.yield($0) }) }
            checkingTask = task
            do {
                let result = try await task.value
                guard !closed, !Task.isCancelled, generation == token else {
                    ApplicationDiagnostics.shared.event(.archiveCheck, .cancelled, trace: diagnostic); return
                }
                contentReport = result; checkedAt = Date()
                notice = "\(result.files.formatted()) file\(result.files == 1 ? "" : "s") passed content checks."
                ApplicationDiagnostics.shared.event(.archiveCheck, .completed, trace: diagnostic, count: UInt64(result.files))
            } catch {
                ApplicationDiagnostics.shared.event(.archiveCheck,
                    error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                    trace: diagnostic, error: DiagnosticErrors.project(error))
                if !closed, !Task.isCancelled, generation == token { notice = Self.message(error) }
            }
        }
    }
    func navigate(_ folder: ZIPFolderID) { navigate(Visit(folder: folder,ordering:ordering)) }
    private func navigate(_ visit: Visit, selected: ZIPItemID? = nil) {
        guard !isLoading, !closed, !suspended, session != nil else { return }
        if embeddedNavigate != nil {
            let paths = Set(visibleItems.filter { $0.id == selected }.map(\.path))
            let token = UUID(); pageGeneration = token; desiredPage = nil; desiredEmbedded = nil
            desiredEmbeddedNavigation = (visit, paths, token); isPaging = true; startPageLoop(); return
        }
        if history.indices.contains(historyIndex), history[historyIndex] == visit, selected == nil { return }
        if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)..<history.count) }
        history.append(visit)
        if history.count > 128 { history.removeFirst() }
        historyIndex = history.count - 1; restoreCriteria(visit); requestPage(visit, selected: selected)
    }
    func openSelection(_ selected: Set<ZIPItemID>) {
        guard viewIsCurrent, !isPaging, !isQueryPending, selected.count == 1,
              let item = visibleItems.first(where: { selected.contains($0.id) }) else { return }
        if let folder = item.folder { navigate(folder) }
        else if item.kind == .file {
            if canEditTextSelection(selected), settings.editorPreferences.route(forFilename: item.name, command: .ordinaryOpen) == .traverse {
                editTextSelection(selected)
            } else { previewSelection(selected) }
        }
    }
    func validateAddressFolder(_ path: [String]) async throws {
        guard permitsEmbeddedAction, !closed, !suspended, viewIsCurrent, !showsStop, let session else {
            throw CancellationError()
        }
        let token = generation
        guard await session.matchesCurrentSourceObservation() else { throw ZIPArchiveFailure.changed }
        _ = try await session.folder(at: path)
        try Task.checkCancellation()
        guard !closed, !suspended, generation == token, viewIsCurrent else { throw CancellationError() }
    }
    func showInArchive() {
        guard canShowInArchive, let id = selection.first, let session else { return }
        let token = generation, pageToken = pageGeneration, chosenOrder = ordering
        isPreparingSelection = true
        selectionWork = Task { [self] in
            defer { selectionWork = nil; isPreparingSelection = false }
            do {
                let position = try await session.location(of: id,sorting:ArchiveOrderingActivation.available ? chosenOrder : nil)
                guard !Task.isCancelled, !closed, !suspended, generation == token, pageGeneration == pageToken else { return }
                navigate(Visit(folder: position.folder,ordering:chosenOrder,offset:position.offset), selected: id)
            } catch { if !closed, !Task.isCancelled, generation == token { notice = Self.message(error) } }
        }
    }
    func back() { if let embeddedBack { embeddedBack(); return }; guard canBack else { return }; historyIndex -= 1; restoreCriteria(history[historyIndex]); requestPage(history[historyIndex]) }
    func forward() { if let embeddedForward { embeddedForward(); return }; guard canForward else { return }; historyIndex += 1; restoreCriteria(history[historyIndex]); requestPage(history[historyIndex]) }
    func up() {
        if let embeddedUp { embeddedUp(); return }
        if isSearchResults, history.indices.contains(historyIndex) { navigate(history[historyIndex].folder) }
        else if let crumbs = page?.breadcrumbs, crumbs.count > 1 { navigate(crumbs[crumbs.count - 2].folder) }
    }
    func nextPage() { if hasNextPage { movePage(to: visibleOffset + 256) } }
    func previousPage() { if visibleOffset > 0 { movePage(to: max(0, visibleOffset - 256)) } }
    private func movePage(to offset: Int) {
        guard !isPaging, !isQueryPending, history.indices.contains(historyIndex) else { return }
        history[historyIndex].offset = offset; requestPage(history[historyIndex])
    }
    private func restoreCriteria(_ visit: Visit) {
        filterTask?.cancel(); isQueryPending = false
        changingFilter = true; filter = visit.query; nameScope = visit.scope; ordering = visit.ordering; changingFilter = false
    }
    func applyFilter() {
        filterTask?.cancel(); isQueryPending = false
        guard !closed, !suspended, !isLoading, history.indices.contains(historyIndex) else { return }
        guard filter.utf8.count <= 128 else {
            pageGeneration = UUID(); desiredPage = nil; selectionWork?.cancel(); selection = []; viewIsCurrent = false
            notice = Self.message(ZIPArchiveFailure.invalidFilter)
            return // Never retain an invalid/unbounded draft in navigation history.
        }
        history[historyIndex].query = filter; history[historyIndex].scope = nameScope; history[historyIndex].offset = 0
        requestPage(history[historyIndex])
    }
    private func scheduleFilter() {
        guard !changingFilter, !closed, !suspended else { return }
        filterTask?.cancel(); selectionWork?.cancel(); pageGeneration = UUID(); selection = []; viewIsCurrent = false; isQueryPending = true
        let token = generation
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !self.closed, self.generation == token else { return }
            self.applyFilter()
        }
    }
    private func requestPage(_ visit: Visit, selected: ZIPItemID? = nil) {
        guard !closed, !suspended, session != nil else { return }
        selectionWork?.cancel(); selection = []; viewIsCurrent = false; isQueryPending = false
        let token = UUID(); pageGeneration = token
        desiredPage = PageRequest(visit: visit, symbols: settings.symbolTolerantNames, token: token, selected: selected)
        isPaging = true; startPageLoop()
    }
    private func startPageLoop() {
        guard pageTask == nil, let session else { return }
        let catalogGeneration = generation
        pageTask = Task { [self] in
            defer {
                pageTask = nil; isPaging = false
                if !closed, !suspended, (!isLoading || generation == catalogGeneration),
                   desiredPage != nil || desiredEmbedded != nil || desiredEmbeddedNavigation != nil { isPaging = true; startPageLoop() }
                revealCreatedMemberIfReady()
            }
            while !closed, !suspended, !Task.isCancelled, generation == catalogGeneration {
                if let navigation = desiredEmbeddedNavigation {
                    desiredEmbeddedNavigation = nil
                    do {
                        let path = try await session.folderPath(of: navigation.visit.folder)
                        guard !closed, !suspended, !Task.isCancelled, pageGeneration == navigation.token else { continue }
                        let visit = navigation.visit
                        let state = ArchiveBrowseState(query: visit.query, scope: visit.scope == .archive ? .archive : .folder,
                            sortField: Self.coreField(visit.ordering.field), ascending: !visit.ordering.descending,
                            offset: visit.offset, selectedPaths: navigation.paths)
                        embeddedNavigate?(path, state)
                    } catch { if !closed, !Task.isCancelled, pageGeneration == navigation.token { notice = Self.message(error) } }
                    continue
                }
                if let presentation = desiredEmbedded {
                    desiredEmbedded = nil
                    do {
                        let sourceMatches = await session.matchesCurrentSourceObservation()
                        guard !closed, !suspended, !Task.isCancelled,
                              embeddedPresentation?.token == presentation.token, pageGeneration == presentation.token,
                              desiredEmbedded == nil else { continue }
                        if !sourceMatches {
                            // A cold Undo or external replacement can leave the
                            // inactive tab's catalog bound to the old inode.
                            // Reuse the ordinary reader instead of stale rows.
                            refresh()
                            return
                        }
                        let folder = try await session.folder(at: presentation.location.folderPath)
                        guard !closed, !suspended, !Task.isCancelled,
                              embeddedPresentation?.token == presentation.token, pageGeneration == presentation.token,
                              desiredEmbedded == nil else { continue }
                        let state = presentation.state
                        let visit = Visit(folder: folder, ordering: Self.zipOrder(state),
                            scope: state.scope == .archive ? .archive : .folder, query: state.query, offset: state.offset)
                        history = [visit]; historyIndex = 0; restoreCriteria(visit)
                        embeddedInstalledToken = presentation.token
                        embeddedSelectedPaths = state.selectedPaths
                        if state.query.utf8.count > 128 {
                            page = nil; searchPage = nil; viewIsCurrent = false; isQueryPending = false
                            notice = Self.message(ZIPArchiveFailure.invalidFilter)
                        } else { requestPage(visit) }
                    } catch {
                        if !closed, !Task.isCancelled, embeddedPresentation?.token == presentation.token, pageGeneration == presentation.token {
                            page = nil; searchPage = nil; viewIsCurrent = false; notice = Self.message(error)
                        }
                    }
                    continue
                }
                guard let request = desiredPage else { break }
                desiredPage = nil
                let diagnostic = ApplicationDiagnostics.shared.begin(request.visit.scope == .archive ? .archiveSearch : .archiveBrowse)
                do {
                    #if DEBUG
                        pageRequestsForVerification += 1
                        if let beforePageForVerification { await beforePageForVerification() }
                    #endif
                    try Task.checkCancellation()
                    guard !closed, !suspended, pageGeneration == request.token else { continue }
                    let folder: ZIPDirectoryPage?, search: ZIPNameSearchPage?
                    if request.visit.scope == .archive {
                        search = try await session.searchNames(request.visit.query, offset: request.visit.offset, symbolTolerant: request.symbols,
                            sorting:ArchiveOrderingActivation.available ? request.visit.ordering : nil)
                        folder = embeddedPresentation != nil ? try await session.page(in: request.visit.folder) : nil
                    } else {
                        folder = try await session.page(in: request.visit.folder, offset: request.visit.offset, filter: request.visit.query, symbolTolerant: request.symbols,
                            sorting:ArchiveOrderingActivation.available ? request.visit.ordering : nil); search = nil
                    }
                    guard !closed, !suspended, !Task.isCancelled, pageGeneration == request.token else { continue }
                    // Keep the true originating folder for breadcrumbs/return; a
                    // search page never masquerades as a local or virtual folder.
                    if let folder { page = folder }
                    searchPage = search
                    viewIsCurrent = true
                    selection = []
                    if let id = request.selected { selection = visibleItems.contains { $0.id == id } ? [id] : [] }
                    else if embeddedPresentation != nil {
                        selection = Set(visibleItems.filter { item in embeddedSelectedPaths.contains { $0.utf8.elementsEqual(item.path.utf8) } }.map(\.id))
                        embeddedSelectedPaths = []
                    }
                    notice = ""
                    ApplicationDiagnostics.shared.event(.archiveBrowse, .completed, trace: diagnostic, count: UInt64(visibleItems.count))
                } catch {
                    ApplicationDiagnostics.shared.event(.archiveBrowse, error is CancellationError ? .cancelled : .failed,
                        trace: diagnostic, error: DiagnosticErrors.project(error))
                    if !closed, !Task.isCancelled, pageGeneration == request.token { notice = Self.message(error) }
                }
            }
        }
    }
    static func size(_ bytes: UInt64) -> String { bytes <= Int64.max ? FileSizeText.string(Int64(bytes)) : "\(bytes.formatted()) bytes" }
    static func message(_ error: Error) -> String {
        if let issue = error as? ZIPContentProblem {
            let member = issue.member.map { " “\(String($0.prefix(120)))”" } ?? ""
            switch issue.reason {
            case .unsupported: return "This check cannot verify\(member). Encrypted files, links and unsupported ZIP variants remain unverified."
            case .metadataMismatch: return "A local file record disagrees with the archive directory\(member). Checking stopped."
            case .contentMismatch: return "A file failed decompression, length or checksum checks\(member)."
            case .limitReached: return "This check reached its size, expansion, time or entry limit. A complete check is unavailable."
            case .codecUnavailable: return "The system decoder could not finish\(member). The archive remains unverified."
            }
        }
        return switch error {
        case ArchiveMetadataAdmission.Failure.busy: "Other archives are still opening. Wait briefly, then refresh this archive."
        case ZIPArchiveFailure.limited: "This archive exceeds the current metadata limits. No files were extracted."
        case ZIPArchiveFailure.unsafeName, ZIPArchiveFailure.ambiguousNames: "The archive contains unsafe or ambiguous names. Its files were left untouched."
        case ZIPArchiveFailure.unsupportedEncoding: "An archive name has an unsupported encoding. Its files were left untouched."
        case ZIPArchiveFailure.unsupported: "This archive layout or source location is not supported yet. Split archives and cloud-only sources are unavailable."
        case ZIPArchiveFailure.changed: "The archive changed while its directory was being read. Refresh to inspect it again."
        case ZIPArchiveFailure.malformed: "The archive directory is incomplete or inconsistent. Its files were left untouched."
        case ZIPArchiveFailure.invalidFilter: "That name search is too long. Try fewer words or characters."
        case ZIPArchiveFailure.busy: "The previous archive read is still finishing. Try again when it stops."
        case ZIPArchiveFailure.stopped, is CancellationError: "Archive read stopped. Refresh to try again."
        default: "The archive could not be read. Check that its drive is connected and access is available."
        }
    }
}

private struct ArchiveBrowserView: View {
    @ObservedObject var model: ArchiveBrowserModel
    @ObservedObject var settings: BrowserSettings
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").interfaceFont(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.source?.lastPathComponent ?? "Archive").interfaceFont(.title2.weight(.semibold)).lineLimit(1).help(model.source?.path ?? "")
                    if let summary = model.summary {
                        Text("\(summary.files.formatted()) file\(summary.files == 1 ? "" : "s") · \(summary.folders.formatted()) folder\(summary.folders == 1 ? "" : "s") · \(ArchiveBrowserModel.size(summary.logicalBytes)) recorded size")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    } else { Text("Browse inside without extracting").interfaceFont(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if ZIPTextEditorFeature.available, model.summary != nil {
                    Button("Edit in Traverse", action: model.editSelectedText).disabled(!model.canEditSelectedText)
                        .help("Edit one UTF-8 text file inside this ZIP. Save keeps the earlier ZIP for Undo.")
                }
                if ZIPTextPreviewFeature.available, model.summary != nil {
                    if ZIPBytePreviewFeature.available {
                        Menu("Preview") {
                            Button(model.preferredPreview.commandTitle, action: model.previewSelected)
                            Button("Hexadecimal", action: model.previewSelectedAsBytes)
                        }.disabled(!model.canPreviewSelected)
                            .help("Preview the selected member without extracting it.")
                    } else {
                        Button(model.preferredPreview.commandTitle, action: model.previewSelected).disabled(!model.canPreviewSelected)
                            .help("Preview the selected member without extracting it.")
                    }
                }
                if ArchiveExtractionActivation.available, model.summary != nil {
                    Button("Extract All…", action: model.extract).disabled(!model.canExtractWhole)
                    if SelectedArchiveExtractionActivation.available {
                        Button("Extract Selected…") { model.reviewExtraction(model.selection) }.disabled(!model.canExtractSelected)
                    }
                }
                if ArchiveContentCheckActivation.available, model.summary != nil {
                    Button(model.contentReport == nil ? "Check File Contents" : "Check Again", action: model.checkContents)
                        .disabled(!model.canCheckContents).help("Read and verify supported ZIP file bodies locally. Nothing is extracted or indexed.")
                }
                ProgressView().controlSize(.small).opacity(model.showsStop ? 1 : 0).frame(width: 16)
                Button(model.showsStop ? "Stop" : "Refresh") { model.showsStop ? model.stop() : model.refresh() }
                    .frame(width: 66).disabled(model.suspended && !model.showsStop)
            }.padding(18)
            Divider()
            HStack(spacing: 8) {
                Button(action: model.back) { Image(systemName: "chevron.left") }.help("Back").disabled(!model.canBack)
                Button(action: model.forward) { Image(systemName: "chevron.right") }.help("Forward").disabled(!model.canForward)
                Button(action: model.up) { Image(systemName: "arrow.up") }.help("Parent folder").disabled(!model.canUp)
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(model.breadcrumbs, id: \.folder) { crumb in
                            if crumb.folder != model.breadcrumbs.first?.folder { Image(systemName: "chevron.right").interfaceFont(.caption2).foregroundStyle(.tertiary) }
                            Button(crumb.folder == model.breadcrumbs.first?.folder ? "Archive" : crumb.name) { model.navigate(crumb.folder) }.buttonStyle(.plain).lineLimit(1)
                        }
                        if model.isSearchResults { Image(systemName: "chevron.right").interfaceFont(.caption2).foregroundStyle(.tertiary); Text("Search").foregroundStyle(.secondary) }
                    }
                }.scrollIndicators(.hidden).frame(minWidth: 50)
                if model.isSearchResults {
                    Button("Show in Archive", action: model.showInArchive).disabled(!model.canShowInArchive)
                }
                Picker("Name search scope", selection: $model.nameScope) {
                    ForEach(ArchiveNameScope.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150).disabled(model.isLoading)
                HStack(spacing: 6) {
                    Button { model.focusNameSearch() } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                        .help("Search archive names (⌘F)").accessibilityLabel("Focus archive name search")
                    ArchiveNameQueryField(text: $model.filter, global: model.nameScope == .archive, onSubmit: model.applyFilter)
                    if !model.filter.isEmpty {
                        Button { model.filter = ""; model.applyFilter() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .help("Clear name search").accessibilityLabel("Clear name search")
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.10), lineWidth: 0.7))
                    .frame(width: 190).disabled(model.isLoading)
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10)
            HStack {
                Text(model.notice.isEmpty ? (ArchivePromiseExportFeature.available
                    ? "Search by name. Preview, extract, or drag selected items to another folder."
                    : "Search by name. Files stay packed until you choose Preview or Extract.") : model.notice)
                    .interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.notice).textSelection(.enabled)
                Spacer(minLength: 0)
            }.frame(height: 34, alignment: .leading).padding(.horizontal, 18)
            if let progress = model.contentProgress, model.isChecking {
                VStack(alignment: .leading, spacing: 5) {
                    if progress.totalLogicalBytes > 0 {
                        ProgressView(value: Double(progress.decodedBytes), total: Double(progress.totalLogicalBytes))
                    }
                    HStack {
                        Text(progress.member).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(progress.completedEntries.formatted()) of \(progress.totalEntries.formatted()) entries · \(ArchiveBrowserModel.size(progress.decodedBytes)) read")
                    }.interfaceFont(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.bottom, 10)
            } else if let report = model.contentReport, let date = model.checkedAt {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Checked snapshot · \(ArchiveBrowserModel.size(report.decodedBytes)) · \(date.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                }.interfaceFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
            }
            ArchiveRowsView(model: model, settings: settings).frame(minHeight: 240)
            Divider()
            HStack {
                if model.page != nil || model.searchPage != nil {
                    Text(model.visibleTotal == 0 ? (model.isSearchResults && model.filter.utf8.count <= 128 && model.filter.allSatisfy(\.isWhitespace) ? "Type a name to search this archive" : "No matching names in this view")
                        : "\(model.visibleOffset + 1)–\(model.visibleOffset + model.visibleItems.count) of \(model.visibleTotal.formatted())\(model.isSearchResults ? " matching names" : "")")
                    if model.isPaging || model.isQueryPending { ProgressView().controlSize(.mini) }
                    Spacer(); Button("Previous") { model.previousPage() }.disabled(model.visibleOffset == 0 || model.isPaging || model.isQueryPending)
                    Button("Next") { model.nextPage() }.disabled(!model.hasNextPage || model.isPaging || model.isQueryPending)
                } else { Text(model.isLoading ? "Reading…" : "Archive directory"); Spacer() }
            }.interfaceFont(.caption).padding(.horizontal, 18).padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.contentReport == nil ? "Read only · sizes are recorded by the archive · no complete content check for this read"
                    : "Read only · content CRC and length checked for this snapshot · not an authenticity guarantee")
                if let summary = model.summary, summary.caseConflicts > 0 {
                    Text("Some names differ only by letter case; extracting them may require conflict choices.")
                }
                if let summary = model.summary, summary.symbolicLinks + summary.specialMembers > 0 {
                    Text("Links and special entries are shown as metadata. No targets are followed.")
                }
            }.interfaceFont(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
        }.frame(minWidth: 800, minHeight: 560)
    }
}

/// Draw only the live text/caret; the stable SwiftUI surround owns its glass
/// surface, avoiding native bezel crossfades when search scope/results change.
private struct ArchiveNameQueryField: NSViewRepresentable {
    @Binding var text: String
    let global: Bool
    let onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: 13); field.focusRingType = .exterior
        field.delegate = context.coordinator; field.identifier = .init("archive-name-query")
        field.setAccessibilityIdentifier("archive-name-query"); field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text; context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = global ? "Search archive names" : "Filter this folder"
        field.setAccessibilityLabel(global ? "Search archive names" : "Filter this folder")
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>, onSubmit: () -> Void
        init(text: Binding<String>, onSubmit: @escaping () -> Void) { self.text = text; self.onSubmit = onSubmit }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { onSubmit(); return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { text.wrappedValue = ""; onSubmit(); return true }
            return false
        }
    }
}

@MainActor private final class ArchiveBrowserWindow: ToolMotionWindow {
    var focusArchiveSearch: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            focusArchiveSearch?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class ArchiveBrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: ArchiveBrowserModel
    var onClose: (() -> Void)?
    init(model: ArchiveBrowserModel) {
        self.model = model
        let window = ArchiveBrowserWindow(contentViewController: InterfaceHostingController(rootView: ArchiveBrowserView(model: model, settings: model.settings)))
        window.focusArchiveSearch = { [weak model] in model?.focusNameSearch() }
        window.title = "Archive"; window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(.init(width: 980, height: 650)); window.minSize = .init(width: 820, height: 580)
        window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        super.init(window: window); window.delegate = self; model.window = window
        ToolWindowChrome.install(in: window, settings: model.settings)
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor final class ApplicationZIPBrowser {
    static let shared = ApplicationZIPBrowser()
    private(set) var controller: ArchiveBrowserWindowController?
    private var retirement: Task<Void, Never>?
    func show(_ url: URL, from browser: BrowserViewController) {
        if GeneratedArchiveDriveReview.requested,
           !GeneratedArchiveDriveReview.permitsFixtureLocations([url]) {
            browser.status.stringValue = "This review accepts generated archive fixtures only."
            return
        }
        guard retirement == nil, !ApplicationFileActivity.gate.isClosed else { browser.status.stringValue = "Finishing the previous archive read. Try again when it stops."; return }
        if controller == nil {
            let reader = ZIPArchiveReader(activity: ApplicationFileActivity.gate,
                excludedRoots: (browser.developmentStateDirectory.map { [$0] } ?? []) + AppStorageLocations.protectedDirectories)
            let model = ArchiveBrowserModel(settings: browser.settings, reader: reader)
            let created = ArchiveBrowserWindowController(model: model)
            created.onClose = { [weak self, weak model] in
                guard let self, let model else { return }
                model.stop()
                self.retirement = Task { [self] in await model.closeAndDrain(); controller = nil; retirement = nil }
            }
            controller = created
        }
        controller?.model.open(url, from: browser)
        if controller?.window?.isVisible != true {
            if browser.isControlledVerification { controller?.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
            else if let window = controller?.window { ToolWindowChrome.position(window, relativeTo: browser.view.window) }
        }
        controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }
    func prepareForVolumeQuiescence() { controller?.model.prepareForVolumeQuiescence() }
    func drain() async { await controller?.model.drain(); if let retirement { await retirement.value } }
    func resumeAfterVolumeQuiescence() { controller?.model.resumeAfterVolumeQuiescence() }
    func stopAndDrain() async { controller?.close(); if let retirement { await retirement.value } }
}

@MainActor extension BrowserViewController {
    var selectedTARURL:URL? {
        guard TARBrowseFeature.available,orderedSelectedURLs.count==1,!isBrowserSuspended,!isReadOnlyFileSession,
              let url=orderedSelectedURLs.first,let row=rowsByURL[url],displayedEntries.indices.contains(row),displayedEntries[row].kind == .file else{return nil}
        return ArchiveFilename(url.lastPathComponent)?.kind.isTAR == true ? url:nil
    }
    var selectedArchiveURL:URL? {selectedZIPURL ?? selectedTARURL}
    var selectedZIPURL: URL? {
        guard ArchiveBrowseActivation.available, orderedSelectedURLs.count == 1, !isBrowserSuspended, !isReadOnlyFileSession,
              let url = orderedSelectedURLs.first, ["zip", "jar", "cbz", "epub"].contains(url.pathExtension.lowercased()),
              let row = rowsByURL[url], displayedEntries.indices.contains(row), displayedEntries[row].kind == .file else { return nil }
        return url
    }
    @objc func browseZIP(_ sender: Any?) {
        if InlineArchiveFeature.available, let url = selectedArchiveURL,
           let value = try? ArchiveLocation(source: url, format: selectedTARURL == nil ? .zip : .tar) {
            navigate(to: .archive(value)); return
        }
        if let url=selectedTARURL{ApplicationTARBrowser.shared.show(url,from:self);return}
        guard let url = selectedZIPURL else { return }; ApplicationZIPBrowser.shared.show(url, from: self)
    }
}
