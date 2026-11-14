#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage
import FileMemory

@MainActor private final class NestedDiagnosticControl: NSObject {
    private var depth = 0
    private let sender = NSButton(title: "Generated control", target: nil, action: nil)
    private(set) var preservesParent = true
    @objc func reenter(_ input: Any?) {
        let preceding = ApplicationDiagnostics.shared.currentTrace
        depth += 1
        if depth < 20 { _ = NSApplication.shared.sendAction(#selector(reenter(_:)), to:self, from:sender) }
        if ApplicationDiagnostics.shared.currentTrace != preceding { preservesParent = false }
        depth -= 1
    }
    func run() { _ = NSApplication.shared.sendAction(#selector(reenter(_:)),to:self,from:sender) }
}

@MainActor enum HelpDiagnosticsVerification {
    static func run() async {
        var controller: BrowserWindowController?
        var recorder: DiagnosticRecorder?
        var namesOwner: ApplicationPrivateNames?
        do {
            guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let root = URL(fileURLWithPath: text)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
                  root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else { throw Failure.scope }
            let source = root.appendingPathComponent("source/Source/Generated-private-name.txt")
            let destination = root.appendingPathComponent("source/Destination")
            let logger = DiagnosticRecorder(directory: root.appendingPathComponent("state/diagnostics"),
                limits: try .init(bytes: 64 << 10, segmentBytes: 8 << 10), recording: true)
            recorder = logger; ApplicationDiagnostics.shared.configureForVerification(logger)
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.navigationStyle = .glass; settings.glassFileContent = true
            InterfacePresentation.shared.bind(settings)
            let owner = BrowserWindowController(settings: settings); controller = owner
            let browser = owner.browser
            browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            browser.recoverableFileOperations = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/operations"))
            browser.operationErrorPresenter = { _ in }
            browser.operationResultPresenter = { _ in }
            owner.window?.setFrameOrigin(.init(x: -12000,y: -12000))
            owner.beginBrowsing(); browser.navigate(to: .directory(destination))
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            try require(NSApplication.shared is TraverseApplication, "The ordinary native action observer is not installed")
            let nested = NestedDiagnosticControl(); nested.run()
            try require(nested.preservesParent && ApplicationDiagnostics.shared.currentTrace == nil,
                "Nested control dispatch corrupted its parent correlation at the bounded depth")
            let help = BrowserMenus.menu(.help, target: browser)
            try require(help.items.contains { $0.title == "App Logs…" } && help.items.contains { $0.title == "About Traverse…" }
                && help.items.contains { $0.title == "Check for Updates…" }
                && help.items.contains { $0.title == "Report a Bug ↗" }, "Help does not expose the requested actions")
            let trace = ApplicationDiagnostics.shared.begin(.copy, command: .copy)
            ApplicationDiagnostics.shared.push(trace)
            browser.beginFileOperation(.copy(sources: [source], destinationDirectory: destination),
                title: "Generated-private-title-must-not-be-logged", roots: [source,destination])
            ApplicationDiagnostics.shared.pop()
            try await wait { browser.operationTask == nil && browser.lastOperationResult != nil }
            try require(browser.lastOperationResult?.disposition == .succeeded, "Actual native Copy did not finish")
            try require(browser.operationHistory.diagnosticTrace == trace,
                "The completed transfer lost its own diagnostic reference")
            await logger.flush()
            guard let copied = browser.lastOperationResult, let parent = owner.window else { throw Failure.scope }
            browser.showOperationResultSheet(copied)
            guard let resultSheet = parent.attachedSheet,
                  let logs = findButton("App Logs…", in: resultSheet.contentView), logs.isEnabled else {
                throw UIVerification.Failure(message: "Actual Results has no reachable App Logs action")
            }
            // A newer review/command must not replace this sheet's captured job.
            browser.operationHistory.diagnosticTrace = UUID()
            logs.performClick(nil)
            try await wait { parent.attachedSheet == nil
                && TraverseHelpController.shared.page == .diagnostics
                && TraverseHelpController.shared.history.traceFilter == trace
                && !TraverseHelpController.shared.history.working }
            try require(TraverseHelpController.shared.history.events.contains { $0.trace == trace },
                "Results opened unrelated or empty operation logs")
            browser.operationHistory.diagnosticTrace = trace
            TraverseHelpController.shared.history.followOperation(nil)
            TraverseHelpController.shared.window?.close()
            guard let recordID = browser.lastRecoveryRecordID else {
                throw UIVerification.Failure(message: "Actual Copy lost its recovery identity")
            }
            browser.openOperationRecovery(recordID: recordID)
            try await wait { browser.recoveryWindow?.selectedRecordID == recordID }
            guard let recovery = browser.recoveryWindow?.window,
                  let recoveryLogs = findButton("App Logs…", in: recovery.contentView), recoveryLogs.isEnabled else {
                throw UIVerification.Failure(message: "Recovery has no selected-operation App Logs action")
            }
            if ProcessInfo.processInfo.arguments.contains("--record-help-motion"), CGPreflightScreenCaptureAccess() {
                let originalSize = settings.interfaceSize
                recovery.title = "Operation Recovery · generated review"
                recovery.center(); recovery.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                for percent in [100, 150] {
                    settings.interfaceSize = .init(percent)
                    try await Task.sleep(for: .milliseconds(160))
                    recovery.contentView?.layoutSubtreeIfNeeded()
                    guard let content = recovery.contentView else { throw Failure.scope }
                    let rect = recoveryLogs.convert(recoveryLogs.bounds, to: content)
                    try require(InterfacePresentation.shared.size.percent == percent
                        && content.bounds.insetBy(dx: -1, dy: -1).contains(rect) && !recoveryLogs.isHidden,
                        "Recovery App Logs is clipped at the selected interface size")
                    try await GlassVerification.captureOwnedWindow(recovery,
                        to: root.appendingPathComponent("evidence/recovery-app-logs-\(percent).png"))
                }
                settings.interfaceSize = originalSize
            }
            browser.operationHistory.diagnosticTrace = UUID()
            recoveryLogs.performClick(nil)
            try await wait { TraverseHelpController.shared.history.traceFilter == recordID
                && !TraverseHelpController.shared.history.working }
            let scopedEvents = TraverseHelpController.shared.history.events
            let linkedWorkers = Set(scopedEvents.filter { $0.trace == trace && $0.action == .fileOperation && $0.phase == .admitted }.compactMap(\.relatedTrace))
            try require(!linkedWorkers.isEmpty
                && scopedEvents.contains { linkedWorkers.contains($0.trace) && $0.relatedTrace == recordID && $0.ordinal != nil }
                && !scopedEvents.contains { $0.trace == trace && $0.relatedTrace == recordID },
                "Recovery did not follow the recorded job's linked logs")
            browser.operationHistory.diagnosticTrace = trace
            TraverseHelpController.shared.history.followOperation(nil)
            TraverseHelpController.shared.window?.close()
            recovery.close()
            do {
                _ = try await browser.recoverableFileOperations!.prepareTransfer(
                    sources: [root.appendingPathComponent("source/Generated-absent-file")], destinationDirectory: destination, move: false)
                throw UIVerification.Failure(message: "The missing-source control was accepted")
            } catch let failure as FileOperationFailure {
                try require(failure == .notFound, "The actual missing-source failure changed its operation outcome")
            }
            browser.showOperationError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey:"generated-secret-error-body",NSFilePathErrorKey:source.path]))
            browser.showOperationError(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                userInfo: [NSLocalizedDescriptionKey:"generated-secret-outer-error",NSUnderlyingErrorKey:
                    NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: [NSFilePathErrorKey:source.path])]))
            let names = ApplicationPrivateNames(directory: root.appendingPathComponent("state/generated-names"), settings: settings)
            namesOwner = names
            let item = try await names.save(AuthoredNames(nickname: "Generated-private-description", labels: ["generated-secret-label"]),
                source: source, id: nil, revision: nil, access: nil, allowFollowing: true)
            try await names.removeAccess(item)
            try require(try await names.forget(item) == .forgotten, "Generated saved-name Forget did not finish")
            await names.close(); namesOwner = nil
            await logger.flush()
            var page = try await logger.page(limit: 256)
            var events = page.events, cursor = page.next
            while let next = cursor {
                try require(events.count <= 512, "The generated log exceeded its bounded test inventory")
                let older = try await logger.page(before: next, limit: 256)
                events += older.events; cursor = older.next
            }
            try require(events.contains { $0.command == .copy && $0.phase == .requested }, "Command admission is missing")
            try require(events.contains { $0.action == .fileOperation && $0.ordinal != nil && $0.phase == .verifying }
                && events.contains { $0.relatedTrace != nil && $0.trace == trace }, "Worker stages lost their command/job correlation")
            try require([DiagnosticPhase.resolving,.preparing,.verifying,.dispatched].allSatisfy { phase in
                events.contains { $0.trace == trace && $0.action == .queue && $0.phase == phase }
            }, "Queued Copy did not distinguish access, source, destination and execution admission")
            try require(events.contains { $0.trace == trace && $0.context?.checkpoint == .queueStart
                && $0.context?.flags.contains(.sourceObserved) == true && $0.context?.flags.contains(.destinationObserved) == true },
                "Queued execution lost its exact admission checkpoint and observed-state snapshot")
            try require(events.contains { $0.action == .fileOperation && $0.phase == .completed }
                && events.contains { $0.error?.domain == .posix && $0.error?.code == Int64(EACCES) }, "Results or errors are missing")
            try require(events.contains { $0.error?.symbol == "fileReadNoPermission" && $0.causes?.first?.symbol == "EPERM" },
                "Canonical error and underlying numeric OS cause are missing")
            try require(events.contains { $0.context?.checkpoint == .nativeStatus && $0.error?.symbol == "ENOENT" && $0.ordinal != nil },
                "Actual native filesystem failure lost its job, stage and errno")
            try require([DiagnosticAction.privateNames,.removeAccess,.forget].allSatisfy { action in
                events.contains { $0.action == action && $0.phase == .completed }
            }, "Saved-name authoring/access/Forget outcomes are missing")
            TraverseHelpController.shared.show(.diagnostics, from: browser, offscreen: true)
            try await wait { !TraverseHelpController.shared.history.events.isEmpty && !TraverseHelpController.shared.history.working }
            try require(TraverseHelpController.shared.window?.contentViewController is ToolWindowChrome,
                "Help did not use the shared glass/window policy")
            try await verifyLogControlsFit()
            do {
                let original = settings.interfaceSize
                defer { settings.interfaceSize = original }
                settings.interfaceSize = .init(150)
                try await Task.sleep(for: .milliseconds(150))
                try await verifyLogControlsFit()
            }
            let logModel = TraverseHelpController.shared.history
            guard let selected = logModel.events.first(where: { $0.trace == trace && $0.phase == .completed }) else {
                throw UIVerification.Failure(message: "The completed Copy trace is missing from App Logs")
            }
            logModel.errorsOnly = true
            logModel.selected = selected.id; logModel.followOperation(trace)
            try await wait { !logModel.working }
            try require(!logModel.errorsOnly && logModel.selected == selected.id
                && logModel.events.contains(where: { $0.id == selected.id }),
                "Following the operation lost the selected entry")
            let scopedExport = root.appendingPathComponent("evidence/operation-diagnostic-export.json")
            guard case .saved(let scopedCount, _, _) = await logger.export(to: scopedExport, retainingAccess: (), scope: .operation(trace)),
                  scopedCount > 0 else { throw Failure.export }
            let scopedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: scopedExport)) as? [String: Any]
            try require(scopedObject?["scope"] as? String == "operation", "Operation export lost its scope")
            logModel.followOperation(nil); try await wait { !logModel.working }
            await logger.flush()
            let count = try await logger.page(limit: 256).events.count
            logger.setRecording(false)
            ApplicationDiagnostics.shared.event(.settings,.requested)
            await logger.flush(); page = try await logger.page(limit: 256)
            try require(page.events.count == count && !logger.status.recording, "Pausing did not stop new records")
            let exported = root.appendingPathComponent("evidence/diagnostic-export.json")
            guard case .saved = await logger.export(to: exported, retainingAccess: ()) else { throw Failure.export }
            let bytes = try Data(contentsOf: exported), string = String(decoding: bytes, as: UTF8.self)
            try require(!string.contains(source.path) && !string.contains("Generated-private") && !string.contains("generated-secret")
                && !string.contains("userInfo"), "The export disclosed sensitive input")
            if ProcessInfo.processInfo.arguments.contains("--record-help-motion"), let help = TraverseHelpController.shared.window {
                owner.window?.center(); owner.showWindow(nil)
                help.title = "Traverse Help · generated review"
                help.center(); help.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
                for (name,target) in [("help-release",TraverseHelpPage.whatsNew),("help-logs",.diagnostics),("help-support",.support),("help-about",.about)] {
                    let movie = try await NativeMotionRecorder.record(window:help,root:root,label:name,
                        sampling: .diagnostic(for: help)) {
                        TraverseHelpController.shared.page = target
                    }
                    try JSONEncoder().encode(movie).write(to:root.appendingPathComponent("evidence/" + name + ".json"),options:.withoutOverwriting)
                }
            }
            try await logger.clear()
            try require(try await logger.page().events.isEmpty, "Explicit Clear left current history visible")
            try require(try Data(contentsOf: destination.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source),
                "Diagnostic Clear changed a copied file")
            let history = try await browser.recoverableFileOperations!.inspectExistingHistory()
            try require(history.records.contains { $0.canUndo }, "Diagnostic Clear changed Undo history")
            let marker = root.appendingPathComponent("state/diagnostics/owner.json")
            let markerBytes = try Data(contentsOf:marker)
            try FileManager().moveItem(at:marker,to:root.appendingPathComponent("evidence/retained-owner.json"))
            try markerBytes.write(to:marker,options:.withoutOverwriting)
            try require(chmod(marker.path,0o600) == 0,"Generated marker permissions")
            logger.setRecording(true); logger.record(.init(session:UUID(),trace:UUID(),action:.diagnostics,phase:.requested))
            await logger.flush()
            try require(logger.status.failure == .changed,"Generated diagnostic failure was not visible")
            TraverseHelpController.shared.show(.diagnostics, from: browser, offscreen: true)
            try await verifyLogControlsFit()
            browser.lastOperationResult = nil
            let second = root.appendingPathComponent("source/Destination2")
            browser.beginFileOperation(.copy(sources:[source],destinationDirectory:second),title:"Copy",roots:[source,second])
            try await wait { !browser.operationCoordinator.transfers.hasOutstandingWork && browser.lastOperationResult != nil }
            try require(browser.lastOperationResult?.disposition == .succeeded
                && (try? Data(contentsOf:second.appendingPathComponent(source.lastPathComponent))) == (try? Data(contentsOf:source)),
                "A failed diagnostic writer affected an actual Copy")
            TraverseHelpController.shared.show(.about, from: browser, offscreen: true)
            try require(TraverseHelpController.shared.page == .about && TraverseHelpPage.about.title == "About", "About is not available in Help")
            TraverseHelpController.shared.window?.close()
            owner.suspendBrowsing(); owner.window?.close(); controller = nil
            await ApplicationDiagnostics.shared.closeAndDrain(); recorder = nil
            let result: [String:Any] = ["passed":true,"groups":16,"events":events.count,
                "actualCopySucceeded":true,"sensitiveInputsExcluded":true,"undoHistoryPreserved":true,
                "copyAfterDiagnosticFailureSucceeded":true,
                "savedNameAccessAndForgetRecorded":true,
                "nestedControlCorrelationPreserved":true,
                "transferAdmissionStagesRecorded":true,
                "rawErrorSymbolsAndUnderlyingCodesRecorded":true,"aboutAvailable":true,
                "actualNativeFailureCodeRecorded":true,
                "operationReviewAndExport":true,
                "actualResultsOpensCapturedOperationLogs":true,
                "actualRecoveryOpensRecordedOperationLogs":true,
                "minimumWindowLogControlsVisible":true,
                "enlargedLogControlsVisible":true,
                "realOSGrants":0,"networkRequests":0]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
                .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        } catch {
            await namesOwner?.close()
            TraverseHelpController.shared.window?.close(); controller?.suspendBrowsing(); controller?.window?.close()
            await recorder?.closeAndDrain(); ApplicationDiagnostics.shared.configureForVerification(nil)
            if let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] {
                let value: [String:Any] = ["passed":false,"failure":String(describing:error)]
                try? JSONSerialization.data(withJSONObject:value).write(to:URL(fileURLWithPath:text).appendingPathComponent("result.json"),options:.withoutOverwriting)
            }
        }
        NSApplication.shared.terminate(nil)
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
    private static func findButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { findButton(title, in: $0) }.first
    }
    private static func verifyLogControlsFit() async throws {
        guard let window = TraverseHelpController.shared.window else { throw Failure.scope }
        let previous = window.frame
        defer { window.setFrame(previous, display: false) }
        window.setFrame(.init(origin: previous.origin, size: window.minSize), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let required: Set<String> = ["help-log-newer","help-log-older","help-log-clear","help-log-export"]
        try await wait { required.isSubset(of: Set(TraverseHelpController.shared.controlFramesForVerification.keys)) }
        try await Task.sleep(for: .milliseconds(80))
        let measured = TraverseHelpController.shared.controlFramesForVerification
        let frames = measured.filter { required.contains($0.key) }
        let size = (window.contentViewController as? ToolWindowChrome)?.children.first?.view.bounds.size ?? .zero
        let visible = NSRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
        if let root = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] {
            let proof: [String:Any] = ["visible":NSStringFromRect(visible),"body":NSStringFromRect(measured["help-body"] ?? .zero),
                "frames":frames.mapValues { NSStringFromRect($0) }]
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted,.sortedKeys]).write(
                to:URL(fileURLWithPath:root).appendingPathComponent("evidence/help-layout-" + UUID().uuidString + ".json"),options:.withoutOverwriting)
        }
        let body = measured["help-body"] ?? .zero
        try require(abs(body.width-size.width) < 2 && abs(body.height-size.height) < 2
            && Set(frames.keys) == required && frames.values.allSatisfy { !$0.isEmpty && visible.contains($0) },
            "App Log export/paging/Clear controls fell outside the minimum window")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 15
        while !condition() { guard ProcessInfo.processInfo.systemUptime < end else { throw Failure.deadline }; try await Task.sleep(for:.milliseconds(10)) }
    }
    private enum Failure: Error { case scope, deadline, export }
}
#endif
