#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage

@MainActor enum ClipboardAdmissionDiagnosticsVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ condition: Bool, _ line: UInt = #line) throws { if !condition { throw Failure.check(line) } }
    private static func wait(_ condition: () -> Bool, _ line: UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 10
        while !condition() { try require(ProcessInfo.processInfo.systemUptime < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func events(_ recorder: DiagnosticRecorder) async throws -> [DiagnosticEvent] {
        await recorder.flush(); var rows: [DiagnosticEvent] = [], cursor: DiagnosticHistoryCursor?
        repeat {
            let page = try await recorder.page(before: cursor, limit: 256)
            rows += page.events; cursor = page.next
            try require(rows.count <= 1024)
        } while cursor != nil
        return rows
    }
    static func run() async {
        var root: URL?, browser: BrowserViewController?, window: NSWindow?, logger: DiagnosticRecorder?, failedLogger: DiagnosticRecorder?
        var board: NSPasteboard?, checks: [String] = [], failure: UInt?, failureType: String?, sourceDenied = false
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent && marker?["action"] as? String == "clipboard-admission-diagnostics"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = admitted
            let service = DiagnosticRecorder(directory: admitted.appendingPathComponent("state/logs"), limits: try .init(bytes: 512 << 10, segmentBytes: 64 << 10), recording: true)
            logger = service; ApplicationDiagnostics.shared.configureForVerification(service)
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.motion.mode = .off; settings.showsDockProgress = false
            let owner = BrowserViewController(settings: settings); browser = owner; owner.permitsBackgroundVerification = true
            owner.recoverableFileOperations = RecoverableFileOperations(journalDirectory: admitted.appendingPathComponent("state/operations"))
            owner.operationErrorPresenter = { _ in }; owner.operationResultPresenter = { _ in }
            let clipboard = NSPasteboard.withUniqueName(); board = clipboard; owner.transferPasteboard = clipboard
            owner.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: clipboard) }
            let host = NSWindow(contentRect: .init(x: -12000,y: -12000,width: 960,height: 640),styleMask: [.titled,.closable],backing: .buffered,defer: false)
            host.isReleasedWhenClosed = false; host.contentViewController = owner; window = host
            let source = admitted.appendingPathComponent("source/PRIVATE-SOURCE"), file = source.appendingPathComponent("PRIVATE-CLIPBOARD.txt")
            let destination = admitted.appendingPathComponent("source/Destination"), denied = admitted.appendingPathComponent("source/Denied")
            owner.navigate(to: .directory(source))
            try await wait { !owner.isLoading && owner.orderingTask == nil && owner.rowsByURL[file] != nil }
            owner.table.deselectAll(nil)
            let emptyGeneration = clipboard.changeCount
            owner.copyFileURLs(nil)
            let empty = try await events(service)
            try require(clipboard.changeCount == emptyGeneration && empty.contains { $0.context?.checkpoint == .clipboardPublish && $0.phase == .blocked && $0.count == 0 && $0.context?.flags == [.selectionUnavailable] })
            checks.append("Empty Copy preserves the private pasteboard and records a closed selection refusal")
            owner.table.selectRowIndexes(IndexSet(integer: owner.rowsByURL[file]!),byExtendingSelection: false)
            owner.copyFileURLs(nil)
            try require(owner.transferFeedback?.intent == .copy && owner.transferFeedback?.urls == [file])
            let published = try await events(service)
            try require(published.contains { $0.context?.checkpoint == .clipboardPublish && $0.phase == .completed && $0.count == 1 })
            checks.append("Real native publication records a successful one-file receipt without reading the file")
            owner.clipboardWriter = { _,_ in .failed }
            let generation = clipboard.changeCount
            owner.copyFileURLs(nil)
            try require(clipboard.changeCount == generation && owner.transferFeedback == nil)
            try require(try await events(service).contains { $0.context?.checkpoint == .clipboardPublish && $0.phase == .blocked && $0.context?.flags == [.clipboardPublicationFailed] })
            checks.append("A refused publisher preserves native data and is distinguishable from changed context")
            owner.clipboardWriter = { [weak owner] text,urls in
                let result = BrowserClipboard.publish(text,urls: urls,to: clipboard)
                owner?.clipboardRevision = UUID(); return result
            }
            owner.copyFileURLs(nil)
            try require(try await events(service).contains { $0.context?.checkpoint == .clipboardPublish && $0.phase == .blocked && $0.context?.flags == [.contextChanged] })
            checks.append("A reentrant changed publication retains stale rejection and a separate numeric outcome")
            owner.clipboardWriter = { text,urls in BrowserClipboard.publish(text,urls: urls,to: clipboard) }
            owner.navigate(to: .directory(destination)); try await wait { !owner.isLoading && owner.orderingTask == nil }
            _ = BrowserClipboard.publish("PRIVATE-CLIPBOARD-CONTENTS",urls: [],to: clipboard)
            let before = owner.operationCoordinator.transfers.results.count
            owner.pasteFiles(into: destination)
            try require(owner.operationCoordinator.transfers.results.count == before && !owner.operationCoordinator.transfers.hasOutstandingWork
                && owner.status.stringValue == "Copy files or folders before pasting here.")
            try require(try await events(service).contains { $0.context?.checkpoint == .clipboardCapture && $0.phase == .blocked && $0.context?.flags == [.clipboardEmpty] && $0.count == 0 })
            checks.append("Text-only Paste starts no file job and explains the missing file references")
            clipboard.clearContents(); try require(clipboard.writeObjects([NSURL(string:"https://private.invalid/PRIVATE-REMOTE-INPUT")!]))
            owner.pasteFiles(into: destination)
            try require(!owner.operationCoordinator.transfers.hasOutstandingWork && owner.operationCoordinator.transfers.results.count == before)
            checks.append("A non-file native URL cannot become a local file operation")

            // A remote intent is never local-file authority, even when another
            // producer offers both representations on the same private board.
            let mixed = NSPasteboardItem()
            try require(mixed.setString(UUID().uuidString, forType: ScopedItemClipboardIntent.pasteboardType)
                && mixed.setString(file.absoluteString, forType: .fileURL))
            clipboard.clearContents(); try require(clipboard.writeObjects([mixed]))
            let mixedGeneration = clipboard.changeCount
            try require(owner.clipboardState.readFiles(allowOwnedCopy: false) == nil
                && owner.clipboardState.readFiles(allowOwnedCopy: true) == nil)
            owner.pasteFileURLs(nil); owner.pasteWithOptions(nil); owner.moveCopiedFiles(nil)
            try require(!owner.operationCoordinator.transfers.hasOutstandingWork
                && owner.operationCoordinator.transfers.results.count == before
                && owner.operationPreparationTask == nil && owner.operationTask == nil
                && host.attachedSheet == nil && clipboard.changeCount == mixedGeneration)
            checks.append("A mixed remote-intent/local-URL clipboard cannot enter Paste, Paste with Options or Move Copied Items; no job, options sheet or clipboard rewrite occurs")

            // Use the real file clipboard and ordinary queue, not the direct
            // engine entry point or a simulated success callback.
            _ = BrowserClipboard.publish(nil,urls: [file],to: clipboard)
            let paste = #selector(BrowserViewController.pasteFileURLs(_:))
            let sender = NSMenuItem(title: "Paste",action: paste,keyEquivalent: "v")
            try require(NSApplication.shared.sendAction(paste,to: owner,from: sender))
            try await wait { owner.operationCoordinator.transfers.isIdleForCopyPreview && owner.operationCoordinator.transfers.results.count > before }
            try require(owner.operationCoordinator.transfers.results.last?.outcome.result.disposition == .succeeded)
            let copied = try await Task.detached { try Data(contentsOf: destination.appendingPathComponent(file.lastPathComponent)) == Data(contentsOf: file) }.value
            try require(copied)
            let copiedEvents = try await events(service)
            guard let command = copiedEvents.last(where: { $0.command == .paste && $0.phase == .requested }) else { throw Failure.scope }
            let lifetime = copiedEvents.filter { $0.trace == command.trace }
            try require(copiedEvents.contains { $0.context?.checkpoint == .clipboardCapture && $0.phase == .completed && $0.count == 1 }
                && lifetime.contains { $0.context?.checkpoint == .clipboardCapture && $0.phase == .completed && $0.count == 1 }
                && lifetime.contains { $0.context?.checkpoint == .queueAdmission && $0.phase == .admitted && $0.count == 1 }
                && lifetime.contains { $0.relatedTrace != nil && $0.action == .fileOperation })
            owner.inspectOperationRecovery(); try await wait { owner.canUndoFileOperation }
            owner.undoFileOperation(nil); try await wait { owner.operationTask == nil && owner.operationCoordinator.activeOwner == nil }
            try require(owner.lastOperationResult?.disposition == .succeeded)
            try require(await Task.detached { !FileManager().fileExists(atPath: destination.appendingPathComponent(file.lastPathComponent).path) }.value)
            checks.append("Real queued Copy and exact Undo keep their source/destination admission and byte equality")

            let permissionCount = owner.operationCoordinator.transfers.results.count
            owner.navigate(to: .directory(denied)); try await wait { !owner.isLoading && owner.orderingTask == nil }
            _ = BrowserClipboard.publish(nil,urls: [file],to: clipboard); owner.pasteFiles(into: denied)
            try await wait { owner.operationCoordinator.transfers.isIdleForCopyPreview && owner.operationCoordinator.transfers.results.count > permissionCount }
            let noDeniedOutput = await Task.detached { !FileManager().fileExists(atPath: denied.appendingPathComponent(file.lastPathComponent).path) }.value
            try require(owner.operationCoordinator.transfers.results.last?.outcome.result.disposition != .succeeded && noDeniedOutput)
            let permissionEvents = try await events(service)
            try require(permissionEvents.contains { $0.error?.domain == .posix && $0.error?.code == Int64(EACCES) })
            checks.append("An actual unwritable generated destination reaches a drained failed result with its OS code")

            // A failure may intentionally pause the serial queue for review.
            // Resume through the same explicit queue action before a new job.
            owner.operationCoordinator.transfers.resume()
            owner.navigate(to: .directory(destination)); try await wait { !owner.isLoading && owner.orderingTask == nil }
            try await Task.detached { guard chmod(file.path,0) == 0 else { throw Failure.scope } }.value; sourceDenied = true
            let readCount = owner.operationCoordinator.transfers.results.count
            _ = BrowserClipboard.publish(nil,urls: [file],to: clipboard); owner.pasteFiles(into: destination)
            try await wait { owner.operationCoordinator.transfers.isIdleForCopyPreview && owner.operationCoordinator.transfers.results.count > readCount }
            try require(owner.operationCoordinator.transfers.results.last?.outcome.result.disposition != .succeeded)
            try await Task.detached { guard chmod(file.path,0o600) == 0 else { throw Failure.scope } }.value; sourceDenied = false
            checks.append("An actual denied generated source cannot leave the queue indefinitely preparing")

            owner.operationCoordinator.transfers.resume()
            // Result presentation refreshes the folder asynchronously. Dispatch
            // only when the ordinary Paste command is enabled again; a direct
            // call during that refresh is correctly refused before enqueueing.
            try await wait { owner.canAdmitTransfer && owner.orderingTask == nil }
            let retryCount = owner.operationCoordinator.transfers.results.count
            _ = BrowserClipboard.publish(nil,urls: [file],to: clipboard); owner.pasteFiles(into: destination)
            try await wait { owner.operationCoordinator.transfers.isIdleForCopyPreview && owner.operationCoordinator.transfers.results.count > retryCount }
            try require(owner.operationCoordinator.transfers.results.last?.outcome.result.disposition == .succeeded)
            checks.append("A fresh action after restored generated access succeeds without recreating the browser")
            owner.inspectOperationRecovery(); try await wait { owner.canUndoFileOperation }
            owner.undoFileOperation(nil); try await wait { owner.operationTask == nil && owner.operationCoordinator.activeOwner == nil }
            try require(owner.lastOperationResult?.disposition == .succeeded)

            owner.isBrowserSuspended = true
            let blockedBefore = owner.operationCoordinator.transfers.results.count
            owner.pasteFiles(into: destination)
            let blockedEvents = try await events(service)
            try require(owner.operationCoordinator.transfers.results.count == blockedBefore
                && blockedEvents.contains { $0.context?.checkpoint == .queueAdmission && $0.phase == .blocked && $0.context?.flags.contains(.browserSuspended) == true })
            owner.isBrowserSuspended = false
            checks.append("Suspended Paste records its admission state without acquiring clipboard or mutation authority")

            let inaccessible = DiagnosticRecorder(directory: admitted.appendingPathComponent("source/Blocker/logs"),limits: try .init(bytes: 64 << 10,segmentBytes: 8 << 10),recording: true)
            failedLogger = inaccessible; ApplicationDiagnostics.shared.configureForVerification(inaccessible)
            owner.navigate(to: .directory(source)); try await wait { !owner.isLoading && owner.orderingTask == nil && owner.rowsByURL[file] != nil }
            owner.table.selectRowIndexes(IndexSet(integer: owner.rowsByURL[file]!),byExtendingSelection: false)
            owner.copyFileURLs(nil); await inaccessible.flush()
            try require(owner.transferFeedback?.urls == [file] && inaccessible.status.failure != nil)
            ApplicationDiagnostics.shared.configureForVerification(service)
            checks.append("An actually unwritable log cannot prevent a successful native Copy publication")

            let export = admitted.appendingPathComponent("evidence/clipboard-log-export.jsonl")
            guard case .saved = await service.export(to: export,retainingAccess: ()) else { throw Failure.scope }
            let exported = try await Task.detached { try String(contentsOf: export,encoding: .utf8) }.value
            try require(!exported.contains("PRIVATE-") && !exported.contains(admitted.path) && !exported.contains(file.absoluteString)
                && !exported.contains(Data(file.absoluteString.utf8).base64EncodedString()) && !exported.contains("private.invalid")
                && service.status.dropped == 0 && service.status.failure == nil)
            checks.append("Actual export retains causes/counts while excluding file, clipboard, encoded URL and host sentinels")
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }
            failureType = String(describing: type(of: error))
        }
        if let browser {
            browser.operationCoordinator.transfers.cancelAllWaiting()
            _ = browser.operationCoordinator.transfers.stopActive()
            do { try await wait { browser.operationCoordinator.transfers.isIdleForCopyPreview && browser.operationTask == nil && browser.operationCoordinator.activeOwner == nil } }
            catch { failure = failure ?? #line; failureType = failureType ?? "drain" }
            browser.suspendBrowser(); await browser.flushBrowserSession()
        }
        if sourceDenied, let root {
            do { try await Task.detached { guard chmod(root.appendingPathComponent("source/PRIVATE-SOURCE/PRIVATE-CLIPBOARD.txt").path,0o600) == 0 else { throw Failure.scope } }.value }
            catch { failure = failure ?? #line; failureType = failureType ?? "generatedModeRestore" }
        }
        window?.close(); board?.releaseGlobally()
        await logger?.closeAndDrain(); await failedLogger?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        let drained = ApplicationFileActivity.gate.activeCount == 0
        if let root {
            let value: [String:Any] = ["passed": failure == nil && drained,"checks": checks,"line": failure as Any,
                "failureType": failureType as Any,"peakRSSBytes":usage.ru_maxrss,"activityDrained":drained,"personalClipboardReads":0,"physicalInputExercised":false]
            try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-clipboard-diagnostics.json"),options:.withoutOverwriting)
        }
        exit(failure == nil && drained ? 0 : 2)
    }
}
#endif
