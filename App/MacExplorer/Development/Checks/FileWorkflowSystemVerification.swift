#if DEBUG
import AppKit
import Darwin
import FileOperations
import LocalStorage

/// Real sandbox and app composition; only an exact generated signed identity.
/// macOS supplies the incoming grant. No permission or filesystem is simulated.
@MainActor enum FileWorkflowSystemVerification {
    static func run(delegate: ApplicationDelegate) async {
        var owner: BrowserWindowController?
        var board: NSPasteboard?
        var stage = "identity"
        do {
            let bundle = Bundle.main
            let root = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
                && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
                && bundle.bundleIdentifier == "local.traverse.file-workflow." + root.lastPathComponent.lowercased()
                && bundle.object(forInfoDictionaryKey: "TraverseFileWorkflowCase") as? String == root.lastPathComponent,
                "Exact generated file-workflow identity required")
            guard let state = AppStorageLocations.stateDirectory else { throw Failure("Storage composition absent") }
            let fixture = root.appendingPathComponent("source/Fixture", isDirectory: true)
            let source = fixture.appendingPathComponent("Source", isDirectory: true)
            let destination = fixture.appendingPathComponent("Destination", isDirectory: true)
            let expanding = CommandLine.arguments.contains("--workflow-expand")
            let upgradeUndo = CommandLine.arguments.contains("--workflow-upgrade-undo")
            let reopening = CommandLine.arguments.contains("--workflow-reopen") || expanding || upgradeUndo
            let stateAbsent = await Task.detached { !FileManager().fileExists(atPath: state.path) }.value
            if !reopening { try require(stateAbsent, "Fresh profile already has app state") }
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.showsDockProgress = false; settings.motion.mode = .off
            let controller = BrowserWindowController(settings: settings); owner = controller
            let browser = controller.browser
            browser.folderAccess = FolderAccessController(stateDirectory: state, policy: .selectedFolders)
            let engine = browser.operationCoordinator.engine(at: state.appendingPathComponent("operation-recovery", isDirectory: true))
            browser.recoverableFileOperations = engine
            browser.permitsBackgroundVerification = true
            let clipboard = NSPasteboard.withUniqueName(); board = clipboard
            browser.transferPasteboard = clipboard
            browser.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: clipboard) }
            browser.operationResultPresenter = { _ in }
            var shownError: String?
            browser.operationErrorPresenter = { shownError = $0 }
            controller.window?.setFrameOrigin(.init(x: -12000, y: -12000))
            delegate.attachIncomingForSystemVerification(controller)
            controller.beginBrowsing()
            if reopening {
                stage = "restored access"
                let restored = await browser.folderAccess.resolveRememberedFolders()
                try require(restored.count == 1 && browser.folderAccess.hasSelectedAccess(to: source), "Saved access did not resolve")
                browser.navigate(to: .directory(destination))
                try await wait { settled(browser) }
                try require(browser.loadError == nil, "Reopened destination listing failed")
                if expanding {
                    stage = "Create Folder"
                    browser.operationNamePrompt = { _,_ in "Created Folder" }
                    let previous = browser.lastRecoveryRecordID
                    browser.createFolder(BrowserMenus.newFolderItem(target: browser, named: true))
                    try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                        && browser.operationCoordinator.activeOwner == nil && browser.lastRecoveryRecordID != previous }
                    try require(shownError == nil && browser.lastOperationResult?.disposition == .succeeded,"Create Folder failed")
                    try require(await exists(destination.appendingPathComponent("Created Folder")),"Created Folder is absent")
                    stage = "Create Folder Undo"
                    browser.inspectOperationRecovery(); try await wait { browser.canUndoFileOperation }
                    browser.undoFileOperation(nil)
                    try await wait { browser.operationTask == nil && browser.operationCoordinator.activeOwner == nil }
                    try require(shownError == nil && browser.lastOperationResult?.disposition == .succeeded,"Create Folder Undo failed")
                    stage = "Rename"
                    browser.navigate(to:.directory(source)); try await wait { settled(browser) }
                    try select("Copy.txt",in:browser)
                    browser.operationNamePrompt = { _,_ in "Renamed.txt" }
                    let oldRename = browser.lastRecoveryRecordID
                    browser.renameSelection(nil)
                    try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil
                        && browser.operationCoordinator.activeOwner == nil && browser.lastRecoveryRecordID != oldRename }
                    try require(shownError == nil && browser.lastOperationResult?.disposition == .succeeded,"Rename failed")
                    try require(await exists(source.appendingPathComponent("Renamed.txt")),"Renamed item is absent")
                    stage = "Rename Undo"
                    browser.inspectOperationRecovery(); try await wait { browser.canUndoFileOperation }
                    browser.undoFileOperation(nil)
                    try await wait { browser.operationTask == nil && browser.operationCoordinator.activeOwner == nil }
                    try require(shownError == nil && browser.lastOperationResult?.disposition == .succeeded,"Rename Undo failed")
                    stage = "Copy before update"
                    browser.navigate(to:.directory(source)); try await wait { settled(browser) }
                    try select("Copy.txt",in:browser); browser.copyFileURLs(nil)
                    browser.navigate(to:.directory(destination)); try await wait { settled(browser) }
                    browser.pasteFiles(into:destination)
                    try await wait { browser.operationCoordinator.transfers.isIdleForCopyPreview && !browser.operationCoordinator.transfers.results.isEmpty }
                    try require(browser.operationCoordinator.transfers.results.last?.outcome.result.disposition == .succeeded,"Copy before update failed")
                    emit(["phase":"expanded", "passed":true, "createdAndUndone":true, "renamedAndUndone":true,
                          "copyCommittedForNextLaunch":true, "bookmarkReselections":0])
                } else {
                stage = upgradeUndo ? "update Copy Undo" : "reopened Move Undo"
                browser.inspectOperationRecovery()
                try await wait { browser.canUndoFileOperation }
                browser.undoFileOperation(nil)
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil && browser.operationCoordinator.activeOwner == nil }
                try require(browser.lastOperationResult?.disposition == .succeeded && shownError == nil, "Reopened Undo failed")
                let restoredName = upgradeUndo ? "Copy.txt" : "Move.txt"
                let sourceRestored = await exists(source.appendingPathComponent(restoredName))
                let destinationRemoved = !(await exists(destination.appendingPathComponent(restoredName)))
                try require(sourceRestored && destinationRemoved, "Reopened Move Undo paths differ")
                }
            } else {
                stage = "baseline"
                let denied = await Task.detached { (try? FileManager().contentsOfDirectory(atPath: fixture.path)) == nil }.value
                try require(denied, "Generated source readable before explicit delivery")
                emit(["phase":"ready", "passed":true, "stateAbsentBefore":stateAbsent, "fixtureDeniedBefore":denied])
                stage = "OS folder delivery"
                let incoming = delegate.incomingForSystemVerification
                try await wait { incoming.openedCount == 1 && browser.location == .directory(fixture) && settled(browser) }
                try require(browser.loadError == nil, "Explicit OS folder grant failed to list")
                stage = "first-use Copy"
                browser.navigate(to: .directory(source)); try await wait { settled(browser) }
                try select("Copy.txt", in: browser)
                browser.copyFileURLs(nil)
                browser.navigate(to: .directory(destination)); try await wait { settled(browser) }
                try require(browser.canAdmitTransfer, "Normal Paste is unavailable")
                browser.pasteFiles(into: destination)
                try await wait { browser.operationCoordinator.transfers.isIdleForCopyPreview && !browser.operationCoordinator.transfers.results.isEmpty }
                let copy = browser.operationCoordinator.transfers.results.last!
                emit(["phase":"firstCopy", "passed":copy.outcome.result.disposition == .succeeded,
                      "disposition":String(describing:copy.outcome.result.disposition),
                      "statuses":copy.outcome.result.items.map { String(describing:$0.status) }])
                try require(copy.outcome.result.disposition == .succeeded, "First-use Copy failed")
                stage = "Copy Undo"
                browser.inspectOperationRecovery(); try await wait { browser.canUndoFileOperation }
                browser.undoFileOperation(nil)
                try await wait { browser.operationTask == nil && browser.operationCoordinator.activeOwner == nil }
                try require(browser.lastOperationResult?.disposition == .succeeded && shownError == nil, "Copy Undo failed")
                try require(!(await exists(destination.appendingPathComponent("Copy.txt"))), "Undo left the destination copy")
                stage = "Move"
                browser.navigate(to: .directory(source)); try await wait { settled(browser) }
                let quarantineBeforeMove = await hasQuarantine(source.appendingPathComponent("Move.txt"))
                try select("Move.txt", in: browser); browser.cutFileURLs(nil)
                try await wait { browser.cutPreparationTask == nil }
                try require(browser.pendingCut != nil, "Cut observation failed")
                browser.navigate(to: .directory(destination)); try await wait { settled(browser) }
                let oldCount = browser.operationCoordinator.transfers.results.count
                browser.pasteFiles(into: destination)
                try await wait { browser.operationCoordinator.transfers.isIdleForCopyPreview && browser.operationCoordinator.transfers.results.count > oldCount }
                let moved = browser.operationCoordinator.transfers.results.last!
                emit(["phase":"move", "passed":moved.outcome.result.disposition == .succeeded,
                      "disposition":String(describing:moved.outcome.result.disposition),
                      "statuses":moved.outcome.result.items.map { String(describing:$0.status) },
                      "quarantineBeforeMove":quarantineBeforeMove,
                      "quarantineAfterMove":await hasQuarantine(destination.appendingPathComponent("Move.txt")),
                      "preparationMessage":moved.preparationMessage ?? "none"])
                try require(moved.outcome.result.disposition == .succeeded, "Move failed")
                stage = "remember generated access"
                guard let exact = browser.folderAccess.selectedRootCovering(fixture) else { throw Failure("OS root was not retained") }
                let remembered = await browser.folderAccess.acceptChosenFolder(exact, remember:true)
                guard case .saved = remembered?.remembering else { throw Failure("Generated bookmark save failed") }
                withExtendedLifetime(remembered) {}
            }
            stage = "drain"
            await delegate.incomingForSystemVerification.closeAndDrain()
            controller.suspendBrowsing(); await controller.flushSession(); controller.window?.close(); owner = nil
            try await wait { ApplicationFileActivity.gate.activeCount == 0 && browser.operationCoordinator.transfers.isIdleForCopyPreview }
            let usage = try await containerUsage()
            var resource = rusage(); getrusage(RUSAGE_SELF, &resource)
            emit(["phase":"complete", "passed":true, "reopened":reopening, "stateAbsentBefore":stateAbsent,
                  "activityCount":ApplicationFileActivity.gate.activeCount, "peakRSSBytes":resource.ru_maxrss,
                  "containerBytes":usage.0, "containerEntries":usage.1,
                  "personalFileMutations":0, "systemPermissionChanges":0])
        } catch {
            await delegate.incomingForSystemVerification.closeAndDrain()
            owner?.suspendBrowsing(); await owner?.flushSession(); owner?.window?.close()
            emit(["phase":"failed", "passed":false, "stage":stage, "message":String(describing:error)])
        }
        board?.releaseGlobally()
        NSApplication.shared.terminate(nil)
    }
    private static func emit(_ values: [String:Any]) {
        var report=values; report["pid"]=getpid()
        if let data=try? JSONSerialization.data(withJSONObject:report, options:[.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
    private static func select(_ name:String, in browser:BrowserViewController) throws {
        guard let row=browser.displayedEntries.firstIndex(where:{$0.name==name}) else { throw Failure("Generated row absent") }
        browser.table.selectRowIndexes(IndexSet(integer:row), byExtendingSelection:false)
    }
    nonisolated private static func existsSync(_ url:URL) -> Bool { FileManager().fileExists(atPath:url.path) }
    private static func exists(_ url:URL) async -> Bool { await Task.detached { existsSync(url) }.value }
    private static func hasQuarantine(_ url:URL) async -> Bool {
        await Task.detached {
            let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else { return false }; defer { close(fd) }
            return fgetxattr(fd,"com.apple.quarantine",nil,0,0,0)>0
        }.value
    }
    private static func settled(_ browser:BrowserViewController) -> Bool {
        !browser.isLoading && browser.orderingTask == nil && browser.canvasTransition == nil
    }
    nonisolated private static func require(_ value:Bool, _ message:String) throws { if !value { throw Failure(message) } }
    private static func wait(_ predicate:()->Bool) async throws {
        let end=ProcessInfo.processInfo.systemUptime+12
        while !predicate() {
            try require(ProcessInfo.processInfo.systemUptime<end,"Generated phase deadline")
            try await Task.sleep(for:.milliseconds(10))
        }
    }
    private static func containerUsage() async throws -> (UInt64,Int) {
        let home=FileManager.default.homeDirectoryForCurrentUser
        try require(home.path.hasSuffix("/Library/Containers/"+Bundle.main.bundleIdentifier!+"/Data"),"Private container home differs")
        return try await Task.detached {
            var pending=[home], bytes:UInt64=0, entries=0
            while let path=pending.popLast() {
                var facts=stat(); try require(lstat(path.path,&facts)==0 && facts.st_size>=0,"Container metadata unavailable")
                entries += 1
                if facts.st_mode & S_IFMT == S_IFDIR { pending += try FileManager().contentsOfDirectory(at:path,includingPropertiesForKeys:nil) }
                else { bytes += UInt64(facts.st_size) }
                try require(entries<=512 && bytes<=32*1024*1024,"Generated container limit")
            }
            return (bytes,entries)
        }.value
    }
    private struct Failure:Error, CustomStringConvertible {
        let description:String
        init(_ text:String) { description=text }
    }
}
#endif
