#if DEBUG
import AppKit
import FileOperations
import LocalStorage

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
            browser.navigate(to: .directory(source.deletingLastPathComponent()))
            try await Probe.wait("tar-members-local-page") { !browser.isLoading && browser.rowsByURL[source] != nil }
            browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
            browser.openSelection(nil)
            try await Probe.wait("tar-members-root-page") { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
            guard let owner = browser.currentArchive, let model = owner.tarModelForVerification,
                  let table = owner.table else { throw Probe.Failure(stage: "tar-members-root-owner") }
            try Probe.need(browser.view.window?.makeFirstResponder(table) == true, "tar-members-table-focus")
            return (owner, model, table)
        }
        func choose(_ names: [String], model: TARBrowserModel, table: FileTableView) throws {
            let rows = IndexSet(model.items.indices.filter { names.contains(model.items[$0].name) })
            try Probe.need(rows.count == names.count, "tar-members-selection-names")
            table.selectRowIndexes(rows, byExtendingSelection: false)
            try Probe.need(browser.view.window?.makeFirstResponder(table) == true && model.selection.count == names.count,
                "tar-members-selected-live-rows")
        }
        func review() async throws -> ArchiveCreationWindowController {
            try await Probe.wait("tar-members-review") { ApplicationArchiveCreation.shared.controller != nil }
            guard let controller = ApplicationArchiveCreation.shared.controller else { throw Probe.Failure(stage: "tar-members-review-missing") }
            return controller
        }
        func typeName(_ name: String, in controller: ArchiveCreationWindowController) async throws {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let window = controller.window, let content = window.contentView,
                  let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: {
                      ["New item name", "New folder name", "File name"].contains($0.placeholderString ?? "")
                  }), window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                throw Probe.Failure(stage: "tar-members-native-name-field")
            }
            editor.selectAll(nil); editor.insertText(name, replacementRange: .init(location: 0, length: editor.string.utf16.count))
            try await Probe.wait("tar-members-native-name-binding") { controller.model.memberName == name }
        }
        func commit(_ controller: ArchiveCreationWindowController) async throws -> UUID {
            try await Probe.wait("tar-members-ready") { !controller.model.isChoosing && !controller.model.isPreparing && !controller.model.previewIsPendingForVerification }
            try Probe.need(controller.model.canCreate, "tar-members-plan: " + controller.model.notice)
            controller.model.create()
            try await Probe.wait("tar-members-published") { !controller.model.isRunning && controller.model.outcome != nil }
            guard controller.model.outcome?.result.disposition == .succeeded, let id = controller.model.outcome?.recordID else {
                throw Probe.Failure(stage: "tar-members-publication: " + controller.model.notice)
            }
            await ApplicationArchiveCreation.shared.closeAndDrain()
            return id
        }
        func undo(_ id: UUID, expected: Data) async throws {
            browser.navigate(to: .directory(source.deletingLastPathComponent()))
            try await Probe.wait("tar-members-undo-local-page") { !browser.isLoading && browser.rowsByURL[source] != nil }
            let result = await cold.undo(recordID: id)
            let restored = try await Task.detached { try Data(contentsOf: source) }.value
            try Probe.need(result.result.disposition == .succeeded && restored == expected, "tar-members-cold-undo-exact")
        }
        let actions: [(TARBrowserModel.MutationAction, [String], String, Set<String>)] = [
            (.rename, ["Generated.json"], "Renamed.json", ["Renamed.json", "Other.json"]),
            (.duplicate, ["Generated.json"], "", ["Generated.json", "Generated (1).json", "Other.json"]),
            (.remove, ["Other.json"], "", ["Generated.json"]),
            (.group, ["Generated.json", "Other.json"], "Grouped", ["Grouped", "Grouped/Generated.json", "Grouped/Other.json"]),
            (.newFolder, [], "Destination", ["Destination", "Generated.json", "Other.json"]),
            (.add, [], "", ["Added.bin", "Generated.json", "Other.json"]),
        ]
        func paths() async throws -> Set<String> {
            let session = try await TARArchiveReader().open(source)
            let result = try await session.searchNames("")
            await session.close()
            return Set(result.items.map(\.path))
        }
        for (action, names, name, expected) in actions {
            let (_, model, table) = try await openRoot()
            try choose(names, model: model, table: table)
            let dropBoard = NSPasteboard(name: .init("Traverse.TAR.AddCheck." + UUID().uuidString))
            defer { dropBoard.releaseGlobally() }
            if action == .add {
                try Probe.need(dropBoard.writeObjects([added as NSURL]), "tar-members-native-add-board")
                let info = FixtureDraggingInfo(board: dropBoard, source: nil, sequence: 913, allowed: .copy)
                guard let rows = table.delegate as? TARMetadataRows else { throw Probe.Failure(stage: "tar-members-native-add-rows") }
                try Probe.need(rows.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .copy
                    && rows.tableView(table, acceptDrop: info, row: -1, dropOperation: .on)
                    && !rows.tableView(table, acceptDrop: info, row: -1, dropOperation: .on), "tar-members-native-add-once")
            } else { model.reviewMutation(action) }
            var shown = try await review()
            if !name.isEmpty { try await typeName(name, in: shown) }
            try await Probe.wait("tar-members-cancel-plan") { !shown.model.isChoosing && !shown.model.isPreparing && !shown.model.previewIsPendingForVerification }
            if action == .rename {
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
            if !ProcessInfo.processInfo.arguments.contains("--offscreen"), action == .group || action == .add,
               CGPreflightScreenCaptureAccess(), let window = shown.window {
                try await Probe.wait("tar-members-visible-review") { shown.model.canCreate }
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/tar-\(action).png"))
            }
            let id = try await commit(shown)
            try Probe.need(try await paths() == expected, "tar-members-exact-paths")
            try await undo(id, expected: before)
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
                guard let rows = table.delegate as? TARMetadataRows, let source = rows.memberDragSource,
                      let writer = source.writer(tarIDs: model.selection),
                      let row = model.items.firstIndex(where: { $0.name == "Destination" }) else {
                    throw Probe.Failure(stage: "tar-members-native-move-source")
                }
                board.clearContents(); try Probe.need(board.writeObjects([writer]), "tar-members-native-move-board")
                source.begin(sequence: 914, tarIDs: model.selection, board: board)
                let info = FixtureDraggingInfo(board: board, source: table, sequence: 914, allowed: [.copy, .move])
                try Probe.need(rows.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on) == .move
                    && rows.tableView(table, acceptDrop: info, row: row, dropOperation: .on)
                    && !rows.tableView(table, acceptDrop: info, row: row, dropOperation: .on), "tar-members-native-move-once")
                source.end(sequence: 914, operation: .move)
                }
                shown = try await review()
            } else {
            let capture = NSMenuItem(title: copying ? "Copy" : "Cut",
                action: copying ? #selector(FileTableView.copy(_:)) : #selector(FileTableView.cut(_:)), keyEquivalent: "")
            let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "")
            func captureFile() async throws {
                try choose(["Generated.json"], model: model, table: table)
                try Probe.need(table.validateMenuItem(capture) && NSApp.sendAction(capture.action!, to: table, from: capture), "tar-members-native-capture")
                try await Probe.wait("tar-members-sealed-clipboard") { browser.clipboardState.scopedItem?.isAlive == true && !model.isPreparingPreview }
                try Probe.need(board.types == [ScopedItemClipboardIntent.pasteboardType]
                    && browser.clipboardState.scopedItem?.operation == (copying ? .copy : .move)
                    && table.validateMenuItem(paste) == copying, "tar-members-private-marker-and-same-folder-rule")
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
        return ["TAR Rename, Duplicate, Remove, Group, New Folder and Add share the ordinary review, preserve the source on Cancel, reject an occupied Rename and cold-Undo to the exact original",
            "Native TAR Cut/Copy → navigate → Paste uses an opaque private marker, rejects changed-board and same-folder Cut, keeps Cancel repeatable, refreshes the complete result and retires the marker only after publication; cold Undo restores both edits",
            interactive ? "The actual native pointer drag from Generated.json onto Destination opens the shared Move review, publishes the exact namespace and cold-Undoes both edits" :
            "TAR local Add and same-archive Move pass the real table delegate callbacks with a private generated drag input and reject duplicate delivery callbacks; actual pointer gestures remain separate acceptance"]
    }
}
#endif
