#if DEBUG
import AppKit
import ExplorerCore
import LocalStorage

@MainActor
enum AnalysisFolderPickerVerification {
    private struct TestFailure: Error {}
    private final class Reader: AnalysisPickerReading, @unchecked Sendable {
        final class Read: @unchecked Sendable {
            let root: URL
            let continuation: AsyncThrowingStream<ListingEvent, Error>.Continuation
            private let lock = NSLock()
            private var completion: (@Sendable () -> Void)?
            init(_ root: URL, _ continuation: AsyncThrowingStream<ListingEvent, Error>.Continuation,
                 _ completion: @escaping @Sendable () -> Void) {
                self.root = root; self.continuation = continuation; self.completion = completion
            }
            func finish(_ entries: [FileEntry] = [], partial: Bool = false, draining: Bool = true) {
                if !entries.isEmpty { continuation.yield(.batch(entries)) }
                continuation.yield(.finished(issues: partial ? [.init(message: "generated unavailable metadata")] : []))
                continuation.finish()
                if draining { drain() }
            }
            func drain() {
                let callback = lock.withLock { let value = completion; completion = nil; return value }
                callback?()
            }
        }
        private let lock = NSLock()
        private var recorded: [Read] = []
        var reads: [Read] { lock.withLock { recorded } }
        func entries(in url: URL, showHidden: Bool, retaining lifetime: (any Sendable)?,
                     didDrain: @escaping @Sendable () -> Void) -> AsyncThrowingStream<ListingEvent, Error> {
            let pair = AsyncThrowingStream<ListingEvent, Error>.makeStream()
            let value = Read(url, pair.continuation, didDrain)
            lock.withLock { recorded.append(value) }
            return pair.stream
        }
    }

    private final class SortLatch: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var calls = 0
        private var waiting = false
        var isWaiting: Bool { lock.withLock { waiting } }
        func holdFirst() throws {
            let first = lock.withLock {
                calls += 1
                if calls == 1 { waiting = true; return true }
                return false
            }
            guard first else { return }
            defer { lock.withLock { waiting = false } }
            guard gate.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            try Task.checkCancellation()
        }
        func release() { gate.signal() }
    }

    /// Exercises the actual analyzer chooser and its shared Settings object,
    /// rather than constructing a controller with a preselected test style.
    static func livePreferences(browser: BrowserViewController, coordinator: ApplicationStorageAnalysis,
                                root: URL, output: URL) async throws -> [String] {
        let settings = browser.settings, previousStyle = browser.settings.analysisFolderPicker
        let originalResult = coordinator.pagedResultForVerification?.id
        let queryCount = coordinator.pagedResultForVerification?.queryWorkerLaunchCountForQualification
        defer { settings.analysisFolderPicker = previousStyle; coordinator.folderPickerForVerification?.cancel() }
        for (index, style) in [AnalysisFolderPickerStyle.explorer, .columns, .explorer].enumerated() {
            settings.analysisFolderPicker = style
            coordinator.openFolderPickerForVerification()
            try await waitForLive("Live preference opens the actual custom picker") {
                coordinator.folderPickerForVerification?.model.isDrained == true
                    && coordinator.folderPickerForVerification?.model.levels.last?.loading == false
            }
            guard let picker = coordinator.folderPickerForVerification else { throw TestFailure() }
            try UIVerification.require(picker.styleForVerification == style && picker.model.location.directoryURL == root,
                "An existing analyzer reused an old folder-picker preference")
            try UIVerification.require(picker.pathField.stringValue == root.path,
                "The automatically focused picker path was left blank")
            let details = style == .explorer
            try UIVerification.require(picker.tablesForVerification.count == 1
                && picker.tablesForVerification[0].tableColumns.count == (details ? 3 : 1),
                "Picker preference did not produce a details list or a folder column")
            if index == 0, let window = picker.window {
                try await UIVerification.snapshot(window, to: output.appendingPathComponent("analysis-picker-live-explorer-" + UUID().uuidString + ".png"))
            }
            let folder = root.appendingPathComponent("Folder", isDirectory: true)
            picker.model.navigate(.directory(folder), appendAfter: 0)
            try await waitForLive("Live picker enters only a generated folder") {
                picker.model.isDrained && picker.model.levels.last?.loading == false
            }
            try UIVerification.require(picker.model.confirmationURL == folder
                && picker.tablesForVerification.count == (details ? 1 : 2), "Picker layout lost its selected folder or adjacent levels")
            if details {
                settings.analysisFolderPicker = .columns
                try await waitForLive("Open picker follows its changed layout preference") {
                    picker.styleForVerification == .columns && picker.tablesForVerification.count == 2
                }
                try UIVerification.require(picker.tablesForVerification.allSatisfy { $0.tableColumns.count == 1 }
                    && picker.model.confirmationURL == folder, "Live Columns layout lost the folder or retained details columns")
            }
            if style == .columns, let window = picker.window {
                try await UIVerification.snapshot(window, to: output.appendingPathComponent("analysis-picker-live-columns-" + UUID().uuidString + ".png"))
            }
            picker.cancel()
            try await waitForLive("Cancelled live picker actually drains") {
                coordinator.folderPickerForVerification == nil && !coordinator.hasWork
            }
        }
        try UIVerification.require(coordinator.pagedResultForVerification?.id == originalResult
            && coordinator.pagedResultForVerification?.queryWorkerLaunchCountForQualification == queryCount,
            "Picker preference checks started a scan or discarded the existing result")
        return ["existing analyzer reads latest picker preference on every open", "live Explorer/Columns preference updates preserve current folder",
                "Explorer is one details list; Columns presents adjacent folder levels", "three picker cancellations drain without rescanning"]
    }

    private static func waitForLive(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UIVerification.Failure(message: description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Synthetic reader output only. No filesystem path is enumerated, no
    /// bookmark store is configured and no native permission query runs.
    static func memoryOnlyProcessing() async throws {
        for closeInsteadOfNavigate in [false, true] {
            let reader = Reader(), latch = SortLatch()
            let root = URL(fileURLWithPath: "/Generated/Picker", isDirectory: true)
            let latest = root.appendingPathComponent("Latest", isDirectory: true)
            let model = AnalysisFolderPickerModel(initialDirectory: root, volumes: [],
                access: FolderAccessController(), reader: reader)
            model.sortingHookForVerification = { try latch.holdFirst() }
            defer { latch.release(); reader.reads.forEach { $0.finish() } }
            model.start()
            try await UIVerification.waitUntil("RAM picker read begins") { reader.reads.count == 1 }
            reader.reads[0].finish([FileEntry(url: root.appendingPathComponent("Stale"), name: "Stale", kind: .directory)])
            try await UIVerification.waitUntil("RAM picker sort is actually running") { latch.isWaiting }
            try await Task.sleep(for: .milliseconds(30))
            var closed = false
            let stop: Task<Void, Never>?
            if closeInsteadOfNavigate {
                stop = Task { await model.cancelAndDrain(); closed = true }
            } else {
                stop = nil
                model.navigate(.directory(root.appendingPathComponent("Superseded")))
                model.navigate(.directory(latest))
            }
            try await Task.sleep(for: .milliseconds(30))
            let waited = !model.isDrained && !closed && reader.reads.count == 1
            latch.release()
            if let stop { await stop.value }
            else {
                try await UIVerification.waitUntil("RAM picker admits only latest after sort drain") { reader.reads.count == 2 }
                try UIVerification.require(reader.reads[1].root == latest, "Picker sorted superseded navigation")
                reader.reads[1].finish()
                try await UIVerification.waitUntil("RAM picker latest listing settles") { model.isDrained && model.levels.last?.loading == false }
                try UIVerification.require(model.levels.last?.entries.isEmpty == true && model.confirmationURL == latest,
                    "Late picker sort replaced the current selection")
                await model.cancelAndDrain()
            }
            try UIVerification.require(waited && model.isDrained,
                "Picker released its processing owner before the actual detached sort completed")
        }
        let reader = Reader()
        let root = URL(fileURLWithPath: "/Generated/Picker", isDirectory: true)
        let latest = root.appendingPathComponent("Latest", isDirectory: true)
        let model = AnalysisFolderPickerModel(initialDirectory: root, volumes: [], access: FolderAccessController(), reader: reader)
        model.start()
        // No task turn between requests: cancelled access preparation must not
        // leave an occupied slot, nor start any superseded backend read.
        for index in 0..<100 { model.navigate(.directory(root.appendingPathComponent("Superseded\(index)"))) }
        model.navigate(.directory(latest))
        try await UIVerification.waitUntil("RAM picker prelaunch cancellation settles") { reader.reads.count == 1 }
        try UIVerification.require(reader.reads[0].root == latest, "Picker launched superseded access preparation")
        reader.reads[0].finish(draining: false)
        try await UIVerification.waitUntil("RAM picker processing finishes before backend drain") { model.levels.last?.loading == false }
        var closed = false
        let stop = Task { await model.cancelAndDrain(); closed = true }
        try await Task.sleep(for: .milliseconds(30))
        let waited = !closed && !model.isDrained
        reader.reads[0].drain(); await stop.value
        try UIVerification.require(waited && model.isDrained && closed,
            "Picker released a read whose stream ended before the backend actually drained")
    }

    static func run(root: URL, output: URL) async throws -> [String] {
        let settings = BrowserSettings(persist: false)
        try UIVerification.require(settings.analysisFolderPicker == .system, "System folder-picker default changed")
        for style in AnalysisFolderPickerStyle.allCases {
            settings.analysisFolderPicker = style
            let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
            try UIVerification.require(restored.analysisFolderPicker == style, "Picker preference did not round-trip")
        }
        let old = BrowserSettings(persist: false, restoredData: Data("{\"version\":13}".utf8))
        try UIVerification.require(old.analysisFolderPicker == .system, "Old settings acquired a custom picker default")
        try await controlled(root: root)
        try await pathDraft(root: root, settings: settings)
        let access = FolderAccessController()
        let model = AnalysisFolderPickerModel(initialDirectory: root, volumes: [], access: access)
        let picker = AnalysisFolderPickerController(model: model, settings: settings, style: .explorer)
        picker.startForVerification()
        try await UIVerification.waitUntil("Native picker shallow folder listing") {
            model.levels.last?.loading == false && model.isDrained
        }
        try UIVerification.require(model.confirmationURL == root && model.levels.last?.readable == true
            && model.levels.last?.entries.allSatisfy { $0.kind == .directory } == true,
            "Real native picker showed files or could not choose its current folder")
        guard let explorer = picker.tablesForVerification.last,
              let scopeIndex = model.levels.last?.entries.firstIndex(where: { $0.name == "scope" }) else { throw TestFailure() }
        explorer.selectRowIndexes(IndexSet(integer: scopeIndex), byExtendingSelection: false)
        try UIVerification.require(picker.tablesForVerification.last === explorer
            && model.confirmationURL?.path == root.appendingPathComponent("scope").path,
            "Explorer selection replaced the table during tracking or changed the confirmation target")
        let before = picker.window?.frame.size ?? .zero
        try UIVerification.require(before.width >= 740 && before.height >= 460, "Native picker shrank below its reviewed bounds")
        picker.window?.contentView?.layoutSubtreeIfNeeded()
        try UIVerification.require((explorer.enclosingScrollView?.bounds.width ?? 0) >= 500
            && explorer.tableColumns.map(\.identifier.rawValue) == ["name", "modified", "kind"],
            "Explorer picker failed to fill its content area or lost its details columns")
        try await UIVerification.snapshot(picker.window!, to: output.appendingPathComponent("analysis-picker-explorer.png"))
        picker.setStyleForVerification(.columns)
        try UIVerification.require(model.confirmationURL?.path == root.appendingPathComponent("scope").path, "Layout switch lost the selected target")
        model.navigate(.directory(root.appendingPathComponent("scope")), appendAfter: 0)
        try await UIVerification.waitUntil("Column child scope") { model.levels.last?.loading == false && model.isDrained }
        model.navigate(.directory(root.appendingPathComponent("scope/Alpha")), appendAfter: 1)
        try await UIVerification.waitUntil("Column empty child directory") { model.levels.last?.loading == false && model.isDrained }
        try UIVerification.require(model.levels.count == 3 && picker.tablesForVerification.count == 3
            && model.confirmationURL?.path == root.appendingPathComponent("scope/Alpha").path
            && model.levels.last?.entries.isEmpty == true && picker.chooseButton.isEnabled,
            "Columns lost ancestry or treated a folder with no subfolders as an error")
        try await UIVerification.snapshot(picker.window!, to: output.appendingPathComponent("analysis-picker-columns.png"))
        let previous = model.location
        try UIVerification.require(!model.navigate(text: "https://example.invalid/elsewhere") && model.location == previous,
            "Picker accepted a remote URL or navigated invalid input")
        try UIVerification.require(model.navigate(text: root.path), "Picker rejected its explicit generated path")
        try await UIVerification.waitUntil("Typed path returns to generated root") { model.levels.last?.loading == false && model.isDrained }
        await model.cancelAndDrain(); picker.close()
        return ["Both native picker layouts: actual shallow folder-only listing, current/selected confirmation, preserved table tracking, empty Columns child/ancestry, exact path and invalid-input controls",
                "Picker model: one active read plus latest demand; stale selection/partial/refusal states and cancellation wait for actual read completion; unsubmitted paths survive late listing/focus changes and cannot confirm an old selection; no file mutations or access prompts",
                "Picker preferences: System remains default, all three styles round-trip, v13 defaults migrate to v14 without filesystem persistence"]
    }

    private static func pathDraft(root: URL, settings: BrowserSettings) async throws {
        let reader = Reader()
        let model = AnalysisFolderPickerModel(initialDirectory: root, volumes: [], access: FolderAccessController(), reader: reader)
        let picker = AnalysisFolderPickerController(model: model, settings: settings, style: .explorer)
        picker.startForVerification()
        try await UIVerification.waitUntil("Held picker draft listing begins") { reader.reads.count == 1 }
        let target = root.appendingPathComponent("scope")
        picker.pathField.stringValue = target.path
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.pathField))
        reader.reads[0].finish()
        try await UIVerification.waitUntil("Listing completes behind edited picker path") { model.isDrained }
        picker.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: picker.pathField))
        try UIVerification.require(!picker.chooseButton.isEnabled && picker.pathField.stringValue == target.path,
            "Late listing or focus loss discarded a draft and enabled confirmation of the old folder")
        let editor = NSTextView()
        try UIVerification.require(picker.control(picker.pathField, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))), "Picker did not consume path Return")
        try await UIVerification.waitUntil("Submitted picker draft begins its own listing") { reader.reads.count == 2 }
        reader.reads[1].finish()
        try await UIVerification.waitUntil("Submitted picker draft settles") { model.isDrained }
        try UIVerification.require(picker.chooseButton.isEnabled && model.confirmationURL == target,
            "Submitted picker path did not become the confirmed location")
        picker.pathField.stringValue = root.path
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.pathField))
        _ = picker.control(picker.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try UIVerification.require(picker.chooseButton.isEnabled && picker.pathField.stringValue == target.path,
            "Escape did not discard the draft and restore the current folder")
        await model.cancelAndDrain(); picker.close()
    }

    private static func controlled(root: URL) async throws {
        let reader = Reader(), access = FolderAccessController()
        let model = AnalysisFolderPickerModel(initialDirectory: root, volumes: [], access: access, reader: reader)
        model.start()
        try await UIVerification.waitUntil("Held picker read begins") { reader.reads.count == 1 }
        let first = reader.reads[0]
        let skipped = root.appendingPathComponent("scope"), latest = root.appendingPathComponent("partial")
        model.navigate(.directory(skipped)); model.navigate(.directory(latest))
        try await Task.sleep(for: .milliseconds(30))
        try UIVerification.require(reader.reads.count == 1 && model.confirmationURL == nil,
            "Cancelled picker stream freed its actual worker slot or enabled unverified confirmation")
        first.finish([FileEntry(url: root.appendingPathComponent("late"), name: "late", kind: .directory)])
        try await UIVerification.waitUntil("Only newest pending picker location starts") { reader.reads.count == 2 }
        try UIVerification.require(reader.reads[1].root == latest, "Superseded picker location was enumerated")
        reader.reads[1].finish()
        try await UIVerification.waitUntil("Empty generated picker location settles") { model.levels.last?.loading == false }
        try UIVerification.require(model.confirmationURL == latest && model.levels.last?.entries.isEmpty == true,
            "Late first-read output replaced the newest empty folder")
        model.navigate(.directory(root))
        try await UIVerification.waitUntil("Partial picker scope begins") { reader.reads.count == 3 }
        reader.reads[2].finish(partial: true)
        try await UIVerification.waitUntil("Partial picker scope settles") { model.levels.last?.loading == false }
        try UIVerification.require(model.confirmationURL == nil && model.levels.last?.message.contains("unavailable") == true,
            "Partial enumeration looked like a confirmed empty folder")
        model.navigate(.directory(root.appendingPathComponent(".ssh")))
        try UIVerification.require(model.confirmationURL == nil && reader.reads.count == 3,
            "Known credential exclusion launched a picker read")
        model.navigate(.directory(root))
        try await UIVerification.waitUntil("Held picker shutdown scope begins") { reader.reads.count == 4 }
        var ended = false
        let stop = Task { await model.cancelAndDrain(); ended = true }
        try await Task.sleep(for: .milliseconds(30))
        try UIVerification.require(!ended, "Picker cancellation returned before actual read completion")
        reader.reads[3].finish(); await stop.value
        try UIVerification.require(ended && model.isDrained, "Picker read did not drain")
    }
}
#endif
