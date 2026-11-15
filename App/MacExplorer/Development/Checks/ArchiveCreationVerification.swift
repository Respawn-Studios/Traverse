#if DEBUG
import AppKit
import ExplorerCore
import CryptoKit
import CoreServices
import Darwin
import FileOperations
import FileMemory
import LocalStorage

/// Hashes only transient generated-file security observations. The native
/// quarantine and provenance bytes never enter a report or operation history.
private struct ArchiveCreationMarkState: Equatable, Sendable {
    let quarantineSHA256: String?
    let provenanceSHA256: String?
    let publiclyMarked: Bool

    static func observe(_ url: URL) throws -> Self {
        var facts = stat()
        guard lstat(url.path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_nlink == 1, facts.st_uid == geteuid() else { throw FileOperationFailure.invalidRequest }
        let quarantine = try digest("com.apple.quarantine", at: url)
        let provenance = try digest("com.apple.provenance", at: url)
        let properties = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        guard (quarantine != nil) == (properties != nil) else { throw FileOperationFailure.copyMetadataMismatch }
        return Self(quarantineSHA256: quarantine, provenanceSHA256: provenance, publiclyMarked: properties != nil)
    }

    private static func digest(_ name: String, at url: URL) throws -> String? {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if count < 0 {
            if errno == ENOATTR { return nil }
            throw FileOperationFailure.ioFailure
        }
        guard count <= 65_536 else { throw FileOperationFailure.invalidRequest }
        var bytes = Data(count: count)
        let read = bytes.withUnsafeMutableBytes {
            getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard read == count else { throw FileOperationFailure.sourceChanged }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor enum ArchiveCreationVerification {
    /// Selects the held public-mark policy only for this exact generated
    /// offscreen route and journal in the ordinary development app.
    static func markedSourceCaseAdmitted(at journal: URL) -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { return false }
        let root = URL(fileURLWithPath: raw)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = repo.appendingPathComponent(".build/traverse-development")
        let prefix = ["--verify-ui", "--check-zip-creation", "--analysis-source", root.path]
        let zip = prefix + ["--offscreen", "--marked-source-create"]
        let tar = prefix + ["--create-tar", "--offscreen", "--marked-source-create"]
        let format: String
        if args == zip || args == zip + ["--archive-create-cold-undo"] { format = "zip" }
        else if args == tar || args == tar + ["--archive-create-cold-undo"] { format = "tar" }
        else { return false }
        guard root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == base,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              journal.standardizedFileURL == root.appendingPathComponent("state/operation-recovery").standardizedFileURL,
              Bundle.main.bundleIdentifier == "local.macexplorer.development",
              Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app"),
              let data = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["packet"] as? String == "traverse-development-v1",
              marker["action"] as? String == "archive-creation",
              marker["markedSourceCreate"] as? Bool == true,
              marker["format"] as? String == format else { return false }
        return true
    }

    /// One ordinary UI/operation flow for the sibling-copy intent. The runner
    /// supplies a small independent Python zipfile source (stored + deflated).
    static func runRenameCopy() async {
        var root: URL?, owner: BrowserWindowController?, stage = "scope", checks = [String](), clips = [[String: Any]]()
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw FileOperationFailure.invalidRequest }
            let area = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            try UIVerification.require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent
                && marker?["action"] as? String == "native-zip-rename-copy"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/xcode/Build/Products/Debug/Mac Explorer.app"), "Exact ordinary generated ZIP-copy scope")
            root = area; stage = "fixture"
            let removing = ProcessInfo.processInfo.arguments.contains("--remove-members")
            let renamingFolder = ProcessInfo.processInfo.arguments.contains("--rename-folder")
            let removingFolders = ProcessInfo.processInfo.arguments.contains("--remove-folders")
            let adding = ProcessInfo.processInfo.arguments.contains("--add-members")
            let newFolder = ProcessInfo.processInfo.arguments.contains("--new-folder")
            let copying = ProcessInfo.processInfo.arguments.contains("--clipboard-copy-members")
            let duplicating = copying || ProcessInfo.processInfo.arguments.contains("--duplicate-members")
            let moving = ProcessInfo.processInfo.arguments.contains("--move-members")
            let clipboardTransfer = moving || copying
            let interactiveMove = moving && ProcessInfo.processInfo.arguments.contains("--interactive-zip-move")
            let updating = ProcessInfo.processInfo.arguments.contains("--update-original")
            let collidingAdd = adding && updating
            let nativeOriginalUpdate = ProcessInfo.processInfo.arguments.contains("--native-original-update")
            let tracked = ProcessInfo.processInfo.arguments.contains("--tracked-zip")
            let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
            try UIVerification.require(!(removing && renamingFolder) && (!removingFolders || removing)
                && !(adding && (removing || renamingFolder))
                && !(newFolder && (adding || removing || renamingFolder))
                && (!(duplicating || moving) || updating && !(newFolder || adding || removing || renamingFolder)
                    && !(duplicating && moving)),
                "One generated copy intent")
            try UIVerification.require(!nativeOriginalUpdate || updating,
                "Native Original Update qualification requires the existing Update flow")
            let expectedFiles = copying || collidingAdd ? 8 : moving ? 4 : duplicating ? 6 : adding ? 5 : removing ? (removingFolders ? 0 : 1) : 3
            let expectedFolders = copying ? 6 : moving || duplicating || adding ? 4 : newFolder ? 3 : removingFolders ? 0 : 2
            let expectedBytes = collidingAdd ? 52 : copying ? 49 : moving ? 22 : duplicating ? 34 : adding ? 30 : removing ? (removingFolders ? 0 : 4) : 17
            let input = area.appendingPathComponent("source/Input")
            let original = input.appendingPathComponent("Original.zip")
            let large = ProcessInfo.processInfo.arguments.contains("--large-interface"), settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.restoresSession = false; settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.appearance = large ? .light : .dark; settings.interfaceSize = .init(large ? 150 : 100)
            settings.motion.mode = large ? .reduced : .full; settings.opensArchivesInTraverse = true
            InterfacePresentation.shared.bind(settings)
            let controller = BrowserWindowController(settings: settings); owner = controller
            let browser = controller.browser
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.pinsController = BrowserPinsController(stateDirectory: nil)
            browser.privateNames = ApplicationPrivateNames(directory: area.appendingPathComponent("state/names"), settings: settings)
            let history = area.appendingPathComponent("state/history")
            let engine = nativeOriginalUpdate
                ? RecoverableFileOperations(journalDirectory: history, protecting: [area.appendingPathComponent("state")],
                    activity: ApplicationFileActivity.beginOperation, authoredZIPMetadataPolicy: .nativeCreate,
                    authoredZIPOriginalUpdateNativePolicy: .qualifiedNativeStage)
                : browser.operationCoordinator.engine(at: history)
            browser.recoverableFileOperations = engine
            if updating {
                let referenceFile = area.appendingPathComponent("source/Catalog Setup.txt")
                try await Task.detached { try Data("Generated catalog setup.".utf8).write(to: referenceFile, options: .withoutOverwriting) }.value
                let id = try await browser.privateNames.save(AuthoredNames(nickname: "Generated catalog setup"),
                    source: referenceFile, id: nil, revision: nil, access: nil, allowFollowing: true)
                try UIVerification.require(try await browser.privateNames.forget(id) == .forgotten,
                    "Separate generated fixture initializes an empty name catalog")
            }
            if tracked {
                let id = try await browser.privateNames.save(AuthoredNames(nickname: "Generated tracked ZIP"),
                    source: original, id: nil, revision: nil, access: nil, allowFollowing: true)
                try UIVerification.require(try await browser.privateNames.forget(id) == .forgotten,
                    "Explicit Forget leaves native tracking intact without a saved binding")
            }
            // This ordinary native flow is an unmarked-source UI/operation
            // check. Actual sandbox stage marks have their own signed gate.
            let expectedMark = large && !nativeOriginalUpdate
                ? Data("0081;65000001;Traverse-Generated-Test;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8) : nil
            let digest = try await Task.detached {
                if let expectedMark {
                    guard expectedMark.withUnsafeBytes({ setxattr(original.path, "com.apple.quarantine",
                        $0.baseAddress, $0.count, 0, XATTR_CREATE) }) == 0 else { throw FileOperationFailure.invalidRequest }
                }
                return SHA256.hash(data: try Data(contentsOf: original))
            }.value
            stage = "ordinary-open"
            controller.window?.setContentSize(.init(width: large ? 1180 : 980, height: large ? 740 : 650))
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if offscreen { controller.window?.setFrameOrigin(.init(x: -12000, y: -12000)) }
            if copying {
                controller.beginBrowsing()
                try await wait { controller.workspace.sessionReady }
            }
            browser.navigate(to: .directory(input))
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[original] != nil }
            browser.setFileSelection([original]); browser.fileSelectionDidChange(); browser.openSelection(nil)
            try await wait { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true && browser.currentArchive?.busy == false }
            guard let archive = browser.currentArchive, let model = archive.zipModelForVerification,
                  let table = archive.table, let folder = model.visibleItems.firstIndex(where: { $0.name == "Project" }) else { throw FileOperationFailure.invalidRequest }
            func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
            guard let testItem = children(archive.view).compactMap({ $0 as? NSPopUpButton })
                .compactMap({ $0.menu?.item(withTitle: "Test ZIP Contents") }).first,
                  let testAction = testItem.action else { throw FileOperationFailure.invalidRequest }
            try UIVerification.require(archive.validateMenuItem(testItem)
                && NSApp.sendAction(testAction, to: testItem.target, from: testItem), "Native Test ZIP command is unavailable")
            await model.drain()
            let unchangedAfterCheck = try await Task.detached { SHA256.hash(data: try Data(contentsOf: original)) == digest }.value
            try UIVerification.require(model.contentReport?.files == model.summary?.files
                && model.checkedAt != nil && unchangedAfterCheck, "The listed ZIP did not pass its read-only content check")
            checks.append("The actual archive More menu tests the exact listed ZIP, reports complete checksum results and leaves its source unchanged")
            if !renamingFolder && !removingFolders && !duplicating && !moving {
                table.selectRowIndexes([folder], byExtendingSelection: false); browser.openSelection(nil)
                try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy && model.visibleItems.contains { $0.name == "Note.txt" } }
            }
            table.deselectAll(nil)
            try await wait { model.selection.isEmpty }
            try UIVerification.require(!archive.canRenameInCopy && (!removing || !archive.canRemoveFromCopy),
                "An empty selection refuses member edits")
            if duplicating { try UIVerification.require(!archive.canDuplicate, "Empty selection cannot duplicate") }
            guard let row = model.visibleItems.firstIndex(where: { $0.name == (renamingFolder || removingFolders || duplicating || moving ? "Project" : "Note.txt") })
            else { throw FileOperationFailure.invalidRequest }
            let menuTitle = duplicating ? "Duplicate…" : newFolder ? "New Folder in ZIP…" : updating
                ? (adding ? "Add to ZIP…" : removing ? "Remove from ZIP…" : "Rename in ZIP…")
                : (adding ? "Add to ZIP Copy…" : removing ? "Remove from ZIP Copy…" : "Rename in ZIP Copy…")
            let item = table.menu?.items.first { $0.title == menuTitle }
            let chosenRows = clipboardTransfer ? IndexSet(model.visibleItems.indices.filter { $0 != row })
                : removingFolders || duplicating ? IndexSet(model.visibleItems.indices)
                : removing ? IndexSet(model.visibleItems.indices.filter { model.visibleItems[$0].kind == .file }) : IndexSet(integer: row)
            table.selectRowIndexes(chosenRows, byExtendingSelection: false)
            var dragSequence = 42
            func openReview(usingBrowserRemove: Bool = false, usingBrowserNewFolder: Bool = false,
                            usingPointer: Bool = false) async throws -> ArchiveCreationWindowController {
                if moving && usingPointer {
                    guard let window = controller.window else { throw FileOperationFailure.invalidRequest }
                    window.title = "Generated ZIP Move · " + area.lastPathComponent.prefix(8)
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    try await wait { window.isKeyWindow && NSApp.isActive }
                    try UIVerification.require(window.makeFirstResponder(table)
                        && table.selectedRowIndexes == chosenRows, "Exact pointer review source selection")
                    try Data("ready\n".utf8).write(to: area.appendingPathComponent("evidence/zip-move-gesture-ready.txt"),
                        options: .withoutOverwriting)
                    try await wait(seconds: 60) { ApplicationArchiveCreation.shared.controller?.model.isMemberMove == true }
                } else if moving {
                    guard let rows = model.rowsForVerification, let source = rows.memberDragSource else { throw FileOperationFailure.invalidRequest }
                    let board = NSPasteboard.withUniqueName()
                    defer { board.releaseGlobally() }
                    let writers = chosenRows.compactMap { rows.tableView(table, pasteboardWriterForRow: $0) }
                    try UIVerification.require(writers.count == chosenRows.count && board.writeObjects(writers), "Exact ZIP member drag offer")
                    dragSequence += 1
                    source.begin(sequence: dragSequence, ids: model.selection, board: board)
                    defer { source.end(sequence: dragSequence, operation: .move) }
                    let info = FixtureDraggingInfo(board: board, source: table, sequence: dragSequence, allowed: [.copy, .move])
                    guard let selectedFolder = chosenRows.first(where: { model.visibleItems[$0].kind == .directory }) else {
                        throw FileOperationFailure.invalidRequest
                    }
                    try UIVerification.require(rows.tableView(table, validateDrop: info, proposedRow: selectedFolder, proposedDropOperation: .on).isEmpty
                        && rows.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on).isEmpty,
                        "Move rejects the selected folder and blank space")
                    try UIVerification.require(rows.tableView(table, validateDrop: info, proposedRow: row, proposedDropOperation: .on) == .move
                        && rows.tableView(table, acceptDrop: info, row: row, dropOperation: .on)
                        && !rows.tableView(table, acceptDrop: info, row: row, dropOperation: .on),
                        "Native drop accepts one move onto the observed ZIP folder")
                } else if duplicating {
                    guard let item, let target = item.target as? NSMenuItemValidation else { throw FileOperationFailure.invalidRequest }
                    controller.window?.makeFirstResponder(table)
                    let duplicate = NSMenuItem(title: "Duplicate", action: #selector(BrowserViewController.duplicateSelection(_:)), keyEquivalent: "d")
                    duplicate.target = browser
                    try UIVerification.require(target.validateMenuItem(item) && browser.validateMenuItem(duplicate)
                        && NSApp.sendAction(duplicate.action!, to: browser, from: duplicate),
                        "Native Duplicate command targets the selected ZIP members")
                } else if usingBrowserNewFolder {
                    controller.window?.makeFirstResponder(table)
                    let create = NSMenuItem(title: "New Folder…", action: #selector(BrowserViewController.createFolder(_:)), keyEquivalent: "")
                    create.target = browser
                    try UIVerification.require(browser.validateMenuItem(create)
                        && NSApp.sendAction(create.action!, to: browser, from: create), "Browser New Folder opens the ZIP folder review")
                } else if usingBrowserRemove {
                    controller.window?.makeFirstResponder(table)
                    let remove = NSMenuItem(title: "Move to Trash…", action: #selector(BrowserViewController.trashSelection(_:)), keyEquivalent: "")
                    remove.target = browser
                    try UIVerification.require(browser.validateMenuItem(remove) && remove.title == "Remove from ZIP…"
                        && NSApp.sendAction(remove.action!, to: browser, from: remove), "Browser Remove command opens ZIP review rather than Trash")
                } else {
                    guard let item, let action = item.action, let target = item.target as? NSMenuItemValidation else {
                        throw FileOperationFailure.invalidRequest
                    }
                    try UIVerification.require(target.validateMenuItem(item) && NSApp.sendAction(action, to: item.target, from: item), "Native member-copy menu")
                }
                try await wait { ApplicationArchiveCreation.shared.controller?.model.isMemberCopy == true
                    && ApplicationArchiveCreation.shared.controller?.model.isMemberRemoval == removing
                    && ApplicationArchiveCreation.shared.controller?.model.isMemberDuplicate == duplicating
                    && ApplicationArchiveCreation.shared.controller?.model.isMemberMove == moving
                    && ApplicationArchiveCreation.shared.controller?.model.isMemberAddition == adding
                    && ApplicationArchiveCreation.shared.controller?.model.isMemberNewFolder == newFolder
                    && ApplicationArchiveCreation.shared.controller?.model.updatesOriginal == updating }
                guard let review = ApplicationArchiveCreation.shared.controller else { throw FileOperationFailure.invalidRequest }
                return review
            }
            let cancel = try await openReview(usingBrowserRemove: updating && removing, usingBrowserNewFolder: newFolder)
            try await wait { !cancel.model.isPreparing && !cancel.model.previewIsPendingForVerification }
            if adding {
                try UIVerification.require(!cancel.model.canCreate && cancel.model.addedSources.isEmpty
                    && cancel.model.additionFolder == "Project", "Add starts with the current ZIP folder and no local selection")
                cancel.model.chooseSourcesForVerification = { _ in nil }
                cancel.model.chooseAdditions()
                try await wait { ApplicationArchiveCreation.shared.controller == nil }
            } else if moving {
                try UIVerification.require(cancel.model.canCreate && cancel.model.moveSelection?.folder == "Project"
                    && Set(cancel.model.moveSelection?.items.archivePaths ?? []) == ["Move Folder", "Top.txt"],
                    "The Move review binds the actual target and whole selection")
            } else if duplicating {
                try UIVerification.require(cancel.model.canCreate
                    && Set(cancel.model.duplicateSelection?.archivePaths ?? []) == (copying ? ["Move Folder", "Top.txt"] : ["Project", "Top.txt"]),
                    "Duplicate preselects available names for both exact roots")
            } else if newFolder {
                try UIVerification.require(cancel.model.canCreate && cancel.model.memberName == "New Folder"
                    && cancel.model.additionFolder == "Project", "New Folder defaults to the current ZIP folder and no filesystem source")
            } else if removing {
                try UIVerification.require(cancel.model.canCreate
                    && Set(cancel.model.removedPaths) == (removingFolders ? ["Project", "Top.txt"] : ["Project/Note.txt", "Project/Other.txt"])
                    && Set(cancel.model.removedFolderPaths) == (removingFolders ? ["Project"] : [])
                    && cancel.model.coveredRemovedSelections == 0, "Removal review contains exactly the chosen roots and kinds")
            } else {
                try UIVerification.require(!cancel.model.canCreate
                    && cancel.model.memberPath == (renamingFolder ? "Project" : "Project/Note.txt"), "Initial rename needs a changed name")
            }
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try UIVerification.require(try await engine.inspectExistingHistory().records.isEmpty, "Cancel admits no copy/history")
            checks.append("Ordinary archive Open, exact current selection, invalid-selection refusal and Cancel without history")
            stage = "review"
            let archiveBoard = clipboardTransfer && !interactiveMove ? NSPasteboard.withUniqueName() : nil
            defer { archiveBoard?.releaseGlobally() }
            let review: ArchiveCreationWindowController
            if adding {
                guard let rows = model.rowsForVerification else { throw FileOperationFailure.invalidRequest }
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let dropped = [area.appendingPathComponent("source/Added Parent A/Added.txt"),
                               area.appendingPathComponent("source/Added Parent B/Bundle", isDirectory: true)]
                try UIVerification.require(board.writeObjects(dropped.map { $0 as NSURL }), "Generated native URL offer")
                if updating {
                    let previousBoard = browser.transferPasteboard
                    browser.transferPasteboard = board
                    defer { browser.transferPasteboard = previousBoard }
                    controller.window?.makeKeyAndOrderFront(nil)
                    controller.window?.makeFirstResponder(table)
                    let paste = NSMenuItem(title: "Paste", action: #selector(BrowserViewController.pasteFileURLs(_:)), keyEquivalent: "")
                    paste.target = browser
                    browser.pendingCut = try await engine.observeSelection(dropped)
                    browser.pendingCutChangeCount = board.changeCount
                    try UIVerification.require(!browser.validateMenuItem(paste), "Archive Paste refuses a pending Cut")
                    browser.clearCutSelection()
                    try UIVerification.require(browser.validateMenuItem(paste)
                        && NSApp.sendAction(paste.action!, to: browser, from: paste), "Ordinary Paste captures copied local items")
                    board.clearContents()
                    try await wait { !model.isPreparingSelection }
                    try UIVerification.require(ApplicationArchiveCreation.shared.controller == nil,
                        "Clipboard change before adoption opens no Add review")
                    try UIVerification.require(board.writeObjects(dropped.map { $0 as NSURL })
                        && browser.validateMenuItem(paste) && NSApp.sendAction(paste.action!, to: browser, from: paste),
                        "Native Paste enters the existing Add review")
                    try await wait { ApplicationArchiveCreation.shared.controller?.model.canCreate == true }
                    guard let shown = ApplicationArchiveCreation.shared.controller else { throw FileOperationFailure.invalidRequest }
                    review = shown
                    checks.append("Ordinary Paste from a private native board refuses Cut and a changed clipboard, then adopts the complete copied local file/folder group in the existing Add review")
                } else {
                    let info = FixtureDraggingInfo(board: board, source: nil, sequence: 14337, allowed: .copy)
                    let moveOnly = FixtureDraggingInfo(board: board, source: nil, sequence: 14338, allowed: .move)
                    try UIVerification.require(rows.tableView(table, validateDrop: moveOnly, proposedRow: -1, proposedDropOperation: .on).isEmpty,
                        "Archive Add refuses a move-only offer")
                    try UIVerification.require(rows.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .copy
                        && rows.tableView(table, acceptDrop: info, row: -1, dropOperation: .on), "Native local-file drop opens the same Add review")
                    try UIVerification.require(!rows.tableView(table, acceptDrop: info, row: -1, dropOperation: .on), "Duplicate native callback cannot create another review")
                    try await wait { ApplicationArchiveCreation.shared.controller?.model.canCreate == true }
                    guard let shown = ApplicationArchiveCreation.shared.controller else { throw FileOperationFailure.invalidRequest }
                    review = shown
                    checks.append("Existing native local-file drop parser, copy-only group acceptance and duplicate-callback refusal")
                }
                try UIVerification.require(review.model.addedSources == dropped, "The review keeps the whole exact native source group")
            } else if let archiveBoard {
                stage = copying ? "zip-copy-paste" : "zip-cut-paste"
                browser.transferPasteboard = archiveBoard
                controller.window?.makeKeyAndOrderFront(nil)
                let capture = copying
                    ? NSMenuItem(title: "Copy", action: #selector(FileTableView.copy(_:)), keyEquivalent: "c")
                    : NSMenuItem(title: "Cut", action: #selector(FileTableView.cut(_:)), keyEquivalent: "x")
                let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "v")
                func captureRoots() async throws {
                    table.selectRowIndexes(chosenRows, byExtendingSelection: false)
                    try UIVerification.require(controller.window?.makeFirstResponder(table) == true
                        && table.validateMenuItem(capture) && NSApp.sendAction(capture.action!, to: table, from: capture), "Copy/Cut routes through the file table")
                    try await wait { browser.clipboardState.scopedItem?.isAlive == true && !model.isPreparingSelection }
                    try UIVerification.require(archiveBoard.types == [ScopedItemClipboardIntent.pasteboardType]
                        && browser.clipboardState.scopedItem?.operation == (copying ? .copy : .move)
                        && table.validateMenuItem(paste) == copying, "ZIP marker is opaque; only Copy admits a same-folder Paste")
                }
                func openFolder(_ name: String) async throws {
                    guard let row = model.visibleItems.firstIndex(where: { $0.name == name }) else { throw FileOperationFailure.invalidRequest }
                    table.selectRowIndexes([row], byExtendingSelection: false); browser.openSelection(nil)
                    try await wait { archive.hasRenderedCurrentRowsForVerification && model.page?.breadcrumbs.last?.name == name }
                    try UIVerification.require(controller.window?.makeFirstResponder(table) == true, "ZIP destination table gains focus")
                }
                func pasteItems() throws {
                    try UIVerification.require(table.validateMenuItem(paste)
                        && NSApp.sendAction(paste.action!, to: table, from: paste), "Native Paste enters the ordinary ZIP review")
                }
                try await captureRoots()
                try await openFolder("Move Folder")
                try UIVerification.require(!table.validateMenuItem(paste), "A selected folder cannot be pasted into itself")
                browser.goUp(nil); try await wait { archive.hasRenderedCurrentRowsForVerification && model.visibleItems.contains { $0.name == "Top.txt" } }
                try await openFolder("Project")
                try pasteItems(); archiveBoard.clearContents()
                try await wait { !model.isPreparingSelection }
                try UIVerification.require(ApplicationArchiveCreation.shared.controller == nil, "A newer clipboard generation refuses the old Paste")
                browser.goUp(nil); try await wait { archive.hasRenderedCurrentRowsForVerification && model.visibleItems.contains { $0.name == "Top.txt" } }
                try await captureRoots(); try await openFolder("Project"); try pasteItems()
                try await wait { ApplicationArchiveCreation.shared.controller?.model.canCreate == true }
                let intent = browser.clipboardState.scopedItem?.id
                await ApplicationArchiveCreation.shared.closeAndDrain()
                controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(table)
                let cancelledHistory = try await engine.inspectExistingHistory()
                try UIVerification.require(intent != nil && browser.clipboardState.scopedItem?.id == intent
                    && cancelledHistory.records.isEmpty, "Cancel keeps the clipboard without a history record")
                try pasteItems()
                try await wait { ApplicationArchiveCreation.shared.controller?.model.canCreate == true }
                guard let shown = ApplicationArchiveCreation.shared.controller else { throw FileOperationFailure.invalidRequest }
                review = shown
                if copying { try UIVerification.require(review.model.copyDestination == "Project", "Copy review names its actual destination") }
                checks.append("Native ZIP \(copying ? "Copy" : "Cut") → navigate → Paste rejects own-folder and changed-board attempts, and Cancel keeps the clipboard")
            } else { review = try await openReview(usingPointer: interactiveMove) }
            let copy = review.model
            guard let window = review.window else { throw FileOperationFailure.invalidRequest }
            if !duplicating && !moving { window.setContentSize(.init(width: large ? 1100 : 760, height: large ? 740 : adding ? 720 : 620)) }
            window.title = copying ? "ZIP Copy · generated review" : moving ? "ZIP Move · generated review" : duplicating ? "ZIP Duplicate · generated review" : newFolder ? "ZIP new folder · generated review" : adding ? "ZIP Add · generated review" : removing ? "ZIP removal · generated review" : "ZIP rename · generated review"
            if offscreen { window.setFrameOrigin(.init(x: -12000, y: -12000)) }
            else {
                window.center(); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await wait { NSApp.isActive && window.isKeyWindow }
            }
            // Update Original has a fixed destination. Only Rename needs a
            // name field; Add and Remove retain their existing reviewed roots.
            if !updating || (!removing && !adding && !duplicating && !moving) {
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                guard let content = window.contentView,
                      let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: {
                          $0.placeholderString == (newFolder || renamingFolder ? "New folder name" : removing || adding ? "Archive name" : "New item name")
                      }) else { throw FileOperationFailure.invalidRequest }
                func typeName(_ value: String) throws {
                    try UIVerification.require(window.makeFirstResponder(field), "Native member-name field focus")
                    guard let editor = field.currentEditor() as? NSTextView else { throw FileOperationFailure.invalidRequest }
                    editor.selectAll(nil); editor.insertText(value, replacementRange: .init(location: 0, length: editor.string.utf16.count))
                }
                let conflictingName = newFolder ? "Other.txt" : removing || adding ? "Original.zip" : renamingFolder ? "Top.txt" : "Other.txt"
                try typeName(conflictingName)
                try await wait { (!newFolder && (removing || adding) ? copy.name == conflictingName : copy.memberName == conflictingName)
                    && !copy.isPreparing && !copy.previewIsPendingForVerification }
                try UIVerification.require(!copy.canCreate && copy.plan == nil, "Occupied member name refuses the change")
                let editedName = newFolder ? "Fresh Folder" : adding ? "Added.zip" : removing ? "Removed.zip" : renamingFolder ? "Renamed Project" : "Renamed.txt"
                if offscreen { try typeName(editedName) }
                else {
                    let report = try await NativeMotionRecorder.record(window: window, root: area, label: "zip-copy-review", sampling: .diagnostic(for: window)) {
                        try typeName(editedName)
                    }
                    try JSONEncoder().encode(report).write(to: area.appendingPathComponent("evidence/zip-copy-review.json"), options: .withoutOverwriting)
                    clips.append(DevelopmentMotionVerification.clip("zip-copy-review", report: report, field: field, window: window))
                }
            }
            try await wait { copy.canCreate }
            guard let plan = copy.plan else { throw FileOperationFailure.invalidRequest }
            try UIVerification.require(plan.destination.deletingLastPathComponent() == original.deletingLastPathComponent()
                && (updating ? plan.destination == original : plan.destination != original)
                && plan.files == expectedFiles && plan.folders == expectedFolders
                && plan.logicalBytes == UInt64(expectedBytes), "Only the reviewed retained members enter the sibling copy")
            if collidingAdd {
                try UIVerification.require(copy.addedNames == ["Added.txt → Added (2).txt", "Bundle → Bundle (1)"]
                    && copy.addedFolderNames == ["Bundle → Bundle (1)"], "Review names both safe collision outcomes")
                copy.additionCollisions = .replaceFiles
                try await wait { !copy.isPreparing && !copy.previewIsPendingForVerification }
                try UIVerification.require(!copy.canCreate && copy.notice.contains("conflicts"),
                    "Replace Files must not merge the occupied folder")
                copy.additionCollisions = .keepBoth
                try await wait { copy.canCreate }
                checks.append("Existing file, numbered name and implied folder stay intact; Add shows the exact new names before Update")
            }
            if !offscreen { try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/rename-copy-review.png")) }
            if !updating { await archive.closeAndDrain() }
            stage = updating ? "update-original" : "save-copy"
            // SwiftUI does not expose this action as an NSTable/NSButton
            // title. Reuse the creator's existing ordinary semantic command.
            copy.create()
            try await wait { copy.outcome != nil && !copy.isRunning && browser.operationTask == nil }
            try UIVerification.require(copy.outcome?.result.disposition == .succeeded && copy.canUndo, "Native Save Copy succeeds with exact Undo")
            if archiveBoard != nil { try UIVerification.require(browser.clipboardState.scopedItem == nil, "Confirmed Update retires only its catalog's clipboard") }
            if tracked {
                try UIVerification.require(await Task.detached {
                    var value = stat()
                    return lstat(original.path, &value) == 0 && value.st_flags == UInt32(UF_TRACKED)
                }.value, "The updated original preserves exactly its tracking flag")
            }
            let checked = try await ZIPArchiveReader().checkContents(plan.destination)
            try UIVerification.require(checked.files == expectedFiles && checked.folders == expectedFolders, "Copied archive content verifies")
            if let expectedMark {
                try UIVerification.require(try await Task.detached {
                    try generatedQuarantine(plan.destination) == expectedMark && generatedQuarantine(original) == expectedMark
                }.value, "The published copy and original retain the exact generated quarantine")
            }
            try await Task.detached { try FileManager().copyItem(at: plan.destination, to: area.appendingPathComponent("evidence/Edited.zip")) }.value
            if updating {
                try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy }
                let records = try await engine.inspectExistingHistory().records
                try UIVerification.require(records.count == 1 && records[0].operation == "Update ZIP"
                    && records[0].canUndo, "One original update has one public history record and Undo")
                let names = Set(model.visibleItems.map(\.name))
                let expectedNames: Set<String> = collidingAdd
                    ? ["Added.txt", "Added (1).txt", "Added (2).txt", "Bundle", "Bundle (1)", "Empty", "Note.txt", "Other.txt"]
                    : adding ? ["Added.txt", "Bundle", "Empty", "Note.txt", "Other.txt"]
                    : newFolder ? ["Empty", "Fresh Folder", "Note.txt", "Other.txt"]
                    : copying ? ["Empty", "Move Folder", "Note.txt", "Other.txt", "Top.txt", "Top (1).txt", "Top (2).txt"]
                    : duplicating ? ["Project", "Project (1)", "Top.txt", "Top (1).txt"]
                    : moving ? (archiveBoard == nil ? ["Project"] : ["Empty", "Move Folder", "Note.txt", "Other.txt", "Top.txt"])
                    : removingFolders ? [] : removing ? ["Empty"] : renamingFolder ? ["Renamed Project", "Top.txt"]
                    : ["Empty", "Renamed.txt", "Other.txt"]
                try UIVerification.require(names == expectedNames, "The still-open archive refreshes its exact current folder after Update")
                let siblings = try await Task.detached { try FileManager().contentsOfDirectory(atPath: input.path) }.value
                try UIVerification.require(siblings.filter { !$0.hasPrefix(".") } == ["Original.zip"], "Update does not create a visible sibling ZIP")
            }
            copy.viewResults()
            try await wait { browser.recoveryWindow?.selectedRecordID == copy.outcome?.recordID }
            browser.recoveryWindow?.close(); window.makeKeyAndOrderFront(nil)
            checks.append(copying ? "Native Copy/Paste retains original roots and occupied names, copies the complete selection, and shows one Results record"
                : moving ? "Native \(archiveBoard == nil ? "table drop" : "Cut/Paste") moves the complete file and folder group into the ZIP folder and shows one Results record"
                : duplicating
                ? "Native Duplicate places a file and complete folder beside their originals, refreshes the open ZIP and shows one Results record"
                : "Native field editing rejects a conflict, retains the exact copy intent, then saves after archive close with exact Results")
            stage = "undo"
            var finalUndo: RecoverableOperationResult?
            if updating && renamingFolder {
                let record = try await engine.inspectExistingHistory().records[0]
                browser.startRecoveryOperation(record, rollback: false, presentsResult: false) { finalUndo = $0 }
                try await wait { finalUndo != nil && browser.operationTask == nil }
            } else {
                copy.undo(); try await wait { copy.undoOutcome != nil && !copy.isRunning && browser.operationTask == nil }
                finalUndo = copy.undoOutcome
            }
            try UIVerification.require(finalUndo?.result.disposition == .succeeded
                && (updating ? FileManager().fileExists(atPath: original.path) : !FileManager().fileExists(atPath: plan.destination.path)),
                "One guarded Undo restores the earlier original or removes only the created sibling")
            if updating {
                try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy }
                checks.append("One Update ZIP record restores the original through guarded Undo and refreshes the open tab")
            }
            try UIVerification.require(try await Task.detached { SHA256.hash(data: try Data(contentsOf: original)) == digest }.value, "Original ZIP stays byte-exact")
            if let expectedMark {
                try UIVerification.require(try await Task.detached { try generatedQuarantine(original) == expectedMark }.value,
                    "Original quarantine remains unchanged after Undo")
            }
            if tracked {
                try UIVerification.require(await Task.detached {
                    var value = stat()
                    return lstat(original.path, &value) == 0 && value.st_flags == UInt32(UF_TRACKED)
                }.value, "Undo restores the tracked original without clearing native flags")
            }
            if newFolder && updating {
                stage = "group-selection"
                await ApplicationArchiveCreation.shared.closeAndDrain()
                table.selectRowIndexes(IndexSet(model.visibleItems.indices.filter {
                    ["Note.txt", "Other.txt"].contains(model.visibleItems[$0].name)
                }), byExtendingSelection: false)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.window?.makeFirstResponder(table)
                let group = NSMenuItem(title: "New Folder with Selection", action: #selector(BrowserViewController.newFolderWithSelection(_:)), keyEquivalent: "")
                group.target = browser
                try UIVerification.require(model.selection.count == 2 && browser.validateMenuItem(group)
                    && NSApp.sendAction(group.action!, to: browser, from: group), "Ordinary grouping command targets this ZIP, not the earlier local directory")
                try await wait { ApplicationArchiveCreation.shared.controller?.model.groupedSelection != nil }
                guard let grouped = ApplicationArchiveCreation.shared.controller else { throw FileOperationFailure.invalidRequest }
                grouped.model.memberName = "Empty"
                try await wait { !grouped.model.isPreparing && !grouped.model.previewIsPendingForVerification }
                try UIVerification.require(!grouped.model.canCreate, "Grouping refuses the existing empty folder")
                grouped.model.memberName = "Grouped Items"
                try await wait { grouped.model.canCreate }
                if !offscreen, let window = grouped.window {
                    try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/group-selection-review.png"))
                }
                grouped.model.create()
                try await wait { grouped.model.outcome != nil && !grouped.model.isRunning
                    && browser.operationTask == nil && archive.hasRenderedCurrentRowsForVerification && !archive.busy }
                try UIVerification.require(grouped.model.outcome?.result.disposition == .succeeded
                    && Set(model.visibleItems.map(\.name)) == ["Empty", "Grouped Items"]
                    && model.visibleItems.contains { model.selection.contains($0.id) && $0.name == "Grouped Items" },
                    "One ZIP update groups both files, visibly refreshes and selects the new folder")
                try await Task.detached { try FileManager().copyItem(at: original,
                    to: area.appendingPathComponent("evidence/Grouped Edited.zip")) }.value
                grouped.model.undo()
                try await wait { grouped.model.undoOutcome != nil && !grouped.model.isRunning && browser.operationTask == nil }
                let groupedUndoExact = try await Task.detached {
                    SHA256.hash(data: try Data(contentsOf: original)) == digest
                }.value
                try UIVerification.require(grouped.model.undoOutcome?.result.disposition == .succeeded
                    && groupedUndoExact,
                    "Grouping Undo restores the exact original ZIP")
                await ApplicationArchiveCreation.shared.closeAndDrain()
                checks.append("New Folder with Selection uses the ordinary ZIP command/review, refuses a merge, selects its new folder and Undoes exactly")
            }
            if collidingAdd {
                stage = "replace-existing-file"
                await ApplicationArchiveCreation.shared.closeAndDrain()
                let replacement = try await openReview()
                replacement.model.chooseSourcesForVerification = { _ in
                    [area.appendingPathComponent("source/Added Parent A/Added.txt")]
                }
                replacement.model.chooseAdditions()
                try await wait { replacement.model.canCreate }
                try UIVerification.require(replacement.model.additionCollisions == .keepBoth
                    && replacement.model.replacedFileCount == 0, "Replacement is never the Add default")
                replacement.model.additionCollisions = .replaceFiles
                try await wait { replacement.model.canCreate && replacement.model.replacedFileCount == 1 }
                try UIVerification.require(replacement.model.addedNames == ["Added.txt · Replace existing file"]
                    && replacement.model.plan?.files == 6 && replacement.model.plan?.folders == 2,
                    "Replace review must identify exactly one existing file and the net counts")
                if !offscreen, let native = replacement.window {
                    native.title = "ZIP Replace · generated review"; native.makeKeyAndOrderFront(nil)
                    try await GlassVerification.captureOwnedWindow(native, to: area.appendingPathComponent("evidence/replace-file-review.png"))
                }
                replacement.model.create()
                try await wait { !replacement.model.isRunning && replacement.model.outcome != nil && browser.operationTask == nil }
                try UIVerification.require(replacement.model.outcome?.result.disposition == .succeeded
                    && replacement.model.canUndo, "Explicit ZIP replacement did not complete")
                try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy }
                try await Task.detached {
                    try Data(contentsOf: original).write(to: area.appendingPathComponent("evidence/Replacement Edited.zip"), options: .withoutOverwriting)
                }.value
                replacement.model.undo()
                try await wait { !replacement.model.isRunning && replacement.model.undoOutcome != nil && browser.operationTask == nil }
                let restored = try await Task.detached { SHA256.hash(data: try Data(contentsOf: original)) == digest }.value
                try UIVerification.require(replacement.model.undoOutcome?.result.disposition == .succeeded
                    && restored,
                    "Replacement Undo must restore exact original ZIP bytes")
                checks.append("Explicit Replace Files refuses folder merging, identifies the exact file, replaces once through Update, refreshes and Undoes the exact original")
            }
            if copying, let archiveBoard {
                stage = "zip-paste-to-local-pane"
                await ApplicationArchiveCreation.shared.closeAndDrain()
                try await verifyPasteOutsideZIP(controller, origin: browser, archive: archive, table: table,
                    model: model, engine: engine, board: archiveBoard, area: area, offscreen: offscreen)
                checks.append("Native cross-pane Paste keeps the ZIP and clipboard, rejects changed-board/occupied names, persists Always review, and completes both reviewed and automatic file/folder Paste with visible refresh and ordinary Undo")
                try UIVerification.require(try await Task.detached { SHA256.hash(data: try Data(contentsOf: original)) == digest }.value,
                    "Cross-pane Paste leaves the original ZIP byte-exact")
                stage = "read-only-archive-paste"
                let readOnlySource = area.appendingPathComponent("source/Read Only.jar")
                let readOnlyArea = area.appendingPathComponent("read-only-copy", isDirectory: true)
                try await Task.detached {
                    try FileManager().copyItem(at: original, to: readOnlySource)
                    try FileManager().createDirectory(at: readOnlyArea.appendingPathComponent("source"), withIntermediateDirectories: true)
                    try FileManager().createDirectory(at: readOnlyArea.appendingPathComponent("evidence"), withIntermediateDirectories: false)
                }.value
                controller.workspace.activate(browser)
                browser.navigate(to: .archive(try ArchiveLocation(source: readOnlySource, format: .zip, folderPath: ["Move Folder"])))
                try await wait { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true && browser.currentArchive?.busy == false }
                guard let readOnlyArchive = browser.currentArchive, let readOnlyModel = readOnlyArchive.zipModelForVerification,
                      let readOnlyTable = readOnlyArchive.table else { throw FileOperationFailure.invalidRequest }
                try await verifyPasteOutsideZIP(controller, origin: browser, archive: readOnlyArchive, table: readOnlyTable,
                    model: readOnlyModel, engine: engine, board: archiveBoard, area: readOnlyArea, offscreen: offscreen,
                    writerAvailable: false)
                try UIVerification.require(try await Task.detached {
                    SHA256.hash(data: try Data(contentsOf: readOnlySource)) == digest
                }.value, "Read-only archive Copy preserves its exact original bytes")
                checks.append("Read-only JAR Copy uses live catalog IDs without a ZIP rewrite token, refuses Cut, and passes file/folder Paste, changed-board/conflict refusal and Undo")
            }
            if updating && !adding && !removing && !renamingFolder && !newFolder && !clipboardTransfer {
                stage = "referenced-original"
                await ApplicationArchiveCreation.shared.closeAndDrain()
                try await wait { browser.operationCoordinator.inspectionCount == 0 }
                let id = try await browser.privateNames.save(AuthoredNames(nickname: "Generated original ZIP"),
                    source: original, id: nil, revision: nil, access: nil, allowFollowing: true)
                try UIVerification.require(try await browser.privateNames.hasCurrentBoundReference(at: original, retaining: nil),
                    "The current original has the explicit generated reference")
                archive.refresh()
                try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy }
                if duplicating {
                    table.selectRowIndexes(IndexSet(model.visibleItems.indices), byExtendingSelection: false)
                } else {
                    guard let index = model.visibleItems.firstIndex(where: { $0.name == "Note.txt" }) else {
                        throw FileOperationFailure.invalidRequest
                    }
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
                let refused = try await openReview()
                if !duplicating { refused.model.memberName = "Renamed.txt" }
                try await wait { !refused.model.isPreparing && !refused.model.previewIsPendingForVerification }
                try UIVerification.require(refused.model.plan == nil && refused.model.notice.contains("saved names"),
                    "A referenced original refuses Update before preparation: mode=\(refused.model.updatesOriginal), plan=\(refused.model.plan != nil), notice=\(refused.model.notice)")
                refused.model.saveCopyInstead()
                try await wait { refused.model.canCreate }
                try UIVerification.require(!refused.model.updatesOriginal && refused.model.plan?.destination != original,
                    "The same review offers a sibling-copy fallback")
                await ApplicationArchiveCreation.shared.closeAndDrain()
                try UIVerification.require(try await browser.privateNames.forget(id) == .forgotten,
                    "Remove only the generated reference")
                checks.append("Referenced original refuses Update and keeps the existing Save ZIP Copy fallback; tracking is never cleared")
            }
            await browser.privateNames.close()
            await ApplicationArchiveCreation.shared.closeAndDrain(); await ArchiveTabCatalogPool.shared.closeAndDrain()
            try await wait { ApplicationFileActivity.gate.activeCount == 0 && browser.operationCoordinator.inspectionCount == 0 }
            checks.append("Undo preserves original ZIP bytes; all archive, operation and inspection owners drain")
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "clips": clips,
                "interfacePercent": settings.interfaceSize.percent, "originalUnchanged": !updating, "originalRestoredAfterUndo": updating, "sourceFolder": "source/Input",
                "sourceProducer": "python-zipfile", "sourceCompression": ["stored", "deflated"],
                "updatedOriginal": updating, "trackingFlagPreserved": tracked, "copyIntent": copying ? "clipboard-copy" : moving ? "move" : duplicating ? "duplicate" : newFolder ? "new-folder" : adding ? "add" : removingFolders ? "remove-folder" : removing ? "remove" : renamingFolder ? "rename-folder" : "rename",
                "quarantineInherited": expectedMark != nil,
                "visualInspection": !offscreen, "offscreenFunctionalFlow": offscreen,
                "activityAfter": 0, "networkCalls": 0, "systemTrashCalls": 0, "physicalPointer": interactiveMove,
                "saveButtonGesture": "NOT EXERCISED", "osGrantAcceptance": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: area.appendingPathComponent("evidence/native-zip-rename-copy.json"), options: .withoutOverwriting)
        } catch {
            if let root { try? JSONSerialization.data(withJSONObject: ["passed": false, "failure": stage,
                "errorType": String(reflecting: type(of: error)), "motionFailure": (error as? NativeMotionRecorder.Failure)?.rawValue ?? "none",
                "message": (error as? UIVerification.Failure)?.message ?? (error is NativeMotionRecorder.Failure
                    ? "The generated window could not be recorded; this is not a filesystem result." : ArchiveCreationModel.message(error)), "checks": checks, "clips": clips], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/native-zip-rename-copy.json"), options: .withoutOverwriting) }
        }
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        await ApplicationArchiveCreation.shared.closeAndDrain(); await ArchiveTabCatalogPool.shared.closeAndDrain()
        owner?.suspendBrowsing(); await owner?.flushSession(); owner?.window?.close(); NSApp.terminate(nil)
    }

    private static func verifyPasteOutsideZIP(_ owner: BrowserWindowController, origin: BrowserViewController,
        archive: ArchiveTabController, table: FileTableView, model: ArchiveBrowserModel,
        engine: RecoverableFileOperations, board: NSPasteboard, area: URL, offscreen: Bool,
        writerAvailable: Bool = true) async throws {
        let priorReviewPreference = origin.settings.alwaysReviewArchiveCopies
        defer { origin.settings.alwaysReviewArchiveCopies = priorReviewPreference }
        origin.settings.alwaysReviewArchiveCopies = false
        let workspace = owner.workspace
        let directory = area.appendingPathComponent("source/Paste Destination", isDirectory: true)
        let occupied = directory.appendingPathComponent("Top.txt"), output = directory.appendingPathComponent("Direct.txt")
        let folderOutput = directory.appendingPathComponent("Move Folder", isDirectory: true)
        try await Task.detached {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("occupied locally\n".utf8).write(to: occupied, options: .withoutOverwriting)
        }.value
        origin.goUp(nil)
        try await wait { archive.hasRenderedCurrentRowsForVerification && !archive.busy && model.visibleItems.contains { $0.name == "Top.txt" } }
        workspace.activate(origin)
        if let window = owner.window, window.frame.width < 1140 {
            window.setContentSize(.init(width: 1140, height: window.contentLayoutRect.height))
        }
        try UIVerification.require(workspace.splitActive(at: .trailing), "Actual split-pane destination")
        let peer = workspace.activeBrowser
        peer.permitsBackgroundVerification = true; peer.recoverableFileOperations = engine
        peer.navigate(to: .directory(directory))
        try await wait { !peer.isLoading && peer.orderingTask == nil && peer.rowsByURL[occupied] != nil }
        try UIVerification.require(peer.transferPasteboard === board, "Both panes share only the generated clipboard")
        let copy = NSMenuItem(title: "Copy", action: #selector(FileTableView.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(FileTableView.paste(_:)), keyEquivalent: "v")
        func capture(_ name: String) async throws {
            guard let row = model.visibleItems.firstIndex(where: { $0.name == name }) else { throw FileOperationFailure.invalidRequest }
            owner.window?.makeKeyAndOrderFront(nil); workspace.activate(origin)
            table.selectRowIndexes([row], byExtendingSelection: false)
            try UIVerification.require(owner.window?.makeFirstResponder(table) == true && table.validateMenuItem(copy)
                && NSApp.sendAction(copy.action!, to: table, from: copy), "ZIP table Copy: \(name)")
            try await wait { origin.clipboardState.scopedItem?.isAlive == true && !model.isPreparingSelection }
            if !writerAvailable {
                guard case .zip(let captured) = origin.clipboardState.scopedItem?.source else { throw FileOperationFailure.invalidRequest }
                try UIVerification.require(captured.memberSelection == nil && !model.canCaptureClipboardMembers(.move),
                    "Read-only Copy retains no writer selection and cannot become Cut")
                guard let rows = model.rowsForVerification,
                      let cutItem = table.menu?.items.first(where: { $0.title == "Cut" }),
                      let menu = table.contextMenuProvider?(),
                      let copyItem = menu.items.first(where: { $0.title == "Copy" }) else { throw FileOperationFailure.invalidRequest }
                menu.update()
                try UIVerification.require(!rows.validateMenuItem(cutItem)
                    && menu.items.first(where: { $0.title == "Cut" })?.isEnabled != true && copyItem.isEnabled,
                    "The actual read-only archive context menu omits unavailable Cut and enables Copy")
            }
            workspace.activate(peer)
            try UIVerification.require(owner.window?.makeFirstResponder(peer.table) == true, "Local destination table gains focus")
        }
        func request() throws {
            try UIVerification.require(peer.table.validateMenuItem(paste)
                && NSApp.sendAction(paste.action!, to: peer.table, from: paste), "Ordinary local table Paste")
        }
        func review() async throws -> ArchiveExtractionWindowController {
            try await wait { ApplicationArchiveExtraction.shared.controller != nil && !model.isPreparingSelection }
            guard let panel = ApplicationArchiveExtraction.shared.controller else { throw FileOperationFailure.invalidRequest }
            try await wait { !panel.model.isPreparing && panel.model.notice != "Checking the archive and destination…" }
            try UIVerification.require(panel.model.presentation == .paste && panel.model.parent.path == directory.path,
                "The native review names the exact local destination")
            return panel
        }
        func extractAndUndo(_ panel: ArchiveExtractionWindowController, output: URL, folder: Bool) async throws {
            panel.model.extract()
            try await wait { panel.model.outcome != nil && !panel.model.isRunning && peer.operationTask == nil }
            try UIVerification.require(panel.model.outcome?.result.disposition == .succeeded && panel.model.canUndo,
                "The confirmed Paste is complete and has an inverse: \(panel.model.notice)")
            try await wait { !peer.isLoading && peer.orderingTask == nil && peer.rowsByURL[output] != nil }
            if folder {
                try UIVerification.require(try Data(contentsOf: output.appendingPathComponent("Member.txt")) == Data("move\n".utf8)
                    && FileManager().contentsOfDirectory(atPath: output.appendingPathComponent("Empty").path).isEmpty,
                    "The original folder name, nested file bytes and empty folder were copied directly")
            } else {
                try UIVerification.require(try Data(contentsOf: output) == Data("top\n".utf8), "Direct file bytes are exact")
            }
            panel.model.undo()
            try await wait { panel.model.undoOutcome != nil && !panel.model.isRunning && !peer.isLoading && peer.rowsByURL[output] == nil }
            try UIVerification.require(panel.model.undoOutcome?.result.disposition == .succeeded
                && !FileManager().fileExists(atPath: output.path), "Undo removes only the newly pasted item")
            await ApplicationArchiveExtraction.shared.closeAndDrain()
        }

        try await capture("Top.txt"); try request(); board.clearContents()
        try await wait { !model.isPreparingSelection }
        try UIVerification.require(ApplicationArchiveExtraction.shared.controller == nil, "Changing the private board stops a pending Paste")
        let initialHistory = try await engine.inspectExistingHistory().records.count
        try await capture("Top.txt"); try request()
        let collision = try await review()
        try UIVerification.require(collision.model.isFileExtraction && !collision.model.canExtract && collision.model.plan == nil,
            "Paste refuses an occupied local name")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        try UIVerification.require(try await engine.inspectExistingHistory().records.count == initialHistory
            && Data(contentsOf: occupied) == Data("occupied locally\n".utf8), "Cancel retains the destination and creates no history")
        origin.settings.alwaysReviewArchiveCopies = true
        let restoredSettings = BrowserSettings(persist: false, restoredData: try origin.settings.encodedSnapshot())
        try UIVerification.require(restoredSettings.alwaysReviewArchiveCopies
            && !BrowserSettings(persist: false, restoredData: Data("{}".utf8)).alwaysReviewArchiveCopies,
            "Always review persists; older preferences receive the direct-copy default")
        owner.window?.makeKeyAndOrderFront(nil); workspace.activate(peer)
        try request(); let file = try await review()
        file.model.name = output.lastPathComponent
        try await wait { file.model.canExtract }
        if !offscreen, let window = file.window {
            try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/zip-paste-local-file.png"))
        }
        try await extractAndUndo(file, output: output, folder: false)
        try UIVerification.require(origin.clipboardState.scopedItem?.isAlive == true, "Paste outside the ZIP does not consume Copy")

        try await capture("Move Folder"); try request()
        let folder = try await review()
        try UIVerification.require(!folder.model.isFileExtraction && folder.model.name == folderOutput.lastPathComponent,
            "One copied folder uses its own name instead of a wrapper")
        try await wait { folder.model.canExtract }
        try await extractAndUndo(folder, output: folderOutput, folder: true)

        // The default path needs only the user's Paste gesture. It shares the
        // same actual browser result, visible refresh and ordinary Undo owner.
        origin.settings.alwaysReviewArchiveCopies = false
        try await Task.detached { try FileManager().removeItem(at: occupied) }.value
        peer.loadLocation()
        try await wait { !peer.isLoading && peer.orderingTask == nil && peer.rowsByURL[occupied] == nil }
        for (name, directOutput, isFolder) in [("Top.txt", occupied, false), ("Move Folder", folderOutput, true)] {
            let earlier = peer.lastRecoveryRecordID
            try await capture(name); try request()
            try await wait { ApplicationArchiveExtraction.shared.canAcceptPreparedSelection && !model.isPreparingSelection
                && peer.operationTask == nil && peer.lastRecoveryRecordID != earlier }
            try UIVerification.require(peer.lastOperationResult?.disposition == .succeeded,
                "One-root Paste starts without an extra confirmation")
            try await wait { !peer.isLoading && peer.orderingTask == nil && peer.rowsByURL[directOutput] != nil }
            try UIVerification.require(try Data(contentsOf: isFolder ? directOutput.appendingPathComponent("Member.txt") : directOutput)
                == Data((isFolder ? "move\n" : "top\n").utf8), "Direct Paste keeps the original name and exact bytes")
            owner.window?.makeKeyAndOrderFront(nil); workspace.activate(peer); peer.focusBrowserContent()
            try await wait { peer.canUndoFileOperation }
            peer.undoFileOperation(nil)
            try await wait { peer.operationTask == nil && peer.lastOperationResult?.disposition == .succeeded
                && !peer.isLoading && peer.rowsByURL[directOutput] == nil }
            try UIVerification.require(!FileManager().fileExists(atPath: directOutput.path),
                "Ordinary Undo removes only the automatic Paste output")
        }
        workspace.activate(peer)
        try UIVerification.require(workspace.closeActivePane(), "Close only the generated destination pane")
        try await wait { workspace.browsers.count == 1 && workspace.activeBrowser === origin }
    }
    private nonisolated static func generatedQuarantine(_ url: URL) throws -> Data {
        let count = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard (1...4096).contains(count) else { throw FileOperationFailure.invalidRequest }
        var value = Data(count: count)
        guard value.withUnsafeMutableBytes({ getxattr(url.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == count else { throw FileOperationFailure.invalidRequest }
        return value
    }
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b09-zip-creation")
        let nativeBase = base.deletingLastPathComponent().appendingPathComponent("traverse-development")
        let reservation = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String: Any]
        try UIVerification.require(root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && (root.deletingLastPathComponent() == base || root.deletingLastPathComponent() == nativeBase
                && reservation?["action"] as? String == "archive-creation"), "Archive creation requires its admitted generated root")
        let args = ProcessInfo.processInfo.arguments, scale = args.contains("--zip-creation-scale"), drive = args.contains("--drive-zip-creation")
        let tar = args.contains("--create-tar")
        let gzip = args.contains("--gzip-tar")
        let bzip2 = args.contains("--bzip2-tar")
        let compressed = gzip || bzip2
        try UIVerification.require(!(gzip && bzip2), "One TAR codec profile")
        try UIVerification.require(!compressed || tar && !args.contains("--marked-source-create"), "Compressed creation has its separate development route")
        let source = root.appendingPathComponent("source/Input"), sources = [source.appendingPathComponent("Folder"), source.appendingPathComponent("Root.txt")]
        let journal = root.appendingPathComponent("state/operation-recovery")
        let markedSource = args.contains("--marked-source-create")
        let coldUndo = args.contains("--archive-create-cold-undo")
        try UIVerification.require(!coldUndo || markedSource, "Cold archive Undo requires the marked generated route")
        if markedSource {
            try UIVerification.require(markedSourceCaseAdmitted(at: journal), "Marked archive creation requires its exact generated App route")
            if coldUndo { return try await runMarkedColdUndo(root: root, browser: browser, tar: tar, source: source, sources: sources, journal: journal) }
        }
        let sourceMark: ArchiveCreationMarkState?
        if markedSource { sourceMark = try await Task.detached { try markGeneratedSource(sources[1]) }.value }
        else { sourceMark = nil }
        let before = try await hashes(sources)
        browser.permitsBackgroundVerification = true
        browser.settings.autoRefreshFolders = false; browser.settings.reviewsRecoveryAtStartup = false
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        if args.contains("--large-interface") {
            browser.settings.appearance = .light; browser.settings.interfaceSize = .init(150)
            browser.settings.motion.mode = .reduced
        }
        InterfacePresentation.shared.bind(browser.settings)
        let previous = browser.recoverableFileOperations
        let engine = browser.operationCoordinator.engine(at: journal)
        browser.recoverableFileOperations = engine; defer { browser.recoverableFileOperations = previous }
        browser.navigate(to: .directory(source))
        try await wait { !browser.isLoading && browser.orderingTask == nil && sources.allSatisfy { browser.rowsByURL[$0] != nil } }
        func open() async throws -> ArchiveCreationWindowController {
            browser.reloadFileRows(preserving: Set(sources))
            try UIVerification.require(browser.canCreateZIP && browser.commandEnabled(#selector(BrowserViewController.createZIP(_:))), "Native creation selection is not eligible")
            browser.createZIP(nil)
            guard let controller = ApplicationArchiveCreation.shared.controller else { throw UIVerification.Failure(message: "ZIP creation review missing") }
            try await wait { !controller.model.isPreparing && controller.model.plan != nil }
            if tar {
                try UIVerification.require(controller.model.offersOutputFormats, "Current development TAR creation is explicit")
                controller.model.chooseOutputFormat(bzip2 ? .tarBzip2 : gzip ? .tarGzip : .tar)
                let suffix = bzip2 ? ".tar.bz2" : gzip ? ".tar.gz" : ".tar"
                try await wait { !controller.model.isPreparing && controller.model.plan?.destination.lastPathComponent.hasSuffix(suffix) == true }
                try UIVerification.require(controller.model.name.hasSuffix(suffix) && controller.model.createTitle == (bzip2 ? "Create TAR.bz2" : gzip ? "Create TAR.gz" : "Create TAR"),
                    "Format choice updates the suggested name and native primary action")
                if compressed {
                    controller.model.chooseOutputFormat(.zip)
                    try await wait { !controller.model.isPreparing && controller.model.plan?.destination.pathExtension == "zip" }
                    try UIVerification.require(!controller.model.name.contains(".tar."), "Changing gzip back to ZIP removes the complete old suffix")
                    controller.model.chooseOutputFormat(bzip2 ? .tarBzip2 : .tarGzip)
                    controller.model.tarCompression = bzip2 ? .bzip2Fast : .gzipFast
                    try await wait { !controller.model.isPreparing && controller.model.plan?.destination.lastPathComponent.hasSuffix(suffix) == true }
                }
            }
            return controller
        }
        let cancelled = try await open()
        try UIVerification.require(cancelled.model.canCreate && browser.operationCoordinator.preparationOwner == nil
            && browser.canPrepareTransferClipboard, "Idle creation preview lost admission or blocked ordinary file work")
        await ApplicationArchiveCreation.shared.closeAndDrain()
        let originalNames = try await Task.detached { try FileManager().contentsOfDirectory(atPath: source.path) }.value
        try UIVerification.require(originalNames.sorted() == ["Folder", "Root.txt"] && !FileManager().fileExists(atPath: root.appendingPathComponent("state/operation-recovery").path), "Cancelled preview created an output or operation history")
        let controller = try await open(), model = controller.model
        controller.window?.title = "Generated archive creation · " + root.lastPathComponent.prefix(8)
        guard let plan = model.plan else { throw UIVerification.Failure(message: "ZIP creation preview missing") }
        try UIVerification.require((controller.window?.contentLayoutRect.height ?? 0) >= 480, "Creation controls were compressed by the chrome fitting size")
        try UIVerification.require(plan.files == (scale ? 10 : 4) && plan.folders == 2
            && plan.logicalBytes == (scale ? 16 * 1_024 * 1_024 + 14 : 256 * 1_024 + 14), "Native creation preview lost members or totals")
        let baseline = resident(), heartbeat = Heartbeat()
        heartbeat.start(); try await Task.sleep(for: .milliseconds(25))
        let began = ProcessInfo.processInfo.systemUptime
        if drive {
            try UIVerification.require(!browser.isControlledVerification && controller.window?.isVisible == true, "Input QA needs the visible generated creation review")
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/input-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.outcome != nil && !model.isRunning }
        } else { model.create() }
        try await wait { model.outcome != nil && !model.isRunning && browser.operationTask == nil }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        try await Task.sleep(for: .milliseconds(30)); heartbeat.stop()
        let forwardPeak = peakResident()
        guard let result = model.outcome, let id = result.recordID else { throw UIVerification.Failure(message: "Created ZIP result missing") }
        try UIVerification.require(result.result.disposition == .succeeded && model.canUndo && browser.view.window?.attachedSheet == nil,
            "Native creation did not finish with quiet exact Undo")
        if tar {
            let pool: TARCompressedPreparationPool?
            let reader: TARArchiveReader
            if compressed {
                let cache = root.appendingPathComponent("state/gzip-create-verification")
                try await Task.detached { try FileManager().createDirectory(at: cache, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]) }.value
                pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init())
                reader = TARArchiveReader(compressedPool: pool)
            } else { pool = nil; reader = TARArchiveReader() }
            let checked = try await (compressed ? reader.prepareCompressed(plan.destination) : reader.open(plan.destination))
            try UIVerification.require(checked.summary.files == plan.files && checked.summary.folders == plan.folders
                && checked.summary.logicalBytes == plan.logicalBytes, "Published TAR agrees with the reviewed source totals")
            await checked.close()
            if let pool { try UIVerification.require(await pool.closeAndDrain(), "gzip creation verification spool drains") }
        } else {
            let checked = try await ZIPArchiveReader().checkContents(plan.destination)
            try UIVerification.require(checked.files == plan.files && checked.folders == plan.folders && checked.decodedBytes == plan.logicalBytes,
                "Published ZIP differs from the reviewed source totals")
        }
        try await Task.detached { try FileManager().copyItem(at: plan.destination, to: root.appendingPathComponent(bzip2 ? "evidence/Created.tar.bz2" : gzip ? "evidence/Created.tar.gz" : tar ? "evidence/Created.tar" : "evidence/Created.zip")) }.value
        if let sourceMark {
            let observedSource = try await Task.detached { try ArchiveCreationMarkState.observe(sources[1]) }.value
            let observedOutput = try await Task.detached { try ArchiveCreationMarkState.observe(plan.destination) }.value
            guard let sourceQuarantine = sourceMark.quarantineSHA256,
                  let outputQuarantine = observedOutput.quarantineSHA256 else {
                throw UIVerification.Failure(message: "Marked archive Create lost its source or output mark")
            }
            try UIVerification.require(observedSource == sourceMark && observedOutput.publiclyMarked
                && plan.destination.deletingLastPathComponent() == source,
                "Marked archive Create did not preserve its input and publish a public-marked output")
            let outputSHA256 = try await contentSHA256(plan.destination)
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try await wait { ApplicationFileActivity.gate.activeCount == 0 && browser.operationCoordinator.inspectionCount == 0 }
            try UIVerification.require(try await hashes(sources) == before, "Marked archive Create changed its generated sources")
            return ["passed": true, "markedSource": true, "format": tar ? "tar" : "zip",
                "coldUndoPending": true, "recordID": id.uuidString,
                "outputName": plan.destination.lastPathComponent, "outputSHA256": outputSHA256,
                "outputQuarantineSHA256": outputQuarantine,
                "outputProvenanceSHA256": observedOutput.provenanceSHA256 ?? "absent",
                "sourceQuarantineSHA256": sourceQuarantine,
                "sourceProvenanceSHA256": sourceMark.provenanceSHA256 ?? "absent",
                "sourceBodiesSHA256": bodiesSHA256(before), "sourceUnchanged": true,
                "ordinaryAppCreate": true, "publicOutputMarkPresent": true,
                "notExercised": ["Cold Undo pending second App launch", "Installed signed archive policy", "Personal sources", "Device removal"]]
        }
        model.viewResults()
        try await wait { browser.recoveryWindow?.selectedRecordID == id }
        browser.recoveryWindow?.close()
        if !browser.isControlledVerification { controller.window?.makeKeyAndOrderFront(nil) }
        if let window = controller.window, !browser.isControlledVerification {
            try await Task.sleep(for: .milliseconds(200)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/creation-native.png"))
        }
        if drive {
            try Data("ready".utf8).write(to: root.appendingPathComponent("evidence/undo-ready"), options: .withoutOverwriting)
            try await wait(seconds: 90) { model.undoAttemptedForVerification }
        } else {
            model.showInExplorer()
            try await wait { browser.location.directoryURL == plan.destination.deletingLastPathComponent() && !browser.isLoading && browser.orderingTask == nil && browser.orderedSelectedURLs == [plan.destination] }
            model.undo()
        }
        try await wait { !model.isRunning && model.undoOutcome != nil && browser.operationTask == nil }
        try UIVerification.require(model.undoOutcome?.result.disposition == .succeeded && !FileManager().fileExists(atPath: plan.destination.path), "Native creation Undo failed")
        if !drive { try await wait { browser.location.directoryURL == source && !browser.isLoading } }
        await ApplicationArchiveCreation.shared.closeAndDrain()
        var stopDrain: Double = 0
        if !scale && !drive {
            let stopping = try await open(); stopping.model.create()
            let start = ProcessInfo.processInfo.systemUptime
            stopping.model.stop(); await ApplicationArchiveCreation.shared.closeAndDrain()
            stopDrain = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            try UIVerification.require(stopDrain <= 2_000 && browser.operationTask == nil
                && !FileManager().fileExists(atPath: plan.destination.path), "Native admission Stop did not drain or created output")
        }
        var closeDuringRun = false
        if !scale && !drive {
            let closing = try await open(); closing.model.create()
            try UIVerification.require(closing.model.isRunning, "Close-during-creation test was not admitted")
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try UIVerification.require(closing.model.outcome?.result.disposition == .succeeded && browser.operationTask == nil,
                "Closing the workbench detached or cancelled an accepted creation")
            let closedID = try requireID(closing.model.outcome)
            let undo = await engine.undo(recordID: closedID)
            try UIVerification.require(undo.result.disposition == .succeeded, "Generated closed-window creation was not undoable")
            closeDuringRun = true
        }
        var unsupportedPreview = false, explicitReviewRefresh = false
        if !scale && !drive {
            let fallback = source.appendingPathComponent("Fallback only.txt")
            try await Task.detached {
                try Data("generated fallback source".utf8).write(to: fallback, options: .withoutOverwriting)
                let bytes = Data("generated resource-fork data".utf8)
                guard bytes.withUnsafeBytes({ setxattr(fallback.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_CREATE) }) == 0 else {
                    throw FileOperationFailure.ioFailure
                }
            }.value
            let records = try await engine.inspectExistingHistory().records.count
            browser.loadLocation()
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[fallback] != nil && browser.canStartArchiveCreation }
            browser.reloadFileRows(preserving: [fallback]); browser.createZIP(nil)
            guard let rejected = ApplicationArchiveCreation.shared.controller else { throw UIVerification.Failure(message: "Unsupported-source preview missing") }
            try await wait { !rejected.model.isPreparing && rejected.model.offersFinderFallback }
            try UIVerification.require(rejected.model.plan == nil && !rejected.model.canCreate && rejected.model.canReview,
                "Unsupported source was admitted or left the review unusable")
            await ApplicationArchiveCreation.shared.closeAndDrain()
            let after = try await engine.inspectExistingHistory().records.count
            try UIVerification.require(after == records, "Unsupported source preview created operation history")
            unsupportedPreview = true
            let fresh = source.appendingPathComponent("Fresh review.txt")
            try await Task.detached { try Data("one".utf8).write(to: fresh, options: .withoutOverwriting) }.value
            browser.loadLocation()
            try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[fresh] != nil && browser.canStartArchiveCreation }
            browser.reloadFileRows(preserving: [fresh]); browser.createZIP(nil)
            guard let recheck = ApplicationArchiveCreation.shared.controller else { throw UIVerification.Failure(message: "Fresh review missing") }
            try await wait { !recheck.model.isPreparing && recheck.model.plan?.logicalBytes == 3 }
            try await Task.detached { try Data("updated".utf8).write(to: fresh) }.value
            recheck.model.reviewAgain()
            try await wait { !recheck.model.isPreparing && recheck.model.plan?.logicalBytes == 7 && recheck.model.canCreate }
            await ApplicationArchiveCreation.shared.closeAndDrain()
            try UIVerification.require(try await engine.inspectExistingHistory().records.count == records, "Review Again mutated history")
            explicitReviewRefresh = true
        }
        let directActions = !scale && !drive && !tar
            ? try await runDirectActions(browser: browser, source: sources[1], engine: engine,
                markedSource: markedSource) : false
        try await wait { ApplicationFileActivity.gate.activeCount == 0 && browser.operationCoordinator.inspectionCount == 0 }
        try UIVerification.require(try await hashes(sources) == before, "ZIP creation or Undo changed the sources")
        let peak = peakResident(), added = peak > baseline ? peak - baseline : 0
        return ["passed": !scale || elapsed <= 10_000 && added <= 96 * 1_024 * 1_024 && heartbeat.count >= 2 && heartbeat.p95 <= 40,
            "format": bzip2 ? "tar.bz2" : gzip ? "tar.gz" : tar ? "tar" : "zip",
            "scale": scale, "files": plan.files, "folders": plan.folders, "decodedBytes": plan.logicalBytes,
            "creationMilliseconds": elapsed, "baselineRSS": baseline, "peakRSS": peak, "addedRSS": added, "forwardPeakRSS": forwardPeak,
            "heartbeatP95Milliseconds": heartbeat.p95, "heartbeatWorstMilliseconds": heartbeat.worst, "heartbeatSamples": heartbeat.count,
            "physicalInput": drive, "sourceUnchanged": true, "exactResults": true, "undoSucceeded": true,
            "cancelCreatedNothing": true, "closeDuringRun": closeDuringRun, "unsupportedPreviewWithFallback": unsupportedPreview,
            "explicitReviewRefresh": explicitReviewRefresh,
            "directCompressExtractAndUndo": directActions,
            "ordinaryActivation": ArchiveCreationActivation.enabled,
            "windowWidth": controller.window?.frame.width ?? 0, "windowHeight": controller.window?.frame.height ?? 0,
            "admissionStopDrainMilliseconds": stopDrain,
            "notExercised": ["Quarantine propagation", "Mac extended-metadata preservation", "Minimum OS", "Personal sources", "Device removal", "Cross-device source"]]
    }
    /// Reuses the ordinary commands and both workbenches. Existing destinations
    /// exercise Keep Both; the actual producers still own exclusive publication.
    private static func runDirectActions(browser: BrowserViewController, source: URL,
                                         engine: RecoverableFileOperations, markedSource: Bool) async throws -> Bool {
        try verifyQuickCompressionPreferences(browser.settings)
        let parent = source.deletingLastPathComponent()
        let occupiedZIP = parent.appendingPathComponent(source.lastPathComponent + ".zip")
        let marker = Data("Existing generated output stays unchanged.".utf8)
        try await Task.detached { try marker.write(to: occupiedZIP, options: .withoutOverwriting) }.value
        browser.loadLocation()
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[source] != nil && browser.canStartArchiveCreation }
        browser.reloadFileRows(preserving: [source])
        let menu = BrowserMenus.fileContextMenu(target: browser)
        try UIVerification.require(browser.quickCompressionCommandTitle == "Compress to ZIP"
            && menu.items.contains { $0.action == #selector(BrowserViewController.compressSelection(_:))
                && $0.title == browser.quickCompressionCommandTitle }
            && menu.items.contains { $0.action == #selector(BrowserViewController.createZIP(_:)) && $0.title.hasSuffix("…") },
            "Direct Compress and its options are not available together")
        browser.compressSelection(nil)
        guard let creation = ApplicationArchiveCreation.shared.controller else {
            throw UIVerification.Failure(message: "Direct Compress did not retain its workbench")
        }
        try await wait { creation.model.outcome != nil && !creation.model.isRunning && browser.operationTask == nil }
        try UIVerification.require(creation.model.outcome?.result.disposition == .succeeded,
            "Direct Compress did not complete: " + creation.model.notice)
        await ApplicationArchiveCreation.shared.closeAndDrain()
        let archive = parent.appendingPathComponent(source.lastPathComponent + " 2.zip")
        let createdID = try requireID(creation.model.outcome)
        let archiveHash = try await contentSHA256(archive)
        let checked = try await ZIPArchiveReader().checkContents(archive)
        try UIVerification.require(checked.files == 1 && checked.folders == 0
            && creation.model.name == archive.lastPathComponent, "Direct Compress lost its full source name or collision suffix")
        let occupiedFolder = parent.appendingPathComponent(ArchiveActionNames.extractionFolder(for: archive), isDirectory: true)
        try await Task.detached { try FileManager().createDirectory(at: occupiedFolder, withIntermediateDirectories: false) }.value
        browser.loadLocation()
        try await wait { !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[archive] != nil && browser.canStartArchiveExtraction }
        browser.reloadFileRows(preserving: [archive])
        try UIVerification.require(browser.canExtractArchiveDirect, "Direct extraction was not enabled for the created archive")
        browser.extractArchiveDirect(nil)
        guard let extraction = ApplicationArchiveExtraction.shared.controller else {
            throw UIVerification.Failure(message: "Direct extraction did not retain its workbench")
        }
        try await wait { extraction.model.outcome != nil && !extraction.model.isRunning && browser.operationTask == nil }
        try UIVerification.require(extraction.model.outcome?.result.disposition == .succeeded,
            "Direct extraction did not complete: " + extraction.model.notice)
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        let extracted = parent.appendingPathComponent(occupiedFolder.lastPathComponent + " 2", isDirectory: true)
        let bodiesMatch = try await Task.detached {
            try Data(contentsOf: extracted.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source)
        }.value
        try UIVerification.require(bodiesMatch && extraction.model.name == extracted.lastPathComponent,
            "Direct extraction lost its contents or occupied-folder suffix")
        let extractedID = try requireID(extraction.model.outcome)
        try UIVerification.require(try await contentSHA256(archive) == archiveHash,
            "Direct extraction changed the source archive")
        let extractionUndo = await engine.undo(recordID: extractedID)
        let creationUndo = await engine.undo(recordID: createdID)
        let preserved = try await Task.detached {
            try Data(contentsOf: occupiedZIP) == marker && FileManager().contentsOfDirectory(atPath: occupiedFolder.path).isEmpty
        }.value
        try UIVerification.require(extractionUndo.result.disposition == .succeeded && creationUndo.result.disposition == .succeeded
            && preserved && !FileManager().fileExists(atPath: extracted.path) && !FileManager().fileExists(atPath: archive.path),
            "Direct archive Undo changed an existing destination or failed")
        if !markedSource {
            try await verifyQuickTARFormats(browser: browser, source: source, engine: engine, marker: marker)
        }
        return true
    }

    private static func verifyQuickCompressionPreferences(_ settings: BrowserSettings) throws {
        guard var saved = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as? [String: Any] else {
            throw UIVerification.Failure(message: "Quick Compress preferences did not encode")
        }
        try UIVerification.require(saved["version"] as? Int == BrowserSettings.preferencesVersion
            && saved["quickCompressionFormat"] as? String == "zip", "Quick Compress default is not ZIP")
        saved["version"] = BrowserSettings.preferencesVersion - 1
        saved.removeValue(forKey: "quickCompressionFormat")
        let older = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: saved))
        try UIVerification.require(older.quickCompressionFormat == .zip && older.preferencesPersistenceStatus.isEmpty,
            "Older saved preferences did not retain ZIP as the quick default")
        saved["version"] = BrowserSettings.preferencesVersion
        saved["quickCompressionFormat"] = "tar.gz"
        let chosen = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: saved))
        try UIVerification.require(chosen.quickCompressionFormat == .tarGzip && chosen.preferencesPersistenceStatus.isEmpty,
            "A saved quick format was not restored")
        chosen.quickCompressionFormat = .tarBzip2
        let roundTrip = BrowserSettings(persist: false, restoredData: try chosen.encodedSnapshot())
        try UIVerification.require(roundTrip.quickCompressionFormat == .tarBzip2,
            "A changed quick format was not encoded and restored")
        saved["quickCompressionFormat"] = "unknown"
        let unknown = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: saved))
        saved["quickCompressionFormat"] = "zip"
        saved["version"] = BrowserSettings.preferencesVersion + 1
        let newer = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: saved))
        try UIVerification.require([unknown, newer].allSatisfy {
            $0.quickCompressionFormat == .zip && $0.preferencesPersistenceStatus.contains("preserved")
        }, "Unknown or newer quick preferences were silently accepted")
    }

    /// Generated, unmarked sources exercise the same one-click owner and
    /// collision/Undo path for each TAR encoder, without a second producer.
    private static func verifyQuickTARFormats(browser: BrowserViewController, source: URL,
                                               engine: RecoverableFileOperations, marker: Data) async throws {
        let settings = browser.settings
        defer { settings.quickCompressionFormat = .zip }
        let parent = source.deletingLastPathComponent()
        for format in [ArchiveCreationFormat.tar, .tarGzip, .tarBzip2] {
            try UIVerification.require(format.availableForQuickAction, "Quick TAR format was unavailable in Development")
            settings.quickCompressionFormat = format
            let occupied = parent.appendingPathComponent(source.lastPathComponent + "." + format.rawValue)
            try await Task.detached { try marker.write(to: occupied, options: .withoutOverwriting) }.value
            browser.loadLocation()
            try await wait { !browser.isLoading && browser.orderingTask == nil
                && browser.rowsByURL[source] != nil && browser.canStartArchiveCreation }
            browser.reloadFileRows(preserving: [source])
            try UIVerification.require(browser.canCompressSelection, "Quick TAR selection was not admitted")
            let menu = BrowserMenus.fileContextMenu(target: browser)
            try UIVerification.require(menu.items.contains {
                $0.action == #selector(BrowserViewController.compressSelection(_:))
                    && $0.title == "Compress to " + format.displayName
            }, "Quick Compress menu did not show the selected TAR format")
            browser.compressSelection(nil)
            guard let creation = ApplicationArchiveCreation.shared.controller else {
                throw UIVerification.Failure(message: "Quick TAR did not retain its workbench")
            }
            try await wait { creation.model.outcome != nil && !creation.model.isRunning && browser.operationTask == nil }
            try UIVerification.require(creation.model.outcome?.result.disposition == .succeeded,
                "Quick TAR did not complete: " + creation.model.notice)
            await ApplicationArchiveCreation.shared.closeAndDrain()
            let archive = parent.appendingPathComponent(source.lastPathComponent + " 2." + format.rawValue)
            let prefix = try await Task.detached { () throws -> Data in
                let handle = try FileHandle(forReadingFrom: archive)
                defer { try? handle.close() }
                var bytes = Data()
                while bytes.count < 262 {
                    let next = try handle.read(upToCount: 262 - bytes.count) ?? Data()
                    if next.isEmpty { break }
                    bytes.append(next)
                }
                return bytes
            }.value
            let matchesFormat: Bool = switch format {
            case .tar: prefix.count == 262 && Data(prefix[257..<262]) == Data("ustar".utf8)
            case .tarGzip: prefix.starts(with: Data([0x1f, 0x8b]))
            case .tarBzip2: prefix.starts(with: Data("BZh".utf8))
            case .zip: false
            }
            try UIVerification.require(creation.model.outputFormat == format
                && creation.model.name == archive.lastPathComponent && matchesFormat,
                "Quick TAR used the wrong output format or collision name")
            let id = try requireID(creation.model.outcome)
            let undone = await engine.undo(recordID: id)
            let occupiedPreserved = try await Task.detached { try Data(contentsOf: occupied) == marker }.value
            try UIVerification.require(undone.result.disposition == .succeeded && occupiedPreserved
                && !FileManager().fileExists(atPath: archive.path),
                "Quick TAR Undo changed an occupied destination or left its output")
        }
    }

    private static func runMarkedColdUndo(root: URL, browser: BrowserViewController, tar: Bool,
                                          source: URL, sources: [URL], journal: URL) async throws -> [String: Any] {
        let warmURL = root.appendingPathComponent("evidence/marked-create.json")
        guard let warm = try JSONSerialization.jsonObject(with: Data(contentsOf: warmURL)) as? [String: Any],
              warm["passed"] as? Bool == true, warm["markedSource"] as? Bool == true,
              warm["coldUndoPending"] as? Bool == true,
              warm["format"] as? String == (tar ? "tar" : "zip"),
              let recordText = warm["recordID"] as? String, let recordID = UUID(uuidString: recordText),
              let outputName = warm["outputName"] as? String, !outputName.isEmpty,
              !outputName.contains("/"), outputName != ".", outputName != "..",
              outputName.hasSuffix(tar ? ".tar" : ".zip") else {
            throw UIVerification.Failure(message: "Cold archive Undo requires its exact warm Create receipt")
        }
        let output = source.appendingPathComponent(outputName)
        let sourceMark = try await Task.detached { try ArchiveCreationMarkState.observe(sources[1]) }.value
        let outputMark = try await Task.detached { try ArchiveCreationMarkState.observe(output) }.value
        let before = try await hashes(sources)
        let outputSHA256 = try await contentSHA256(output)
        try UIVerification.require(sourceMark.publiclyMarked && outputMark.publiclyMarked
            && sourceMark.quarantineSHA256 == warm["sourceQuarantineSHA256"] as? String
            && (sourceMark.provenanceSHA256 ?? "absent") == warm["sourceProvenanceSHA256"] as? String
            && outputMark.quarantineSHA256 == warm["outputQuarantineSHA256"] as? String
            && (outputMark.provenanceSHA256 ?? "absent") == warm["outputProvenanceSHA256"] as? String
            && bodiesSHA256(before) == warm["sourceBodiesSHA256"] as? String
            && outputSHA256 == warm["outputSHA256"] as? String,
            "Cold archive Undo found changed source or output")
        browser.permitsBackgroundVerification = true
        browser.settings.reviewsRecoveryAtStartup = false
        let previous = browser.recoverableFileOperations
        let engine = browser.operationCoordinator.engine(at: journal)
        browser.recoverableFileOperations = engine; defer { browser.recoverableFileOperations = previous }
        let existing = try await engine.inspectExistingHistory()
        try UIVerification.require(existing.records.contains { $0.id == recordID && $0.state == "committed"
            && $0.canUndo && $0.operation == (tar ? "Create TAR" : "Create ZIP")
            && $0.locations.contains(output) }, "Cold App engine did not recognize the committed archive")
        let undone = await engine.undo(recordID: recordID)
        try UIVerification.require(undone.result.disposition == .succeeded
            && !FileManager().fileExists(atPath: output.path), "Cold App archive Undo failed")
        let after = try await engine.inspectExistingHistory()
        try UIVerification.require(after.records.contains { $0.id == recordID && $0.state == "undone" && !$0.canUndo },
            "Cold App archive Undo did not persist")
        let finalSource = try await Task.detached { try ArchiveCreationMarkState.observe(sources[1]) }.value
        let finalBodies = try await hashes(sources)
        try UIVerification.require(finalSource == sourceMark && finalBodies == before,
            "Cold App archive Undo changed its generated source")
        return ["passed": true, "markedSource": true, "format": tar ? "tar" : "zip",
            "coldUndoSucceeded": true, "sourceMarkUnchanged": true, "sourceBodiesUnchanged": true,
            "outputRemoved": true, "recordUndone": true, "ordinaryAppCreate": true,
            "notExercised": ["Installed signed archive policy", "Personal sources", "Device removal"]]
    }

    nonisolated private static func markGeneratedSource(_ url: URL) throws -> ArchiveCreationMarkState {
        let before = try ArchiveCreationMarkState.observe(url)
        guard before.quarantineSHA256 == nil else { throw FileOperationFailure.invalidRequest }
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Traverse Generated Archive Check",
            kLSQuarantineTimeStampKey as String: Date()
        ]
        var target = url
        try target.setResourceValues(values)
        let after = try ArchiveCreationMarkState.observe(url)
        let publicValues = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        guard after.publiclyMarked && after.quarantineSHA256 != nil,
              publicValues?[kLSQuarantineAgentNameKey as String] as? String == "Traverse Generated Archive Check",
              publicValues?[kLSQuarantineTimeStampKey as String] is Date else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        return after
    }

    private static func contentSHA256(_ url: URL) async throws -> String {
        guard let digest = try await hashes([url])[url.path] else { throw FileOperationFailure.ioFailure }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func bodiesSHA256(_ values: [String: Data]) -> String {
        var digest = SHA256()
        for (path, hash) in values.sorted(by: { $0.key < $1.key }) {
            digest.update(data: Data(path.utf8))
            digest.update(data: hash)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requireID(_ outcome: RecoverableOperationResult?) throws -> UUID {
        guard let id = outcome?.recordID else { throw UIVerification.Failure(message: "Generated close result missing") }; return id
    }
    private static func hashes(_ sources: [URL]) async throws -> [String: Data] {
        try await Task.detached {
            var pending = sources, result: [String: Data] = [:]
            while let source = pending.popLast() {
                let facts = try source.resourceValues(forKeys: [.isDirectoryKey])
                if facts.isDirectory == true {
                    pending += try FileManager().contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                } else {
                    let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }; var hash = SHA256()
                    while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty { hash.update(data: bytes) }
                    result[source.path] = Data(hash.finalize())
                }
            }
            return result
        }.value
    }
    private static func wait(seconds: Double = 30, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(8)) }
        try UIVerification.require(condition(), "Native creation did not settle")
    }
    @MainActor private final class Heartbeat {
        private var task: Task<Void, Never>?, intervals: [Double] = []
        func start() { task = Task { [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20)); guard let self, !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if intervals.count < 4_096 { intervals.append((now - previous) * 1_000) }; previous = now
            }
        } }
        func stop() { task?.cancel(); task = nil }
        var count: Int { intervals.count }
        var p95: Double { let sorted = intervals.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] }
        var worst: Double { intervals.max() ?? 0 }
    }
    private static func resident() -> UInt64 {
        var value = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? UInt64(value.resident_size) : 0
    }
    private static func peakResident() -> UInt64 { var value = rusage(); _ = getrusage(RUSAGE_SELF, &value); return UInt64(max(0, value.ru_maxrss)) }
}
#endif
