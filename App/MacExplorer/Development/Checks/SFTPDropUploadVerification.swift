#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) @testable import LocalStorage

@MainActor enum SFTPDropUploadVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ value: () -> Bool, _ line: UInt = #line, seconds: Double = 6) async throws {
        let end = ContinuousClock.now + .seconds(seconds)
        while !value() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    static func run() async {
        if ProcessInfo.processInfo.arguments.contains("--physical-drop") { await gesture(); return }
        var area: URL?, browser: BrowserViewController?, host: NSWindow?, connection: SFTPTabController?
        var checks: [String] = [], failure: UInt?, kind: String?
        var clips: [[String: Any]] = []
        var boards: [NSPasteboard] = []
        SFTPDropUploadFeature.qualifying = true
        SFTPFolderUploadFeature.qualifying = true
        SFTPRemoteActionFeature.qualifying = true
        defer { SFTPDropUploadFeature.qualifying = false; SFTPFolderUploadFeature.qualifying = false; SFTPRemoteActionFeature.qualifying = false }
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let root = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(root.resolvingSymlinksInPath() == root && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-sftp-drop-upload" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            area = root
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.startupMode = .computer
            settings.reviewsRecoveryAtStartup = false; settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserViewController(settings: settings); browser = owner; owner.permitsBackgroundVerification = true
            owner.readVolumesForVerification = { [] }
            owner.recoverableFileOperations = .init(journalDirectory: root.appendingPathComponent("state/local-history"))
            let workspace = BrowserWorkspaceController(primaryBrowser: owner)
            // Exercise the actual browser event routing and standard Edit menu;
            // a tool-window stand-in cannot reproduce sheet input failures.
            let window = BrowserWindow(contentRect: .init(origin: .zero, size: .init(width: 1120, height: 720)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.browser = owner; window.workspace = workspace; window.contentViewController = workspace
            let previousMenu = NSApp.mainMenu
            NSApp.mainMenu = BrowserMenus.applicationMenu(target: owner)
            defer { NSApp.mainMenu = previousMenu }
            host = window; ToolWindowChrome.install(in: window, settings: settings)
            window.title = "SFTP group upload · generated review"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if ProcessInfo.processInfo.arguments.contains("--offscreen") { window.setFrameOrigin(.init(x: -12000, y: -12000)) }
            workspace.begin(); try await wait { workspace.sessionReady }
            owner.navigate(to: .directory(root.appendingPathComponent("source/Local")))
            try await wait { !owner.isLoading && owner.displayedEntries.count == 3 && owner.orderingTask == nil }
            owner.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
            try require((0..<3).allSatisfy { owner.dragDrop.pasteboardWriter(for: $0) == nil })
            checks.append("A verification browser refuses every source writer before its explicit drag admission")
            owner.dragDrop.windowWillClose(); owner.dragDrop.permitsVerification = true; owner.dragDrop.selectionDidChange()
            try await wait { (0..<3).allSatisfy { owner.dragDrop.pasteboardWriter(for: $0) != nil } }
            checks.append("The same actual source rows gain prepared writers only after verification drag admission")
            let transport = Transport(), session = SFTPBrowserSession(id: UUID(), transport: transport)
            let storage = SFTPUploadStorage(directory: root.appendingPathComponent("state/upload-history"))
            let normal = SFTPTabController(session: session, address: try .init("sftp://generated.invalid"), title: "Generated server", uploads: storage, reviewsUploads: false)
            connection = normal; owner.installSFTPTab(normal)
            try await wait { normal.rows.cache.retainedCount == 2 && !normal.hasPendingPages }
            try require(owner.sftpDropUpload.canRequest(from: normal))
            checks.append("Only the active complete writable remote directory admits a group")
            let urls = ["First.txt","Folder","Last.txt"].map { root.appendingPathComponent("source/Local/" + $0) }
            func info(_ sequence: Int, urls selected: [URL]? = nil, source: Any? = nil, allowed: NSDragOperation = .copy) -> Info {
                let board = NSPasteboard(name: .init("traverse.generated.sftp-drop." + UUID().uuidString)); boards.append(board)
                _ = board.writeObjects((selected ?? urls).map { $0 as NSURL })
                let value = Info(board, source: source, sequence: sequence, allowed: allowed); value.draggingDestinationWindow = window
                let clip = normal.rows.scroll.contentView
                value.draggingLocation = clip.convert(.init(x: clip.bounds.midX, y: clip.bounds.maxY - 20), to: nil)
                return value
            }
            let plain = NSPasteboard(name: .init("traverse.generated.sftp-drop." + UUID().uuidString)); boards.append(plain)
            plain.setString("file:///generated/plain-string", forType: .string)
            try require(BrowserDragDropController.captureLocalFileDropSource(Info(plain, source: nil, sequence: 1)) == nil)
            try require(BrowserDragDropController.captureLocalFileDropSource(info(2, source: NSView())) == nil)
            try require(BrowserDragDropController.captureLocalFileDropSource(info(3, allowed: .move)) == nil)
            checks.append("Plain strings, unknown in-process sources and move-only offers cannot gain upload authority")
            let child = info(4)
            child.draggingLocation = normal.rows.table.convert(.init(x: 60, y: normal.rows.table.rect(ofRow: 0).midY), to: nil)
            try require(normal.rows.draggingUpdated(child).isEmpty && !normal.rows.performDragOperation(child))
            try require(owner.sftpDropUpload.acceptedCount == 0)
            checks.append("A child-folder row is refused without constructing a destination from its display name")
            var reviews = 0
            owner.sftpDropUpload.reviewForVerification = { _, _ in reviews += 1; return false }
            let first = info(5)
            try require(normal.rows.draggingUpdated(first) == .copy && normal.rows.prepareForDragOperation(first))
            try require(normal.rows.performDragOperation(first))
            try await wait { owner.sftpDropUpload.work == nil }
            try require(owner.sftpDropUpload.lastCompleted?.completed.count == 3 && reviews == 0)
            let calls = await transport.names
            try require(calls == ["First.txt","Folder","Last.txt"])
            try await wait { normal.rows.cache.retainedCount == 2 && !normal.hasPendingPages }
            let opens = await transport.opens
            try require(opens == 2 && owner.sftpDropUpload.acceptedCount == 1)
            checks.append("Normal native drop admits one reviewed mixed group with no extra confirmation and one final refresh")
            try require(!normal.rows.performDragOperation(first) && owner.sftpDropUpload.acceptedCount == 1)
            checks.append("A repeated native sequence/pasteboard delivery cannot repeat a transfer")
            let clipboard = try await verifyClipboard(root: root, browser: owner, owner: normal, transport: transport)
            boards.append(clipboard)
            checks.append("Native Paste uses one mixed copied group without a chooser, preserves local originals and refuses plain text")
            owner.navigate(to: .computer)
            try require(!owner.sftpDropUpload.canRequest(from: normal))
            guard case .sftp = normal.currentBrowserLocation else { throw Failure.scope }
            owner.navigate(to: normal.currentBrowserLocation)
            try await wait { normal.rows.cache.retainedCount == 2 && !normal.hasPendingPages }
            checks.append("An owned tab showing This Mac cannot receive an invisible remote upload")
            _ = await normal.close().value

            let cautiousTransport = Transport(), cautiousSession = SFTPBrowserSession(id: UUID(), transport: cautiousTransport)
            let cautious = SFTPTabController(session: cautiousSession, address: try .init("sftp://generated.invalid"), title: "Generated cautious server", uploads: storage, reviewsUploads: true)
            connection = cautious; owner.installSFTPTab(cautious)
            try await wait { cautious.rows.cache.retainedCount == 2 && !cautious.hasPendingPages }
            let cautiousInfo = info(6)
            cautiousInfo.draggingLocation = cautious.rows.scroll.contentView.convert(.init(x: 300, y: 200), to: nil)
            try require(cautious.rows.performDragOperation(cautiousInfo)); try await wait { owner.sftpDropUpload.work == nil }
            let cancelledCalls = await cautiousTransport.names
            try require(reviews == 1 && cancelledCalls.isEmpty && !FileManager().fileExists(atPath: root.appendingPathComponent("state/upload-history").path))
            checks.append("Cautious mode reviews the entire group once; Cancel starts no transfer or durable history")
            owner.sftpDropUpload.reviewForVerification = { plan, destination in
                reviews += 1
                return plan.items.count == 3 && !destination.isEmpty
            }
            let next = info(7); next.draggingLocation = cautiousInfo.draggingLocation
            try require(cautious.rows.performDragOperation(next)); try await wait { owner.sftpDropUpload.work == nil }
            try require(reviews == 2 && owner.sftpDropUpload.lastCompleted?.completed.count == 3)
            checks.append("One cautious approval authorizes the group without per-item sheets")
            let beforeChangedClipboard = await cautiousTransport.names
            owner.sftpDropUpload.reviewForVerification = { _, _ in
                clipboard.clearContents(); clipboard.setString("changed during review", forType: .string); return true
            }
            try await wait { owner.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:))) }
            owner.pasteFileURLs(nil); try await wait { owner.sftpDropUpload.work == nil }
            let afterChangedClipboard = await cautiousTransport.names
            try require(afterChangedClipboard == beforeChangedClipboard && owner.sftpDropUpload.lastCompleted == nil)
            checks.append("Changing the clipboard during cautious review invalidates Paste before any simulated upload")
            let projection = DiagnosticErrors.project(SFTPUploadBatchIssue.historyFull)
            try require(projection.domain == .network && projection.code == 855)
            try require(BrowserSFTPDropUpload.message(SFTPUploadBatchIssue.duplicateNames, stopped: false).contains("same destination name"))
            let selection = try SFTPUploadSelection(request: UUID(), generation: UUID(), revision: 0,
                directory: "/generated", name: SFTPRemoteName(Data("Denied.txt".utf8)), logicalBytes: 1)
            let refusedOpen = SFTPUploadInterruption(selection: selection, cause: .status, phase: .openingFinal,
                status: 3, temporaryMayExist: false, publicationMayHaveHappened: true)
            let refusedBatch = SFTPUploadBatchInterruption(completed: [], totalRoots: 1,
                currentMayHaveStarted: true, cause: refusedOpen, connectionFailed: true)
            let refusedNotice = BrowserSFTPDropUpload.message(refusedBatch, stopped: false)
            try require(refusedNotice.contains("permission") && refusedNotice.contains("may")
                && refusedNotice.contains("connection") && !refusedNotice.contains("Nothing was changed"))
            let refusedFolder = SFTPFolderUploadInterruption(cause: .status, phase: 2, node: 0,
                rootMayExist: true, rootAcknowledged: false, verifiedFiles: 0, verifiedBytes: 0, status: 3)
            let folderNotice = BrowserSFTPFolderUpload.message(refusedFolder, stopped: false)
            try require(folderNotice.contains("permission") && folderNotice.contains("connection"))
            checks.append("Limits and refusals have fixed diagnostic codes and actionable native messages")
            _ = await cautious.close().value
            let readOnlyTransport = Transport(uploads: false), readOnlySession = SFTPBrowserSession(id: UUID(), transport: readOnlyTransport)
            let readOnly = SFTPTabController(session: readOnlySession, address: try .init("sftp://generated.invalid"), title: "Generated read-only server", uploads: storage)
            connection = readOnly; owner.installSFTPTab(readOnly)
            try await wait { readOnly.rows.cache.retainedCount == 2 && !readOnly.hasPendingPages }
            try require(!owner.sftpDropUpload.canRequest(from: readOnly) && readOnly.rows.onDropFiles == nil
                && readOnly.rows.onPaste == nil && !owner.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:))))
            checks.append("Read-only connections expose neither drop nor Paste mutation callbacks")
            let drained = await readOnly.close().value
            try require(drained.localResourcesEnded && ApplicationFileActivity.gate.activeCount == 0 && owner.sftpDropUpload.work == nil)
            checks.append("All native operations and exact session owners drain before window closure")

            owner.navigate(to: .directory(root.appendingPathComponent("source/Local")))
            try await wait { !owner.isLoading && owner.displayedEntries.count == 3 && owner.orderingTask == nil }
            try require(workspace.splitActive(at: .trailing))
            let peer = workspace.activeBrowser; peer.permitsBackgroundVerification = true
            let paneTransport = Transport(), paneSession = SFTPBrowserSession(id: UUID(), transport: paneTransport)
            let pane = SFTPTabController(session: paneSession, address: try .init("sftp://generated.invalid"), title: "Generated pane server", uploads: storage, reviewsUploads: false)
            connection = pane; peer.installSFTPTab(pane)
            try await wait { pane.rows.cache.retainedCount == 2 && !pane.hasPendingPages }
            workspace.activate(owner); owner.focusBrowserContent()
            owner.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
            try require(owner.sftpPaneUpload.canRequest)
            let local = root.appendingPathComponent("source/Local"), last = local.appendingPathComponent("Last.txt")
            let kept = local.appendingPathComponent("Retained Last.txt")
            try FileManager().moveItem(at: last, to: kept)
            try FileManager().createDirectory(at: last, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            owner.uploadToSFTPPane(nil)
            try await wait { peer.sftpDropUpload.work == nil }
            let refusedKinds = await paneTransport.names
            try require(refusedKinds.isEmpty && peer.sftpDropUpload.lastCompleted == nil && peer.sftpDropUpload.acceptedCount == 1)
            try FileManager().removeItem(at: last); try FileManager().moveItem(at: kept, to: last)
            checks.append("Pane upload refuses a source whose observed file kind changed before planning; no remote request starts")

            let fileMenu = BrowserMenus.menu(.file, target: owner)
            guard let uploadIndex = fileMenu.items.firstIndex(where: { $0.action == #selector(BrowserViewController.copyToOtherPane(_:)) }) else { throw Failure.scope }
            try require(owner.commandEnabled(fileMenu.items[uploadIndex].action))
            var paneReviews = 0
            peer.sftpDropUpload.reviewForVerification = { _, _ in paneReviews += 1; return false }
            fileMenu.performActionForItem(at: uploadIndex)
            try await wait { peer.sftpDropUpload.work == nil }
            let paneCalls = await paneTransport.names
            try require(peer.sftpDropUpload.lastCompleted?.completed.count == 3 && paneReviews == 0 && Set(paneCalls) == Set(["First.txt", "Folder", "Last.txt"]))
            checks.append("The ordinary Copy-to-Other-Pane command uploads the selected mixed group without a chooser or normal-mode confirmation")
            try await wait { pane.rows.cache.retainedCount == 2 && !pane.hasPendingPages }
            workspace.activate(owner); owner.focusBrowserContent()
            try require(workspace.splitActive(at: .bottom))
            let extra = workspace.activeBrowser; extra.permitsBackgroundVerification = true
            let extraFolder = root.appendingPathComponent("source/Local Destination")
            try FileManager().createDirectory(at: extraFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            extra.navigate(to: .directory(extraFolder))
            try await wait { !extra.isLoading && extra.location.directoryURL == extraFolder }
            workspace.activate(owner); owner.focusBrowserContent()
            owner.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
            var offersBoth = false
            owner.paneTransfers.presentForVerification = { offered in
                let ids = Set(offered.items.compactMap { $0.representedObject as? UUID })
                offersBoth = ids == Set([extra.paneID, peer.paneID])
            }
            owner.copyToOtherPane(nil)
            try require(offersBoth && peer.sftpDropUpload.work == nil)
            owner.paneTransfers.presentForVerification = { offered in
                owner.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                if let index = offered.items.firstIndex(where: { ($0.representedObject as? UUID) == peer.paneID }) {
                    offered.performActionForItem(at: index)
                }
            }
            owner.copyToOtherPane(nil)
            let noMorePaneCalls = await paneTransport.names
            try require(noMorePaneCalls == paneCalls && !owner.operationCoordinator.transfers.hasOutstandingWork && peer.sftpDropUpload.work == nil)
            try require(FileManager().contentsOfDirectory(atPath: extraFolder.path).isEmpty)
            owner.paneTransfers.presentForVerification = nil
            workspace.activate(extra); try require(workspace.closeActivePane())
            checks.append("Mixed local/SFTP destinations share one menu; Cancel or a changed selection starts neither copy nor upload")
            _ = await pane.close().value

            let changedTransport = Transport(), changedSession = SFTPBrowserSession(id: UUID(), transport: changedTransport)
            let changed = SFTPTabController(session: changedSession, address: try .init("sftp://generated.invalid"), title: "Generated cautious pane", uploads: storage, reviewsUploads: true)
            connection = changed; peer.installSFTPTab(changed)
            try await wait { changed.rows.cache.retainedCount == 2 && !changed.hasPendingPages }
            peer.sftpDropUpload.reviewForVerification = { _, _ in
                owner.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                return true
            }
            workspace.activate(owner); owner.focusBrowserContent()
            owner.table.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)
            owner.uploadToSFTPPane(nil)
            try await wait { peer.sftpDropUpload.work == nil }
            let changedCalls = await changedTransport.names
            try require(changedCalls.isEmpty && peer.sftpDropUpload.lastCompleted == nil)
            _ = await changed.close().value
            workspace.activate(peer); try require(workspace.closeActivePane())
            checks.append("A changed source selection during cautious review invalidates the pane intent and sends no replacement selection")
            checks += try await verifyFileActions(root: root, browser: owner, uploadStorage: storage, clips: &clips)
            checks += try await verifyFileMove(root: root, browser: owner)
            checks += try await verifyServerCopy(root: root, browser: owner)
            checks += try await verifyNewTextFile(root: root, browser: owner, uploadStorage: storage, clips: &clips)
            checks += try await verifyCutPaste(root: root, browser: owner)
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }; kind = String(reflecting: type(of: error))
        }
        if let connection { _ = await connection.close().value }
        browser?.suspendBrowser(); host?.close(); boards.forEach { $0.releaseGlobally() }
        if let area {
            let report: [String:Any] = ["passed": failure == nil,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),
                "checks":checks,"clips":clips,"networkRequests":0,"bodyTransfers":0,"physicalInputExercised":false,
                "lastActionNotice":browser?.sftpFileActions.lastNotice ?? "",
                "offscreenFunctionalFlow":ProcessInfo.processInfo.arguments.contains("--offscreen"),
                "activityDrained":ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]).write(to: area.appendingPathComponent("evidence/native-sftp-drop-upload.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func verifyFileActions(root: URL, browser: BrowserViewController,
        uploadStorage: SFTPUploadStorage, clips: inout [[String: Any]]) async throws -> [String] {
        let previousSize = browser.settings.interfaceSize, previousAppearance = browser.settings.appearance,
            previousMotion = browser.settings.motion.mode
        if ProcessInfo.processInfo.arguments.contains("--large-interface") {
            browser.settings.interfaceSize = .init(150); browser.settings.appearance = .light; browser.settings.motion.mode = .reduced
        }
        defer { browser.settings.interfaceSize = previousSize; browser.settings.appearance = previousAppearance; browser.settings.motion.mode = previousMotion }
        let transport = Transport(actions: true, fileBytes: 2 << 30), session = SFTPBrowserSession(id: UUID(), transport: transport)
        let store = SFTPRemoteActionStore(directory: root.appendingPathComponent("state/file-actions"))
        let owner = SFTPTabController(session: session, address: try .init("sftp://generated.invalid"),
            title: "Generated action server", uploads: uploadStorage, remoteActions: store, reviewsUploads: false)
        try require(owner.allowsEmptyDirectoryDelete && owner.rows.allowsEmptyDirectoryDelete && owner.allowsDirectoryRename)
        let routedSession = SFTPBrowserSession(id: UUID(), transport: Transport(actions: true))
        let routed = SFTPTabController(session: routedSession, address: try .init("sftp://generated.invalid"),
            title: "Generated routed action server", remoteActions: store, routeDescription: try .init(
                destination: .init(name: "Destination", address: .init("sftp://generated.invalid"), account: "generated"),
                jump: .init(name: "Jump", address: .init("sftp://jump.generated.invalid"), account: "generated")))
        try require(!routed.allowsEmptyDirectoryDelete && !routed.rows.allowsEmptyDirectoryDelete && !routed.allowsDirectoryRename)
        _ = await routed.close().value
        browser.installSFTPTab(owner)
        try await wait { owner.sealedActionSnapshot != nil }
        let disconnect = BrowserMenus.menu(.go, target: browser).items.first { $0.title == "Disconnect This Tab" }
        try require(disconnect?.action == #selector(BrowserViewController.disconnectCurrentConnection(_:))
            && BrowserCommand.disconnectServer.selector == disconnect?.action
            && browser.commandEnabled(disconnect?.action))
        @MainActor func done(_ count: Int) async throws {
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                && owner.rows.cache.retainedCount == count && owner.sealedActionSnapshot != nil }
        }
        @MainActor func selectFile() throws {
            guard let row = (0..<owner.rows.table.numberOfRows).first(where: { owner.rows.cache.entry(at: UInt64($0))?.entry.isDirectory == false }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        browser.operationNamePrompt = { _, _ in nil }
        browser.createFolder(nil); try await done(2)
        let cancelled = try await store.inspect(); try require(cancelled.records.isEmpty)
        browser.operationNamePrompt = { _, _ in "Created Folder" }
        browser.createFolder(nil); try await done(3)
        try require(browser.sftpFileActions.lastResult?.record.outcome == .confirmed)
        try require(owner.transferNotice == browser.sftpFileActions.lastNotice
            && browser.status.stringValue == owner.transferNotice
            && owner.rows.outcomeVisibleForVerification)
        try selectFile()
        try require(owner.rows.selectedDownload == nil && browser.sftpFileActions.canRequest(.renameFile, from: owner)
            && browser.sftpFileActions.canRequest(.deleteFilePermanently, from: owner))
        browser.operationNamePrompt = nil
        browser.renameSelection(nil)
        try await wait { browser.inlineRename.field?.currentEditor() != nil }
        guard let nameField = browser.inlineRename.field, let editor = nameField.currentEditor() as? NSTextView else { throw Failure.scope }
        try require(nameField.superview === owner.rows.table && editor.string == "Generated.txt")
        _ = browser.inlineRename.control(nameField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try await done(3)
        try require(try await store.inspect().records.count == 1)
        browser.operationNamePrompt = { _, _ in "Renamed.txt" }
        browser.renameSelection(nil); try await done(3)
        try require(browser.sftpFileActions.lastResult?.record.destinationName == "Renamed.txt"
            && browser.sftpFileActions.blocksImplicitUndo)
        try selectFile(); browser.operationNamePrompt = { _, _ in "Folder on server" }
        browser.renameSelection(nil); try await done(3)
        let afterNameConflict = try await store.inspect()
        try require(browser.sftpFileActions.lastResult == nil && afterNameConflict.records.count == 2)
        try selectFile(); browser.sftpFileActions.confirmDeleteForVerification = { false }
        browser.deleteRemoteFilePermanently(nil); try await done(3)
        let beforeDelete = try await store.inspect(); try require(beforeDelete.records.count == 2)
        browser.sftpFileActions.confirmDeleteForVerification = { true }
        browser.deleteRemoteFilePermanently(nil); try await done(2)
        let complete = try await store.inspect()
        try require(complete.records.count == 3 && complete.active.isEmpty
            && complete.records.filter { $0.outcome == .confirmed }.count == 3)
        @MainActor func selectFolder(_ name: String) throws {
            guard let row = (0..<owner.rows.table.numberOfRows).first(where: {
                owner.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == name
            }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        try selectFolder("Folder on server")
        try require(browser.sftpFileActions.canDelete(from: owner)
            && !browser.sftpFileActions.canRequest(.renameFile, from: owner))
        browser.deleteRemoteFilePermanently(nil); try await done(2)
        try require(browser.sftpFileActions.lastResult?.record.refusal == .notEmpty
            && DiagnosticErrors.remoteFileAction(browser.sftpFileActions.lastResult!.record)?.symbol == "sftp.fileAction.notEmpty")
        try selectFolder("Created Folder")
        browser.sftpFileActions.confirmDeleteForVerification = { false }
        browser.deleteRemoteFilePermanently(nil); try await done(2)
        let afterFolderCancel = try await store.inspect(); try require(afterFolderCancel.records.count == 4)
        browser.sftpFileActions.confirmDeleteForVerification = { true }
        browser.deleteRemoteFilePermanently(nil); try await done(1)
        let afterFolderDelete = try await store.inspect()
        try require(afterFolderDelete.records.count == 5 && afterFolderDelete.active.isEmpty
            && browser.sftpFileActions.lastResult?.record.kind == .deleteEmptyDirectoryPermanently
            && browser.sftpFileActions.lastResult?.record.outcome == .confirmed)
        // One complete folder Rename path uses the ordinary File command,
        // including Cancel, the App-wide editor admission fence, a collision,
        // checked success and another tab's now-stale descendant observations.
        try selectFolder("Folder on server")
        try require(browser.sftpFileActions.canRename(from: owner))
        browser.operationNamePrompt = { _, _ in nil }
        browser.renameSelection(nil); try await done(1)
        try require(try await store.inspect().records.count == 5)
        let editors = ApplicationRemoteTextEditors.shared
        guard let fence = editors.beginDirectoryMutation() else { throw Failure.scope }
        defer { editors.finishDirectoryMutation(fence) }
        try require(!browser.sftpFileActions.canRename(from: owner) && editors.beginDirectoryMutation() == nil)
        editors.finishDirectoryMutation(UUID())
        try require(!editors.canBeginDirectoryMutation && browser.sftpFileActions.renameExplanation(from: owner) != nil)
        editors.finishDirectoryMutation(fence)
        try require(editors.canBeginDirectoryMutation && browser.sftpFileActions.canRename(from: owner))
        browser.operationNamePrompt = { _, _ in "Occupied Folder" }
        browser.createFolder(nil); try await done(2)
        try selectFolder("Folder on server")
        browser.renameSelection(nil); try await done(2)
        let afterFolderNameConflict = try await store.inspect()
        try require(browser.sftpFileActions.lastResult == nil && afterFolderNameConflict.records.count == 6
            && editors.canBeginDirectoryMutation)
        let parentTab = browser.activeID
        let childTransport = Transport(actions: true)
        let childSession = SFTPBrowserSession(id: UUID(), transport: childTransport)
        let childOwner = SFTPTabController(session: childSession, address: try .init("sftp://generated.invalid"),
            title: "Generated descendant view", remoteActions: store,
            defaultDirectory: try .init(root: .home, components: [.init(Data("Folder on server".utf8)), .init(Data("Child".utf8))]))
        browser.installSFTPTab(childOwner)
        try await wait { childOwner.sealedActionSnapshot != nil }
        browser.selectTab(parentTab); try await done(2)
        try selectFolder("Folder on server")
        let childOpens = await childTransport.opens
        browser.operationNamePrompt = { _, _ in "Renamed Folder" }
        browser.renameSelection(nil); try await done(2)
        let childOpensAfter = await childTransport.opens
        try require(browser.sftpFileActions.lastResult?.record.kind == .renameDirectory
            && browser.sftpFileActions.lastResult?.record.outcome == .confirmed
            && owner.rows.cache.loadedEntries.contains { $0.row.entry.name.displayName == "Renamed Folder" }
            && childOwner.sealedActionSnapshot == nil && childOwner.rows.cache.retainedCount == 0
            && childOpensAfter == childOpens && editors.canBeginDirectoryMutation)
        _ = await childOwner.close().value
        let finalActions = try await store.inspect()
        try require(finalActions.records.count == 7 && finalActions.active.isEmpty)
        let remembered = SFTPRememberedState(settings: .init(directory: root.appendingPathComponent("state/action-server-settings")),
            passwords: .refusingQualification { })
        let catalogs = try SMBTemporaryStorage(directory: root.appendingPathComponent("state/action-catalogs"))
        let review = SFTPConnectionStorageWindow(settings: browser.settings, remembered: remembered, storage: catalogs, remoteActions: store)
        review.window?.title = "SFTP file actions · generated review"
        review.present(relativeTo: browser.view.window); try await wait { !review.model.busy }
        try require(review.model.actionHistory?.records.count == finalActions.records.count)
        guard let window = review.window else { throw Failure.scope }
        if ProcessInfo.processInfo.arguments.contains("--offscreen") {
            window.setFrameOrigin(.init(x: -12000, y: -12000)); review.model.clearCompletedActions()
        } else {
            let capture = try await NativeMotionRecorder.record(window: window, root: root, label: "sftp-action-history-clear", sampling: .diagnostic(for: window)) {
                review.model.clearCompletedActions()
            }
            clips.append(DevelopmentMotionVerification.clip("sftp-action-history-clear", report: capture, field: nil, window: window))
        }
        try await wait { !review.model.busy }
        try require(review.model.actionHistory?.records.isEmpty == true)
        await review.closeAndDrain()
        let actionTab = browser.activeID
        browser.operationNamePrompt = { _, _ in "Uncertain Folder" }
        browser.createFolder(nil)
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil && browser.sftpTabs[actionTab] == nil }
        try require(browser.sftpClosedUploadNotices[actionTab]?.message.contains("could not be confirmed") == true
            && !browser.hasExclusiveBrowserOperation && browser.commandEnabled(#selector(BrowserViewController.showSMBConnections(_:))))
        let closed = await store.close(); try require(closed)
        let cold = SFTPRemoteActionStore(directory: root.appendingPathComponent("state/file-actions"))
        let retained = try await cold.inspect()
        try require(retained.records.count == 1 && retained.records[0].outcome == .needsReview && retained.active.isEmpty)
        _ = await cold.close()
        browser.operationNamePrompt = nil; browser.sftpFileActions.confirmDeleteForVerification = nil
        let closeOwner = SFTPTabController(session: SFTPBrowserSession(id: UUID(), transport: Transport()),
            address: try .init("sftp://generated.invalid"), title: "Generated disconnect")
        browser.installSFTPTab(closeOwner)
        try await wait { closeOwner.sealedActionSnapshot != nil }
        let closeTab = browser.activeID
        browser.disconnectCurrentConnection(nil)
        try await wait { browser.sftpTabs[closeTab] == nil }
        try require(!browser.commandEnabled(#selector(BrowserViewController.disconnectCurrentConnection(_:))))
        return ["Ordinary New Folder and file Rename share existing commands; Cancel records nothing and a name conflict has a fixed actionable result",
            "Metadata-only Rename/Delete remain available beyond the download body limit; permanent Delete asks once and Cancel changes nothing",
            "The same Delete command routes an empty folder to its distinct durable action; nonempty refusal preserves the folder and Cancel records nothing",
            "Empty-folder Delete is enabled only for the qualified direct tab; a routed tab does not advertise or admit it",
            "Direct folder Rename uses the ordinary command, preserves a collision, releases its exact editor fence and invalidates matching descendant observations without a new read",
            "Connection Storage reviews durable file-action results and explicitly clears completed local records without a remote request",
            "An uncertain action closes/drains its tab, keeps cold local review and leaves Connect usable without a ghost busy browser",
            "Go Disconnect routes to the actual current protocol, drains SFTP and disables after disconnect"]
    }
    /// One whole native Copy/Duplicate flow, using the existing simulated
    /// transport. It proves App composition and cold receipt presentation,
    /// not live copy-data, byte equality or sandbox publication.
    private static func verifyServerCopy(root: URL, browser: BrowserViewController) async throws -> [String] {
        try require(!SFTPRemoteActionFeature.copiesAvailable && !RemoteClipboardFeature.sftpCopyAvailable)
        SFTPRemoteActionFeature.qualifyingCopies = true
        defer { SFTPRemoteActionFeature.qualifyingCopies = false; browser.sftpFileActions.destinationForVerification = nil }
        try require(!RemoteClipboardFeature.qualifying && RemoteClipboardFeature.sftpCopyAvailable)
        let storeRoot = root.appendingPathComponent("state/server-copy-actions")
        let store = SFTPRemoteActionStore(directory: storeRoot)
        let peer = Transport(actions: true, copies: true, fileBytes: 2 << 30)
        let owner = SFTPTabController(session: .init(id: UUID(), transport: peer),
            address: try .init("sftp://generated.invalid"), title: "Generated Copy server",
            remoteActions: store, reviewsUploads: false, defaultDirectory: try .init(root: .home))
        browser.installSFTPTab(owner)
        try await wait { owner.sealedActionSnapshot != nil && owner.rows.cache.retainedCount == 2 }
        @MainActor func selectOriginal() throws {
            guard let index = (0..<owner.rows.table.numberOfRows).first(where: {
                owner.rows.cache.entry(at: UInt64($0))?.entry.name.displayName == "Generated.txt"
            }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        @MainActor func settled(_ count: Int, _ line: UInt = #line, seconds: Double = 6) async throws {
            try await wait({ browser.operationTask == nil && browser.operationPreparationTask == nil
                && owner.sealedActionSnapshot != nil && owner.rows.cache.retainedCount == count }, line, seconds: seconds)
        }
        try selectOriginal()
        try require(owner.allowsServerCopy && owner.rows.onServerCopy != nil && owner.rows.onDuplicate != nil
            && browser.commandEnabled(#selector(BrowserViewController.copyServerSelection(_:)))
            && browser.commandEnabled(#selector(BrowserViewController.duplicateSelection(_:))))
        var pickerChecked = false, copyInputFailure: Error?
        let nativeTyping = ProcessInfo.processInfo.arguments.contains("--interactive-sidebar-review")
        browser.sftpFileActions.destinationForVerification = { model in
            pickerChecked = model.rootTitle == "Server Root" && model.currentFolder == "/fixture"
                && model.path == "/fixture" && model.operation == .copy && !model.canMove
            if nativeTyping {
                do { _ = try await reviewCopyDestination(model, browser: browser, root: root, cancel: true, nativeTyping: true) }
                catch { copyInputFailure = error }
            }
            return nil
        }
        browser.copyServerSelection(nil); try await settled(2, seconds: nativeTyping ? 630 : 6)
        let cancelledCopy = try await store.inspect()
        try require(pickerChecked && copyInputFailure == nil && cancelledCopy.records.isEmpty)
        let editors = ApplicationRemoteTextEditors.shared
        guard let fence = editors.beginDirectoryMutation() else { throw Failure.scope }
        try require(!browser.sftpFileActions.canCopy(from: owner))
        editors.finishDirectoryMutation(fence)
        browser.sftpFileActions.destinationForVerification = { model in
            model.path = "/occupied"; model.destinationName = "Generated.txt"
            return model.canMove ? model.path : nil
        }
        browser.copyServerSelection(nil); try await settled(2)
        try require(browser.sftpFileActions.lastResult?.record.refusal == .targetExists)
        try selectOriginal()
        browser.sftpFileActions.destinationForVerification = { model in
            model.path = "/target"; model.destinationName = "Copied.txt"
            return model.canMove ? model.path : nil
        }
        browser.copyServerSelection(nil); try await settled(2)
        let copied = browser.sftpFileActions.lastResult?.record
        try require(copied?.kind == .copyFile && copied?.outcome == .confirmed
            && copied?.remoteDirectory == "/fixture" && copied?.destinationDirectory == "/target"
            && copied?.destinationName == "Copied.txt" && copied?.copyStageName != nil
            && browser.sftpFileActions.blocksImplicitUndo && editors.canBeginDirectoryMutation)
        try selectOriginal()
        var duplicatePickerWasCalled = false
        browser.sftpFileActions.destinationForVerification = { _ in duplicatePickerWasCalled = true; return nil }
        try require(browser.sftpFileActions.canCopy(from: owner) && browser.canDuplicateSelection)
        browser.duplicateSelection(nil); try await settled(3)
        try require(!duplicatePickerWasCalled && browser.sftpFileActions.lastResult?.record.destinationName == "Generated copy.txt")
        try selectOriginal(); browser.duplicateSelection(nil); try await settled(4)
        try require(owner.rows.cache.loadedEntries.filter { $0.row.entry.isDirectory == false }.count == 3
            && browser.sftpFileActions.lastResult?.record.destinationName != "Generated copy.txt")
        let tab = browser.activeID
        browser.disconnectCurrentConnection(nil); try await wait { browser.sftpTabs[tab] == nil }
        try require(await store.close())
        let cold = SFTPRemoteActionStore(directory: storeRoot), snapshot = try await cold.inspect()
        try require(snapshot.active.isEmpty && snapshot.records.count == 4
            && snapshot.records.filter { $0.outcome == .confirmed }.count == 3
            && snapshot.records.allSatisfy { $0.kind == .copyFile && $0.copyStageName != nil })
        try require(await cold.close())
        let unsupported = SFTPTabController(session: .init(id: UUID(), transport: Transport(actions: true)),
            address: try .init("sftp://generated.invalid"), title: "No Copy extension", remoteActions: store)
        try require(!unsupported.allowsServerCopy && unsupported.rows.onServerCopy == nil && unsupported.rows.onDuplicate == nil)
        _ = await unsupported.close().value
        return ["Conditional SFTP Copy reuses the ordinary Copy To/ Duplicate commands and destination model; Home-relative browsing obtains its canonical parent without guessing",
            "Copy Cancel submits nothing; an editor fence blocks admission; an occupied destination refuses while the source remains visible",
            "Copy To and two one-click Duplicates keep the original, choose distinct loaded names, refresh rows and retain cold version2 receipts with private stages",
            "A peer without negotiated Copy support advertises neither Copy command; no network/body/publication proof is inferred from this simulated native flow"]
    }
    private static func reviewCopyDestination(_ model: RemoteMoveDestinationModel,
        browser: BrowserViewController, root: URL, cancel: Bool, nativeTyping: Bool = false) async throws -> String? {
        guard let parent = browser.view.window else { throw Failure.scope }
        let review = RemoteMoveDestination(model: model, settings: browser.settings)
        let input = Task { @MainActor () throws -> Void in
            var stage = "awaitSheet"
            do {
                try await wait { parent.attachedSheet === review.window }
                try await Task.sleep(for: .milliseconds(180))
                if nativeTyping, let panel = review.window {
                    stage = "awaitTyping"
                    let ready: [String: Any] = ["stage": "waitingForNativeTyping", "networkConnections": 0,
                        "entryPoint": "directCopyTo", "initialValidationIssue": model.issue != nil,
                        "panelIsKey": panel.isKeyWindow, "panelOwnsKeyWindow": NSApp.keyWindow === panel,
                        "firstResponderClass": panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                        "parentWindowClass": String(describing: type(of: parent)),
                        "expectedPath": "/typed", "expectedName": "typed.txt"]
                    try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("evidence/destination-input-ready.json"), options: .withoutOverwriting)
                    try await wait({ model.path == "/typed" && model.destinationName == "typed.txt"
                        || parent.attachedSheet !== panel }, seconds: 600)
                    let typed = model.path == "/typed" && model.destinationName == "typed.txt"
                    try JSONSerialization.data(withJSONObject: ["nativeTypingObserved": typed,
                        "panelIsKey": panel.isKeyWindow], options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("evidence/destination-input-result.json"), options: .withoutOverwriting)
                    try require(typed)
                }
                if cancel, !ProcessInfo.processInfo.arguments.contains("--offscreen"), let panel = review.window {
                    stage = "capture"
                    let capture = nativeTyping ? "sftp-direct-copy-input.png" : "sftp-clipboard-copy-review.png"
                    try await GlassVerification.captureOwnedWindow(panel,
                        to: root.appendingPathComponent("evidence/" + capture))
                }
                stage = "cancelControl"
                try require(SFTPFolderUploadPreviewVerification.pressMove(in: review, cancel: cancel))
            } catch {
                if nativeTyping {
                    try? JSONSerialization.data(withJSONObject: ["stage": stage,
                        "nativeTypingObserved": model.path == "/typed" && model.destinationName == "typed.txt"], options: [.sortedKeys])
                        .write(to: root.appendingPathComponent("evidence/destination-input-failure.json"), options: .withoutOverwriting)
                }
                review.finish(nil); throw error
            }
        }
        let answer = await review.choose(in: parent)
        defer { review.close() }
        try await input.value
        return answer
    }

    /// Uses the same action owner, picker model and outcome store as Rename.
    /// This verifies native composition with a simulated transport, not a live Move.
    private static func verifyFileMove(root: URL, browser: BrowserViewController) async throws -> [String] {
        try require(!SFTPRemoteActionFeature.fileMoveAvailable)
        try require(!SFTPRemoteActionFeature.directoryMoveAvailable)
        SFTPRemoteActionFeature.qualifyingMoves = true
        SFTPRemoteActionFeature.qualifyingDirectoryMoves = true
        defer {
            SFTPRemoteActionFeature.qualifyingMoves = false; SFTPRemoteActionFeature.qualifyingDirectoryMoves = false
            browser.sftpFileActions.destinationForVerification = nil
        }
        let store = SFTPRemoteActionStore(directory: root.appendingPathComponent("state/file-moves"))
        let source = try SFTPDefaultDirectory(field: "/fixture", root: .server)
        @MainActor func makeOwner(transport: Transport = Transport(actions: true), directory: SFTPDefaultDirectory? = nil) throws -> SFTPTabController {
            .init(session: SFTPBrowserSession(id: UUID(), transport: transport),
                address: try .init("sftp://generated.invalid/fixture"), title: "Generated Move server",
                remoteActions: store, defaultDirectory: directory ?? source)
        }
        let transport = Transport(actions: true)
        let owner = try makeOwner(transport: transport); browser.installSFTPTab(owner)
        try await wait { owner.sealedActionSnapshot != nil && owner.rows.cache.retainedCount == 2 }
        // Keep an old read suspended across the cache hint. Its completion must
        // trigger a new read, never restore admission of the pre-Move snapshot.
        let firstRead = owner.sealedActionSnapshot!.snapshot.read
        await transport.holdNextDirectoryOpen()
        owner.refreshAfterUpload()
        let deadline = ContinuousClock.now + .seconds(6)
        while !(await transport.waitingForDirectoryOpen) {
            try require(.now < deadline); try await Task.sleep(for: .milliseconds(5))
        }
        owner.refreshAfterFileMove(source: Data("/fixture".utf8), destination: Data("/target".utf8))
        try require(owner.sealedActionSnapshot == nil)
        await transport.resumeDirectoryOpen()
        try await wait { owner.sealedActionSnapshot?.snapshot.read == firstRead + 2 }
        @MainActor func selectFile(_ owner: SFTPTabController) throws {
            guard let index = (0..<owner.rows.table.numberOfRows).first(where: {
                owner.rows.cache.entry(at: UInt64($0))?.entry.permissions.map { $0 & 0o170000 == 0o100000 } == true
            }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        @MainActor func selectFolder(_ owner: SFTPTabController) throws {
            guard let index = (0..<owner.rows.table.numberOfRows).first(where: {
                owner.rows.cache.entry(at: UInt64($0))?.entry.permissions.map { $0 & 0o170000 == 0o040000 } == true
            }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        @MainActor func settled(_ count: Int) async throws {
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                && owner.sealedActionSnapshot != nil && owner.rows.cache.retainedCount == count }
        }
        try selectFile(owner)
        try require(owner.allowsFileMove && browser.commandEnabled(#selector(BrowserViewController.moveServerSelection(_:))))
        var pickerWasCorrect = false
        browser.sftpFileActions.destinationForVerification = { model in
            pickerWasCorrect = model.rootTitle == "Server Root" && model.currentFolder == "/fixture" && !model.canMove
            return nil
        }
        browser.moveServerSelection(nil); try await settled(2)
        let cancelled = try await store.inspect()
        try require(pickerWasCorrect && cancelled.records.isEmpty)
        let editors = ApplicationRemoteTextEditors.shared
        guard let fence = editors.beginDirectoryMutation() else { throw Failure.scope }
        try require(!browser.sftpFileActions.canMove(from: owner) && browser.sftpFileActions.moveExplanation(from: owner) != nil)
        editors.finishDirectoryMutation(fence)
        browser.sftpFileActions.destinationForVerification = { model in model.path = "/occupied"; return model.canMove ? model.path : nil }
        browser.moveServerSelection(nil); try await settled(2)
        try require(browser.sftpFileActions.lastResult?.record.refusal == .targetExists && editors.canBeginDirectoryMutation)
        // The real refreshed source table has cleared its old selection.
        try selectFile(owner)
        browser.sftpFileActions.destinationForVerification = { model in model.path = "/target"; return model.canMove ? model.path : nil }
        browser.moveServerSelection(nil); try await settled(1)
        let moved = browser.sftpFileActions.lastResult?.record
        try require(moved?.kind == .moveFile && moved?.outcome == .confirmed && moved?.destinationDirectory == "/target"
            && moved?.remoteDirectory == "/fixture" && browser.sftpFileActions.blocksImplicitUndo
            && editors.canBeginDirectoryMutation)
        let sourceTab = browser.activeID
        var otherViews: [(SFTPTabController, Transport)] = []
        for directory in [try SFTPDefaultDirectory(field: "/fixture/Folder on server/Child", root: .server),
                          try SFTPDefaultDirectory(field: "/folder-target/Folder on server/Child", root: .server),
                          try SFTPDefaultDirectory(field: "~/Alias", root: .home)] {
            let peer = Transport(actions: true), other = try makeOwner(transport: peer, directory: directory)
            otherViews.append((other, peer)); browser.installSFTPTab(other)
            try await wait { other.sealedActionSnapshot != nil && other.rows.cache.retainedCount == 2 }
        }
        browser.selectTab(sourceTab); try await settled(1); try selectFolder(owner)
        var rejectedDescendant = false
        browser.sftpFileActions.destinationForVerification = { model in
            model.path = "/fixture/Folder on server/Child"; rejectedDescendant = !model.canMove
            return nil
        }
        browser.moveServerSelection(nil); try await settled(1)
        let afterFolderCancel = try await store.inspect()
        try require(rejectedDescendant && afterFolderCancel.records.count == 2)
        browser.sftpFileActions.destinationForVerification = { model in model.path = "/folder-target"; return model.path }
        browser.moveServerSelection(nil); try await settled(0)
        try require(browser.sftpFileActions.lastResult?.record.kind == .moveDirectory
            && browser.sftpFileActions.lastResult?.record.outcome == .confirmed && editors.canBeginDirectoryMutation)
        for (other, peer) in otherViews {
            try require(other.rows.cache.retainedCount == 0)
            let reads = await peer.opens; try require(reads == 1)
            _ = await other.close().value
        }
        _ = await owner.close().value
        let uncertain = try makeOwner(); browser.installSFTPTab(uncertain)
        try await wait { uncertain.sealedActionSnapshot != nil && uncertain.rows.cache.retainedCount == 2 }
        try selectFolder(uncertain)
        browser.sftpFileActions.destinationForVerification = { model in model.path = "/uncertain"; return model.path }
        let tab = browser.activeID
        browser.moveServerSelection(nil)
        try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil && browser.sftpTabs[tab] == nil }
        try require(browser.sftpClosedUploadNotices[tab]?.message.contains("could not be confirmed") == true
            && editors.canBeginDirectoryMutation)
        try require(await store.close())
        let cold = SFTPRemoteActionStore(directory: root.appendingPathComponent("state/file-moves"))
        let history = try await cold.inspect()
        try require(history.records.count == 4 && history.active.isEmpty
            && history.records.allSatisfy { ($0.kind == .moveFile || $0.kind == .moveDirectory) && $0.destinationDirectory != nil }
            && history.records.filter { $0.outcome == .needsReview }.count == 1)
        try require(await cold.close())
        return ["An in-flight other-parent directory read cannot re-admit its invalidated pre-Move snapshot; it rereads before selection authority returns",
            "SFTP Move uses the shared destination picker and ordinary command; Cancel submits nothing and editor admission remains fenced",
            "An occupied destination preserves the selected file; confirmed Move refreshes the source and keeps both parents in durable local history",
            "Folder Move refuses a descendant destination and invalidates old/new subtree views plus Home aliases without retargeting or new reads",
            "An uncertain Move drains its connection without retry, releases the editor fence and retains both parents for cold review; live-server Move is not exercised"]
    }
    /// One app-level Cut/Copy/Paste journey through existing tab, clipboard, action and
    /// history owners. The same small transport double supplies scoped listings;
    /// no server, body transfer or native security qualification is implied.
    private static func verifyCutPaste(root: URL, browser: BrowserViewController) async throws -> [String] {
        let previousSize = browser.settings.interfaceSize, previousAppearance = browser.settings.appearance,
            previousMotion = browser.settings.motion.mode
        if ProcessInfo.processInfo.arguments.contains("--large-interface") {
            browser.settings.interfaceSize = .init(150); browser.settings.appearance = .light; browser.settings.motion.mode = .reduced
        }
        RemoteClipboardFeature.qualifying = true
        SFTPRemoteActionFeature.qualifyingMoves = true; SFTPRemoteActionFeature.qualifyingDirectoryMoves = true
        let oldBoard = browser.transferPasteboard, board = NSPasteboard.withUniqueName()
        var opened: [(SFTPTabController, Transport, SFTPRemoteActionStore)] = []
        defer {
            browser.settings.interfaceSize = previousSize; browser.settings.appearance = previousAppearance
            browser.settings.motion.mode = previousMotion
            RemoteClipboardFeature.qualifying = false
            SFTPRemoteActionFeature.qualifyingMoves = false; SFTPRemoteActionFeature.qualifyingDirectoryMoves = false
            browser.sftpFileActions.destinationForVerification = nil
            browser.clipboardState.clear(); browser.transferPasteboard = oldBoard; board.releaseGlobally()
        }
        browser.transferPasteboard = board
        browser.workspace?.activate(browser); browser.focusBrowserContent()
        let source = try SFTPDefaultDirectory(field: "/fixture", root: .server)
        @MainActor func start(_ label: String, cautious: Bool = false, copying: Bool = false) async throws -> (SFTPTabController, Transport, SFTPRemoteActionStore) {
            let transport = Transport(actions: true, copies: copying, scopedDirectories: true)
            let store = SFTPRemoteActionStore(directory: root.appendingPathComponent("state/cut-" + label))
            let owner = SFTPTabController(session: SFTPBrowserSession(id: UUID(), transport: transport),
                address: try .init("sftp://generated.invalid/fixture"), title: "Generated Cut server",
                remoteActions: store, reviewsUploads: cautious, defaultDirectory: source)
            opened.append((owner, transport, store)); browser.installSFTPTab(owner)
            try await wait { owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 2 }
            return (owner, transport, store)
        }
        @MainActor func select(_ owner: SFTPTabController, folder: Bool = false) throws {
            guard let row = (0..<owner.rows.table.numberOfRows).first(where: {
                owner.rows.cache.entry(at: UInt64($0))?.entry.isDirectory == folder
            }) else { throw Failure.scope }
            owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        @MainActor func navigate(_ owner: SFTPTabController, to path: String, count: Int) async throws {
            let directory = try SFTPDefaultDirectory(field: path, root: .server)
            browser.navigate(to: .sftp(try owner.directoryLocation(components: directory.components, relativeToHome: false)))
            try await wait { owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == count }
        }
        @MainActor func settled(_ owner: SFTPTabController, count: Int) async throws {
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil
                && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == count }
        }
        @MainActor func cut(_ owner: SFTPTabController, folder: Bool = false) throws {
            try select(owner, folder: folder)
            guard let menu = owner.rows.table.contextMenuProvider?(),
                  let index = menu.items.firstIndex(where: { $0.title == "Cut" }) else { throw Failure.scope }
            try require(browser.canCutRemoteSelection && browser.commandEnabled(#selector(browser.cutFileURLs(_:))))
            menu.performActionForItem(at: index)
            try require(browser.clipboardState.scopedItem != nil && board.types == [ScopedItemClipboardIntent.pasteboardType]
                && board.string(forType: .string) == nil && board.availableType(from: [.fileURL]) == nil)
        }
        do {
            let (normal, transport, store) = try await start("normal")
            try cut(normal)
            try await navigate(normal, to: "/target", count: 0)
            try require(browser.canPasteScopedItem && normal.rows.pasteAllowed?() == true)
            browser.focusLocation(nil)
            try require(browser.view.window?.firstResponder is NSTextView
                && !browser.canPasteScopedItem && !browser.canCutRemoteSelection)
            normal.rows.table.paste(nil)
            try require(browser.operationPreparationTask == nil && browser.operationTask == nil)
            browser.cancelLocationEditing()
            try require(browser.view.window?.makeFirstResponder(normal.rows.table) == true && browser.canPasteScopedItem)
            normal.rows.table.paste(nil)
            try await settled(normal, count: 1)
            let saved = try await store.inspect()
            try require(saved.records.count == 1 && saved.records[0].outcome == .confirmed
                && saved.records[0].remoteDirectory == "/fixture" && saved.records[0].destinationDirectory == "/target"
                && browser.clipboardState.scopedItem == nil && browser.pendingCut == nil)
            try require(await transport.actions == 1)
            try await navigate(normal, to: "/fixture", count: 1)
            try cut(normal, folder: true)
            try await navigate(normal, to: "/target", count: 1)
            browser.pasteFileURLs(nil); try await settled(normal, count: 2)
            try require(browser.sftpFileActions.lastResult?.record.kind == .moveDirectory
                && browser.sftpFileActions.lastResult?.record.outcome == .confirmed && browser.clipboardState.scopedItem == nil)

            let (collision, _, collisionStore) = try await start("collision")
            try cut(collision); try await navigate(collision, to: "/occupied", count: 1)
            browser.pasteFileURLs(nil); try await settled(collision, count: 1)
            try require(browser.sftpFileActions.lastResult?.record.refusal == .targetExists && browser.clipboardState.scopedItem != nil)
            try await navigate(collision, to: "/target", count: 0)
            browser.pasteFileURLs(nil); try await settled(collision, count: 1)
            let collisions = try await collisionStore.inspect()
            try require(collisions.records.count == 2 && collisions.records.filter { $0.outcome == .confirmed }.count == 1
                && browser.clipboardState.scopedItem == nil)

            let (changed, changedTransport, changedStore) = try await start("changed")
            try cut(changed); try await navigate(changed, to: "/target", count: 0)
            await changedTransport.changeCutSourceMetadata()
            browser.pasteFileURLs(nil); try await settled(changed, count: 0)
            let changedHistory = try await changedStore.inspect()
            try require(changedHistory.records.isEmpty && browser.clipboardState.scopedItem == nil
                && changed.transferNotice?.contains("changed") == true)
            try require(await changedTransport.actions == 0)

            let (cautious, _, cautiousStore) = try await start("cautious", cautious: true)
            try cut(cautious); try await navigate(cautious, to: "/target", count: 0)
            var reviews = 0
            browser.sftpFileActions.destinationForVerification = { model in
                reviews += 1; return nil
            }
            browser.pasteFileURLs(nil); try await settled(cautious, count: 0)
            let cancelled = try await cautiousStore.inspect()
            try require(reviews == 1 && cancelled.records.isEmpty && browser.clipboardState.scopedItem != nil)
            browser.sftpFileActions.destinationForVerification = { model in
                reviews += 1; return model.canMove ? model.path : nil
            }
            browser.pasteFileURLs(nil); try await settled(cautious, count: 1)
            try require(reviews == 2 && browser.clipboardState.scopedItem == nil)

            let (stale, staleTransport, staleStore) = try await start("navigation")
            try cut(stale); try await navigate(stale, to: "/target", count: 0)
            await staleTransport.holdNextDirectoryOpen()
            browser.pasteFileURLs(nil)
            let deadline = ContinuousClock.now + .seconds(6)
            while !(await staleTransport.waitingForDirectoryOpen) {
                try require(.now < deadline); try await Task.sleep(for: .milliseconds(5))
            }
            board.clearContents(); board.setString("New generated clipboard text", forType: .string)
            browser.navigate(to: .computer)
            await staleTransport.resumeDirectoryOpen()
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
            let staleHistory = try await staleStore.inspect()
            try require(staleHistory.records.isEmpty && browser.location == .computer
                && board.string(forType: .string) == "New generated clipboard text")
            try require(await staleTransport.actions == 0)
            // Copy crosses the same clipboard/source-observation owner. It
            // keeps the source and clipboard after success, instead of borrowing
            // Move semantics or publishing an exportable server URL.
            SFTPRemoteActionFeature.qualifyingCopies = true
            defer { SFTPRemoteActionFeature.qualifyingCopies = false }
            let (copy, _, copyStore) = try await start("copy", copying: true)
            try select(copy)
            guard let copiedRow = copy.rows.selectedObservation,
                  let copyMenu = copy.rows.table.contextMenuProvider?(),
                  let copyIndex = copyMenu.items.firstIndex(where: { $0.title == "Copy" }) else { throw Failure.scope }
            try require(browser.commandEnabled(#selector(browser.copyFileURLs(_:))))
            copyMenu.performActionForItem(at: copyIndex)
            let copiedID = browser.clipboardState.scopedItem?.id
            try require(copiedID != nil && browser.clipboardState.scopedItem?.operation == .copy
                && browser.transferFeedback?.message.contains("Copied 1 server item") == true
                && board.types == [ScopedItemClipboardIntent.pasteboardType]
                && board.string(forType: .string) == nil && board.availableType(from: [.fileURL]) == nil
                && copy.rows.cutAppearanceForEntry?(copiedRow.entry) == false)
            try await navigate(copy, to: "/target", count: 0)
            browser.focusLocation(nil)
            let clipboardCount = board.changeCount
            try require(browser.view.window?.firstResponder is NSTextView && !browser.canCopyRemoteSelection && !browser.canPasteScopedItem)
            copy.rows.table.copy(nil); copy.rows.table.paste(nil)
            try require(board.changeCount == clipboardCount && browser.operationPreparationTask == nil)
            browser.cancelLocationEditing(); try require(browser.view.window?.makeFirstResponder(copy.rows.table) == true)
            copy.rows.table.paste(nil); try await settled(copy, count: 1)
            try require(browser.sftpFileActions.lastResult?.record.kind == .copyFile
                && browser.sftpFileActions.lastResult?.record.outcome == .confirmed
                && browser.clipboardState.scopedItem?.id == copiedID)
            copy.rows.table.paste(nil); try await settled(copy, count: 1)
            try require(browser.sftpFileActions.lastResult?.record.refusal == .targetExists
                && browser.clipboardState.scopedItem?.id == copiedID)
            try await navigate(copy, to: "/elsewhere", count: 0)
            browser.pasteFileURLs(nil); try await settled(copy, count: 1)
            try await navigate(copy, to: "/fixture", count: 2)
            browser.pasteFileURLs(nil); try await settled(copy, count: 3)
            try require(copy.rows.cache.loadedEntries.contains { $0.row.entry.name.displayName == "Generated.txt" }
                && copy.rows.cache.loadedEntries.contains { $0.row.entry.name.displayName == "Generated copy.txt" }
                && browser.clipboardState.scopedItem?.id == copiedID)
            let copyHistory = try await copyStore.inspect()
            try require(copyHistory.records.count == 4
                && copyHistory.records.allSatisfy { $0.kind == .copyFile }
                && copyHistory.records.filter { $0.outcome == .confirmed }.count == 3)
            let copyTab = browser.activeID
            let (foreign, foreignPeer, foreignStore) = try await start("copy-foreign", copying: true)
            try require(!browser.canPasteScopedItem)
            browser.pasteFileURLs(nil)
            let foreignHistory = try await foreignStore.inspect()
            let foreignActions = await foreignPeer.actions
            try require(foreignHistory.records.isEmpty && foreignActions == 0)
            browser.selectTab(copyTab); try await settled(copy, count: 3)
            let (changedCopy, changedPeer, changedCopyStore) = try await start("copy-changed", copying: true)
            try select(changedCopy); changedCopy.rows.table.copy(nil)
            try await navigate(changedCopy, to: "/target", count: 0)
            await changedPeer.changeCutSourceMetadata()
            browser.pasteFileURLs(nil); try await settled(changedCopy, count: 0)
            let changedCopyHistory = try await changedCopyStore.inspect()
            try require(changedCopyHistory.records.isEmpty && browser.clipboardState.scopedItem == nil)
            try require(await changedPeer.actions == 0)
            let (reviewCopy, _, reviewCopyStore) = try await start("copy-cautious", cautious: true, copying: true)
            try select(reviewCopy); reviewCopy.rows.table.copy(nil)
            try await navigate(reviewCopy, to: "/target", count: 0)
            var copyReviews = 0, reviewCopyModelValid = false
            var copyReviewFailure: Error?
            @MainActor func chooseCopy(_ model: RemoteMoveDestinationModel, cancel: Bool) async -> String? {
                do { return try await reviewCopyDestination(model, browser: browser, root: root, cancel: cancel) }
                catch { copyReviewFailure = error; return nil }
            }
            browser.sftpFileActions.destinationForVerification = { model in
                copyReviews += 1
                reviewCopyModelValid = model.operation == .copy && model.path == "/target" && model.destinationName == "Generated.txt"
                return await chooseCopy(model, cancel: true)
            }
            browser.pasteFileURLs(nil); try await settled(reviewCopy, count: 0)
            let noCopy = try await reviewCopyStore.inspect()
            try require(copyReviewFailure == nil && reviewCopyModelValid && copyReviews == 1 && noCopy.records.isEmpty && browser.clipboardState.scopedItem?.operation == .copy)
            browser.sftpFileActions.destinationForVerification = { model in
                copyReviews += 1; return await chooseCopy(model, cancel: false)
            }
            browser.pasteFileURLs(nil); try await settled(reviewCopy, count: 1)
            try require(copyReviewFailure == nil && copyReviews == 2 && browser.clipboardState.scopedItem?.operation == .copy
                && browser.sftpFileActions.lastResult?.record.kind == .copyFile)
            _ = foreign // Kept alive until the common joined close below.
        } catch {
            for (owner, transport, store) in opened {
                await transport.resumeDirectoryOpen(); _ = await owner.close().value; _ = await store.close()
            }
            throw error
        }
        for (owner, _, store) in opened { _ = await owner.close().value; try require(await store.close()) }
        return ["Actual Cut menu and Paste responder move one file and one folder after navigation through fresh source snapshots; no server URLs or text enter the private clipboard, and address-field editing cannot start a file action",
            "Occupied-name refusal retains the Cut intent for a new destination, confirmed Move consumes only that clipboard generation, and the visible destination refreshes",
            "Changed source metadata refuses before any action/history; cautious Cancel starts no mutation and one later approval uses the same Move owner",
            "Clipboard replacement and navigation during a held source read prevent Move, preserve newer text and keep the user's current location; all generated owners drain",
            "Native remote Copy/Paste retains the original and clipboard, handles collision/repeated destinations and same-folder Duplicate, and refuses a different connection or address-field text edit",
            "A changed copied source refuses before any action; cautious Copy Cancel records nothing and a later single review uses the same ordinary Copy owner"]
    }

    /// Exercises the ordinary command, private empty producer, busy lifetime and
    /// refreshed selection together. The transport is deliberately simulated;
    /// this is not server publication or editor Save qualification.
    private static func verifyNewTextFile(root: URL, browser: BrowserViewController,
        uploadStorage: SFTPUploadStorage, clips: inout [[String: Any]]) async throws -> [String] {
        let transport = Transport(closeDelayMilliseconds: 180), session = SFTPBrowserSession(id: UUID(), transport: transport)
        let sourceRoot = root.appendingPathComponent("state/new-text-sources")
        let owner = SFTPTabController(session: session, address: try .init("sftp://generated.invalid"),
            title: "Generated text server", uploads: uploadStorage,
            newTextStorage: try .init(directory: sourceRoot), reviewsUploads: false)
        browser.installSFTPTab(owner)
        do {
            try await wait { owner.sealedActionSnapshot != nil && browser.sftpNewFile.canRequest(from: owner) }
            browser.operationNamePrompt = { _, _ in nil }
            browser.createTextFile(nil)
            try await wait { browser.operationPreparationTask == nil && browser.sftpNewFile.canRequest(from: owner) }
            let cancelledNames = await transport.names
            try require(cancelledNames.isEmpty && !FileManager().fileExists(atPath: sourceRoot.path))
            browser.operationNamePrompt = { _, _ in "Draft.txt" }
            browser.createTextFile(nil)
            try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                && browser.sftpNewFile.canRequest(from: owner) }
            let createdNames = await transport.names
            try require(createdNames == ["Draft.txt"] && owner.rows.cache.retainedCount == 3
                && owner.rows.selectedObservation?.entry.name.displayName == "Draft.txt"
                && owner.rows.selectedObservation?.entry.logicalBytes == 0)
            browser.operationNamePrompt = nil
            try require(!browser.connectionIndicator.isHidden
                && browser.connectionIndicator.accessibilityValue() as? String == "Connected")
            let tab = browser.activeID
            if !ProcessInfo.processInfo.arguments.contains("--offscreen"), let window = browser.view.window {
                window.title = "SFTP group upload · generated review"
                let capture = try await NativeMotionRecorder.record(window: window, root: root,
                    label: "sftp-connection-status", sampling: .diagnostic(for: window)) {
                    browser.disconnectCurrentConnection(nil)
                }
                try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/sftp-connection-status.json"), options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip("sftp-connection-status", report: capture, field: nil, window: window))
            } else { browser.disconnectCurrentConnection(nil) }
            try await wait { browser.sftpTabs[tab] == nil }
            try require(owner.drain?.localResourcesEnded == true && !browser.hasExclusiveBrowserOperation
                && browser.connectionIndicator.accessibilityValue() as? String == "Disconnected"
                && browser.connectionIndicator.accessibilityHelp()?.contains("Click to sign in to this server.") == true)
            return ["Ordinary remote New Text File Cancel starts no local source or transfer",
                "New Text File stages the typed empty source, acknowledges once, refreshes and selects the zero-byte row through the ordinary command; transport is simulated",
                "Connection status follows actual simulated session close/drain and exposes its disconnected action without a network probe"]
        } catch {
            browser.operationNamePrompt = nil
            _ = await owner.close().value
            throw error
        }
    }
    private static func verifyClipboard(root: URL, browser: BrowserViewController, owner: SFTPTabController,
        transport: Transport) async throws -> NSPasteboard {
        let parent = root.appendingPathComponent("source/Clipboard"), folder = parent.appendingPathComponent("Pasted Folder")
        let file = parent.appendingPathComponent("Pasted.txt"), child = folder.appendingPathComponent("Child.txt")
        try await Task.detached {
            try FileManager().createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Generated clipboard text\n".utf8).write(to: file, options: .withoutOverwriting)
            try Data("Generated clipboard child\n".utf8).write(to: child, options: .withoutOverwriting)
        }.value
        let board = NSPasteboard(name: .init("traverse.generated.sftp-paste." + UUID().uuidString))
        browser.transferPasteboard = board
        board.setString("file:///plain-text-is-not-a-file-offer", forType: .string)
        try require(!browser.sftpDropUpload.canPasteClipboard(to: owner))
        board.clearContents(); try require(board.writeObjects([file as NSURL, folder as NSURL]))
        try require(browser.sftpDropUpload.canPasteClipboard(to: owner)
            && browser.commandEnabled(#selector(BrowserViewController.pasteFileURLs(_:))))
        let before = await transport.names
        let paste = NSMenuItem(title: "Paste", action: #selector(RemoteFileTableView.paste(_:)), keyEquivalent: "")
        try require(owner.rows.table.validateMenuItem(paste) && NSApp.sendAction(paste.action!, to: owner.rows.table, from: paste))
        try await wait { browser.sftpDropUpload.work == nil }
        let after = await transport.names
        try require(Array(after.dropFirst(before.count)) == ["Pasted.txt", "Pasted Folder"]
            && browser.sftpDropUpload.lastCompleted?.completed.count == 2)
        let intact = try await Task.detached {
            try Data(contentsOf: file) == Data("Generated clipboard text\n".utf8)
                && Data(contentsOf: child) == Data("Generated clipboard child\n".utf8)
        }.value
        try require(intact)
        try await wait { owner.rows.cache.retainedCount == 2 && !owner.hasPendingPages }
        return board
    }
    private static func gesture() async {
        var root: URL?, source: BrowserViewController?, target: BrowserViewController?
        var sourceWindow: NSWindow?, targetWindow: NSWindow?, connection: SFTPTabController?, logger: DiagnosticRecorder?
        var checks: [String] = [], failure: UInt?, kind: String?
        SFTPDropUploadFeature.qualifying = true; SFTPFolderUploadFeature.qualifying = true
        defer { SFTPDropUploadFeature.qualifying = false; SFTPFolderUploadFeature.qualifying = false }
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath:raw), repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:area.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-sftp-drop-gesture" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = area
            let recorder = DiagnosticRecorder(directory: area.appendingPathComponent("state/drag-logs"), limits: try .init(bytes: 256 << 10, segmentBytes: 64 << 10), recording: true)
            logger = recorder; ApplicationDiagnostics.shared.configureForVerification(recorder)
            let settings = BrowserSettings(persist:false); settings.autoRefreshFolders=false; settings.folderSummariesEnabled=false
            settings.reviewsRecoveryAtStartup=false; settings.navigationStyle = .glass; settings.glassFileContent=true; settings.appearance = .dark
            InterfacePresentation.shared.bind(settings)
            let local = BrowserViewController(settings:settings), remote = BrowserViewController(settings:settings); source=local; target=remote
            for owner in [local,remote] { owner.permitsBackgroundVerification=true; owner.readVolumesForVerification={ [] } }
            let screen = NSScreen.main?.visibleFrame ?? .init(x:0,y:0,width:1440,height:900)
            let width = min(610,(screen.width-60)/2), height = min(600,screen.height-100)
            func host(_ owner: BrowserViewController, x: CGFloat, title: String) -> NSWindow {
                let window = NSWindow(contentRect:.init(x:x,y:screen.minY+50,width:width,height:height),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false; window.contentViewController=owner; window.title=title; window.makeKeyAndOrderFront(nil); return window
            }
            sourceWindow=host(local,x:screen.minX+20,title:"Generated SFTP drag source")
            targetWindow=host(remote,x:screen.minX+width+40,title:"Generated SFTP drag destination")
            local.navigate(to:.directory(area.appendingPathComponent("source/Local")))
            try await wait { local.displayedEntries.count == 3 && local.table.numberOfRows == 3 }
            await local.listingTask?.value; await local.orderingTask?.value
            local.table.selectRowIndexes(IndexSet(integersIn:0..<3),byExtendingSelection:false)
            try require((0..<3).allSatisfy { local.dragDrop.pasteboardWriter(for: $0) == nil })
            local.dragDrop.windowWillClose(); local.dragDrop.permitsVerification = true; local.dragDrop.selectionDidChange()
            try await wait { (0..<3).allSatisfy { local.dragDrop.pasteboardWriter(for: $0) != nil } }
            let transport=Transport(), session=SFTPBrowserSession(id:UUID(),transport:transport)
            let storage=SFTPUploadStorage(directory:area.appendingPathComponent("state/upload-history"))
            let controller=SFTPTabController(session:session,address:try .init("sftp://generated.invalid"),title:"Generated server",uploads:storage,reviewsUploads:false)
            connection=controller; remote.installSFTPTab(controller)
            try await wait { controller.rows.cache.retainedCount == 2 && !controller.hasPendingPages && remote.sftpDropUpload.canRequest(from:controller) }
            sourceWindow?.title="Generated SFTP drag source";targetWindow?.title="Generated SFTP drag destination"
            if let sourceWindow, let targetWindow {
                try require(sourceWindow.frame.width + targetWindow.frame.width + 60 <= screen.width)
                sourceWindow.setFrameOrigin(.init(x: screen.minX + 20, y: screen.minY + 50))
                targetWindow.setFrameOrigin(.init(x: sourceWindow.frame.maxX + 20, y: screen.minY + 50))
                try require(!sourceWindow.frame.intersects(targetWindow.frame))
            }
            sourceWindow?.makeKeyAndOrderFront(nil)
            let expectedNames = local.orderedSelectedURLs.map(\.lastPathComponent)
            let literalNames = ["Folder", "First.txt", "Last.txt"]
            try require(expectedNames.count == 3 && Set(expectedNames) == Set(literalNames))
            if let sourceWindow,let targetWindow {
                let geometry:[String:Any]=["sourceWindow":NSStringFromRect(sourceWindow.frame),"destinationWindow":NSStringFromRect(targetWindow.frame),
                    "sourceView":NSStringFromRect(local.view.frame),"screen":NSStringFromRect(screen)]
                try JSONSerialization.data(withJSONObject:geometry,options:[.sortedKeys]).write(to:area.appendingPathComponent("evidence/Gesture.geometry.json"),options:.withoutOverwriting)
            }
            try Data("Generated AppKit drop ready\n".utf8).write(to:area.appendingPathComponent("evidence/Gesture.ready"),options:.withoutOverwriting)
            NSApp.activate(ignoringOtherApps:true)
            let deadline=ContinuousClock.now + .seconds(480)
            while remote.sftpDropUpload.acceptedCount == 0 { try require(.now < deadline); try await Task.sleep(for:.milliseconds(10)) }
            try await wait { remote.sftpDropUpload.work == nil }
            let names=await transport.names
            let outcome: [String: Any] = ["accepted": remote.sftpDropUpload.acceptedCount,
                "completed": remote.sftpDropUpload.lastCompleted?.completed.count ?? 0,
                "expectedOrdinals": expectedNames.map { literalNames.firstIndex(of: $0) ?? -1 },
                "actualOrdinals": names.map { literalNames.firstIndex(of: $0) ?? -1 },
                "selectedAfterDrag": local.selectedItemCount]
            try JSONSerialization.data(withJSONObject: outcome, options: [.prettyPrinted, .sortedKeys]).write(to: area.appendingPathComponent("evidence/Gesture.outcome.json"), options: .withoutOverwriting)
            try require(remote.sftpDropUpload.acceptedCount == 1 && remote.sftpDropUpload.lastCompleted?.completed.count == 3 && names == expectedNames)
            checks.append("Actual AppKit local-table group drag reaches the remote-row callback once in selection order")
            try require(remote.view.window?.attachedSheet == nil)
            checks.append("Normal mode admits the group without an upload confirmation")
            let ended=await controller.close().value
            try require(ended.localResourcesEnded && ApplicationFileActivity.gate.activeCount == 0 && remote.sftpDropUpload.work == nil)
            checks.append("Native adapter, fake transport and exact session owners drain")
        } catch {
            if case let Failure.check(line)=error { failure=line } else { failure=0 };kind=String(reflecting:type(of:error))
        }
        if let connection { _=await connection.close().value }
        source?.suspendBrowser();target?.suspendBrowser();sourceWindow?.close();targetWindow?.close()
        ApplicationDiagnostics.shared.configureForVerification(nil); await logger?.closeAndDrain()
        if let root {
            let report:[String:Any]=["passed":failure == nil,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),
                "checks":checks,"physicalInputExercised":target?.sftpDropUpload.acceptedCount == 1,"networkRequests":0,"bodyTransfers":0,"activityDrained":ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-sftp-drop-gesture.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private actor Transport: SFTPDirectoryTransport {
        nonisolated let allowsFreshUploads: Bool, allowsFreshFolderUploads: Bool
        nonisolated let allowsRemoteActions: Bool, allowsServerCopy: Bool
        private var generation = UUID()
        private(set) var opens = 0, names: [String] = []
        private var fileName = "Generated.txt", folderName = "Folder on server", filePresent = true, folderPresent = true, createdFolders: [String] = []
        private var createdText: [String] = []
        private var copiedFiles: [String: [String]] = [:]
        private var visibleCopies: [String] { copiedFiles[scopedDirectories ? currentPath : "/fixture"] ?? [] }
        private var fileBytes: UInt64
        private let scopedDirectories: Bool
        private var currentPath = "/fixture", movedFileDirectory: String?, movedFolderDirectory: String?
        private(set) var actions = 0
        func changeCutSourceMetadata() { fileBytes += 1 }
        private let closeDelayMilliseconds: Int
        private var holdNextOpen = false
        private var heldOpen: CheckedContinuation<Void, Never>?
        var waitingForDirectoryOpen: Bool { heldOpen != nil }
        func holdNextDirectoryOpen() { holdNextOpen = true }
        func resumeDirectoryOpen() { let value = heldOpen; heldOpen = nil; value?.resume() }
        init(uploads: Bool = true, actions: Bool = false, copies: Bool = false, fileBytes: UInt64 = 16, closeDelayMilliseconds: Int = 0,
             scopedDirectories: Bool = false) {
            allowsFreshUploads = uploads; allowsFreshFolderUploads = uploads; allowsRemoteActions = actions; allowsServerCopy = actions && copies; self.fileBytes = fileBytes
            self.closeDelayMilliseconds = closeDelayMilliseconds
            self.scopedDirectories = scopedDirectories
        }
        func openStoredDirectory(_ path: String) async throws -> (UUID,SFTPStoredSnapshot) {
            opens += 1; generation = UUID()
            if holdNextOpen {
                holdNextOpen = false
                await withCheckedContinuation { heldOpen = $0 }
            }
            currentPath = path
            return (generation,.init(read:UInt64(opens),revision:0,count:UInt64((visibleFolder ? 1 : 0) + (scopedDirectories && path != "/fixture" ? 0 : createdFolders.count + createdText.count) + visibleCopies.count + (visibleFile ? 1 : 0)),folders:UInt64((visibleFolder ? 1 : 0) + (scopedDirectories && path != "/fixture" ? 0 : createdFolders.count)),state:.complete))
        }
        private var visibleFile: Bool { !scopedDirectories ? filePresent : currentPath == "/fixture" && filePresent || movedFileDirectory == currentPath || currentPath == "/occupied" }
        private var visibleFolder: Bool { !scopedDirectories ? folderPresent : currentPath == "/fixture" && folderPresent || movedFolderDirectory == currentPath }
        func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { throw Failure.scope }
        func page(_ generation: UUID,snapshot:SFTPStoredSnapshot,offset:UInt64,sort:SFTPStoredSort,descending:Bool) async throws -> SFTPStoredPage? {
            guard generation == self.generation && offset == 0 else { throw Failure.scope }
            var rows: [SFTPStoredRow] = []
            if visibleFolder { rows.append(.init(observation:1,entry:.init(name:try .init(Data(folderName.utf8)),logicalBytes:0,modifiedSeconds:0,permissions:0o040755))) }
            if visibleFile { rows.append(.init(observation:2,entry:.init(name:try .init(Data(fileName.utf8)),logicalBytes:fileBytes,modifiedSeconds:0,permissions:0o100644))) }
            for (index, name) in createdFolders.enumerated() { rows.append(.init(observation:UInt64(index + 3),entry:.init(name:try .init(Data(name.utf8)),logicalBytes:0,modifiedSeconds:0,permissions:0o040755))) }
            for (index, name) in createdText.enumerated() { rows.append(.init(observation: UInt64(index + createdFolders.count + 3), entry: .init(name: try .init(Data(name.utf8)), logicalBytes: 0, modifiedSeconds: 0, permissions: 0o100600))) }
            for (index, name) in visibleCopies.enumerated() {
                rows.append(.init(observation: UInt64(index + createdFolders.count + createdText.count + 3),
                    entry: .init(name: try .init(Data(name.utf8)), logicalBytes: fileBytes, modifiedSeconds: 0, permissions: 0o100644)))
            }
            rows.sort { descending ? $1.entry.name.wireUTF8.lexicographicallyPrecedes($0.entry.name.wireUTF8) : $0.entry.name.wireUTF8.lexicographicallyPrecedes($1.entry.name.wireUTF8) }
            return .init(request:UUID(),generation:generation,snapshot:snapshot,offset:0,rows:rows)
        }
        func observedActionDirectory(for intent: SFTPRemoteActionIntent) async throws -> SFTPDefaultDirectory {
            guard allowsServerCopy, intent.generation == generation else { throw SFTPBrowserFailure.stale }
            return try .init(field: currentPath.hasPrefix("/") ? currentPath : "/fixture", root: .server)
        }
        func performRemoteAction(_ intent: SFTPRemoteActionIntent, store: SFTPRemoteActionStore) async throws -> SFTPRemoteActionResult {
            guard allowsRemoteActions, intent.generation == generation else { throw Failure.scope }
            actions += 1
            var key = Data(); try SFTPWire.field(Data("ssh-ed25519".utf8), into: &key); try SFTPWire.field(Data(repeating: 1, count: 32), into: &key)
            let context = SFTPVerifiedSessionContext(host: "generated.invalid", port: 22, requestedScopeID: 0,
                account: "generated", key: try .init(key), previous: nil, permitsRememberingHost: false)
            let started = try await store.prepare(intent, context: context, directory: scopedDirectories ? currentPath : "/fixture")
            if (intent.kind == .moveFile || intent.kind == .moveDirectory || intent.kind == .copyFile), intent.destinationDirectory?.fieldText == "/occupied" {
                return try await store.update(started.record.id, outcome: .failedSafe, refusal: .targetExists)
            }
            if let destination = intent.destinationName?.displayName {
                let target = intent.kind == .copyFile ? intent.destinationDirectory?.fieldText ?? "" : currentPath
                let baseline = target == "/fixture" || !scopedDirectories && intent.kind != .copyFile
                if copiedFiles[target]?.contains(destination) == true
                    || baseline && (destination == folderName || createdFolders.contains(destination) || (filePresent && destination == fileName)) {
                    return try await store.update(started.record.id, outcome: .failedSafe, refusal: .targetExists)
                }
            }
            if intent.kind == .deleteEmptyDirectoryPermanently, intent.row?.entry.name.displayName == "Folder on server" {
                return try await store.update(started.record.id, outcome: .failedSafe, refusal: .notEmpty)
            }
            let marked = try await store.update(started.record.id, outcome: .needsReview)
            if intent.name?.displayName == "Uncertain Folder" || intent.destinationDirectory?.fieldText == "/uncertain" {
                let ended = await close()
                if ended.localResourcesEnded { await store.releaseAfterDrain(started.record.id) }
                return marked
            }
            switch intent.kind {
            case .copyFile:
                guard allowsServerCopy, let name = intent.destinationName?.displayName else { throw Failure.scope }
                guard let target = intent.destinationDirectory?.fieldText else { throw Failure.scope }
                copiedFiles[target, default: []].append(name)
            case .newFolder: createdFolders.append(intent.name!.displayName)
            case .renameFile: fileName = intent.destinationName!.displayName
            case .renameDirectory: folderName = intent.destinationName!.displayName
            case .moveFile: filePresent = false; movedFileDirectory = intent.destinationDirectory?.fieldText
            case .moveDirectory: folderPresent = false; movedFolderDirectory = intent.destinationDirectory?.fieldText
            case .deleteFilePermanently: filePresent = false
            case .deleteEmptyDirectoryPermanently:
                guard let name = intent.row?.entry.name.displayName, let index = createdFolders.firstIndex(of: name) else { throw Failure.scope }
                createdFolders.remove(at: index)
            }
            return try await store.update(started.record.id, outcome: .confirmed)
        }
        func upload(_ request:SFTPRequestedUpload,snapshot:SFTPStoredSnapshot,storage:SFTPUploadStorage,excluding roots:[URL],progress:(@Sendable(UInt64)->Void)?) async throws -> SFTPCompletedUpload {
            guard request.generation == generation, let stamp = request.expectedSource else { throw Failure.scope }
            names.append(request.name.displayName); let bytes = UInt64(stamp.size); progress?(bytes); return .init(id:UUID(),logicalBytes:bytes)
        }
        func uploadEditedText(_ request: SFTPRequestedEditedTextUpload, snapshot: SFTPStoredSnapshot,
            storage: SFTPUploadStorage, progress: (@Sendable (UInt64) -> Void)?) async throws -> SFTPTextFreshCopyReceipt {
            guard request.destinationGeneration == generation, request.snapshot.logicalBytes == 0,
                  !createdText.contains(request.name.displayName), request.name.displayName != fileName,
                  request.name.displayName != folderName else { throw Failure.scope }
            createdText.append(request.name.displayName); names.append(request.name.displayName)
            return try .init(.init(id: UUID(), logicalBytes: 0), snapshot: request.snapshot)
        }
        func uploadFolder(_ request:SFTPRequestedFolderUpload,snapshot:SFTPStoredSnapshot,storage:SFTPUploadStorage,excluding roots:[URL],progress:(@Sendable(UInt64,Int)->Void)?) async throws -> SFTPCompletedFolderUpload {
            guard request.generation == generation else { throw Failure.scope }
            let source = request.source; names.append(request.name.displayName); progress?(source.logicalBytes,source.files)
            return .init(id:UUID(),files:source.files,folders:source.folders,logicalBytes:source.logicalBytes)
        }
        func close() async -> SFTPWorkerClose {
            resumeDirectoryOpen()
            if closeDelayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(closeDelayMilliseconds)) }
            return .init(actualExit:true,exitStatus:0,ipcEOF:true,contained:false,protocolValid:true,terminal:nil,temporaryStoreRemoved:true)
        }
    }
    @MainActor private final class Info: NSObject,NSDraggingInfo {
        let draggingPasteboard:NSPasteboard, draggingSource:Any?, draggingSequenceNumber:Int, draggingSourceOperationMask:NSDragOperation
        var draggingDestinationWindow:NSWindow?, draggingLocation:NSPoint = .zero
        var draggedImageLocation:NSPoint { .zero }; nonisolated var draggedImage:NSImage? { nil }
        var draggingFormation:NSDraggingFormation = .none, animatesToDestination = false, numberOfValidItemsForDrop = 0
        var springLoadingHighlight:NSSpringLoadingHighlight { .none }
        init(_ board:NSPasteboard,source:Any?,sequence:Int,allowed:NSDragOperation = .copy) { draggingPasteboard=board;draggingSource=source;draggingSequenceNumber=sequence;draggingSourceOperationMask=allowed }
        func slideDraggedImage(to screenPoint:NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination:URL)->[String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts:NSDraggingItemEnumerationOptions,for view:NSView?,classes classArray:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:@escaping(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
    }
}
#endif
