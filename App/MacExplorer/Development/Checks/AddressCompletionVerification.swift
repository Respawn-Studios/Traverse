#if DEBUG
import AppKit
import FileOperations
import ExplorerCore
import LocalStorage

@MainActor
enum AddressCompletionVerification {
    static func run(in testRoot: URL, output: URL, interactive: Bool = true) async throws -> [String] {
        let root = testRoot.appendingPathComponent("address-native-" + UUID().uuidString, isDirectory: true)
        let journal = root.appendingPathComponent("journal", isDirectory: true)
        try await Task.detached {
            let fm = FileManager()
            try fm.createDirectory(at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Explicitly generated legacy fixture, imported once as fixture setup.
            // The application startup path below performs only passive inspection.
            let owner = UUID(), id = UUID()
            let marker = journal.appendingPathComponent(".mac-explorer-journal-v1")
            try Data(owner.uuidString.utf8).write(to: marker, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            let record: [String: Any] = ["version": 1, "owner": owner.uuidString, "id": id.uuidString,
                "operation": "Copy", "createdAt": Date().timeIntervalSinceReferenceDate,
                "revision": 0, "state": "preparing", "locations": [], "steps": [], "areas": [], "trashIntents": []]
            let file = journal.appendingPathComponent(id.uuidString + "-000000.json")
            try JSONSerialization.data(withJSONObject: record).write(to: file, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }.value
        let engine = RecoverableFileOperations(journalDirectory: journal)
        let setup = try await engine.recoveryRecords()
        try UIVerification.require(setup.unfinishedCount == 1 && setup.records.count == 1, "Generated startup fixture was not imported")
        let before = try await Task.detached { try journalBytes(journal) }.value
        for _ in 0..<2 {
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false
            let browser = BrowserViewController(settings: settings)
            browser.recoverableFileOperations = engine
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = browser
            defer { browser.suspendBrowser(); window.close() }
            browser.inspectOperationRecovery()
            try await UIVerification.waitUntil("Generated startup history inspection") { browser.recoveryUnfinishedCount == 1 }
            try await Task.sleep(for: .milliseconds(80))
            let interruptedBrowsing = window.attachedSheet != nil
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            await browser.recoveryInspectionTask?.value
            try UIVerification.require(!interruptedBrowsing, "Retained interrupted history blocks browsing with a startup review sheet on relaunch")
            try UIVerification.require(!browser.recoveryAttentionButton.isHidden && browser.recoveryAttentionButton.isEnabled,
                        "Quiet startup omitted its actionable in-window attention control")
            browser.recoveryAttentionButton.performClick(nil)
            await browser.recoveryInspectionTask?.value
            try UIVerification.require(browser.recoveryWindow != nil, "Recovery attention could not open review")
            browser.recoveryWindow?.close()
            try UIVerification.require(browser.recoveryRecords.count == 1 && browser.recoveryUnfinishedCount == 1,
                        "Quiet startup hid or resolved the underlying interrupted record")
        }
        try UIVerification.require(before == (try await Task.detached { try journalBytes(journal) }.value), "Startup inspection changed retained history")
        var checks = ["Repeated startup inspection remains quiet and preserves the interrupted operation and all catalog bytes"]
        if interactive {
            checks += try await verifyEditor(in: root, output: output)
            checks += try await FolderLookupVerification.run(in: root)
        } else { checks.append("Native address editing, completion focus and keyboard acceptance are not exercised by hidden windows") }
        checks += try verifySearchDefaults(in: root)
        checks += try await verifyVisits(in: root)
        checks += try verifyEjectPreferences()
        if interactive { checks += try await verifyPanes(in: root, output: output) }
        checks += try await profile(in: root, output: output)
        return checks
    }

    /// Positive text-entry checks use real visible owners. The ordinary
    /// address command must keep refusing a hidden or detached browser.
    static func showInputWindow(_ window: NSWindow, title: String) async throws {
        window.title = title
        ToolWindowChrome.position(window, relativeTo: nil)
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
        try await UIVerification.waitUntil("Generated address window gained focus") {
            window.isVisible && window.isKeyWindow
        }
    }

    private static func verifySearchDefaults(in root: URL) throws -> [String] {
        let browser = BrowserViewController(settings: BrowserSettings(persist: false))
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        _ = browser.view
        let search = browser.metadataSearch
        browser.tabs[browser.activeIndex].navigate(to: .directory(root))
        search.show()
        try UIVerification.require(search.scopePopup.indexOfSelectedItem == 0,
            "The first folder search inherited This Mac scope from initial browser construction")
        search.cancel(restoreFolder: false)
        browser.tabs[browser.activeIndex].navigate(to: .directory(URL(fileURLWithPath: "/", isDirectory: true)))
        search.show()
        try UIVerification.require(search.scopePopup.indexOfSelectedItem == 1 && !search.canSearchFolder
            && search.scopePopup.item(at: 0)?.isEnabled == false,
            "Macintosh HD root promised a refused recursive root scan instead of the explicit This Mac index scope")
        search.cancel(restoreFolder: false); browser.suspendBrowser()
        return ["First folder search uses that folder; Macintosh HD root offers the indexed This Mac scope instead of promising a refused root crawl"]
    }

    private static func verifyPanes(in root: URL, output: URL) async throws -> [String] {
        let folders = root.appendingPathComponent("Completions", isDirectory: true)
        let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false
        let host = BrowserWindowController(settings: settings), workspace = host.workspace
        guard let window = host.window else { throw UIVerification.Failure(message: "Completion workspace has no native window") }
        window.setContentSize(NSSize(width: 1800, height: 1000)); window.contentView?.layoutSubtreeIfNeeded()
        defer { workspace.browsers.values.forEach { $0.suspendBrowser() }; window.close() }
        try await showInputWindow(window, title: "Traverse · generated four-pane address check")
        try UIVerification.require(workspace.splitActive(at: .trailing) && workspace.splitActive(at: .bottom)
            && workspace.splitActive(at: .leading), "Completion workspace could not establish four native panes")
        for preset in [KeyboardProfile.explorer, .mac] {
            settings.keyboardProfile = preset
            for pane in Array(workspace.browsers.values) {
                pane.permitsBackgroundVerification = true
                workspace.activate(pane)
                pane.navigate(to: .directory(folders))
                try await UIVerification.waitUntil("Four-pane completion listing") { !pane.isLoading && pane.orderingTask == nil }
                try UIVerification.require(pane.folderFilter.displaysSearch && pane.metadataSearch.scopePopup.indexOfSelectedItem == 0
                    && pane.metadataSearch.view.isHidden && !pane.metadataSearch.hasActiveSession,
                    "A pane or keyboard preset lost its idle Search Folder default or started work automatically")
                pane.focusLocation(nil)
                guard let editor = pane.pathField.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Active pane lost its native editor") }
                let text = folders.path + "/Do"
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
                try await UIVerification.waitUntil("Four-pane address suggestions") { pane.addressCompletion.suggestions.count == 2 }
                try UIVerification.require(pane.control(pane.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
                    && editor.string == folders.path + "/Documents/", "Preset changed address-editor Tab completion")
                pane.toggleLocationEditing(nil)
                try UIVerification.require(pane.pathField.isHidden && pane.addressCompletion.suggestions.isEmpty, "Four-pane pencil left a stale suggestion surface")
            }
        }
        let active = workspace.activeBrowser
        active.focusLocation(nil)
        if let editor = active.pathField.currentEditor() as? NSTextView {
            let text = folders.path + "/Do"
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            try await UIVerification.waitUntil("Pane-change completion baseline") { active.addressCompletion.suggestions.count == 2 }
            guard let peer = workspace.browsers.values.first(where: { $0 !== active }) else { throw UIVerification.Failure(message: "Completion workspace has no other pane") }
            workspace.activate(peer)
            try UIVerification.require(active.addressCompletion.suggestions.isEmpty, "Switching command panes retained the previous pane's suggestions")
        }
        return ["Four native panes in Explorer and Mac presets complete paths independently; pencil and active-pane changes retire the old completion surface"]
    }

    private static func verifyEjectPreferences() throws -> [String] {
        let settings = BrowserSettings(persist: false), browser = BrowserViewController(settings: BrowserSettings(persist: false))
        let stable = ManagedVolume(id: UUID(), name: "Generated drive", url: nil, isInternal: false,
            canMount: true, canUnmount: false, canEject: true, fileSystemID: nil, group: 1, volumeUUID: UUID())
        let unkeyed = ManagedVolume(id: UUID(), name: "Generated unkeyed drive", url: nil, isInternal: false,
            canMount: true, canUnmount: false, canEject: true, fileSystemID: nil, group: 2)
        try UIVerification.require(!settings.showsSidebarEject && settings.hiddenEjectVolumes.isEmpty, "Sidebar Eject changed its off-by-default policy")
        browser.setSidebarEjectHidden(true, for: stable); browser.setSidebarEjectHidden(true, for: unkeyed)
        let restored = BrowserSettings(persist: false, restoredData: try browser.settings.encodedSnapshot())
        try UIVerification.require(restored.hiddenEjectVolumes == [stable.volumeUUID!]
            && restored.hiddenEjectSessions.isEmpty && browser.isSidebarEjectHidden(for: unkeyed),
            "Per-drive preference lost stable UUIDs or persisted session-only identifiers")
        browser.setSidebarEjectHidden(false, for: stable); browser.setSidebarEjectHidden(false, for: unkeyed)
        try UIVerification.require(browser.settings.hiddenEjectVolumes.isEmpty && browser.settings.hiddenEjectSessions.isEmpty
            && browser.isSidebarEjectHidden(for: stable) == !browser.operationCoordinator.drives.permitsRemoval(stable, action: .eject)
            && browser.isSidebarEjectHidden(for: unkeyed) == !browser.operationCoordinator.drives.permitsRemoval(unkeyed, action: .eject),
            "Restoring the Eject preference lost the drive-removal protection policy")
        let cell = SidebarLocationCell(frame: NSRect(x: 0, y: 0, width: 180, height: 25))
        var clicks = 0
        cell.configureEject(visible: true, enabled: true) { clicks += 1 }
        cell.eject.performClick(nil)
        try UIVerification.require(clicks == 1 && !cell.eject.isHidden && cell.eject.frame.height <= cell.bounds.height,
                                  "Sidebar Eject click target did not dispatch once")
        cell.configureEject(visible: false, enabled: false, action: nil)
        try UIVerification.require(cell.eject.isHidden && !cell.eject.isEnabled, "Reused sidebar cell retained an old Eject action")
        return ["Sidebar Eject defaults off; UUID hide choices persist, unkeyed choices remain session-only, and reused cell actions reset without issuing a drive request"]
    }

    private static func verifyVisits(in root: URL) async throws -> [String] {
        let state = root.appendingPathComponent("VisitState", isDirectory: true)
        let directory = root.appendingPathComponent("Completions/Documents", isDirectory: true)
        let visits = BrowserDirectoryVisits(directory: state)
        visits.configure(enabled: true, policy: .init())
        visits.record(directory); visits.record(directory)
        await visits.flush()
        try UIVerification.require(visits.counts[directory.path] == 2, "Visits during initial restore were lost or duplicated")
        let reopened = BrowserDirectoryVisits(directory: state)
        reopened.configure(enabled: true, policy: .init())
        await reopened.flush()
        try UIVerification.require(reopened.counts[directory.path] == 2, "Private visit history did not survive reopening")
        let file = state.appendingPathComponent("directory-visits-v1.json")
        let expired: [String: Any] = ["version": 1, "history": ["visits": [["path": directory.path, "count": 2,
            "lastVisit": Date().addingTimeInterval(-60 * 86_400).timeIntervalSinceReferenceDate]]]]
        let expiredData = try JSONSerialization.data(withJSONObject: expired)
        try await Task.detached { try expiredData.write(to: file) }.value
        let expiry = BrowserDirectoryVisits(directory: state)
        expiry.configure(enabled: true, policy: .init()); await expiry.flush()
        let prunedData = try await Task.detached { try Data(contentsOf: file) }.value
        let pruned = try JSONSerialization.jsonObject(with: prunedData) as? [String: Any]
        try UIVerification.require(expiry.counts.isEmpty && ((pruned?["history"] as? [String: Any])?["visits"] as? [Any])?.isEmpty == true,
                                  "Expired visits survived private-store restoration or persisted pruning")
        reopened.record(directory); reopened.clear(); await reopened.flush()
        try UIVerification.require(reopened.counts.isEmpty && !FileManager().fileExists(atPath: file.path), "Clear did not erase queued visits and their persisted snapshot")
        reopened.record(directory); await reopened.flush()
        reopened.configure(enabled: false, policy: .init()); await reopened.flush()
        try UIVerification.require(reopened.counts.isEmpty && !FileManager().fileExists(atPath: file.path), "Disable retained or repopulated saved visits")
        let unknown = Data("Generated unsupported history".utf8)
        try await Task.detached { try unknown.write(to: file, options: .withoutOverwriting) }.value
        let guarded = BrowserDirectoryVisits(directory: state)
        guarded.configure(enabled: true, policy: .init()); await guarded.flush()
        guarded.record(directory); guarded.clear(); await guarded.flush()
        let retained = try await Task.detached { try Data(contentsOf: file) }.value
        try UIVerification.require(!guarded.status.isEmpty && retained == unknown, "Unknown saved history was silently replaced or cleared")
        let settings = BrowserSettings(persist: false)
        let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        try UIVerification.require(restored.addressPresentation == .both && !restored.ranksAddressVisits
            && restored.addressVisitDays == 30 && restored.addressVisitEntryLimit == 200,
            "Address preferences changed the selected privacy defaults")
        return ["Private visits reopen correctly; initial-restore visits survive, Clear/Disable erase queued updates, and unsupported history stays protected"]
    }

    private static func profile(in root: URL, output: URL) async throws -> [String] {
        let directory = root.appendingPathComponent("Profile", isDirectory: true)
        try await Task.detached {
            let fm = FileManager(); try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            for i in 0..<1_000 { try fm.createDirectory(at: directory.appendingPathComponent(String(format: "Folder %04d", i)), withIntermediateDirectories: false) }
        }.value
        let service = DirectoryCompletionService(activityGate: ApplicationFileActivity.gate)
        let request = try AddressCompletionRequest(text: directory.path + "/Folder", home: directory)
        var samples: [[String: Any]] = []
        for _ in 0..<3 {
            let sessions = (0..<4).map { _ in service.start(owner: UUID(), request: request) }
            let start = ProcessInfo.processInfo.systemUptime
            for session in sessions {
                for try await value in session.results {
                    samples.append(["workerMilliseconds": value.elapsed * 1_000,
                        "observedEntries": value.observedEntries, "truncated": value.isTruncated,
                        "retainedCandidates": value.suggestions.count,
                        "fourRequestElapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1_000])
                    try UIVerification.require(value.suggestions.count <= 8 && value.observedEntries <= 10_000,
                                              "Completion exceeded its measured observation or retention bounds")
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["directoryEntries": 1_000, "concurrentEditors": 4,
            "workerLimit": 2, "samples": samples], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("completion-profile.json"), options: .withoutOverwriting)
        return ["Generated 1,000-directory profiling records three four-editor rounds through two workers with bounded retained candidates"]
    }

    private static func verifyEditor(in root: URL, output: URL) async throws -> [String] {
        let folders = root.appendingPathComponent("Completions", isDirectory: true)
        try await Task.detached {
            let fm = FileManager()
            for name in ["Documents", "Downloads", "Notes", "Café 文件", ".hidden", "Example.app"] {
                try fm.createDirectory(at: folders.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        }.value
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        let browser = BrowserViewController(settings: settings)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.permitsBackgroundVerification = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1600, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        defer { browser.suspendBrowser(); window.close() }
        try await showInputWindow(window, title: "Traverse · generated address completion")
        browser.navigate(to: .directory(folders))
        try await UIVerification.waitUntil("Completion fixture listing") { !browser.isLoading && browser.orderingTask == nil }
        let address = browser.addressCompletion
        func type(_ text: String) throws -> NSTextView {
            browser.focusLocation(nil)
            guard let editor = browser.pathField.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Native address field has no editor") }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            return editor
        }
        let partial = folders.path + "/Do"
        var editor = try type(partial)
        try await UIVerification.waitUntil("Native prefix completion") { address.suggestions.count == 2 }
        try UIVerification.require(address.suggestions.map(\.name) == ["Documents", "Downloads"], "Native address prefix order is incorrect")
        try UIVerification.require(editor.string == partial && browser.pathField.stringValue == partial,
                                  "Ghost text entered the native editable value")
        try UIVerification.require(address.ghostTextForVerification == "cuments/", "Inline ghost was not drawn at the native caret: " + address.geometryForVerification)
        let originalLocation = browser.location
        try UIVerification.require(browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))), "Tab did not accept the visible completion")
        try UIVerification.require(editor.string == folders.path + "/Documents/" && browser.location == originalLocation,
                                  "Tab navigated or failed to complete the path")
        browser.cancelLocationEditing()

        editor = try type(folders.path + "/Documnts")
        try await UIVerification.waitUntil("Native approximate completion") { !address.suggestions.isEmpty }
        try UIVerification.require(address.selectedIndex == nil && address.ghostTextForVerification == nil, "Typo suggestion was automatically accepted or ghosted")
        _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try await UIVerification.waitUntil("Explicit typo navigation") { !browser.isLoading && browser.orderingTask == nil }
        try UIVerification.require(browser.location.directoryURL?.lastPathComponent == "Documents", "Explicitly selected typo completion did not navigate")

        editor = try type(partial)
        try await UIVerification.waitUntil("Escape completion") { address.suggestions.count == 2 }
        _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try UIVerification.require(!browser.pathField.isHidden && address.suggestions.isEmpty, "First Escape did not dismiss only suggestions")
        _ = browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try UIVerification.require(browser.pathField.isHidden && !browser.pathControl.isHidden, "Second Escape did not restore breadcrumbs")
        editor = try type(partial)
        try await UIVerification.waitUntil("Pencil completion") { address.suggestions.count == 2 }
        browser.toggleLocationEditing(nil)
        try UIVerification.require(browser.pathField.isHidden && address.suggestions.isEmpty, "Pencil failed to close completion and editing")

        for presentation in AddressSuggestionPresentation.allCases where presentation != .off {
            settings.addressPresentation = presentation
            editor = try type(partial)
            try await UIVerification.waitUntil("Completion display preference") { address.result != nil }
            try UIVerification.require((address.ghostTextForVerification != nil) == presentation.showsInline,
                                      "Display preference did not control inline completion")
            let panel = address.panelForVerification
            try UIVerification.require(!panel.canBecomeKey && window.firstResponder === editor,
                                      "Suggestion panel stole native text focus")
            if presentation.showsDropdown, let content = panel.contentView {
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("completion-\(presentation == .both ? "both" : "dropdown").png"))
                }
            }
            browser.cancelLocationEditing()
        }
        settings.addressPresentation = .off
        editor = try type(partial)
        try await Task.sleep(for: .milliseconds(120))
        try UIVerification.require(address.suggestions.isEmpty && address.ghostTextForVerification == nil, "Off preference still produced completion")
        settings.addressPresentation = .both
        editor = try type(partial)
        try await UIVerification.waitUntil("Selected text completion") { address.result != nil }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        try UIVerification.require(address.ghostTextForVerification == nil && address.suggestions.isEmpty
            && !browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))),
            "Selecting path text retained a misleading completion or intercepted native Tab focus")
        browser.cancelLocationEditing()

        editor = try type(partial)
        try await UIVerification.waitUntil("IME completion baseline") { address.result != nil }
        editor.setMarkedText("Do", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: editor.string.utf16.count - 2, length: 2))
        try UIVerification.require(editor.hasMarkedText() && address.ghostTextForVerification == nil
            && !browser.control(browser.pathField, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))),
            "Completion consumed an IME composition or exposed ghost text over marked input")
        editor.unmarkText(); browser.cancelLocationEditing()

        window.setContentSize(NSSize(width: 820, height: 600)); window.contentView?.layoutSubtreeIfNeeded()
        editor = try type(partial)
        try await UIVerification.waitUntil("Narrow address completion") { address.result != nil }
        try UIVerification.require(address.panelForVerification.frame.width >= 260 && address.suggestions.count == 2,
                                  "Narrow address lost its dropdown fallback")
        // Publication must remain bound to this editor/visit after navigation.
        let abandoned = address.taskForVerification
        browser.navigate(to: .directory(folders.appendingPathComponent("Notes")))
        await abandoned?.value
        try UIVerification.require(address.suggestions.isEmpty && address.ghostTextForVerification == nil,
                                  "Late completion survived a folder-context change")
        return ["Native prefix and approximate completions preserve the editable value; Tab completes without navigating and explicit typo selection navigates",
                "Escape twice and pencil restore breadcrumbs; Both/Dropdown/Inline/Off retain native field focus and selected text suppresses the ghost",
                "Native marked text keeps Tab/IME ownership; narrow fields retain dropdown completion and navigation rejects stale results"]
    }

    nonisolated private static func journalBytes(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager().contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
#endif
