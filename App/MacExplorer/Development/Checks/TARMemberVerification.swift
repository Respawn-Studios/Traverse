#if DEBUG || (TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !TRAVERSE_SFTP_EDITOR_QA)
import AppKit
import ExplorerCore
import FileOperations
import LocalStorage

/// Drives the ordinary TAR rows and creation review in both generated Debug
/// checks and the isolated signed archive visit. The caller owns observations
/// and recovery; this driver never writes archive bytes or undoes a record.
@MainActor enum TARMemberActionDriver {
    #if DEBUG
    typealias Failure = ArchiveTextEditorVerification.Failure
    #else
    struct Failure: Error { let stage: String }
    #endif
    struct Context {
        let owner: ArchiveTabController
        let model: TARBrowserModel
        let table: FileTableView
    }
    static func need(_ value: Bool, _ stage: String) throws {
        if !value { throw Failure(stage: stage) }
    }
    static func wait(_ stage: String, seconds: Double = 10, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready() {
            try need(.now < deadline && !Task.isCancelled, stage)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func prepare(_ source: URL, browser: BrowserViewController) async throws {
        #if DEBUG
        try await ArchiveTextEditorVerification.prepareTARIfNeeded(source, browser: browser)
        #else
        guard TARBrowserModel.isCompressed(source) else { return }
        try await wait("tar-members-preparation-page", seconds: 30) {
            browser.currentArchive?.source == source &&
                (browser.currentArchive?.tarModelForVerification?.current == true
                    || browser.currentArchive?.tarModelForVerification?.canPrepareCompressed == true)
        }
        if !CompressedArchiveOpenFeature.available,
           browser.currentArchive?.tarModelForVerification?.canPrepareCompressed == true {
            browser.currentArchive?.tarModelForVerification?.prepareCompressed()
        }
        try await wait("tar-members-prepared-page", seconds: 30) {
            browser.currentArchive?.tarModelForVerification?.current == true
        }
        #endif
    }
    private static func admitted(_ source: URL, addedSource: URL? = nil) -> Bool {
        #if TRAVERSE_ARCHIVE_DRIVE_QA && !DEBUG
        guard GeneratedArchiveDriveReview.archiveForwardAdmitted,
              let selected = GeneratedArchiveDriveReview.selection,
              selected.suite == .tarMembers,
              source.deletingLastPathComponent().standardizedFileURL == selected.fixtureRoot.standardizedFileURL,
              ["Review.tar", "Review.tar.gz", "Review.tar.bz2"].contains(source.lastPathComponent) else { return false }
        if let addedSource {
            let allowed = ["Source/Notes.txt", "Source/Nested/Config.json"]
                .map { selected.fixtureRoot.appendingPathComponent($0).standardizedFileURL }
            guard allowed.contains(addedSource.standardizedFileURL) else { return false }
        }
        return GeneratedArchiveDriveReview.permitsFixtureLocations([source] + (addedSource.map { [$0] } ?? []))
        #else
        return true
        #endif
    }
    static func currentPath(_ model: TARBrowserModel) -> [String] {
        Array(model.breadcrumbs.dropFirst().map(\.name))
    }
    static func open(_ source: URL, browser: BrowserViewController, folder: [String] = []) async throws -> Context {
        #if TRAVERSE_ARCHIVE_DRIVE_QA && !DEBUG
        let promiseSource: Bool
        if let selected = GeneratedArchiveDriveReview.selection,
           GeneratedArchiveDriveReview.tarPromisesForwardAdmitted {
            promiseSource = source.deletingLastPathComponent().path == selected.fixtureRoot.path
                && ["Promise.tar", "Promise.tar.gz", "Promise.tar.bz2"].contains(source.lastPathComponent)
                && GeneratedArchiveDriveReview.permitsFixtureLocations([source])
        } else { promiseSource = false }
        try need(admitted(source) || promiseSource, "tar-members-generated-archive-scope")
        #else
        try need(admitted(source), "tar-members-generated-archive-scope")
        #endif
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait("tar-members-local-page", seconds: 30) { !browser.isLoading && browser.rowsByURL[source] != nil }
        browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        browser.openSelection(nil)
        try await prepare(source, browser: browser)
        try await wait("tar-members-root-page", seconds: 30) {
            guard let owner = browser.currentArchive, let model = owner.tarModelForVerification,
                  let table = owner.table else { return false }
            #if DEBUG
            return owner.hasRenderedCurrentRowsForVerification && model.current && table.numberOfRows == model.items.count
            #else
            return model.current && table.numberOfRows == model.items.count
            #endif
        }
        guard let owner = browser.currentArchive, let model = owner.tarModelForVerification,
              let table = owner.table else { throw Failure(stage: "tar-members-root-owner") }
        for (index, component) in folder.enumerated() {
            try choose([component], model: model, table: table, browser: browser)
            try need(model.items.contains { $0.name == component && $0.folder != nil }, "tar-members-folder-selection")
            browser.openSelection(nil)
            let expected = Array(folder.prefix(index + 1))
            try await wait("tar-members-folder-page", seconds: 30) {
                model.current && currentPath(model) == expected && table.numberOfRows == model.items.count
            }
        }
        try need(browser.view.window?.makeFirstResponder(table) == true, "tar-members-table-focus")
        return Context(owner: owner, model: model, table: table)
    }
    static func choose(_ names: [String], model: TARBrowserModel, table: FileTableView,
                       browser: BrowserViewController) throws {
        let rows = IndexSet(model.items.indices.filter { names.contains(model.items[$0].name) })
        let selected = Set(rows.map { model.items[$0].id })
        try need(rows.count == names.count && Set(names).count == names.count, "tar-members-selection-names")
        table.selectRowIndexes(rows, byExtendingSelection: false)
        try need(browser.view.window?.makeFirstResponder(table) == true && model.selection == selected,
            "tar-members-selected-live-rows")
    }
    static func review() async throws -> ArchiveCreationWindowController {
        try await wait("tar-members-review", seconds: 30) { ApplicationArchiveCreation.shared.controller != nil }
        guard let controller = ApplicationArchiveCreation.shared.controller else {
            throw Failure(stage: "tar-members-review-missing")
        }
        return controller
    }
    static func typeName(_ name: String, in controller: ArchiveCreationWindowController) async throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let window = controller.window, let content = window.contentView,
              let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: {
                  ["New item name", "New folder name", "File name"].contains($0.placeholderString ?? "")
              }), window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
            throw Failure(stage: "tar-members-native-name-field")
        }
        editor.selectAll(nil); editor.insertText(name, replacementRange: .init(location: 0, length: editor.string.utf16.count))
        try await wait("tar-members-native-name-binding") { controller.model.memberName == name }
    }
    static func commit(_ controller: ArchiveCreationWindowController) async throws -> UUID {
        try await wait("tar-members-ready", seconds: 30) {
            !controller.model.isChoosing && !controller.model.isPreparing && !controller.model.previewIsPendingForVerification
        }
        try need(controller.model.canCreate, "tar-members-plan: " + controller.model.notice)
        controller.model.create()
        try await wait("tar-members-published", seconds: 60) { !controller.model.isRunning && controller.model.outcome != nil }
        guard controller.model.outcome?.result.disposition == .succeeded,
              let id = controller.model.outcome?.recordID else {
            throw Failure(stage: "tar-members-publication: " + controller.model.notice)
        }
        await ApplicationArchiveCreation.shared.closeAndDrain()
        return id
    }
    static func paths(_ source: URL) async throws -> Set<String> {
        let reader = ApplicationCompressedArchives.shared.reader(excluding: [])
        let session = try await (TARBrowserModel.isCompressed(source) ? reader.prepareCompressed(source) : reader.open(source))
        do {
            let result = try await session.searchNames("")
            await session.close()
            return Set(result.items.map(\.path))
        } catch { await session.close(); throw error }
    }
    static func beginNativeAdd(_ source: URL, in context: Context, board: NSPasteboard) throws {
        try need(board.writeObjects([source as NSURL]), "tar-members-native-add-board")
        let info = FixtureDraggingInfo(board: board, source: nil, sequence: 913, allowed: .copy)
        guard let rows = context.table.delegate as? TARMetadataRows else {
            throw Failure(stage: "tar-members-native-add-rows")
        }
        try need(rows.tableView(context.table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .copy
            && rows.tableView(context.table, acceptDrop: info, row: -1, dropOperation: .on)
            && !rows.tableView(context.table, acceptDrop: info, row: -1, dropOperation: .on),
            "tar-members-native-add-once")
    }
    enum Transfer: Equatable { case copy, cut, drag }
    private static func navigate(_ context: Context, browser: BrowserViewController,
                                 to destination: [String]) async throws {
        let model = context.model, table = context.table
        let current = currentPath(model)
        let common = zip(current, destination).prefix { $0.0 == $0.1 }.count
        for length in stride(from: current.count - 1, through: common, by: -1) {
            browser.goUp(nil)
            let expected = Array(current.prefix(length))
            try await wait("tar-members-navigation-up", seconds: 30) {
                model.current && currentPath(model) == expected && table.numberOfRows == model.items.count
            }
        }
        for index in common..<destination.count {
            let component = destination[index]
            try choose([component], model: model, table: table, browser: browser)
            try need(model.items.contains { $0.name == component && $0.folder != nil }, "tar-members-destination-folder")
            browser.openSelection(nil)
            let expected = Array(destination.prefix(index + 1))
            try await wait("tar-members-navigation-down", seconds: 30) {
                model.current && currentPath(model) == expected && table.numberOfRows == model.items.count
            }
        }
        try need(currentPath(model) == destination && browser.view.window?.makeFirstResponder(table) == true,
            "tar-members-destination-focus")
    }
    static func captureClipboard(_ transfer: Transfer, context: Context,
                                 browser: BrowserViewController, board: NSPasteboard) async throws {
        let action: Selector = transfer == .copy ? #selector(FileTableView.copy(_:)) : #selector(FileTableView.cut(_:))
        let item = NSMenuItem(title: transfer == .copy ? "Copy" : "Cut", action: action, keyEquivalent: "")
        try need(context.table.validateMenuItem(item) && NSApp.sendAction(action, to: context.table, from: item),
            "tar-members-native-capture")
        try await wait("tar-members-sealed-clipboard", seconds: 30) {
            browser.clipboardState.scopedItem?.isAlive == true && !context.model.isPreparingPreview
        }
        try need(board.types == [ScopedItemClipboardIntent.pasteboardType]
            && browser.clipboardState.scopedItem?.operation == (transfer == .copy ? .copy : .move),
            "tar-members-private-marker")
    }
    static func beginNativeMove(_ context: Context, name: String, destination: String,
                                board: NSPasteboard) throws {
        let model = context.model, table = context.table
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        try need(!AppFeatureAvailability.allows(.archiveInternalTransfers)
            && !ArchiveMemberDragActivation.available
            && !SelectedArchiveExtractionActivation.available
            && !TARPromiseExportFeature.available
            && model.canMoveMembers(model.selection)
            && !model.canExtractMemberDrag(model.selection),
            "tar-members-native-move-isolated-capabilities")
        #endif
        guard let rows = table.delegate as? TARMetadataRows, let source = rows.memberDragSource,
              let writer = source.writer(tarIDs: model.selection),
              let row = model.items.firstIndex(where: { $0.name == destination && $0.folder != nil }),
              model.selection.count == 1, model.items.contains(where: { $0.name == name && model.selection.contains($0.id) }) else {
            throw Failure(stage: "tar-members-native-move-source")
        }
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        try need(writer is NSPasteboardItem && !(writer is NSFilePromiseProvider),
            "tar-members-native-move-opaque-writer")
        #endif
        board.clearContents(); try need(board.writeObjects([writer]), "tar-members-native-move-board")
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        let markers = board.pasteboardItems ?? []
        try need(markers.count == 1
            && markers[0].types == [ArchiveMemberDragSource.pasteboardType]
            && markers[0].string(forType: ArchiveMemberDragSource.pasteboardType)
                .flatMap(UUID.init(uuidString:)) != nil,
            "tar-members-native-move-private-marker")
        #endif
        source.begin(sequence: 914, tarIDs: model.selection, board: board)
        var ended = false
        defer { if !ended { source.end(sequence: 914, operation: []) } }
        let info = FixtureDraggingInfo(board: board, source: table, sequence: 914, allowed: [.copy, .move])
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        guard let offer = ArchiveMemberDragSource.capture(info, for: .moveWithinArchive) else {
            throw Failure(stage: "tar-members-native-move-private-capture")
        }
        try need(offer.tarIDs == model.selection && offer.canStart && !offer.canExtract
            && ArchiveMemberDragSource.capture(info, for: .extract) == nil,
            "tar-members-native-move-no-extraction")
        #endif
        try need(rows.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on) == .move
            && rows.tableView(table, acceptDrop: info, row: row, dropOperation: .on)
            && !rows.tableView(table, acceptDrop: info, row: row, dropOperation: .on),
            "tar-members-native-move-once")
        source.end(sequence: 914, operation: .move); ended = true
    }
    static func perform(_ action: TARBrowserModel.MutationAction, source: URL,
                        browser: BrowserViewController, folder: [String], names: [String] = [],
                        name: String? = nil, batchPrefix: String? = nil,
                        addedSource: URL? = nil, replaceFiles: Bool = false,
                        nativeAddDrop: Bool = false) async throws -> UUID {
        try need(admitted(source, addedSource: addedSource), "tar-members-generated-input-scope")
        try need(action == .add ? addedSource != nil && names.isEmpty
            : addedSource == nil && !replaceFiles && !nativeAddDrop, "tar-members-action-options")
        let context = try await open(source, browser: browser, folder: folder)
        try need(ApplicationArchiveCreation.shared.controller == nil, "tar-members-review-owner-not-idle")
        try choose(names, model: context.model, table: context.table, browser: browser)
        let board = nativeAddDrop ? NSPasteboard(name: .init("Traverse.TAR.AddCheck." + UUID().uuidString)) : nil
        defer { board?.releaseGlobally() }
        if let board, let addedSource {
            try beginNativeAdd(addedSource, in: context, board: board)
        } else {
            context.model.reviewMutation(action, addedSource: addedSource.map { ArchiveAdditionInput(urls: [$0]) })
        }
        let shown = try await review()
        if let name { try await typeName(name, in: shown) }
        if let batchPrefix {
            try need(shown.model.isMemberBatchRename && shown.model.batchNames.count == names.count,
                "tar-members-batch-review")
            shown.model.batchOptions.prefix = batchPrefix
        }
        if replaceFiles { shown.model.additionCollisions = .replaceFiles }
        return try await commit(shown)
    }
    static func transfer(_ transfer: Transfer, source: URL, browser: BrowserViewController,
                         from folder: [String], names: [String], destination: [String]) async throws -> UUID {
        try need(admitted(source) && names.count == 1 && Set(names).count == 1,
            "tar-members-transfer-scope")
        let board = NSPasteboard(name: .init("Traverse.TAR.MemberCheck." + UUID().uuidString))
        let previousBoard = browser.transferPasteboard
        browser.transferPasteboard = board
        defer { browser.transferPasteboard = previousBoard; board.releaseGlobally() }
        let context = try await open(source, browser: browser, folder: folder)
        try need(ApplicationArchiveCreation.shared.controller == nil, "tar-members-review-owner-not-idle")
        try choose(names, model: context.model, table: context.table, browser: browser)
        if transfer == .drag {
            try need(destination.count == folder.count + 1 && Array(destination.dropLast()) == folder,
                "tar-members-drag-sibling-destination")
            guard let target = destination.last else { throw Failure(stage: "tar-members-drag-destination") }
            try beginNativeMove(context, name: names[0], destination: target, board: board)
        } else {
            try await captureClipboard(transfer, context: context, browser: browser, board: board)
            try await navigate(context, browser: browser, to: destination)
            let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "")
            try need(context.table.validateMenuItem(paste)
                && NSApp.sendAction(paste.action!, to: context.table, from: paste), "tar-members-native-paste")
        }
        let shown = try await review()
        let id = try await commit(shown)
        if transfer != .drag {
            try need(browser.clipboardState.scopedItem == nil, "tar-members-published-marker-retirement")
        }
        return id
    }
}

#if DEBUG
/// The TAR branch of the existing editor check exercises the ordinary archive
/// workbench and private native clipboard. It never changes a system clipboard.
@MainActor enum TARMemberVerification {
    private typealias Probe = ArchiveTextEditorVerification
    private enum Transfer { case cut, copy, drag }
    static func check(source: URL, browser: BrowserViewController,
        cold: RecoverableFileOperations, root: URL) async throws -> [String] {
        let before = try await Task.detached { try Data(contentsOf: source) }.value
        let added = source.deletingLastPathComponent().appendingPathComponent("Added.bin")
        try await Task.detached { try Data([0, 1, 255]).write(to: added, options: .withoutOverwriting) }.value
        let board = NSPasteboard(name: .init("Traverse.TAR.MemberCheck." + UUID().uuidString))
        let previousBoard = browser.transferPasteboard
        let interactive = ProcessInfo.processInfo.arguments.contains("--interactive-tar-member-drag")
        browser.transferPasteboard = board
        defer { browser.transferPasteboard = previousBoard; board.releaseGlobally() }

        func openRoot() async throws -> (ArchiveTabController, TARBrowserModel, FileTableView) {
            let context = try await TARMemberActionDriver.open(source, browser: browser)
            return (context.owner, context.model, context.table)
        }
        func choose(_ names: [String], model: TARBrowserModel, table: FileTableView) throws {
            try TARMemberActionDriver.choose(names, model: model, table: table, browser: browser)
        }
        func review() async throws -> ArchiveCreationWindowController {
            try await TARMemberActionDriver.review()
        }
        func typeName(_ name: String, in controller: ArchiveCreationWindowController) async throws {
            try await TARMemberActionDriver.typeName(name, in: controller)
        }
        func commit(_ controller: ArchiveCreationWindowController) async throws -> UUID {
            try await TARMemberActionDriver.commit(controller)
        }
        func undo(_ id: UUID, expected: Data) async throws {
            browser.navigate(to: .directory(source.deletingLastPathComponent()))
            try await Probe.wait("tar-members-undo-local-page") { !browser.isLoading && browser.rowsByURL[source] != nil }
            await browser.recoveryInspectionTask?.value
            let result = await cold.undo(recordID: id)
            let restored = try await Task.detached { try Data(contentsOf: source) }.value
            try Probe.need(result.result.disposition == .succeeded && restored == expected, "tar-members-same-process-undo-exact")
        }
        let actions: [(TARBrowserModel.MutationAction, [String], String, Set<String>)] = [
            (.rename, ["Generated.json"], "Renamed.json", ["Renamed.json", "Other.json"]),
            (.rename, ["Generated.json", "Other.json"], "", ["Batch Generated.json", "Batch Other.json"]),
            (.duplicate, ["Generated.json"], "", ["Generated.json", "Generated (1).json", "Other.json"]),
            (.remove, ["Other.json"], "", ["Generated.json"]),
            (.group, ["Generated.json", "Other.json"], "Grouped", ["Grouped", "Grouped/Generated.json", "Grouped/Other.json"]),
            (.newFolder, [], "Destination", ["Destination", "Generated.json", "Other.json"]),
            (.add, [], "", ["Added.bin", "Generated.json", "Other.json"]),
        ]
        func paths() async throws -> Set<String> {
            try await TARMemberActionDriver.paths(source)
        }
        for (action, names, name, expected) in actions {
            let (owner, model, table) = try await openRoot()
            try choose(names, model: model, table: table)
            let dropBoard = NSPasteboard(name: .init("Traverse.TAR.AddCheck." + UUID().uuidString))
            defer { dropBoard.releaseGlobally() }
            if action == .add {
                try TARMemberActionDriver.beginNativeAdd(added, in: .init(owner: owner, model: model, table: table), board: dropBoard)
            } else { model.reviewMutation(action) }
            var shown = try await review()
            if !name.isEmpty { try await typeName(name, in: shown) }
            if action == .rename, names.count > 1 {
                try Probe.need(shown.model.isMemberBatchRename && shown.model.batchNames.count == 2, "tar-members-shared-batch-review")
                shown.model.batchOptions.prefix = "Batch "
            }
            try await Probe.wait("tar-members-cancel-plan") { !shown.model.isChoosing && !shown.model.isPreparing && !shown.model.previewIsPendingForVerification }
            if action == .rename, names.count == 1 {
                try await typeName("Other.json", in: shown)
                try await Probe.wait("tar-members-conflict-refused") { !shown.model.isPreparing && !shown.model.previewIsPendingForVerification }
                try Probe.need(!shown.model.canCreate, "tar-members-occupied-rename-enabled")
            }
            await ApplicationArchiveCreation.shared.closeAndDrain()
            let cancelled = try await Task.detached { try Data(contentsOf: source) }.value
            try Probe.need(cancelled == before, "tar-members-cancel-changed-source")
            model.reviewMutation(action, addedSource: action == .add ? .init(urls: [added]) : nil)
            shown = try await review()
            if !name.isEmpty { try await typeName(name, in: shown) }
            if action == .rename, names.count > 1 { shown.model.batchOptions.prefix = "Batch " }
            if action == .add, TARBrowserModel.isCompressed(source) {
                shown.model.keepsCurrentTARCompression = false
                shown.model.tarCompression = model.formatName == "TAR.bz2" ? .bzip2Fast : .gzipFast
            }
            if !ProcessInfo.processInfo.arguments.contains("--offscreen"), action == .group || action == .add || shown.model.isMemberBatchRename,
               CGPreflightScreenCaptureAccess(), let window = shown.window {
                try await Probe.wait("tar-members-visible-review") { shown.model.canCreate }
                let label = shown.model.isMemberBatchRename ? "batch-rename" : "\(action)"
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/tar-\(label).png"))
            }
            let id = try await commit(shown)
            if action == .add, TARBrowserModel.isCompressed(source) {
                let bytes = try await Task.detached { try Data(contentsOf: source) }.value
                try Probe.need(model.formatName == "TAR.bz2" ? bytes.count >= 4 && bytes[3] == 49
                    : bytes.count >= 10 && bytes[8] == 4, "tar-members-selected-compression-applied")
            }
            try Probe.need(try await paths() == expected, "tar-members-exact-paths")
            try await undo(id, expected: before)
        }
        let replacementParent = root.appendingPathComponent("source/Replacement Inputs")
        let replacement = replacementParent.appendingPathComponent("Generated.json")
        let replacementText = "{\"replacement\":true}\n"
        try await Task.detached {
            try FileManager().createDirectory(at: replacementParent, withIntermediateDirectories: false)
            try Data(replacementText.utf8).write(to: replacement, options: .withoutOverwriting)
        }.value
        for cancel in [true, false] {
            let (_, model, _) = try await openRoot()
            model.reviewMutation(.add, addedSource: .init(urls: [replacement]))
            let shown = try await review()
            try await Probe.wait("tar-members-default-keep-both") { shown.model.canCreate && shown.model.preparedAdditions.count == 1 }
            try Probe.need(shown.model.additionCollisions == .keepBoth && shown.model.replacedFileCount == 0,
                "tar-members-replacement-default-remains-keep-both")
            shown.model.additionCollisions = .replaceFiles
            try await Probe.wait("tar-members-explicit-replacement-plan") {
                shown.model.canCreate && shown.model.replacedFileCount == 1 && shown.model.summary?.files == 2
            }
            if cancel {
                await ApplicationArchiveCreation.shared.closeAndDrain()
                let cancelled = try await Task.detached { try Data(contentsOf: source) }.value
                try Probe.need(cancelled == before, "tar-members-replacement-cancel")
            } else {
                if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = shown.window {
                    try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/tar-replace-file.png"))
                }
                let id = try await commit(shown)
                func replacedText() async throws -> String {
                    let reader = ApplicationCompressedArchives.shared.reader(excluding: [])
                    let session = try await (TARBrowserModel.isCompressed(source) ? reader.prepareCompressed(source) : reader.open(source))
                    let text: String
                    do {
                        let page = try await session.page(in: session.root)
                        guard let member = page.items.first(where: { $0.name == "Generated.json" }) else {
                            throw Probe.Failure(stage: "tar-members-replaced-member-missing")
                        }
                        let document = try await reader.openTextForEdit(session.selectionForTextPreview(member.id))
                        text = document.contents.text
                    } catch { await session.close(); throw error }
                    await session.close(); return text
                }
                let text = try await replacedText(), currentPaths = try await paths()
                try Probe.need(text == replacementText && currentPaths == Set(["Generated.json", "Other.json"]),
                    "tar-members-exact-replaced-content")
                try await undo(id, expected: before)
            }
        }
        for transfer in [Transfer.cut, .copy, .drag] {
            let copying = transfer == .copy
            var (owner, model, table) = try await openRoot()
            model.reviewMutation(.newFolder)
            let folderReview = try await review(); try await typeName("Destination", in: folderReview)
            let folderID = try await commit(folderReview)
            let withFolder = try await Task.detached { try Data(contentsOf: source) }.value
            (owner, model, table) = try await openRoot()
            var shown: ArchiveCreationWindowController
            if transfer == .drag {
                try choose(["Generated.json"], model: model, table: table)
                if interactive {
                    guard let window = browser.view.window else { throw Probe.Failure(stage: "tar-members-native-window") }
                    window.title = "Generated TAR Move · " + root.lastPathComponent.prefix(8)
                    window.setContentSize(.init(width: 1080, height: 680)); window.center()
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    try Probe.need(window.makeFirstResponder(table), "tar-members-pointer-focus")
                    let receipt = ["title": window.title, "from": "Generated.json", "to": "Destination"]
                    try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("evidence/tar-drag-ready.json"), options: .withoutOverwriting)
                    try await Probe.wait("tar-members-pointer-review", seconds: 180) { ApplicationArchiveCreation.shared.controller != nil }
                } else {
                try TARMemberActionDriver.beginNativeMove(.init(owner: owner, model: model, table: table),
                    name: "Generated.json", destination: "Destination", board: board)
                }
                shown = try await review()
            } else {
            let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "")
            func captureFile() async throws {
                try choose(["Generated.json"], model: model, table: table)
                try await TARMemberActionDriver.captureClipboard(copying ? .copy : .cut,
                    context: .init(owner: owner, model: model, table: table), browser: browser, board: board)
                try Probe.need(table.validateMenuItem(paste) == copying,
                    "tar-members-private-marker-and-same-folder-rule")
            }
            func enterDestination() async throws {
                try choose(["Destination"], model: model, table: table); browser.openSelection(nil)
                try await Probe.wait("tar-members-destination-page") { owner.hasRenderedCurrentRowsForVerification && model.breadcrumbs.last?.name == "Destination" }
                try Probe.need(browser.view.window?.makeFirstResponder(table) == true, "tar-members-destination-focus")
            }
            try await captureFile(); try await enterDestination()
            try Probe.need(table.validateMenuItem(paste) && NSApp.sendAction(paste.action!, to: table, from: paste), "tar-members-native-paste")
            board.clearContents()
            try await Probe.wait("tar-members-changed-clipboard-drain") { !model.isPreparingPreview }
            try Probe.need(ApplicationArchiveCreation.shared.controller == nil, "tar-members-new-board-refuses-old-paste")
            browser.goUp(nil)
            try await Probe.wait("tar-members-return-root") { owner.hasRenderedCurrentRowsForVerification && model.items.contains { $0.name == "Generated.json" } }
            try await captureFile(); try await enterDestination()
            try Probe.need(table.validateMenuItem(paste) && NSApp.sendAction(paste.action!, to: table, from: paste), "tar-members-paste-cancel")
            shown = try await review()
            try await Probe.wait("tar-members-paste-cancel-ready") { shown.model.canCreate }
            let marker = browser.clipboardState.scopedItem?.id
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try Probe.need(marker != nil && browser.clipboardState.scopedItem?.id == marker, "tar-members-cancel-keeps-marker")
            try Probe.need(browser.view.window?.makeFirstResponder(table) == true
                && table.validateMenuItem(paste) && NSApp.sendAction(paste.action!, to: table, from: paste), "tar-members-paste-after-cancel")
            shown = try await review()
            }
            let id = try await commit(shown)
            var expected: Set<String> = ["Destination", "Destination/Generated.json", "Other.json"]
            if copying { expected.insert("Generated.json") }
            try Probe.need(try await paths() == expected && browser.clipboardState.scopedItem == nil,
                "tar-members-paste-paths-and-marker-retirement")
            try await undo(id, expected: withFolder); try await undo(folderID, expected: before)
        }
        return ["TAR Rename, batch Rename, Duplicate, Remove, Group, New Folder and Add share the ordinary review, preserve the source on Cancel, reject an occupied Rename and restore exact bytes with a reopened engine in the same process",
            "TAR Add defaults to Keep Both; explicit Replace Files shows its captured replacement, Cancel changes nothing, successful content replacement and same-process reopened-engine Undo preserve exact names and original bytes",
            "Native TAR Cut/Copy → navigate → Paste uses an opaque private marker, rejects changed-board and same-folder Cut, keeps Cancel repeatable, refreshes the complete result and retires the marker only after publication; same-process reopened-engine Undo restores both edits",
            interactive ? "The actual native pointer drag from Generated.json onto Destination opens the shared Move review, publishes the exact namespace and same-process Undo restores both edits" :
            "TAR local Add and same-archive Move pass the real table delegate callbacks with a private generated drag input and reject duplicate delivery callbacks; actual pointer gestures remain separate acceptance"]
    }
}
#endif
#endif
