import AppKit
import ExplorerCore
import FileOperations

#if DEBUG
@MainActor
enum BrowserShortcutVerification {
    static func run(_ browser: BrowserViewController, fixture: URL, output: URL, interactive: Bool) async throws -> [String] {
        guard let window = browser.view.window else { throw UIVerification.Failure(message: "Shortcut verification has no native window") }
        let settings = browser.settings
        let originalProfile = settings.keyboardProfile, originalCustom = settings.customBehavior
        let originalKeys = settings.shortcutPreferences, originalHidden = settings.showsHiddenFiles
        let originalConflicts = settings.conflictPreferences, originalEject = settings.ejectNewWorkPolicy
        let originalBackground = browser.permitsBackgroundVerification
        let originalMenu = NSApplication.shared.mainMenu
        browser.permitsBackgroundVerification = !interactive
        defer {
            settings.shortcutPreferences = .init(); settings.customBehavior = originalCustom
            settings.shortcutPreferences = originalKeys; settings.keyboardProfile = originalProfile
            settings.showsHiddenFiles = originalHidden; settings.conflictPreferences = originalConflicts
            settings.ejectNewWorkPolicy = originalEject
            browser.permitsBackgroundVerification = originalBackground
            NSApplication.shared.mainMenu = originalMenu
        }
        browser.navigate(to: .directory(fixture)); try await UIVerification.settled(browser)
        settings.keyboardProfile = .explorer; settings.shortcutPreferences = .init()
        browser.focusBrowserContent()

        NSApplication.shared.mainMenu = BrowserMenus.applicationMenu(target: browser)
        SystemShortcutSnapshot.shared.refresh()
        if interactive { try await verifyControlNavigation(browser, fixture: fixture) }
        let candidates: [(ShortcutSpecialKey, UInt16)] = [(.f7, 98), (.f8, 100), (.f9, 101), (.f10, 109), (.f11, 103), (.f12, 111)]
        guard let chosen = candidates.first(where: { !SystemShortcutSnapshot.shared.conflicts(event($0.0, code: $0.1, window: window)) }) else {
            throw UIVerification.Failure(message: "No generated test chord is free of enabled system reservations")
        }
        let chord = BrowserShortcut(.special(chosen.0), [.control, .option, .shift])
        settings.customizeBehavior()
        settings.shortcutPreferences = .init(overrides: [.hiddenFiles: [chord]])
        try require(settings.shortcutMap.issues.isEmpty, "Custom shortcut test map is ambiguous")
        let key = event(chosen.0, code: chosen.1, window: window)
        try require(BrowserShortcut(key) == chord, "Native special-key adapter changed the recorded chord")
        let before = settings.showsHiddenFiles
        try require(browser.routeBrowserShortcut(key) && settings.showsHiddenFiles != before, "Recorded shortcut failed semantic dispatch")
        try await UIVerification.settled(browser)
        let once = settings.showsHiddenFiles
        try require(browser.routeBrowserShortcut(event(chosen.0, code: chosen.1, window: window, repeated: true))
            && settings.showsHiddenFiles == once, "Repeating a toggle dispatched it again")
        BrowserShortcutMenus.refresh(NSApplication.shared.mainMenu, browser: browser)
        let viewMenu = BrowserMenus.menu(.view, target: browser)
        let menuItem = viewMenu.items.first { $0.action == #selector(BrowserViewController.toggleHidden(_:)) }
        try require(menuItem?.keyEquivalent == chord.menuEquivalent && menuItem?.keyEquivalentModifierMask == chord.nativeModifiers,
                    "Custom shortcut and native menu hint disagree")

        for (action, scope) in [(BrowserCommand.directFilter, 0), (.searchFolder, 1), (.searchThisMac, 2)] {
            settings.shortcutPreferences = .init(overrides: [action: [chord]])
            browser.focusBrowserContent()
            let text = browser.folderFilter.displayedField.stringValue
            try require(browser.routeBrowserShortcut(key)
                && browser.folderFilter.displaysSearch == (scope != 0)
                && (scope == 0 || browser.metadataSearch.scopePopup.indexOfSelectedItem == scope - 1)
                && browser.folderFilter.displayedField.stringValue == text
                && !browser.metadataSearch.hasActiveSession && !browser.metadataSearch.isShowingResults,
                "A custom scope shortcut lost text, chose the wrong scope or auto-submitted a search")
            guard let fieldEditor = window.firstResponder as? NSTextView else {
                throw UIVerification.Failure(message: "Scope shortcut failed to focus its existing native query field")
            }
            let beforeText = fieldEditor.string, selection = fieldEditor.selectedRange()
            try require(!browser.routeBrowserShortcut(key) && fieldEditor.string == beforeText
                && fieldEditor.selectedRange() == selection,
                "A scope shortcut intercepted native text editing")
        }
        browser.focusBrowserContent()
        browser.metadataSearch.cancel(restoreFolder: false)
        settings.shortcutPreferences = .init(overrides: [.hiddenFiles: [chord]])

        settings.shortcutPreferences.overrides[.hiddenFiles] = []
        try require(!browser.routeBrowserShortcut(key) && settings.showsHiddenFiles == once, "Cleared shortcut still dispatched")
        settings.shortcutPreferences = .init(swapsCommandAndOption: true)
        try require(settings.shortcutMap.resolve(.init(.character("t"), .option), fileSurface: true) == .newTab,
                    "App modifier swap lost preset commands")
        settings.shortcutPreferences = .init(overrides: [.hiddenFiles: [chord]])

        if interactive {
            browser.focusLocation(nil)
            guard let editor = window.firstResponder as? NSTextView else { throw UIVerification.Failure(message: "Address editor did not own native focus") }
            editor.string = "/generated/typing"; editor.setSelectedRange(NSRange(location: 3, length: 4))
            let selected = editor.selectedRange()
            try require(!browser.routeBrowserShortcut(key) && editor.string == "/generated/typing" && editor.selectedRange() == selected,
                        "Custom file shortcut intercepted native text editing")
            editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = editor.string
            let f4 = UIVerification.key(String(UnicodeScalar(NSF4FunctionKey)!), code: 118, flags: [], window: window)
            try require(editor.hasMarkedText() && !browser.routeBrowserShortcut(f4) && editor.string == marked,
                        "Preset focus key intercepted marked IME text")
            editor.unmarkText(); browser.cancelLocationEditing()
        } else {
            // The production address command deliberately refuses hidden windows.
            // Leave its native focus/IME behavior to the foreground flow.
            browser.focusLocation(nil)
            try require(browser.pathField.isHidden && browser.pathField.currentEditor() == nil,
                        "A hidden browser started address editing")
        }
        browser.focusBrowserContent()

        let override = UserOverrideItem(title: "Show Hidden Files", action: #selector(BrowserViewController.toggleHidden(_:)), keyEquivalent: "")
        let overrideMenu = NSMenu(); overrideMenu.addItem(override)
        NSApplication.shared.mainMenu = overrideMenu
        try require(BrowserShortcutMenus.hasUserOverride(.hiddenFiles, in: overrideMenu)
            && !browser.routeBrowserShortcut(key) && settings.showsHiddenFiles == once,
                    "App routing competed with a native user menu override")
        NSApplication.shared.mainMenu = BrowserMenus.applicationMenu(target: browser)
        settings.shortcutPreferences = .init(overrides: [.hiddenFiles: [chord]])
        settings.conflictPreferences = .init(files: .keepBoth, folders: .skip)
        settings.ejectNewWorkPolicy = .cancelEject
        let restored = BrowserSettings(persist: false, restoredData: try settings.encodedSnapshot())
        try require(restored.keyboardProfile == .custom && restored.shortcutPreferences == settings.shortcutPreferences
            && restored.conflictPreferences == settings.conflictPreferences && restored.ejectNewWorkPolicy == .cancelEject,
                    "Workflow preferences lost captured values after reopening")
        var corrupted = try JSONSerialization.jsonObject(with: settings.encodedSnapshot()) as! [String: Any]
        let duplicate = BrowserShortcutPreferences(overrides: [.trash: [.init(.character("c"), .command)]])
        corrupted["shortcutPreferences"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(duplicate))
        // Hidden Custom data must also be validated while a preset is selected.
        corrupted["keyboardProfile"] = "Mac"
        let refused = BrowserSettings(persist: false, restoredData: try JSONSerialization.data(withJSONObject: corrupted))
        try require(!refused.preferencesPersistenceStatus.isEmpty && refused.shortcutMap.issues.isEmpty,
                    "Invalid stored bindings silently became active or overwritable")
        let refreshStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<512 { BrowserShortcutMenus.refresh(NSApplication.shared.mainMenu, browser: browser) }
        let refreshMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - refreshStarted) / 1_000_000
        try JSONSerialization.data(withJSONObject: ["passed": true, "interactive": interactive,
            "menuRefreshIterations": 512, "menuRefreshTotalMilliseconds": refreshMilliseconds,
            "notExercised": ["Physical key delivery", "Input source switching", "Real App Shortcuts preferences", "Physical IME candidate window", "VoiceOver"]],
            options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("shortcut-routing.json"), options: .withoutOverwriting)
        return ["Custom native key adapter dispatches once; repeated toggles and cleared bindings are inert; menu hints match",
                interactive ? "Native address focus and marked IME text reject custom browser routing; simulated native menu overrides take priority"
                    : "Hidden address editing refuses; native address focus/IME NOT EXERCISED offscreen; simulated native menu overrides take priority",
                "Shortcut/conflict/eject preferences round trip; invalid hidden Custom data fails safely",
                "Custom scope shortcuts preserve text, explicitly choose Filter/Folder/This Mac and defer to native text focus without auto-search"]
    }
    private static func event(_ key: ShortcutSpecialKey, code: UInt16, window: NSWindow, repeated: Bool = false) -> NSEvent {
        let shortcut = BrowserShortcut(.special(key), [.control, .option, .shift])
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.nativeModifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: shortcut.menuEquivalent, charactersIgnoringModifiers: shortcut.menuEquivalent,
            isARepeat: repeated, keyCode: code)!
    }
    private static func verifyControlNavigation(_ browser: BrowserViewController, fixture: URL) async throws {
        guard let window = browser.view.window, window.isKeyWindow else {
            throw UIVerification.Failure(message: "Keyboard navigation check requires its actual key window")
        }
        let preset = browser.settings.keyboardProfile, keys = browser.settings.shortcutPreferences
        let viewMode = browser.paneViewMode
        defer {
            browser.settings.keyboardProfile = preset; browser.settings.shortcutPreferences = keys
            browser.paneViewMode = viewMode; browser.applyDisplayPreferences()
        }
        func key(_ backwards: Bool = false) -> NSEvent {
            UIVerification.key(String(UnicodeScalar(NSF6FunctionKey)!), code: 97,
                flags: backwards ? .shift : [], window: window)
        }
        for mode in [KeyboardProfile.mac, .explorer] {
            browser.settings.keyboardProfile = mode; browser.settings.shortcutPreferences = .init()
            browser.focusLocation(nil)
            try require(browser.pathField.currentEditor() != nil, "Address command did not enter its native editor")
            try require(browser.routeBrowserShortcut(key()) && browser.pathField.currentEditor() == nil
                && browser.location == .directory(fixture), "F6 trapped the address editor or navigated without Return")
            browser.focusBrowserContent()
            try require(browser.routeBrowserShortcut(key(true)), "Shift-F6 was absent from the selected keyboard preset")
            try require(browser.routeBrowserShortcut(key()) && window.firstResponder === browser.activeFileView,
                "F6 did not return from the query control to the actual file surface")
            let originalTab = browser.activeID
            browser.newTab(nil)
            let extraTab = browser.activeID
            try require(extraTab != originalTab, "Keyboard tab fixture did not create its second tab")
            browser.navigate(to: .directory(fixture)); try await UIVerification.settled(browser)
            browser.focusLocation(nil)
            let nextID = browser.tabs[(browser.activeIndex + 1) % browser.tabs.count].id
            let next = UIVerification.key("\t", code: 48, flags: .control, window: window)
            let previous = UIVerification.key("\t", code: 48, flags: [.control, .shift], window: window)
            try require(browser.routeBrowserShortcut(next) && browser.activeID == nextID
                && browser.pathField.currentEditor() == nil, "Control-Tab was trapped by the address field")
            try await UIVerification.settled(browser)
            browser.focusFilter(nil)
            try require(browser.folderFilter.displayedField.currentEditor() != nil
                && browser.routeBrowserShortcut(previous) && browser.activeID == extraTab,
                "Control-Shift-Tab was trapped by the query field")
            try await UIVerification.settled(browser)
            browser.focusLocation(nil)
            if let editor = window.firstResponder as? NSTextView {
                editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                try require(!browser.routeBrowserShortcut(next) && browser.activeID == extraTab,
                    "Tab navigation intercepted marked IME input")
                editor.unmarkText(); browser.cancelLocationEditing()
            }
            browser.closeTab(id: extraTab); browser.selectTab(originalTab)
            try await UIVerification.settled(browser)
        }
        let selected = Array(browser.displayedEntries.filter { $0.kind == .file }.prefix(2).map(\.url))
        try require(selected.count == 2, "Keyboard context-menu fixture lacks two local files")
        for mode in [BrowserViewMode.details, .icons] {
            browser.paneViewMode = mode; browser.applyDisplayPreferences()
            browser.setFileSelection(Set(selected)); browser.focusBrowserContent()
            let before = browser.selectedURLs
            let request = browser.keyboardContextMenuRequest()
            try require(request?.menu.items.contains(where: { $0.action == #selector(BrowserViewController.copyFileURLs(_:)) }) == true
                && browser.selectedURLs == before && before == Set(selected),
                "Keyboard context-menu preparation changed selection or lost its shared file commands")
        }
        browser.navigate(to: .computer); try await UIVerification.settled(browser)
        let outline = browser.outline
        try require(outline.selectedRow >= 0 && window.makeFirstResponder(outline), "This Mac sidebar selection did not accept focus")
        try await Task.sleep(for: .milliseconds(25))
        let selectedRow = outline.selectedRow
        let row = outline.rowView(atRow: selectedRow, makeIfNecessary: true)
        try require(row?.isEmphasized == true && BrowserSelectionFocus.isEmphasized(in: outline),
            "Focused sidebar selection did not use active native emphasis")
        browser.focusBrowserContent()
        try await Task.sleep(for: .milliseconds(25))
        try require(outline.selectedRow == selectedRow && row?.isEmphasized == false,
            "Moving focus into This Mac left active blue sidebar emphasis or erased its location selection")
        browser.navigate(to: .directory(fixture)); try await UIVerification.settled(browser)
        browser.focusBrowserContent()
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
    private final class UserOverrideItem: NSMenuItem {
        override var userKeyEquivalent: String { "k" }
    }
}
#endif
