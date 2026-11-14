#if DEBUG
import AppKit
import ExplorerCore
import FileOperations

/// Real app command paths, absent state parent and no preference persistence.
@MainActor
enum StatePreparationVerification {
    static func run(root: URL) async throws -> [String: Any] {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repository.deleteLastPathComponent() }
        try UIVerification.require(root.deletingLastPathComponent() == repository.appendingPathComponent(".build/fixtures")
            && root.lastPathComponent.hasPrefix("first-use-") && root.resolvingSymlinksInPath() == root,
            "Only the explicit generated first-use root is admitted")
        let marker = try await Task.detached { try Data(contentsOf: root.appendingPathComponent(".fixture-owner")) }.value
        try UIVerification.require(marker == Data("mac-explorer-first-use-v1".utf8), "Generated first-use marker missing")
        let coordinator = ApplicationOperationCoordinator.shared, queue = coordinator.transfers
        try UIVerification.require(queue.isIdleForCopyPreview && coordinator.activeOwner == nil, "First-use requires idle ownership")
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
        let browser = BrowserViewController(settings: settings)
        browser.permitsBackgroundVerification = true
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        let window = BrowserWindow(contentRect: .init(x: 80, y: 100, width: 1000, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.browser = browser; window.contentViewController = browser
        var errors: [String] = []
        browser.operationErrorPresenter = { errors.append($0) }; browser.operationResultPresenter = { _ in }
        defer { browser.suspendBrowser(); window.close() }
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
        func wait(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try UIVerification.require(condition(), message)
        }
        let files = root.appendingPathComponent("Files"), destination = files.appendingPathComponent("Destination")
        browser.navigate(to: .directory(files))
        try await wait("First-use listing") { !browser.isLoading && browser.orderingTask == nil }
        var checks: [String] = []
        for command in ["Copy", "Rename", "New Folder"] {
            let state = root.appendingPathComponent("state-" + command.replacingOccurrences(of: " ", with: ""))
            let engine = coordinator.engine(at: state.appendingPathComponent("history"))
            browser.recoverableFileOperations = engine
            let history = try await engine.inspectExistingHistory()
            try UIVerification.require(history.readiness == .absent && !FileManager().fileExists(atPath: state.path),
                "Passive inspection created state")
            let source = files.appendingPathComponent(command + ".txt")
            if command == "Copy" {
                let selection = try await browser.fileOperations.observeSelection([source])
                browser.beginRecoverableOperation(.copy(sources: [source], destinationDirectory: destination), title: "First Copy",
                    roots: [source, destination], observing: selection, engine: engine)
                try await wait("First-use Copy did not drain") { queue.isIdleForCopyPreview }
                try UIVerification.require(queue.results.last?.outcome.result.disposition == .succeeded
                    && FileManager().fileExists(atPath: destination.appendingPathComponent("Copy.txt").path),
                    "First queued Copy failed without preferences: " + (queue.results.last?.contextDescription ?? "no result"))
            } else {
                let request: FileOperationRequest = command == "Rename" ? .rename(source: source, name: "Renamed.txt")
                    : .createFolder(parent: files, name: "Created Folder")
                let observation = command == "Rename" ? try await browser.fileOperations.observeSelection([source])
                    : try await browser.fileOperations.observeDirectory(files)
                browser.beginRecoverableOperation(request, title: "First " + command, roots: [files], observing: observation, engine: engine)
                try await wait("First-use exclusive command did not drain") { browser.operationTask == nil }
                try UIVerification.require(browser.lastOperationResult?.disposition == .succeeded && errors.isEmpty,
                    "First exclusive command failed without preferences")
            }
            try UIVerification.require(FileManager().fileExists(atPath: state.path), "Explicit command did not prepare state")
            let records = try await engine.inspectExistingHistory()
            try UIVerification.require(records.records.count == 1, "First-use history did not retain one result")
            checks.append("passive absence then first " + command + " through native app routing")
        }
        browser.recoveryInspectionTask?.cancel()
        try await wait("First-use ownership did not drain") { coordinator.activeOwner == nil && coordinator.inspectionCount == 0 }
        try UIVerification.require(ApplicationFileActivity.gate.activeCount == 0, "First-use activity retained")
        return ["passed": true, "checks": checks, "gate_active": ApplicationFileActivity.gate.activeCount,
            "preferences_saved": false, "owner_history_modified": false]
    }
}
#endif
