#if DEBUG
import AppKit
import ExplorerCore

/// Appearance has no connection or prepared-transfer token. It can be repeated
/// without using a server session, credentials or a publication destination.
@MainActor enum SFTPFolderPreviewVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 10
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, owner: BrowserWindowController?, preview: SFTPFolderDownloadPreview?
        var pending: Task<SFTPFolderPreviewChoice, Never>?
        do {
            let args = ProcessInfo.processInfo.arguments
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
                  let index = args.firstIndex(of: "--generated-motion"), args.indices.contains(index + 1),
                  let motion = BrowserMotionMode(rawValue: args[index + 1]) else { throw Failure.scope }
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let admitted = URL(fileURLWithPath: raw)
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1" && marker?["action"] as? String == "sftp-folder-preview"
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = admitted
            let large = args.contains("--large-interface"), settings = BrowserSettings(persist: false)
            settings.appearance = large ? .light : .dark; settings.navigationStyle = args.contains("--solid") ? .solid : .glass
            settings.glassFileContent = true; settings.motion.mode = motion; settings.interfaceSize = .init(large ? 150 : 100)
            settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false; settings.autoRefreshFolders = false
            InterfacePresentation.shared.bind(settings)
            let parent = BrowserWindowController(settings: settings); owner = parent
            let browser = parent.browser; browser.readVolumesForVerification = { [] }; browser.permitsBackgroundVerification = true
            browser.tabs = [.init(location: .directory(admitted.appendingPathComponent("source/Destination")))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            guard let window = parent.window else { throw Failure.scope }
            window.setContentSize(.init(width: large ? 1240 : 960, height: 650)); window.center()
            window.title = "Folder review · generated review"; window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            let review = SFTPFolderDownloadPreview(summary: .init(generatedFiles: 3, folders: 2, bytes: 65_570),
                parentPath: admitted.appendingPathComponent("source/Destination").path, name: "Campaign", settings: settings); preview = review
            let choice = Task { @MainActor in await review.choose(in: window) }; pending = choice
            try await wait { window.attachedSheet === review.window }
            guard let panel = review.window else { throw Failure.scope }
            try await Task.sleep(for: .milliseconds(250))
            var clips: [[String: Any]] = []
            for (label, expanded) in [("folder-details-open", true), ("folder-details-close", false)] {
                window.title = "Folder review · generated review"
                let report = try await NativeMotionRecorder.record(window: window, root: admitted, label: label, sampling: .diagnostic(for: window)) { review.model.details = expanded }
                try JSONEncoder().encode(report).write(to: admitted.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window))
            }
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let content = panel.contentView, let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Folder name" }),
                  panel.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.scope }
            window.title = "Folder review · generated review"
            let report = try await NativeMotionRecorder.record(window: window, root: admitted, label: "folder-name-edit", sampling: .diagnostic(for: window)) {
                editor.selectAll(nil); editor.insertText("Generated copy", replacementRange: .init(location: 0, length: field.stringValue.utf16.count))
            }
            try require(review.model.name == "Generated copy" && review.model.valid)
            try JSONEncoder().encode(report).write(to: admitted.appendingPathComponent("evidence/folder-name-edit.json"), options: .withoutOverwriting)
            var clip = DevelopmentMotionVerification.clip("folder-name-edit", report: report, field: nil, window: window)
            let screen = panel.convertToScreen(field.convert(field.bounds, to: nil))
            clip["fieldRegion"] = ["x": screen.minX - window.frame.minX, "y": window.frame.maxY - screen.maxY, "width": screen.width, "height": screen.height]
            clips.append(clip)
            review.model.name = "../refused"; try require(!review.model.valid); review.model.name = "Generated copy"
            review.model.expired = true; try await Task.sleep(for: .milliseconds(80)); try require(review.model.expired)
            review.finish(.cancel)
            guard case .cancel = await choice.value else { throw Failure.scope }; pending = nil
            try require(window.attachedSheet == nil && browser.operationTask == nil && browser.operationPreparationTask == nil
                && browser.sftpTabs.isEmpty && browser.smbTabs.isEmpty)
            try write(["passed": true, "clips": clips, "motion": motion.rawValue, "interfacePercent": settings.interfaceSize.percent,
                "glass": settings.navigationStyle == .glass, "nativeFieldEdited": true, "invalidNameRefused": true, "expiredReviewVisible": true,
                "cancelDrained": true, "networkRequests": 0, "keychainCalls": 0, "sourceBodyReads": 0, "transferAuthority": false], root: admitted)
        } catch {
            preview?.finish(.cancel); _ = await pending?.value
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "line": line, "errorType": String(reflecting: type(of: error))], root: root) }
        }
        owner?.window?.close(); NSApplication.shared.terminate(nil)
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("evidence/native-folder-download.json"), options: .withoutOverwriting)
    }
}
#endif
