import AppKit
import Carbon
import Combine
import ExplorerCore

@MainActor
extension BrowserShortcut {
    init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var flags: ShortcutModifiers = []
        for (native, logical) in [(NSEvent.ModifierFlags.command, ShortcutModifiers.command), (.control, .control), (.option, .option), (.shift, .shift)] {
            if event.modifierFlags.contains(native) { flags.insert(logical) }
        }
        if let named = Self.namedKeys[event.keyCode] { self.init(.special(named), flags); return }
        guard let character = event.characters(byApplyingModifiers: [])?.precomposedStringWithCanonicalMapping.lowercased(),
              character.count == 1 else { return nil }
        self.init(.character(character), flags)
    }
    static let namedKeys: [UInt16: ShortcutSpecialKey] = [36: .returnKey, 76: .returnKey, 48: .tab, 51: .backspace,
        117: .forwardDelete, 49: .space, 53: .escape, 123: .left, 124: .right, 126: .up, 125: .down,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6, 98: .f7, 100: .f8, 101: .f9, 109: .f10, 103: .f11, 111: .f12]
    var nativeModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for (logical, native) in [(ShortcutModifiers.command, NSEvent.ModifierFlags.command), (.control, .control), (.option, .option), (.shift, .shift)] {
            if modifiers.contains(logical) { flags.insert(native) }
        }
        return flags
    }
    var menuEquivalent: String {
        switch key {
        case .character(let value): return value
        case .special(let value):
            let codes: [ShortcutSpecialKey: UInt32] = [.returnKey: 13, .tab: 9, .backspace: 8, .forwardDelete: UInt32(NSDeleteFunctionKey),
                .space: 32, .escape: 27, .left: UInt32(NSLeftArrowFunctionKey), .right: UInt32(NSRightArrowFunctionKey),
                .up: UInt32(NSUpArrowFunctionKey), .down: UInt32(NSDownArrowFunctionKey), .f1: UInt32(NSF1FunctionKey),
                .f2: UInt32(NSF2FunctionKey), .f3: UInt32(NSF3FunctionKey), .f4: UInt32(NSF4FunctionKey), .f5: UInt32(NSF5FunctionKey),
                .f6: UInt32(NSF6FunctionKey), .f7: UInt32(NSF7FunctionKey), .f8: UInt32(NSF8FunctionKey), .f9: UInt32(NSF9FunctionKey),
                .f10: UInt32(NSF10FunctionKey), .f11: UInt32(NSF11FunctionKey), .f12: UInt32(NSF12FunctionKey)]
            return codes[value].flatMap(UnicodeScalar.init).map(String.init) ?? ""
        }
    }
}

/// The public Carbon snapshot is serialized on the main actor and refreshed on
/// editor/app activation. No per-keystroke OS query or global event tap.
@MainActor
final class SystemShortcutSnapshot: ObservableObject {
    static let shared = SystemShortcutSnapshot()
    private struct Key: Hashable { let code: UInt16; let modifiers: Int }
    private var enabled = Set<Key>()
    @Published private(set) var status = "System shortcut check has not run."
    func refresh() {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else {
            status = "System shortcut check unavailable. macOS and other apps may reserve more shortcuts."; return
        }
        var keys = Set<Key>()
        for item in list where (item[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true {
            guard let code = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let raw = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { continue }
            guard let flags = Self.supportedModifiers(raw.intValue) else { continue }
            keys.insert(Key(code: code.uint16Value, modifiers: flags.rawValue))
        }
        enabled = keys
        status = "Checked \(keys.count) enabled system shortcuts. App-specific overrides and third-party shortcuts may also take precedence."
    }
    func conflicts(_ event: NSEvent) -> Bool {
        guard let shortcut = BrowserShortcut(event) else { return false }
        return shortcut.isReserved || enabled.contains(Key(code: event.keyCode, modifiers: shortcut.modifiers.rawValue))
    }
    /// The editor supports four modifiers. A system Fn-qualified shortcut is
    /// distinct: dropping Fn would falsely reserve its unqualified counterpart.
    /// Fn-qualified reservations cannot be represented by this four-key map.
    static func supportedModifiers(_ raw: Int) -> ShortcutModifiers? {
        guard raw & Int(kEventKeyModifierFnMask) == 0 else { return nil }
        var flags: ShortcutModifiers = []
        for (native, logical) in [(Int(cmdKey), ShortcutModifiers.command), (Int(controlKey), .control), (Int(optionKey), .option), (Int(shiftKey), .shift)] {
            if raw & native != 0 { flags.insert(logical) }
        }
        return flags
    }
}

@MainActor
extension BrowserCommand {
    var isPresentedInBuild: Bool {
        if self == .openTrash { return OwnedTrashFeature.browseAvailable }
        if self == .copyOnServer { return SMBRemoteActionFeature.copiesAvailable }
        return self != .moveOnServer || SMBRemoteActionFeature.movesAvailable || SFTPRemoteActionFeature.movesAvailable
    }
    var selector: Selector {
        switch self {
        case .selectionMenu: #selector(BrowserViewController.showKeyboardContextMenu(_:))
        case .openTerminal: #selector(BrowserViewController.openTerminalHere(_:))
        case .compareFiles: #selector(BrowserViewController.compareSelectedFiles(_:))
        case .findCommand: #selector(BrowserViewController.findCommand(_:))
        case .launchProfiles: #selector(BrowserViewController.showLaunchProfiles(_:))
        case .switchLaunchProfile: #selector(BrowserViewController.switchLaunchProfile(_:))
        case .copyToPane: #selector(BrowserViewController.copyToOtherPane(_:))
        case .moveToPane: #selector(BrowserViewController.moveToOtherPane(_:))
        case .moveOnServer: #selector(BrowserViewController.moveServerSelection(_:))
        case .copyOnServer: #selector(BrowserViewController.copyServerSelection(_:))
        case .saveFolderView: #selector(BrowserViewController.saveFolderView(_:))
        case .applyFolderView: #selector(BrowserViewController.applySavedFolderView(_:))
        case .forgetFolderView: #selector(BrowserViewController.forgetFolderView(_:))
        case .folderViews: #selector(BrowserViewController.showFolderViews(_:))
        case .connectServer: #selector(BrowserViewController.showSMBConnections(_:))
        case .disconnectServer: #selector(BrowserViewController.disconnectCurrentConnection(_:))
        case .browseArchive: #selector(BrowserViewController.browseZIP(_:))
        case .extractArchive: #selector(BrowserViewController.extractArchive(_:))
        case .createZIP: #selector(BrowserViewController.createZIP(_:))
        case .batchRename: #selector(BrowserViewController.batchRenameSelection(_:))
        case .namesAndLabels: #selector(BrowserViewController.editPrivateNames(_:))
        case .rememberedItems: #selector(BrowserViewController.showPrivateNames(_:))
        case .storageAnalysis: #selector(BrowserViewController.showStorageAnalysis(_:))
        case .directFilter: #selector(BrowserViewController.chooseDirectFilter(_:))
        case .searchFolder: #selector(BrowserViewController.chooseFolderSearch(_:))
        case .searchThisMac: #selector(BrowserViewController.chooseThisMacSearch(_:))
        case .open: #selector(BrowserViewController.openSelection(_:))
        case .openWith: #selector(BrowserViewController.openWithSelection(_:))
        case .editText: #selector(BrowserViewController.editTextInTraverse(_:))
        case .share: #selector(BrowserViewController.shareSelection(_:))
        case .quickLook: #selector(BrowserViewController.showQuickLook(_:))
        case .properties: #selector(BrowserViewController.showProperties(_:))
        case .revealInFinder: #selector(BrowserViewController.revealInFinder(_:))
        case .copy: #selector(BrowserViewController.copyFileURLs(_:))
        case .duplicate: #selector(BrowserViewController.duplicateSelection(_:))
        case .cut: #selector(BrowserViewController.cutFileURLs(_:))
        case .paste: #selector(BrowserViewController.pasteFileURLs(_:))
        case .moveCopied: #selector(BrowserViewController.moveCopiedFiles(_:))
        case .pasteOptions: #selector(BrowserViewController.pasteWithOptions(_:))
        case .copyPath: #selector(BrowserViewController.copyPath(_:))
        case .copyNames: #selector(BrowserViewController.copyNames(_:))
        case .copyRelativePaths: #selector(BrowserViewController.copyRelativePaths(_:))
        case .dismissClipboard: #selector(BrowserViewController.dismissAppClipboard(_:))
        case .selectAll: #selector(BrowserViewController.selectAllBrowserFiles(_:))
        case .newFolder: #selector(BrowserViewController.createFolder(_:))
        case .newTextFile: #selector(BrowserViewController.createTextFile(_:))
        case .newFolderWithSelection: #selector(BrowserViewController.newFolderWithSelection(_:))
        case .sendViaAirDrop: #selector(BrowserViewController.sendViaAirDrop(_:))
        case .rename: #selector(BrowserViewController.renameSelection(_:))
        case .trash: #selector(BrowserViewController.trashSelection(_:))
        case .undo: #selector(BrowserViewController.undoFileOperation(_:))
        case .back: #selector(BrowserViewController.goBack(_:))
        case .forward: #selector(BrowserViewController.goForward(_:))
        case .up: #selector(BrowserViewController.goUp(_:))
        case .computer: #selector(BrowserViewController.goComputer(_:))
        case .home: #selector(BrowserViewController.goHome(_:))
        case .refresh: #selector(BrowserViewController.refresh(_:))
        case .address: #selector(BrowserViewController.focusLocation(_:))
        case .filter: #selector(BrowserViewController.focusFilter(_:))
        case .search: #selector(BrowserViewController.showMetadataSearch(_:))
        case .newTab: #selector(BrowserViewController.newTab(_:))
        case .closeTab: #selector(BrowserViewController.closeTab(_:))
        case .duplicateTab: #selector(BrowserViewController.duplicateCurrentTab(_:))
        case .reopenTab: #selector(BrowserViewController.reopenClosedTab(_:))
        case .tabLeft: #selector(BrowserViewController.moveCurrentTabLeft(_:))
        case .tabRight: #selector(BrowserViewController.moveCurrentTabRight(_:))
        case .nextTab: #selector(BrowserViewController.nextBrowserTab(_:))
        case .previousTab: #selector(BrowserViewController.previousBrowserTab(_:))
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9: #selector(BrowserViewController.selectNumberedBrowserTab(_:))
        case .nextFocus: #selector(BrowserViewController.nextBrowserControl(_:))
        case .previousFocus: #selector(BrowserViewController.previousBrowserControl(_:))
        case .splitRight: #selector(BrowserViewController.splitPaneRight(_:))
        case .splitBelow: #selector(BrowserViewController.splitPaneBelow(_:))
        case .closePane: #selector(BrowserViewController.closePane(_:))
        case .nextPane: #selector(BrowserViewController.focusOtherPane(_:))
        case .previewPane: #selector(BrowserViewController.toggleInlinePreview(_:))
        case .hiddenFiles: #selector(BrowserViewController.toggleHidden(_:))
        case .pathBar: #selector(BrowserViewController.togglePathBar(_:))
        case .compactRows: #selector(BrowserViewController.toggleCompactRows(_:))
        case .extensions: #selector(BrowserViewController.toggleExtensions(_:))
        case .foldersFirst: #selector(BrowserViewController.toggleFoldersFirst(_:))
        case .details, .list, .icons: #selector(BrowserViewController.changeViewMode(_:))
        case .queue: #selector(BrowserViewController.showTransferQueue(_:))
        case .progress: #selector(BrowserViewController.showFileOperationDetails(_:))
        case .stop: #selector(BrowserViewController.cancelFileOperation(_:))
        case .results: #selector(BrowserViewController.showLastOperationResult(_:))
        case .continueRemaining: #selector(BrowserViewController.continueRemainingTransfer(_:))
        case .recovery: #selector(BrowserViewController.showOperationRecovery(_:))
        case .openTrash: #selector(BrowserViewController.showOwnedTrash(_:))
        case .drives: #selector(BrowserViewController.showDriveControls(_:))
        case .driveManagement: #selector(BrowserViewController.showDriveManagement(_:))
        case .driveBenchmark: #selector(BrowserViewController.showDriveBenchmark(_:))
        case .rememberFolder: #selector(BrowserViewController.rememberFolder(_:))
        case .pinFolder: #selector(BrowserViewController.pinCurrentFolder(_:))
        case .renamePin: #selector(BrowserViewController.renameSelectedPin(_:))
        case .removePin: #selector(BrowserViewController.removeSelectedPin(_:))
        case .pinUp: #selector(BrowserViewController.moveSelectedPinUp(_:))
        case .pinDown: #selector(BrowserViewController.moveSelectedPinDown(_:))
        }
    }
    static func command(for item: NSMenuItem) -> Self? {
        // The configured variant shares validation/dispatch, not the direct
        // command's shortcut. Binding both would duplicate Command-Shift-N.
        if item.action == #selector(BrowserViewController.createFolder(_:)),
           item.representedObject as? String == "named-local-folder" { return nil }
        switch item.action {
        case #selector(NSText.copy(_:)): return .copy
        case #selector(NSText.cut(_:)): return .cut
        case #selector(NSText.paste(_:)): return .paste
        case #selector(NSText.selectAll(_:)): return .selectAll
        case #selector(FileTableView.undo(_:)): return .undo
        case #selector(BrowserViewController.changeViewMode(_:)):
            return [BrowserCommand.details, .list, .icons].indices.contains(item.tag) ? [BrowserCommand.details, .list, .icons][item.tag] : nil
        default: return item.action.flatMap { commandBySelector[$0] }
        }
    }
    private static let commandBySelector: [Selector: BrowserCommand] = {
        var values: [Selector: BrowserCommand] = [:]
        for action in allCases where action.tabIndex == nil && ![.details, .list, .icons].contains(action) { values[action.selector] = action }
        return values
    }()
}

@MainActor
extension BrowserViewController {
    func routeBrowserShortcut(_ event: NSEvent) -> Bool {
        guard isActiveCommandPane, hasFileCommandFocus, !isBrowserSuspended, view.window?.attachedSheet == nil,
              NSApplication.shared.modalWindow == nil, let shortcut = BrowserShortcut(event) else { return false }
        let editing = view.window?.firstResponder is NSTextView
        if editing {
            if (view.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            // Only dedicated navigation keys leave our own address/search
            // fields. Other text editors and marked IME input keep their keys.
            let ownField = browserFieldOwnsEditor(view.window?.firstResponder)
            let navigationKey = shortcut.key == .special(.f6)
                || (shortcut.key == .special(.tab) && [.control, [.control, .shift], [.command, .option]].contains(shortcut.modifiers))
            if ownField, navigationKey,
               let action = settings.shortcutMap.resolve(shortcut, fileSurface: false),
               [.nextFocus, .previousFocus, .nextTab, .previousTab, .nextPane].contains(action),
               !SystemShortcutSnapshot.shared.conflicts(event),
               !BrowserShortcutMenus.hasUserOverride(action, in: NSApplication.shared.mainMenu) {
                if commandEnabled(action.selector) { NSApp.sendAction(action.selector, to: self, from: nil) }
                return true
            }
            if settings.behavior.explorerFunctionKeysEnabled, shortcut.modifiers.intersection([.command, .control, .option]).isEmpty {
                if shortcut.key == .special(.f4) { focusLocation(nil); return true }
            }
            return false
        }
        guard !SystemShortcutSnapshot.shared.conflicts(event) else { return false }
        if transferQueueDetails.consumeShortcut(event) { return true }
        let responder = view.window?.firstResponder
        let fileSurface = responder === activeFileView || responder === volumeBrowser.collectionView
        if let action = settings.shortcutMap.resolve(shortcut, fileSurface: fileSurface) {
            guard !BrowserShortcutMenus.hasUserOverride(action, in: NSApplication.shared.mainMenu) else { return false }
            if !event.isARepeat || action.allowsRepeat {
                if action == .trash, isRemoteLocation {
                    if commandEnabled(#selector(deleteRemoteFilePermanently(_:))) { deleteRemoteFilePermanently(nil) }
                    return true // Remote Delete always asks; it never becomes a local Trash request.
                }
                if action == .dismissClipboard, transferFeedback == nil { return true }
                if commandEnabled(action.selector) {
                    if [.details, .list, .icons].contains(action) {
                        let sender = NSMenuItem(); sender.tag = [BrowserCommand.details, .list, .icons].firstIndex(of: action)!
                        changeViewMode(sender)
                    } else if let index = action.tabIndex {
                        let sender = NSMenuItem(); sender.tag = index; selectNumberedBrowserTab(sender)
                    } else { NSApplication.shared.sendAction(action.selector, to: self, from: nil) }
                }
            }
            return true // A disabled binding cannot fall through to another command.
        }
        return false
    }
    @objc func dismissAppClipboard(_ sender: Any?) {
        synchronizeTransferClipboard()
        if let feedback = transferFeedback { _ = clipboardState.dismiss(feedbackID: feedback.id); renderTransferFeedback() }
    }
    @objc func selectAllBrowserFiles(_ sender: Any?) {
        if isRemoteLocation { selectAllLoadedRemoteItems(sender) }
        else if showsComputerVolumes { volumeBrowser.selectAll() } else { selectAllFiles() }
    }
    private func browserFieldOwnsEditor(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        return pathField.currentEditor() === responder || folderFilter.displayedField.currentEditor() === responder
    }
    @objc func nextBrowserTab(_ sender: Any?) { if canManageBrowserTabs { cycleTab(backward: false) } }
    @objc func previousBrowserTab(_ sender: Any?) { if canManageBrowserTabs { cycleTab(backward: true) } }
    @objc func selectNumberedBrowserTab(_ sender: NSMenuItem) {
        let index = sender.tag == 8 ? tabs.count - 1 : sender.tag
        if tabs.indices.contains(index) { selectTab(tabs[index].id) }
    }
    @objc func nextBrowserControl(_ sender: Any?) { cycleBrowserFocus(backward: false) }
    @objc func previousBrowserControl(_ sender: Any?) { cycleBrowserFocus(backward: true) }
}

/// Menus retain native user overrides. Edit equivalents switch back to native
/// text keys while an editor has focus. Open With retains its own menu delegate.
@MainActor
final class BrowserShortcutMenus: NSObject, NSMenuDelegate {
    static let shared = BrowserShortcutMenus()
    private let owners = NSMapTable<NSMenu, BrowserViewController>.weakToWeakObjects()
    static func bind(_ menu: NSMenu, to browser: BrowserViewController) {
        if menu.delegate == nil || menu.delegate === shared {
            shared.owners.setObject(browser, forKey: menu); menu.delegate = shared
            refresh(menu, browser: browser)
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let owner = owners.object(forKey: menu) { Self.refresh(menu, browser: owner) }
    }
    static func refresh(_ menu: NSMenu?, browser: BrowserViewController) {
        guard let menu else { return }
        let editing = NSApplication.shared.keyWindow?.firstResponder is NSTextView
        let responder = browser.viewIfLoaded?.window?.firstResponder
        let fileSurface = !editing && (responder === browser.activeFileView || responder === browser.volumeBrowser.collectionView)
        let map = browser.settings.shortcutMap
        for item in menu.items {
            if let action = BrowserCommand.command(for: item) {
                let nativeText: [BrowserCommand: String] = [.copy: "c", .cut: "x", .paste: "v", .undo: "z", .selectAll: "a"]
                if action == .undo, item.action == action.selector {
                    // Edit → Undo owns the shortcut and follows the responder
                    // chain into either the file surface or native text. The
                    // explicit File command is available by menu action only.
                    item.keyEquivalent = ""
                } else if editing, let key = nativeText[action] {
                    // File commands have explicit browser selectors. They must
                    // not compete with responder-chain text editing, including
                    // a native item whose target AppKit has resolved already.
                    if item.action == action.selector { item.keyEquivalent = "" }
                    else { item.keyEquivalent = key; item.keyEquivalentModifierMask = .command }
                } else if let primary = map.shortcuts(for: action).first(where: { fileSurface || !$0.requiresFileSurface }) {
                    item.keyEquivalent = primary.menuEquivalent; item.keyEquivalentModifierMask = primary.nativeModifiers
                } else { item.keyEquivalent = "" }
            }
            if let submenu = item.submenu, submenu.delegate == nil || submenu.delegate === shared {
                shared.owners.setObject(browser, forKey: submenu); submenu.delegate = shared
                refresh(submenu, browser: browser)
            }
        }
    }
    static func hasUserOverride(_ action: BrowserCommand, in menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        return menu.items.contains { item in
            (BrowserCommand.command(for: item) == action && !item.userKeyEquivalent.isEmpty)
                || hasUserOverride(action, in: item.submenu)
        }
    }
}
