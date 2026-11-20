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
        try await verifyRestoredArchiveViewControl(fixture: fixture)
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
            let reverseFocus = UIVerification.key(String(UnicodeScalar(NSF6FunctionKey)!), code: 97,
                                                  flags: [.shift], window: window)
            try require(!window.performKeyEquivalent(with: reverseFocus) && window.firstResponder === editor
                    && editor.hasMarkedText() && editor.string == marked,
                        "Native reverse focus changed marked address text")
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
        let focusKey = BrowserShortcut(.special(.f6)).menuEquivalent
        try require(!BrowserShortcutMenus.hasUserKeyEquivalent(focusKey, in: window),
                    "An unrelated native override claimed the focus key")
        override.equivalent = focusKey
        try require(BrowserShortcutMenus.hasUserKeyEquivalent(focusKey, in: window),
                    "The focus key would bypass another command's native override")
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
    private static func verifyRestoredArchiveViewControl(fixture: URL) async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.reviewsRecoveryAtStartup = false
        let cold = BrowserViewController(settings: settings)
        cold.permitsBackgroundVerification = true
        cold.folderAccess = FolderAccessController(stateDirectory: nil)
        let reference = try ArchiveLocation(source: fixture.appendingPathComponent("Unprepared.tar.gz"), format: .tar)
        let tab = BrowserTab(location: .archive(reference))
        cold.tabs = [tab]; cold.activeID = tab.id
        cold.tabs[0].resolveFolderView(mode: .details, sort: .init())
        _ = cold.view
        defer { cold.suspendBrowser() }
        // Restore a passive reference before constructing the native controls;
        // this must not prepare or read the referenced archive body.
        cold.applyDisplayPreferences(); cold.updateNavigation()
        try require(!cold.viewModeControl.isEnabled, "A restored archive enabled local view choices")
        cold.navigate(to: .directory(fixture))
        try await UIVerification.settled(cold)
        let expected = BrowserViewMode.allCases.firstIndex(of: cold.effectiveViewMode)
        try require(cold.viewModeControl.isEnabled && cold.viewModeControl.selectedSegment == expected,
                    "Returning from a cold restored archive lost the selected local file-view control")
    }

    static func verifyArchiveContextMenu(_ table: FileTableView, browser: BrowserViewController,
                                        settings: BrowserSettings, label: String) throws {
        guard let window = table.window, window.isKeyWindow, table.numberOfRows >= 2,
              window.makeFirstResponder(table) else {
            throw UIVerification.Failure(message: "\(label) keyboard menu needs its actual focused member table")
        }
        let profile = settings.keyboardProfile, bindings = settings.shortcutPreferences, behavior = settings.customBehavior
        let provider = table.contextMenuProvider, menu = table.menu, selection = table.selectedRowIndexes
        let mainMenu = NSApp.mainMenu, windowMenu = NSApp.windowsMenu, helpMenu = NSApp.helpMenu
        defer {
            table.contextMenuProvider = provider; table.menu = menu
            settings.customBehavior = behavior; settings.shortcutPreferences = bindings; settings.keyboardProfile = profile
            table.selectRowIndexes(selection, byExtendingSelection: false)
            NSApp.mainMenu = mainMenu; NSApp.windowsMenu = windowMenu; NSApp.helpMenu = helpMenu
        }
        if let archive = table as? ArchiveMetadataTable, window is ArchiveKeyboardWindow {
            try verifyStandaloneArchiveKeys(archive, settings: settings, label: label)
        }
        // Direct table routing is checked separately from menu interception.
        // The complete production event path below uses the real app menu.
        NSApp.mainMenu = nil
        let members = IndexSet([0, table.numberOfRows - 1])
        table.selectRowIndexes(members, byExtendingSelection: false)
        var requests = 0
        // Reach the actual key route without entering a native menu tracking
        // loop. Returning no menu preserves an unattended, bounded regression.
        table.menu = nil
        table.contextMenuProvider = { requests += 1; return nil }
        func direct(_ event: NSEvent) {
            // Browser preference subscribers can rebuild the menu while this
            // check switches presets. Keep each direct route isolated; the
            // normal menu/event pipeline is exercised separately below.
            NSApp.mainMenu = nil
            BrowserShortcutMenus.refreshWindowMenus(window, browser: browser)
            table.keyDown(with: event)
        }
        SystemShortcutSnapshot.shared.refresh()
        let key = UIVerification.key(String(UnicodeScalar(NSF10FunctionKey)!), code: 109, flags: .shift, window: window)
        try require(!SystemShortcutSnapshot.shared.conflicts(key), "The system reserves the generated Show Context Menu chord")
        for preset in [KeyboardProfile.mac, .explorer] {
            settings.keyboardProfile = preset; settings.shortcutPreferences = .init(); requests = 0
            direct(key)
            try require(requests == 1 && table.selectedRowIndexes == members,
                "\(label) did not route Show Context Menu to its existing menu without changing the selection")
        }
        settings.customizeBehavior()
        settings.shortcutPreferences = .init(overrides: [.selectionMenu: []]); requests = 0
        try require(settings.shortcutMap.shortcuts(for: .selectionMenu).isEmpty && settings === browser.settings,
            "\(label) generated cleared-binding setup disagrees with its browser settings")
        if !(window is ArchiveKeyboardWindow) {
            NSApp.mainMenu = BrowserMenus.applicationMenu(target: browser)
            NSApp.sendEvent(key)
            try require(requests == 0 && table.selectedRowIndexes == members,
                "\(label) native dispatch retained a cleared default key through a header menu")
        }
        direct(key)
        try require(requests == 0 && table.selectedRowIndexes == members,
            "\(label) retained a cleared context-menu binding or changed the selection")
        let candidates: [(ShortcutSpecialKey, UInt16)] = [(.f7, 98), (.f8, 100), (.f9, 101), (.f10, 109), (.f11, 103), (.f12, 111)]
        guard let custom = candidates.map({ event($0.0, code: $0.1, window: window) })
            .first(where: { !SystemShortcutSnapshot.shared.conflicts($0) }), let chord = BrowserShortcut(custom) else {
            throw UIVerification.Failure(message: "No free generated context-menu chord")
        }
        settings.shortcutPreferences = .init(overrides: [.selectionMenu: [chord]]); requests = 0
        direct(custom)
        try require(requests == 1 && table.selectedRowIndexes == members,
            "\(label) lost its custom context-menu binding or multiple selection")
        requests = 0
        table.showContextMenuForSelection(nil)
        try require(requests == 1 && table.selectedRowIndexes == members,
            "\(label) changed its selection through the native keyboard/Accessibility menu action")
        settings.keyboardProfile = .explorer; settings.shortcutPreferences = .init(); requests = 0
        NSApp.mainMenu = BrowserMenus.applicationMenu(target: browser)
        let action = #selector(BrowserViewController.showKeyboardContextMenu(_:))
        let go = NSApp.mainMenu?.items.first { $0.submenu?.title == "Go" }?.submenu
        let navigation = go?.items.first { $0.title == "Keyboard Navigation" }?.submenu
        guard let command = navigation?.items.first(where: { $0.action == action }) else {
            throw UIVerification.Failure(message: "Generated main menu lost Show Context Menu")
        }
        if window is ArchiveKeyboardWindow {
            try require(window.makeFirstResponder(nil), "Archive window did not release its member-table focus")
            try require(!table.validateMenuItem(command), "Cached archive menu stayed enabled after focus left its table")
            (table as? ArchiveMetadataTable)?.showKeyboardContextMenu(nil)
            try require(requests == 0 && table.selectedRowIndexes == members,
                "A cached archive menu acted after focus moved to another control")
            try require(window.makeFirstResponder(table), "Archive window did not restore member-table focus")
            try require(command.target as? ArchiveMetadataTable === table,
                "Archive focus did not update the real main menu's target")
        }
        try require(NSApp.mainMenu?.performKeyEquivalent(with: key) == true && requests == 1 && table.selectedRowIndexes == members,
            "\(label) menu-bar equivalent did not reach the focused archive table")
        requests = 0
        NSApp.sendEvent(key)
        try require(requests == 1 && table.selectedRowIndexes == members,
            "\(label) full native event dispatch lost its menu request or dispatched twice")
        settings.customizeBehavior(); settings.shortcutPreferences = .init(overrides: [.selectionMenu: [chord]])
        try require(window.makeFirstResponder(nil) && window.makeFirstResponder(table), "Custom menu focus did not return")
        requests = 0; NSApp.sendEvent(custom)
        try require(requests == 1 && table.selectedRowIndexes == members,
            "\(label) custom chord did not survive the real window/menu event path")
        settings.shortcutPreferences = .init(overrides: [.selectionMenu: []])
        try require(window.makeFirstResponder(nil) && window.makeFirstResponder(table), "Cleared menu focus did not return")
        requests = 0; NSApp.sendEvent(custom)
        try require(requests == 0 && table.selectedRowIndexes == members,
            "\(label) real menu event retained a cleared custom chord")
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
    private static func verifyStandaloneArchiveKeys(_ table: ArchiveMetadataTable, settings: BrowserSettings, label: String) throws {
        guard let window = table.window else { throw UIVerification.Failure(message: "Standalone shortcut window missing") }
        let open = table.onOpen, rename = table.onRename, preview = table.onPreview
        let copy = table.onCopy, cut = table.onCut, paste = table.onPaste, validation = table.commandValidation
        let menu = NSApp.mainMenu
        defer {
            table.onOpen = open; table.onRename = rename; table.onPreview = preview
            table.onCopy = copy; table.onCut = cut; table.onPaste = paste; table.commandValidation = validation
            NSApp.mainMenu = menu
        }
        var opened = 0, renamed = 0, previewed = 0
        table.onOpen = { opened += 1 }; table.onRename = { renamed += 1 }; table.onPreview = { previewed += 1 }
        NSApp.mainMenu = nil
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let key = UIVerification.key("\r", code: 36, flags: [], window: window)
        settings.keyboardProfile = .mac; settings.shortcutPreferences = .init()
        table.keyDown(with: key)
        try require(renamed == 1 && opened == 0, "\(label) Return ignored the Mac Rename preference")
        settings.keyboardProfile = .explorer; settings.shortcutPreferences = .init()
        table.keyDown(with: key)
        try require(opened == 1 && renamed == 1, "\(label) Return lost the Explorer Open preference")
        settings.customizeBehavior()
        settings.shortcutPreferences = .init(overrides: [.open: [], .rename: [], .quickLook: [.init(.special(.returnKey))]])
        try require(settings.shortcutMap.issues.isEmpty, "Standalone remapped Return setup is invalid")
        table.keyDown(with: key)
        try require(previewed == 1 && opened == 1 && renamed == 1, "\(label) Return ignored the remapped Preview action")
        settings.shortcutPreferences = .init(overrides: [.open: [], .rename: []])
        table.keyDown(with: key)
        try require(previewed == 1 && opened == 1 && renamed == 1, "\(label) cleared Return still invoked an archive action")
        settings.shortcutPreferences = .init(overrides: [.filter: []])
        let find = UIVerification.key("f", code: 3, flags: .command, window: window)
        try require(window.makeFirstResponder(table), "Standalone Find fixture lost its table")
        try require(!window.performKeyEquivalent(with: find) && !(window.firstResponder is NSTextView),
            "\(label) retained the cleared Find shortcut")
        SystemShortcutSnapshot.shared.refresh()
        let candidates: [(ShortcutSpecialKey, UInt16)] = [(.f7, 98), (.f8, 100), (.f9, 101), (.f10, 109)]
        guard let custom = candidates.map({ event($0.0, code: $0.1, window: window) })
            .first(where: { !SystemShortcutSnapshot.shared.conflicts($0) }), let chord = BrowserShortcut(custom) else {
            throw UIVerification.Failure(message: "No free standalone Find test chord")
        }
        settings.shortcutPreferences = .init(overrides: [.filter: [chord]])
        NSApp.mainMenu = nil
        try require(window.performKeyEquivalent(with: custom) && window.firstResponder is NSTextView,
            "\(label) lost its remapped Find shortcut")
        try require(window.makeFirstResponder(table), "Standalone Find did not release its editor")
        var copies = 0, cuts = 0, pastes = 0
        table.onCopy = { copies += 1 }; table.onCut = { cuts += 1 }; table.onPaste = { pastes += 1 }
        table.commandValidation = { _ in true }
        for action in [BrowserCommand.copy, .cut, .paste] {
            settings.shortcutPreferences = .init(overrides: [action: [chord]])
            NSApp.mainMenu = menu
            try require(window.performKeyEquivalent(with: custom), "\(label) did not own its clipboard equivalent")
        }
        try require(copies == 1 && cuts == 1 && pastes == 1, "\(label) lost a remapped clipboard shortcut")
        table.commandValidation = { _ in false }; table.keyDown(with: custom)
        try require(pastes == 1, "\(label) dispatched a refused Paste")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
    private final class UserOverrideItem: NSMenuItem {
        var equivalent = "k"
        override var userKeyEquivalent: String { equivalent }
    }
}
#endif
