import Foundation

public enum BrowserCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case open, openWith, share, sendViaAirDrop, quickLook, properties, revealInFinder
    case editText
    case copy, cut, paste, moveCopied, pasteOptions, copyPath, dismissClipboard, selectAll
    case copyNames, copyRelativePaths
    case newFolder, newTextFile, newFolderWithSelection, duplicate, rename, trash, undo
    case back, forward, up, computer, home, refresh, address, filter, search
    case directFilter, searchFolder, searchThisMac
    case newTab, closeTab, duplicateTab, reopenTab, tabLeft, tabRight, nextTab, previousTab
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9
    case nextFocus, previousFocus, splitRight, splitBelow, closePane, nextPane, swapPaneSides, balancePaneSizes
    case rotatePaneSplit, linkPaneNavigation, selectMatchingPaneItem
    case previewPane, hiddenFiles, pathBar, compactRows, extensions, foldersFirst, details, list, icons
    case queue, progress, stop, results, continueRemaining, recovery, openTrash, drives, driveManagement, driveBenchmark
    case rememberFolder, pinFolder, renamePin, removePin, pinUp, pinDown
    case launchProfiles, browseArchive, extractArchive, createZIP, batchRename, namesAndLabels, rememberedItems, storageAnalysis
    case saveFolderView, applyFolderView, forgetFolderView, folderViews
    case connectServer, disconnectServer
    case switchLaunchProfile
    case copyToPane, moveToPane, moveOnServer, copyOnServer
    case findCommand, selectionMenu, openTerminal, compareFiles, compareFolders, selectByName, compareTextFiles, compareGitRevisions
    case gitFileHistory, gitFolderHistory, reviewStagedChanges, compareGitWorkingFolder, compareGitWorkingFile
    case compareGitFileRevisions, browseGitWorktrees, compareGitCheckouts, stageGitFile, unstageGitFile
    public var id: Self { self }
    public var title: String {
        switch self {
        case .open: "Open Selection"; case .openWith: "Open With"; case .share: "Share"; case .quickLook: "Quick Look"
        case .editText: "Edit in Traverse"
        case .sendViaAirDrop: "Send via AirDrop"
        case .properties: "Properties"; case .revealInFinder: "Reveal in Finder"
        case .copy: "Copy Files"; case .cut: "Cut Files"; case .paste: "Paste Files"; case .moveCopied: "Move Copied Items Here"
        case .pasteOptions: "Paste with Options"; case .copyPath: "Copy Path"; case .dismissClipboard: "Dismiss App Clipboard Intent"
        case .copyNames: "Copy Names"; case .copyRelativePaths: "Copy Relative Paths"
        case .selectAll: "Select All Files"; case .newFolder: "New Folder"; case .rename: "Rename"; case .trash: "Move to Trash"; case .undo: "Undo File Operation"
        case .newFolderWithSelection: "New Folder with Selection"
        case .newTextFile: "New File"
        case .duplicate: "Duplicate Selected Items"
        case .back: "Back"; case .forward: "Forward"; case .up: "Parent Folder"; case .computer: "This Mac"; case .home: "Home"
        case .refresh: "Refresh"; case .address: "Edit Location"; case .filter: "Focus Filter or Search"; case .search: "Search Folders or This Mac"
        case .directFilter: "Choose Filter Loaded Items"; case .searchFolder: "Choose Search Folder"; case .searchThisMac: "Choose Search This Mac"
        case .newTab: "New Tab"; case .closeTab: "Close Tab"; case .duplicateTab: "Duplicate Tab"; case .reopenTab: "Reopen Closed Tab"
        case .tabLeft: "Move Tab Left"; case .tabRight: "Move Tab Right"; case .nextTab: "Next Tab"; case .previousTab: "Previous Tab"
        case .tab1: "Select Tab 1"; case .tab2: "Select Tab 2"; case .tab3: "Select Tab 3"; case .tab4: "Select Tab 4"
        case .tab5: "Select Tab 5"; case .tab6: "Select Tab 6"; case .tab7: "Select Tab 7"; case .tab8: "Select Tab 8"; case .tab9: "Select Last Tab"
        case .nextFocus: "Next Browser Control"; case .previousFocus: "Previous Browser Control"
        case .splitRight: "Split Pane Right"; case .splitBelow: "Split Pane Below"; case .closePane: "Close Pane (Keep Tabs)"; case .nextPane: "Focus Next Pane"
        case .swapPaneSides: "Swap Pane Sides"; case .balancePaneSizes: "Balance Pane Sizes"
        case .rotatePaneSplit: "Change Pane Split Direction"
        case .linkPaneNavigation: "Link Pane Navigation"
        case .selectMatchingPaneItem: "Select Matching Item in Other Pane"
        case .previewPane: "Toggle Preview Pane"; case .hiddenFiles: "Toggle Hidden Files"; case .pathBar: "Toggle Path Bar"
        case .compactRows: "Toggle Compact Rows"; case .extensions: "Toggle Filename Extensions"; case .foldersFirst: "Toggle Folders First"
        case .details: "Details View"; case .list: "List View"; case .icons: "Icons View"
        case .queue: "Transfer Queue"; case .progress: "File Operation Details"; case .stop: "Stop File Operation"
        case .results: "Last Operation Results"; case .continueRemaining: "Continue Remaining"; case .recovery: "Operation Recovery"; case .drives: "Drives"
        case .openTrash: "Traverse Trash"
        case .driveManagement: "Drive Management"; case .driveBenchmark: "Drive Benchmark"
        case .rememberFolder: "Remember Folder"; case .pinFolder: "Pin Current Folder"; case .renamePin: "Rename Pin Label"; case .removePin: "Remove Pin"
        case .pinUp: "Move Pin Up"; case .pinDown: "Move Pin Down"
        case .launchProfiles: "Launch Profiles"; case .browseArchive: "Browse Archive"
        case .extractArchive: "Extract Archive to New Folder"
        case .createZIP: "Create ZIP"
        case .batchRename: "Rename Multiple Items"
        case .namesAndLabels: "Names & Labels"; case .rememberedItems: "Remembered Items"; case .storageAnalysis: "Storage Analysis"
        case .saveFolderView: "Save View for This Folder"; case .applyFolderView: "Apply Saved Folder View"
        case .forgetFolderView: "Forget Saved Folder View"; case .folderViews: "Manage Saved Folder Views"
        case .connectServer: "Connect to Server"; case .disconnectServer: "Disconnect Active Connection"
        case .switchLaunchProfile: "Switch Layout Profile"
        case .copyToPane: "Copy to Other Pane"; case .moveToPane: "Move to Other Pane"
        case .moveOnServer: "Move to Server Folder"
        case .copyOnServer: "Copy to Server Folder"
        case .findCommand: "Find a Command"
        case .selectionMenu: "Show Context Menu"
        case .openTerminal: "Open Terminal Here"
        case .compareFiles: "Compare Files"
        case .compareFolders: "Compare Folders"
        case .selectByName: "Select by Name"
        case .compareTextFiles: "Compare Text Files"
        case .browseGitWorktrees: "Browse Git Worktrees"
        case .compareGitRevisions: "Compare Git Revisions"
        case .compareGitCheckouts: "Compare Git Checkouts"
        case .compareGitFileRevisions: "Compare File Across Revisions"
        case .compareGitWorkingFile: "Compare Working File with Revision"
        case .compareGitWorkingFolder: "Compare Working Folder"
        case .reviewStagedChanges: "Review Staged Changes"
        case .stageGitFile: "Stage Saved File"
        case .unstageGitFile: "Unstage File"
        case .gitFileHistory: "Git File History"
        case .gitFolderHistory: "Git Folder History"
        }
    }
    public var allowsRepeat: Bool {
        switch self { case .back, .forward, .up, .nextTab, .previousTab, .nextFocus, .previousFocus, .nextPane: true; default: false }
    }
    public var tabIndex: Int? { [BrowserCommand.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9].firstIndex(of: self) }
}

public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1), control = Self(rawValue: 2), option = Self(rawValue: 4), shift = Self(rawValue: 8)
    public var display: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

public enum ShortcutSpecialKey: String, Codable, CaseIterable, Sendable {
    case returnKey, tab, backspace, forwardDelete, space, escape, left, right, up, down
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    public var display: String {
        switch self {
        case .returnKey: "↩"; case .tab: "⇥"; case .backspace: "⌫"; case .forwardDelete: "⌦"; case .space: "Space"
        case .escape: "⎋"; case .left: "←"; case .right: "→"; case .up: "↑"; case .down: "↓"
        default: rawValue.uppercased()
        }
    }
}

public enum ShortcutKey: Hashable, Codable, Sendable {
    case character(String), special(ShortcutSpecialKey)
    public var display: String { switch self { case .character(let value): value.uppercased(); case .special(let value): value.display } }
}

public struct BrowserShortcut: Hashable, Codable, Sendable {
    public let key: ShortcutKey
    public let modifiers: ShortcutModifiers
    public init(_ key: ShortcutKey, _ modifiers: ShortcutModifiers = []) { self.key = key; self.modifiers = modifiers }
    public var display: String { modifiers.display + key.display }
    public var requiresFileSurface: Bool {
        switch key {
        case .special(.returnKey), .special(.space), .special(.backspace), .special(.forwardDelete), .special(.f2): true
        default: false
        }
    }
    public var isWellFormed: Bool {
        guard (0...15).contains(modifiers.rawValue) else { return false }
        switch key {
        case .character(let value):
            return value.count == 1 && value == value.precomposedStringWithCanonicalMapping.lowercased()
                && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
                && !modifiers.intersection([.command, .control, .option]).isEmpty
        case .special(let key):
            if [.tab, .escape, .left, .right, .up, .down].contains(key) { return !modifiers.intersection([.command, .control, .option]).isEmpty }
            return true
        }
    }
    public var isReserved: Bool {
        switch (key, modifiers) {
        case (.character("q"), .command), (.character("q"), [.command, .shift]),
             (.character("q"), [.command, .control]), (.character("h"), .command),
             (.character("h"), [.command, .option]), (.character("m"), .command),
             (.character("m"), [.command, .option]), (.character(","), .command),
             (.special(.space), .command), (.special(.space), [.command, .option]),
             (.special(.space), [.command, .control]), (.special(.tab), .command),
             (.special(.tab), [.command, .shift]), (.special(.escape), [.command, .option]): true
        default: false
        }
    }
    public func swappingCommandAndOption() -> Self {
        var changed = modifiers.subtracting([.command, .option])
        if modifiers.contains(.command) { changed.insert(.option) }
        if modifiers.contains(.option) { changed.insert(.command) }
        return Self(key, changed)
    }
}

public struct BrowserShortcutPreferences: Codable, Equatable, Sendable {
    public var swapsCommandAndOption: Bool
    /// Missing means preset; an empty array explicitly disables that action's keys.
    public var overrides: [BrowserCommand: [BrowserShortcut]]
    public init(swapsCommandAndOption: Bool = false, overrides: [BrowserCommand: [BrowserShortcut]] = [:]) {
        self.swapsCommandAndOption = swapsCommandAndOption; self.overrides = overrides
    }
}

/// Finite app-local map; OS/text focus and enabled-state handling live in the
/// native adapter. An ambiguous/corrupt map never resolves a command.
public struct BrowserShortcutMap: Sendable {
    public enum Issue: Equatable, Sendable {
        case invalid(BrowserCommand), reserved(BrowserCommand), duplicate(BrowserCommand, BrowserCommand, BrowserShortcut)
    }
    public let bindings: [BrowserCommand: [BrowserShortcut]]
    public let issues: [Issue]
    private let owners: [BrowserShortcut: BrowserCommand]
    public init(behavior: BrowserBehaviorPreferences, preferences: BrowserShortcutPreferences = .init()) {
        var values = Self.defaults(behavior)
        if preferences.swapsCommandAndOption { values = values.mapValues { $0.map { $0.swappingCommandAndOption() } } }
        for (action, keys) in preferences.overrides { values[action] = keys }
        // Adding a new preset must not invalidate an older user's explicit key.
        // Explicit new bindings still participate in normal conflicts.
        for introduced in [BrowserCommand.connectServer, .switchLaunchProfile, .findCommand, .nextFocus, .previousFocus, .selectionMenu, .nextTab, .previousTab] {
            if preferences.overrides[introduced] == nil, let proposed = values[introduced],
               preferences.overrides.contains(where: { $0.key != introduced && !$0.value.filter(proposed.contains).isEmpty }) {
                values[introduced] = []
            }
        }
        var issues: [Issue] = [], claims: [BrowserShortcut: BrowserCommand] = [:]
        for action in BrowserCommand.allCases {
            let keys = values[action] ?? []
            if keys.count > 8 || Set(keys).count != keys.count { issues.append(.invalid(action)) }
            for key in keys.prefix(8) {
                if !key.isWellFormed { issues.append(.invalid(action)) }
                if key.isReserved { issues.append(.reserved(action)) }
                if let first = claims[key], first != action { issues.append(.duplicate(first, action, key)) }
                else { claims[key] = action }
            }
        }
        self.bindings = values; self.issues = issues; owners = claims
    }
    public func resolve(_ shortcut: BrowserShortcut, fileSurface: Bool) -> BrowserCommand? {
        guard issues.isEmpty, fileSurface || !shortcut.requiresFileSurface else { return nil }
        return owners[shortcut]
    }
    public func shortcuts(for action: BrowserCommand) -> [BrowserShortcut] { bindings[action] ?? [] }

    private static func defaults(_ behavior: BrowserBehaviorPreferences) -> [BrowserCommand: [BrowserShortcut]] {
        var result: [BrowserCommand: [BrowserShortcut]] = [:]
        func character(_ action: BrowserCommand, _ key: String, _ modifiers: ShortcutModifiers = .command) {
            result[action, default: []].append(.init(.character(key), modifiers))
        }
        func special(_ action: BrowserCommand, _ key: ShortcutSpecialKey, _ modifiers: ShortcutModifiers = []) {
            result[action, default: []].append(.init(.special(key), modifiers))
        }
        for (action, key): (BrowserCommand, String) in [(.newTab, "t"), (.closeTab, "w"), (.copy, "c"), (.cut, "x"),
            (.paste, "v"), (.undo, "z"), (.selectAll, "a"), (.address, "l"), (.filter, "f"), (.refresh, "r"),
            (.properties, "i"), (.quickLook, "y"), (.back, "["), (.forward, "]")] { character(action, key) }
        for (action, key): (BrowserCommand, String) in [(.reopenTab, "t"), (.newFolder, "n"), (.search, "f"),
            (.previewPane, "p"), (.hiddenFiles, "."), (.computer, "c"), (.home, "h")] { character(action, key, [.command, .shift]) }
        character(.directFilter, "f", [.command, .option])
        character(.duplicate, "d")
        character(.connectServer, "k")
        character(.findCommand, "k", [.command, .shift])
        character(.switchLaunchProfile, "p", [.command, .control])
        character(.newFolderWithSelection, "n", [.command, .control])
        character(.searchFolder, "f", [.command, .option, .shift])
        character(.searchThisMac, "f", [.command, .control, .shift])
        character(.copyPath, "c", [.command, .option]); character(.moveCopied, "v", [.command, .option])
        character(.pathBar, "p", [.command, .option])
        special(.open, .down, .command); special(.up, .up, .command)
        special(.nextPane, .tab, [.command, .option]); special(.trash, .backspace, .command)
        special(.nextFocus, .f6); special(.previousFocus, .f6, .shift)
        special(.selectionMenu, .f10, .shift)
        special(.nextTab, .tab, .control); special(.previousTab, .tab, [.control, .shift])
        special(behavior.returnAction == .open ? .open : .rename, .returnKey)
        special(.quickLook, .space)
        if behavior.backspaceGoesBack { special(.back, .backspace) }
        special(.back, .left, .option); special(.forward, .right, .option); special(.up, .up, .option)
        if behavior.explorerFunctionKeysEnabled {
            special(.rename, .f2); special(.address, .f4); special(.refresh, .f5)
            special(.trash, .forwardDelete)
        }
        if behavior.controlAliasesEnabled {
            for (index, action) in [BrowserCommand.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9].enumerated() {
                character(action, String(index + 1), .control)
            }
            for (action, key): (BrowserCommand, String) in [(.newTab, "t"), (.closeTab, "w"), (.copy, "c"), (.cut, "x"),
                (.paste, "v"), (.undo, "z"), (.selectAll, "a"), (.address, "l"), (.filter, "f")] { character(action, key, .control) }
            character(.address, "d", .option); character(.copyPath, "c", [.control, .shift]); character(.reopenTab, "t", [.control, .shift])
        }
        return result
    }
}
