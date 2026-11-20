#if DEBUG
import AppKit
import ExplorerCore
import FileOperations

@MainActor enum CommandFinderVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath() == root,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["action"] as? String == "traverse-command-finder" else { exit(2) }
        var owner: BrowserWindowController?, editorOwner: NativeTextEditorWindow?
        var checks: [String] = [], failures: [String] = []
        var filterMilliseconds: [Double] = []
        do {
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            let controller = BrowserWindowController(settings: settings); owner = controller
            let browser = controller.browser; browser.permitsBackgroundVerification = true
            NSApp.mainMenu = BrowserMenus.applicationMenu(target: browser)
            guard let parent = controller.window else { throw UIVerification.Failure(message: "Missing generated browser window") }
            parent.title = "Command discovery · generated review"; parent.setContentSize(.init(width: 960, height: 640))
            parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            browser.navigate(to: .directory(root.appendingPathComponent("source/Files")))
            try await settle(browser)
            browser.focusBrowserContent()
            let finder = browser.commandFinder
            func find(_ text: String) { finder.query.stringValue = text; finder.updateMatches() }
            func open() async throws {
                parent.makeKeyAndOrderFront(nil); browser.focusBrowserContent()
                try UIVerification.require(browser.routeBrowserShortcut(UIVerification.key("k", code: 40,
                    flags: [.command, .shift], window: parent)), "Find a Command shortcut did not route through the native browser")
                try await Task.sleep(for: .milliseconds(40))
                try UIVerification.require(finder.window?.isKeyWindow == true, "Command panel did not take key focus")
            }
            try await open()
            let helpCommand = NSApp.helpMenu?.items.first { $0.action == #selector(BrowserViewController.findCommand(_:)) }
            try UIVerification.require(helpCommand != nil && helpCommand?.keyEquivalent == "k"
                && helpCommand?.keyEquivalentModifierMask == [.command, .shift], "Native Help menu and effective shortcut differ")
            finder.window?.contentView?.layoutSubtreeIfNeeded()
            try UIVerification.require((finder.window?.frame.width ?? 0) >= 620
                && (finder.table.enclosingScrollView?.frame.height ?? 0) >= 240
                && finder.table.rows(in: finder.table.visibleRect).length >= 4,
                "Command results collapse before the user can browse them")
            try UIVerification.require(finder.query.currentEditor() === finder.window?.firstResponder
                && finder.query.maximumRecents == 0 && finder.query.recentsAutosaveName == nil,
                "Command input focus or transient-only contract differs")
            if let window = finder.window, let screen = parent.screen {
                try UIVerification.require(screen.visibleFrame.contains(window.frame), "Command panel starts off screen")
            }
            for text in ["disk usage", "nicknames", "split right", "⌘T", "network", "unzip"] {
                let start = CACurrentMediaTime(); find(text); filterMilliseconds.append((CACurrentMediaTime() - start) * 1000)
                try UIVerification.require(!finder.matches.isEmpty && finder.matches.count <= 20, "Typed command search loses a known alias or bound")
            }
            try UIVerification.require(filterMilliseconds.allSatisfy { $0 < 100 }, "Generated command filtering exceeds 100 ms")
            find("New Tab")
            try UIVerification.require(finder.matches.first?.command == .newTab
                && finder.matches.first?.shortcut == settings.shortcutMap.shortcuts(for: .newTab).map(\.display).joined(separator: " · "),
                "Displayed shortcut differs from effective binding")
            checks.append("Finite command aliases/current shortcuts filter within bounds, without stored recents")

            let initialTabs = browser.tabs.count
            // Native search sends this action while typing and clearing. It
            // must never execute the currently highlighted command.
            find("New Tab")
            finder.query.sendAction(finder.query.action, to: finder.query.target)
            try UIVerification.require(browser.tabs.count == initialTabs && finder.window?.isKeyWindow == true,
                "Native search action dispatched a command before Return")
            guard let editor = finder.query.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Missing native query editor") }
            editor.setMarkedText("compose", selectedRange: NSRange(location: 0, length: 7), replacementRange: NSRange(location: NSNotFound, length: 0))
            try UIVerification.require(editor.hasMarkedText()
                && !finder.control(finder.query, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                "Command routing consumed input-method composition")
            finder.activateSelection(nil)
            try UIVerification.require(browser.tabs.count == initialTabs && finder.dispatchedForVerification.isEmpty, "IME composition dispatched a command")
            editor.unmarkText(); find("Rename")
            try UIVerification.require(finder.matches.first?.command == .rename && finder.matches.first?.enabled == false,
                "Unavailable rename is not discoverable as disabled")
            finder.activateSelection(nil)
            try UIVerification.require(finder.window?.isVisible == true && finder.dispatchedForVerification.isEmpty,
                "Unavailable command fell through to another action")
            guard let nativePanel = finder.window else { throw UIVerification.Failure(message: "Missing command panel to close") }
            nativePanel.sendEvent(UIVerification.key("\u{1b}", code: 53, flags: [], window: nativePanel))
            let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while finder.window != nil && ContinuousClock.now < closeDeadline { try await Task.sleep(for: .milliseconds(10)) }
            try UIVerification.require(finder.window == nil && NSApp.keyWindow === parent && parent.firstResponder === browser.activeFileView,
                "Cancel did not return original file focus")
            checks.append("IME/disabled actions do not dispatch; closing clears query and restores original focus")

            try await open(); find("New Tab")
            if let editor = finder.query.currentEditor() as? NSTextView {
                editor.keyDown(with: UIVerification.key("\r", code: 36, flags: [], window: finder.window!))
            }
            try await settle(browser)
            try UIVerification.require(browser.tabs.count == initialTabs + 1 && finder.window == nil
                && NSApp.keyWindow === parent && finder.query.stringValue.isEmpty,
                "Native Return did not dispatch exactly one New Tab after relinquishing key window")
            try await open(); find("Close Tab"); finder.activateSelection(nil)
            try await settle(browser)
            try UIVerification.require(browser.tabs.count == initialTabs && parent.isVisible && finder.window == nil,
                "Close Tab affected the command panel or wrong window")
            checks.append("Native Return executes New Tab once; Close Tab targets the original browser window")

            try await open(); find("Toggle Hidden Files")
            let before = settings.showsHiddenFiles, dispatched = finder.dispatchedForVerification.count
            browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            finder.activateSelection(nil)
            try UIVerification.require(settings.showsHiddenFiles == before && finder.dispatchedForVerification.count == dispatched
                && finder.window != nil, "Changed selection dispatched a stale command")
            finder.dismiss(restoringFocus: true)
            browser.table.deselectAll(nil)
            try await open(); find("Toggle Hidden Files")
            browser.sessionID = UUID(); finder.activateSelection(nil)
            try UIVerification.require(settings.showsHiddenFiles == before && finder.dispatchedForVerification.count == dispatched,
                "Changed visit dispatched a stale command")
            finder.dismiss(restoringFocus: true)
            checks.append("Selection/visit changes refuse stale command dispatch")

            for _ in 0..<8 {
                try await open(); find("transfer"); finder.dismiss(restoringFocus: true)
                try UIVerification.require(finder.window == nil && finder.query.stringValue.isEmpty
                    && finder.matches.isEmpty && finder.table.tableColumns.count == 1,
                    "Repeated open/close retains queries, matches or extra columns")
            }
            try await open()
            let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false; other.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(20))
            try UIVerification.require(finder.window == nil && NSApp.keyWindow === other,
                "Focus loss kept the command panel or stole another window's focus")
            other.close()
            checks.append("Repeated presentation clears transient data; losing key focus closes without stealing focus")

            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                for mode in BrowserMotionMode.allCases {
                    settings.motion.mode = mode
                    try await open(); find("New Tab")
                    guard let panel = finder.window else { throw UIVerification.Failure(message: "Missing panel for exact-window recording") }
                    panel.title = "Find a Command · generated review"
                    let report = try await NativeMotionRecorder.record(window: panel, root: root, label: "command-" + mode.rawValue) {
                        NativeMotionRecorder.replayToolWindowEntrance(panel)
                    }
                    try JSONEncoder().encode(report).write(to: root.appendingPathComponent("evidence/command-" + mode.rawValue + ".json"), options: .withoutOverwriting)
                    try UIVerification.require(panel.alphaValue == 1, "Entrance leaves the panel translucent")
                    finder.dismiss(restoringFocus: true)
                }
                checks.append("Exact-window Full/Reduced/Off clips complete and recorder users drain")
            }
            try await open(); parent.close()
            try UIVerification.require(finder.window == nil && finder.matches.isEmpty, "Closing origin retains the command panel")
            checks.append("Closing the origin window drains and clears its command panel")

            // The same presentation discovers the actual editor menu. This is
            // an in-memory flow: Save/Save As are deliberately unavailable.
            InterfacePresentation.shared.bind(settings)
            settings.interfaceSize = .init(150); settings.motion.mode = .full
            let textOwner = NativeTextEditorWindow(displayName: "Generated editor commands", installChrome: {
                ToolWindowChrome.install(in: $0, settings: settings)
            })
            editorOwner = textOwner; textOwner.bindKeyboardBehavior(to: settings)
            textOwner.shouldClose = { true }
            let original = try TextDocumentValue.original(Data("beta\nalpha\n".utf8))
            textOwner.surface.install(original)
            textOwner.saveButton.isEnabled = false; textOwner.saveAsButton.isEnabled = false
            var unexpectedSaves = 0
            textOwner.onSave = { unexpectedSaves += 1 }; textOwner.onSaveAs = { unexpectedSaves += 1 }
            textOwner.showWindow(nil); textOwner.window?.makeKeyAndOrderFront(nil)
            guard let native = textOwner.window else { throw UIVerification.Failure(message: "Missing editor command origin") }
            try UIVerification.require(native.makeFirstResponder(textOwner.surface.textView), "Editor command focus missing")
            textOwner.surface.textView.setSelectedRange(.init(location: 0, length: original.utf16Count))
            let palette = textOwner.commandFinder
            func editorOpen(_ query: String) async throws {
                native.makeKeyAndOrderFront(nil); native.makeFirstResponder(textOwner.surface.textView)
                guard let help = NSApp.mainMenu?.items.last?.submenu,
                      let command = help.items.first(where: { $0.action == #selector(NativeTextEditorWindow.findEditorCommand(_:)) }) else {
                    throw UIVerification.Failure(message: "Help discovery still targets the browser beneath the editor")
                }
                NSApp.sendAction(command.action!, to: command.target, from: command)
                try await Task.sleep(for: .milliseconds(40))
                try UIVerification.require(palette.window?.isKeyWindow == true && finder.window == nil,
                    "Editor command discovery opened the wrong panel")
                palette.query.stringValue = query; palette.updateMatches()
            }
            try await editorOpen("Save")
            try UIVerification.require(palette.matches.first?.item.title == "Save"
                && palette.matches.first?.enabled == false, "Disabled Save is not discoverable safely")
            palette.activateSelection(nil)
            try UIVerification.require(palette.window != nil && unexpectedSaves == 0, "Disabled command invoked Save")
            palette.dismiss(restoringFocus: true)
            try await editorOpen("Lines")
            palette.query.sendAction(palette.query.action, to: palette.query.target)
            try UIVerification.require(palette.window?.isKeyWindow == true
                && textOwner.surface.textView.string == original.text,
                "Native editor search action edited the document while typing")
            try UIVerification.require(InterfacePresentation.shared.size.percent == 150
                && (palette.query.font?.pointSize ?? 0) >= 25
                && palette.table.rowHeight >= 63, "Editor discovery did not use the actual enlarged presentation owner")
            if ProcessInfo.processInfo.arguments.contains("--record-motion"), let panel = palette.window {
                panel.title = "Find an Editor Command · generated review"
                let clip = try await NativeMotionRecorder.record(window: panel, root: root, label: "editor-command-full",
                    sampling: .diagnostic(for: panel)) {
                    NativeMotionRecorder.replayToolWindowEntrance(panel)
                }
                try JSONEncoder().encode(clip).write(to: root.appendingPathComponent("evidence/editor-command-full.json"), options: .withoutOverwriting)
            }
            palette.window?.contentView?.layoutSubtreeIfNeeded()
            if let cell = palette.table.view(atColumn: 0, row: 0, makeIfNecessary: true),
               let row = cell.subviews.first as? NSStackView,
               let key = row.arrangedSubviews.last as? NSTextField,
               let clip = palette.table.enclosingScrollView?.contentView {
                try UIVerification.require(key.bounds.width + 1 >= key.intrinsicContentSize.width
                    && clip.bounds.contains(key.convert(key.bounds, to: clip)),
                    "Enlarged command shortcut is clipped: bounds \(key.bounds), intrinsic \(key.intrinsicContentSize), in clip \(key.convert(key.bounds, to: clip)), viewport \(clip.bounds)")
            } else { throw UIVerification.Failure(message: "Missing actual enlarged command shortcut row") }
            palette.query.stringValue = "Sort Lines Ascending"; palette.updateMatches()
            try UIVerification.require(palette.matches.count == 1 && palette.matches[0].enabled,
                "Actual editor line command is not discoverable")
            palette.activateSelection(nil)
            let editorDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while textOwner.surface.textView.string == original.text && ContinuousClock.now < editorDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try UIVerification.require(palette.window == nil && native.isKeyWindow
                && native.firstResponder === textOwner.surface.textView
                && textOwner.surface.textView.string == "alpha\nbeta\n" && unexpectedSaves == 0,
                "Command selection did not restore the exact editor and apply its ordinary line edit")
            textOwner.surface.textView.undoManager?.undo()
            try UIVerification.require(textOwner.surface.textView.string == original.text,
                "Discovered line command lost its ordinary one-step Undo")
            checks.append("Enlarged editor Help discovers its own commands; disabled Save stays disabled; selected line action retains native Undo")

            try await editorOpen("Duplicate Lines")
            let changed = try TextDocumentValue.original(Data("changed elsewhere\n".utf8))
            textOwner.surface.install(changed)
            palette.activateSelection(nil)
            try UIVerification.require(palette.window != nil && textOwner.surface.textView.string == changed.text
                && palette.status.stringValue.contains("document changed"), "Changed document received a stale discovered command")
            palette.dismiss(restoringFocus: true)
            textOwner.surface.textView.isEditable = false
            try await editorOpen("Duplicate Lines")
            try UIVerification.require(palette.matches.first?.enabled == false,
                "Read-only retained editor offers an active text mutation")
            textOwner.finishClose()
            try UIVerification.require(palette.window == nil && palette.query.stringValue.isEmpty
                && palette.matches.isEmpty && unexpectedSaves == 0, "Closing editor retains discovery or invokes a file write")
            checks.append("Changed/read-only editor refuses mutation; origin close clears transient discovery without Save or browser dispatch")
        } catch { failures.append(String(describing: error)) }
        editorOwner?.finishClose()
        owner?.browser.commandFinder.dismiss(restoringFocus: false); owner?.suspendBrowsing(); owner?.window?.close()
        let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "filterMilliseconds": filterMilliseconds, "spokenVoiceOver": false, "fileMutations": 0,
            "networkRequests": 0, "systemAccessibilityChanges": 0, "personalCatalogs": 0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func settle(_ browser: BrowserViewController) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 8
        while browser.isLoading || browser.orderingTask != nil || browser.canvasTransition != nil {
            try UIVerification.require(ProcessInfo.processInfo.systemUptime < until, "Generated browser did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.view.window?.contentView?.layoutSubtreeIfNeeded()
    }
}
#endif
