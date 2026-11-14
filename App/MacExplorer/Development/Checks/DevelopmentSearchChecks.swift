#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import Search

/// Actual native inputs and local metadata search over one admitted tiny fixture.
/// No index query, saved-name catalog, file body, clipboard or network is read.
@MainActor enum DevelopmentSearchChecks {
    static func run(root: URL, settings: BrowserSettings) async throws -> (checks: [String: Any], clips: [[String: Any]]) {
        settings.restoresSession = false
        let owner = BrowserWindowController(settings: settings), browser = owner.browser
        let scope = root.appendingPathComponent("source/FilterFiles")
        var clips: [[String: Any]] = [], checks: [String] = []
        let hold = Hold()
        func close() async {
            hold.release(); browser.metadataSearch.cancel(restoreFolder: false)
            owner.suspendBrowsing(); await owner.flushSession(); owner.window?.close()
            try? await wait("actual search drain") { ApplicationFileActivity.gate.activeCount == 0 }
        }
        func finished() async throws {
            try await wait("native search result") {
                browser.metadataSearch.isShowingResults && browser.metadataSearch.coverage != nil && !browser.metadataSearch.hasActiveSession
                    && !browser.isLoading && browser.orderingTask == nil
            }
        }
        func requireResult(_ names: [String]) throws {
            guard Set(browser.displayedEntries.map(\.name)) == Set(names), browser.displayedEntries.count == names.count,
                  browser.metadataSearch.coverage?.completion == .completed else { throw Failure.result }
        }
        do {
            guard owner.isWorkspacePresentation, let window = owner.window else { throw Failure.presentation }
            browser.permitsBackgroundVerification = true
            browser.folderAccess = FolderAccessController(stateDirectory: nil)
            window.title = "Search filters · generated review"
            window.setContentSize(.init(width: 1000, height: 700)); window.center()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            owner.beginBrowsing()
            try await wait("workspace") { owner.workspace.sessionReady }
            browser.navigate(to: .directory(scope))
            try await wait("fixture listing") { !browser.isLoading && browser.orderingTask == nil }
            let search = browser.metadataSearch
            search.show(scopeIndex: 0, copyFilter: false); search.sources = .files
            browser.view.layoutSubtreeIfNeeded()
            let scopeWidth = (search.scopePopup.titleOfSelectedItem ?? "").size(withAttributes: [.font: search.scopePopup.font ?? NSFont.systemFont(ofSize: 13)]).width
            guard search.scopePopup.bounds.width >= scopeWidth + 25 * InterfaceMetrics.scale else { throw Failure.presentation }
            search.queryField.stringValue = "Report"; search.kindPopup.selectItem(at: 1)
            search.extensionField.stringValue = "txt"
            search.minimumSizeField.stringValue = "1 KiB"; search.maximumSizeField.stringValue = "2 KiB"
            search.submit(); try await finished(); try requireResult(["Report match.txt"])
            guard browser.status.toolTip?.contains("1 KiB to 2 KiB, inclusive") == true else { throw Failure.result }
            checks.append("Explicit units use the existing local search and inclusive typed byte range")

            search.minimumSizeField.stringValue = "1536"; search.maximumSizeField.stringValue = "1536"
            search.submit(); try await finished(); try requireResult(["Report match.txt"])
            search.minimumSizeField.stringValue = "2 KiB"; search.maximumSizeField.stringValue = ""
            search.submit(); try await finished(); try requireResult(["Report large.txt"])
            guard browser.status.toolTip?.contains("At least 2 KiB") == true,
                  browser.status.toolTip?.contains(String(Int64.max)) == false else { throw Failure.result }
            search.minimumSizeField.stringValue = ""; search.maximumSizeField.stringValue = "0"
            search.submit(); try await finished(); try requireResult(["Report empty.txt"])
            guard browser.status.toolTip?.contains("At most 0 bytes") == true else { throw Failure.result }
            checks.append("Raw-byte equality, one-sided bounds and explicit zero retain their distinct meanings")

            search.filtersButton.performClick(nil)
            try await wait("filter popover") { search.minimumSizeField.window != nil }
            guard let panel = search.minimumSizeField.window, let content = panel.contentView else { throw Failure.presentation }
            panel.title = "Size filters · generated review"
            window.title = "Search filters · generated review"
            try await Task.sleep(for: .milliseconds(300))
            content.layoutSubtreeIfNeeded()
            for field in [search.minimumSizeField, search.maximumSizeField, search.extensionField] {
                let rectangle = field.convert(field.bounds, to: content)
                guard content.bounds.contains(rectangle), field.bounds.width >= 100 * InterfaceMetrics.scale,
                      (field.font?.pointSize ?? 0) >= 11 * InterfaceMetrics.scale else { throw Failure.presentation }
            }
            // On this macOS build the native child filter advertises the child
            // size but delivers its parent scene. Record that known generated
            // parent explicitly, then map the owned field into its coordinates.
            guard search.filtersButton.window === window, search.minimumSizeField.window === panel,
                  NSApp.windows.contains(where: { $0 === panel }), panel.isVisible else { throw Failure.presentation }
            try JSONSerialization.data(withJSONObject: ["generatedParent": window.windowNumber,
                "ownedPopover": panel.windowNumber, "positioningControlInParent": true,
                "fieldInOwnedPopover": true, "nativeChildRelationship": panel.parent === window], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("evidence/filter-hierarchy.json"), options: .withoutOverwriting)
            func measured(_ label: String, _ report: NativeMotionRecorder.Report) throws -> [String: Any] {
                var value = DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window)
                let field = search.minimumSizeField
                let screen = panel.convertToScreen(field.convert(field.bounds, to: nil))
                let base = window.convertFromScreen(screen)
                let region = NSRect(x: base.minX, y: CGFloat(report.height) - base.maxY, width: base.width, height: base.height)
                guard panel.isVisible, field.window === panel, !field.isHiddenOrHasHiddenAncestor,
                      NSRect(x: 0, y: 0, width: report.width, height: report.height).contains(region) else { throw Failure.presentation }
                value["fieldRegion"] = ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]
                value["fieldVisibility"] = "visible; owned popover mapped into generated parent"
                value["fieldOwnerVerified"] = true
                return value
            }
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/filters-layout.png"))
            let expected: NSAppearance.Name = settings.appearance == .light ? .aqua : .darkAqua
            guard panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected else { throw Failure.presentation }

            guard panel.makeFirstResponder(search.minimumSizeField), let editor = search.minimumSizeField.currentEditor() as? NSTextView else { throw Failure.presentation }
            let edited = try await NativeMotionRecorder.record(window: window, root: root, label: "filters-size-edit",
                sampling: .diagnostic(for: window)) {
                editor.selectAll(nil); editor.insertText("0.1 KiB", replacementRange: .init(location: 0, length: search.minimumSizeField.stringValue.utf16.count))
            }
            try JSONEncoder().encode(edited).write(to: root.appendingPathComponent("evidence/filters-size-edit.json"), options: .withoutOverwriting)
            clips.append(try measured("filters-size-edit", edited))
            guard search.minimumSizeField.stringValue == "0.1 KiB" else { throw Failure.presentation }
            let oldSession = browser.sessionID, oldCoverage = search.coverage?.finishedAt
            guard let action = search.minimumSizeField.action else { throw Failure.presentation }
            let invalid = try await NativeMotionRecorder.record(window: window, root: root, label: "filters-invalid-size",
                sampling: .diagnostic(for: window)) { _ = search.minimumSizeField.sendAction(action, to: search.minimumSizeField.target) }
            try JSONEncoder().encode(invalid).write(to: root.appendingPathComponent("evidence/filters-invalid-size.json"), options: .withoutOverwriting)
            clips.append(try measured("filters-invalid-size", invalid))
            guard browser.sessionID == oldSession, search.coverage?.finishedAt == oldCoverage,
                  errorText(in: panel)?.contains("whole bytes") == true else { throw Failure.result }
            try requireResult(["Report empty.txt"])
            checks.append("Native field editing/Return rejects fractional bytes without clearing finished results")

            for (minimum, maximum, expected) in [("2 GB", "1 GB", "Maximum size"),
                ("9223372036854775808", "", "too large")] {
                search.minimumSizeField.stringValue = minimum; search.maximumSizeField.stringValue = maximum
                search.submit()
                guard browser.sessionID == oldSession, errorText(in: panel)?.contains(expected) == true else { throw Failure.result }
                try requireResult(["Report empty.txt"])
            }
            checks.append("Reversed and overflowing bounds keep drafts/results and report the relevant input")

            search.minimumSizeField.stringValue = "1 KiB"; search.maximumSizeField.stringValue = "2 KiB"
            search.localForVerification = LocalMetadataSearch(activityGate: ApplicationFileActivity.gate, qualificationVisit: { hold.pause() })
            search.submit()
            try await wait("held actual observation") { hold.entered && search.hasActiveSession }
            let runningSession = browser.sessionID
            search.minimumSizeField.stringValue = "0.1 KiB"; search.submit()
            guard browser.sessionID == runningSession, search.hasActiveSession,
                  ApplicationFileActivity.gate.activeCount > 0 else { throw Failure.result }
            hold.release(); try await finished(); try requireResult(["Report match.txt"])
            search.localForVerification = nil
            checks.append("An invalid submission cannot cancel an already-running admitted search")

            search.externalToggle.state = .on
            search.exactToggle.state = .on; search.datePopup.selectItem(at: 2)
            guard let clear = descendants(panel.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Clear file filters" }) else { throw Failure.presentation }
            clear.performClick(nil)
            guard search.sources == .files, search.scopePopup.indexOfSelectedItem == 0, search.externalToggle.state == .on,
                  search.queryField.stringValue == "Report", search.exactToggle.state == .off, search.kindPopup.indexOfSelectedItem == 0,
                  search.datePopup.indexOfSelectedItem == 0, search.extensionField.stringValue.isEmpty,
                  search.minimumSizeField.stringValue.isEmpty, search.maximumSizeField.stringValue.isEmpty,
                  errorText(in: panel) == nil else { throw Failure.result }
            search.submit(); try await finished()
            try requireResult(["Report tiny.txt", "Report match.txt", "Report large.txt", "Report Other.pdf", "Report empty.txt", "Report Folder"])
            checks.append("Clear resets criteria while preserving filename, source, scope and drive-choice draft")
            await close()
            guard ApplicationFileActivity.gate.activeCount == 0 else { throw Failure.result }
            return (["passed": true, "checks": checks, "actualActivityCount": 0,
                "fileBodyReads": 0, "indexQueries": 0, "personalFiles": 0], clips)
        } catch { await close(); throw error }
    }
    private static func descendants(_ view: NSView?) -> [NSView] { view.map { [$0] + $0.subviews.flatMap { descendants($0) } } ?? [] }
    private static func errorText(in window: NSWindow) -> String? {
        descendants(window.contentView).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Search filter error" }?.stringValue
    }
    private static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 8
        while !condition() {
            guard CACurrentMediaTime() < deadline else { throw Failure.deadline(label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case presentation, result, deadline(String) }
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var reached = false, released = false
        var entered: Bool { lock.withLock { reached } }
        func pause() {
            let shouldWait = lock.withLock { if reached || released { return false }; reached = true; return true }
            if shouldWait { _ = semaphore.wait(timeout: .now() + 4) }
        }
        func release() { lock.withLock { released = true }; semaphore.signal() }
    }
}
#endif
