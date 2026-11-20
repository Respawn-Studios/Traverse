import AppKit
import ExplorerCore

@MainActor
enum BrowserMenus {
    enum Kind: String { case file = "File", view = "View", go = "Go", settings = "Settings", help = "Help" }
    static let gitSectionIdentifier = NSUserInterfaceItemIdentifier("browser-git-section")

    static func item(_ title: String, _ action: Selector, key: String = "",
                     modifiers: NSEvent.ModifierFlags = .command, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    static func addSection(_ title: String, to menu: NSMenu, identifier: NSUserInterfaceItemIdentifier? = nil,
                           build: (NSMenu) -> Void) {
        let section = NSMenu(title: title)
        build(section)
        guard !section.items.isEmpty else { return }
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.identifier = identifier
        entry.submenu = section
        menu.addItem(entry)
    }

    /// Finds the actual native item, including commands grouped into submenus.
    static func commandItem(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for entry in menu.items {
            if entry.action == action { return entry }
            if let child = entry.submenu, let found = commandItem(action, in: child) { return found }
        }
        return nil
    }

    static func newFolderItem(target: BrowserViewController, named: Bool = false, shortcut: Bool = false) -> NSMenuItem {
        let needsName = named || target.isRemoteLocation || target.isArchiveLocation
        let entry = item(needsName ? "New Folder…" : "New Folder", #selector(BrowserViewController.createFolder(_:)),
                         key: shortcut ? "n" : "", modifiers: [.command, .shift], target: target)
        if named { entry.representedObject = "named-local-folder" }
        return entry
    }

    static func gitReviewItems(target: BrowserViewController) -> [NSMenuItem] {
        [item("Browse Git Worktrees…", #selector(BrowserViewController.browseGitWorktrees(_:)), target: target),
         item("Compare Git Revisions…", #selector(BrowserViewController.compareGitRevisions(_:)), target: target),
         item("Compare Working Folder…", #selector(BrowserViewController.compareGitWorkingFolder(_:)), target: target),
         item("Review Staged Changes…", #selector(BrowserViewController.reviewStagedChanges(_:)), target: target),
         item("Git Folder History…", #selector(BrowserViewController.showGitFolderHistory(_:)), target: target),
         item("Compare File Across Revisions…", #selector(BrowserViewController.compareSelectedGitFileRevisions(_:)), target: target),
         item("Compare Working File with Revision…", #selector(BrowserViewController.compareSelectedGitWorkingFile(_:)), target: target),
         item("Git File History…", #selector(BrowserViewController.showGitFileHistory(_:)), target: target)]
            + gitIndexItems(target: target)
    }

    private static func gitIndexItems(target: BrowserViewController) -> [NSMenuItem] {
        [BrowserCommand.stageGitFile, .unstageGitFile].map {
            item($0.title + "…", $0.selector, target: target)
        }
    }

    static func menu(_ kind: Kind, target: BrowserViewController) -> NSMenu {
        let menu = NSMenu(title: kind.rawValue)
        switch kind {
        case .file:
            menu.addItem(item("New Tab", #selector(BrowserViewController.newTab(_:)), key: "t", target: target))
            menu.addItem(item("Close Tab", #selector(BrowserViewController.closeTab(_:)), key: "w", target: target))
            addSection("Tabs", to: menu) { section in
                section.addItem(item("Duplicate Tab", #selector(BrowserViewController.duplicateCurrentTab(_:)), target: target))
                section.addItem(item("Reopen Closed Tab", #selector(BrowserViewController.reopenClosedTab(_:)), key: "t", modifiers: [.command, .shift], target: target))
                section.addItem(item("Launch Profiles…", #selector(BrowserViewController.showLaunchProfiles(_:)), target: target))
                section.addItem(item("Move Tab Left", #selector(BrowserViewController.moveCurrentTabLeft(_:)), target: target))
                section.addItem(item("Move Tab Right", #selector(BrowserViewController.moveCurrentTabRight(_:)), target: target))
            }
            menu.addItem(.separator())
            menu.addItem(item("Open Folder…", #selector(BrowserViewController.chooseFolder(_:)), key: "o", modifiers: [.command, .shift], target: target))
            menu.addItem(item("Open Selection", #selector(BrowserViewController.openSelection(_:)), key: String(UnicodeScalar(0xF701)!), target: target))
            menu.addItem(item("Open in Default App", #selector(BrowserViewController.openSelectedFileInDefaultApp(_:)), target: target))
            menu.addItem(openWithItem(target: target))
            addSection("Compare", to: menu) { section in
                section.addItem(item(target.textComparisonTitle, #selector(BrowserViewController.compareTextFiles(_:)), target: target))
                section.addItem(item("Compare Folders…", #selector(BrowserViewController.compareFolders(_:)), target: target))
                section.addItem(item("Compare Files", #selector(BrowserViewController.compareSelectedFiles(_:)), target: target))
            }
            addSection("Git", to: menu, identifier: gitSectionIdentifier) { section in
                gitReviewItems(target: target).forEach(section.addItem)
            }
            if LocalTextEditorFeature.ordinaryEnabled || RemoteTextEditorFeature.available {
                menu.addItem(item("Edit in Traverse", #selector(BrowserViewController.editTextInTraverse(_:)), target: target))
            }
            if RemoteTextViewFeature.available {
                menu.addItem(item("View in Traverse", #selector(BrowserViewController.viewTextInTraverse(_:)), target: target))
            }
            if RemoteTextEditorFeature.available {
                menu.addItem(item("Saved Versions…", #selector(ApplicationRemoteSavedVersions.showSavedVersions(_:)),
                    target: ApplicationRemoteSavedVersions.shared))
            }
            menu.addItem(item("Share…", #selector(BrowserViewController.shareSelection(_:)), target: target))
            menu.addItem(item("Send via AirDrop…", #selector(BrowserViewController.sendViaAirDrop(_:)), target: target))
            menu.addItem(item("Quick Look", #selector(BrowserViewController.showQuickLook(_:)), key: "y", target: target))
            menu.addItem(.separator())
            addSection("New", to: menu) { section in
                section.addItem(newFolderItem(target: target, shortcut: true))
                section.addItem(newFolderItem(target: target, named: true))
                if LocalTextEditorFeature.ordinaryEnabled {
                    section.addItem(item(FilenamePrompt.newFileTitle + "…", #selector(BrowserViewController.createTextFile(_:)), target: target))
                }
                if SelectionGroupFeature.available {
                    section.addItem(item("New Folder with Selection", #selector(BrowserViewController.newFolderWithSelection(_:)), key: "n", modifiers: [.command, .control], target: target))
                }
            }
            menu.addItem(item("Duplicate", #selector(BrowserViewController.duplicateSelection(_:)), target: target))
            menu.addItem(item("Copy to Other Pane", #selector(BrowserViewController.copyToOtherPane(_:)), target: target))
            menu.addItem(item("Move to Other Pane", #selector(BrowserViewController.moveToOtherPane(_:)), target: target))
            menu.addItem(item("Rename…", #selector(BrowserViewController.renameSelection(_:)), target: target))
            menu.addItem(item("Rename Items…", #selector(BrowserViewController.batchRenameSelection(_:)), target: target))
            menu.addItem(item(target.trashCommandTitle, #selector(BrowserViewController.trashSelection(_:)), target: target))
            if SFTPRemoteActionFeature.available || SMBRemoteActionFeature.available {
                menu.addItem(item("Delete Permanently…", #selector(BrowserViewController.deleteRemoteFilePermanently(_:)), target: target))
            }
            addSection("Archives", to: menu) { section in
                section.addItem(item("Browse Archive…", #selector(BrowserViewController.browseZIP(_:)), target: target))
                section.addItem(item("Extract to New Folder", #selector(BrowserViewController.extractArchiveDirect(_:)), target: target))
                section.addItem(item("Extract…", #selector(BrowserViewController.extractArchive(_:)), target: target))
                section.addItem(item(target.quickCompressionCommandTitle, #selector(BrowserViewController.compressSelection(_:)), target: target))
                section.addItem(item(ArchiveCreationActivation.commandTitle, #selector(BrowserViewController.createZIP(_:)), target: target))
            }
            addSection("Transfers", to: menu) { section in
                if SMBRemoteActionFeature.movesAvailable || SFTPRemoteActionFeature.movesAvailable {
                    section.addItem(item("Move To…", #selector(BrowserViewController.moveServerSelection(_:)), target: target))
                }
                if SMBRemoteActionFeature.copiesAvailable || SFTPRemoteActionFeature.copiesAvailable {
                    section.addItem(item("Copy To…", #selector(BrowserViewController.copyServerSelection(_:)), target: target))
                }
                section.addItem(item("Upload to SFTP Pane…", #selector(BrowserViewController.uploadToSFTPPane(_:)), target: target))
                if SMBUploadFeature.available {
                    section.addItem(item(SMBUploadFeature.commandTitle, #selector(BrowserViewController.uploadFileToSMB(_:)), target: target))
                    section.addItem(item("SMB Upload Outcomes…", #selector(BrowserViewController.showSMBUploadOutcomes(_:)), target: target))
                }
            }
            addSection("Copy Details", to: menu) { section in
                section.addItem(item("Copy Path", #selector(BrowserViewController.copyPath(_:)), key: "c", modifiers: [.command, .option], target: target))
                section.addItem(item("Copy Names", #selector(BrowserViewController.copyNames(_:)), target: target))
                section.addItem(item("Copy Relative Paths", #selector(BrowserViewController.copyRelativePaths(_:)), target: target))
            }
            addSection("Clipboard Options", to: menu) { section in
                section.addItem(item("Move Copied Items Here", #selector(BrowserViewController.moveCopiedFiles(_:)), key: "v", modifiers: [.command, .option], target: target))
                section.addItem(item("Paste with Options…", #selector(BrowserViewController.pasteWithOptions(_:)), target: target))
            }
            menu.addItem(.separator())
            menu.addItem(item("Undo File Operation", #selector(BrowserViewController.undoFileOperation(_:)), target: target))
            addSection("Operations", to: menu) { section in
                section.addItem(item("File Operation Details", #selector(BrowserViewController.showFileOperationDetails(_:)), target: target))
                section.addItem(item("Transfer Queue…", #selector(BrowserViewController.showTransferQueue(_:)), target: target))
                section.addItem(item("Last Operation Results…", #selector(BrowserViewController.showLastOperationResult(_:)), target: target))
                section.addItem(item("Continue Remaining", #selector(BrowserViewController.continueRemainingTransfer(_:)), target: target))
                section.addItem(item("Stop File Operation", #selector(BrowserViewController.cancelFileOperation(_:)), target: target))
            }
            menu.addItem(.separator())
            menu.addItem(item("Properties…", #selector(BrowserViewController.showProperties(_:)), key: "i", target: target))
            menu.addItem(item("Names & Labels…", #selector(BrowserViewController.editPrivateNames(_:)), target: target))
        case .view:
            menu.addItem(item("Refresh", #selector(BrowserViewController.refresh(_:)), key: "r", target: target))
            menu.addItem(item("Focus Filter or Search", #selector(BrowserViewController.focusFilter(_:)), key: "f", target: target))
            menu.addItem(item("Search Folders or This Mac…", #selector(BrowserViewController.showMetadataSearch(_:)), key: "f", modifiers: [.command, .shift], target: target))
            menu.addItem(item("Filter Loaded Items", #selector(BrowserViewController.chooseDirectFilter(_:)), target: target))
            menu.addItem(item("Search Folder", #selector(BrowserViewController.chooseFolderSearch(_:)), target: target))
            menu.addItem(item("Search This Mac", #selector(BrowserViewController.chooseThisMacSearch(_:)), target: target))
            menu.addItem(item("Preview Pane", #selector(BrowserViewController.toggleInlinePreview(_:)), key: "p", modifiers: [.command, .shift], target: target))
            menu.addItem(item("Hide Sidebar", #selector(BrowserViewController.toggleSidebar(_:)), target: target))
            menu.addItem(.separator())
            menu.addItem(item("Split Pane Right", #selector(BrowserViewController.splitPaneRight(_:)), target: target))
            menu.addItem(item("Split Pane Below", #selector(BrowserViewController.splitPaneBelow(_:)), target: target))
            menu.addItem(item("Close Pane (Keep Tabs)", #selector(BrowserViewController.closePane(_:)), target: target))
            menu.addItem(item("Focus Next Pane", #selector(BrowserViewController.focusOtherPane(_:)), key: "\t", modifiers: [.command, .option], target: target))
            menu.addItem(item(WorkspaceDividerAction.swap.title, #selector(BrowserViewController.swapPaneSides(_:)), target: target))
            menu.addItem(item(WorkspaceDividerAction.balance.title, #selector(BrowserViewController.balancePaneSizes(_:)), target: target))
            menu.addItem(item(WorkspaceDividerAction.rotate.title, #selector(BrowserViewController.rotatePaneSplit(_:)), target: target))
            menu.addItem(item(WorkspaceDividerAction.link.title, #selector(BrowserViewController.toggleLinkedPaneNavigation(_:)), target: target))
            menu.addItem(item(WorkspaceDividerAction.selectMatch.title, #selector(BrowserViewController.selectMatchingPaneItem(_:)), target: target))
            menu.addItem(item(WorkspaceDividerAction.compareGit.title, #selector(BrowserViewController.comparePaneGitCheckouts(_:)), target: target))
            menu.addItem(.separator())
            menu.addItem(item("Show Hidden Files", #selector(BrowserViewController.toggleHidden(_:)), key: ".", modifiers: [.command, .shift], target: target))
            menu.addItem(item("Show Title Bar Menus", #selector(BrowserViewController.toggleCommandRow(_:)), target: target))
            menu.addItem(item("Show Path Bar", #selector(BrowserViewController.togglePathBar(_:)), key: "p", modifiers: [.command, .option], target: target))
            menu.addItem(.separator())
            for entry in viewModeMenu(target: target).items {
                entry.menu?.removeItem(entry)
                menu.addItem(entry)
            }
            menu.addItem(item("Compact Rows", #selector(BrowserViewController.toggleCompactRows(_:)), target: target))
            menu.addItem(item("Show Filename Extensions", #selector(BrowserViewController.toggleExtensions(_:)), target: target))
            menu.addItem(item("Folders First", #selector(BrowserViewController.toggleFoldersFirst(_:)), target: target))
            let columns = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
            columns.submenu = columnMenu(target: target)
            menu.addItem(columns)
            let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            let sortMenu = NSMenu(title: "Sort By")
            for (tag, column) in BrowserColumn.allCases.enumerated() {
                let entry = item(column.title, #selector(BrowserViewController.changeSort(_:)), target: target)
                entry.tag = tag
                sortMenu.addItem(entry)
            }
            sortMenu.addItem(.separator())
            sortMenu.addItem(item("Ascending", #selector(BrowserViewController.toggleAscending(_:)), target: target))
            sortItem.submenu = sortMenu
            menu.addItem(sortItem)
            let folderView = NSMenuItem(title: "Folder View", action: nil, keyEquivalent: "")
            let folderMenu = NSMenu(title: "Folder View")
            folderMenu.addItem(item("Save View for This Folder", #selector(BrowserViewController.saveFolderView(_:)), target: target))
            folderMenu.addItem(item("Apply Saved Folder View", #selector(BrowserViewController.applySavedFolderView(_:)), target: target))
            folderMenu.addItem(item("Forget Saved Folder View", #selector(BrowserViewController.forgetFolderView(_:)), target: target))
            folderMenu.addItem(.separator())
            folderMenu.addItem(item("Manage Saved Folder Views…", #selector(BrowserViewController.showFolderViews(_:)), target: target))
            folderView.submenu = folderMenu; menu.addItem(folderView)
        case .go:
            menu.addItem(item("Switch Layout Profile…", #selector(BrowserViewController.switchLaunchProfile(_:)), target: target))
            if SMBConnectionFeature.ordinaryEnabled {
                menu.addItem(item("Connect to Server…", #selector(BrowserViewController.showSMBConnections(_:)), key: "k", target: target))
                menu.addItem(item("Current Connection Properties…", #selector(BrowserViewController.showCurrentConnectionProperties(_:)), target: target))
                menu.addItem(item("Disconnect This Tab", #selector(BrowserViewController.disconnectCurrentConnection(_:)), target: target))
                menu.addItem(item("Reconnect This Tab", #selector(BrowserViewController.reconnectFromConnectionStatus(_:)), target: target))
                let activity = NSMenuItem(title: "Connection Activity", action: nil, keyEquivalent: "")
                let activityMenu = NSMenu(title: "Connection Activity")
                activityMenu.addItem(item("SMB…", #selector(BrowserViewController.showSMBConnectionActivity(_:)), target: target))
                if SFTPConnectionFeature.ordinaryEnabled {
                    activityMenu.addItem(item("SFTP…", #selector(BrowserViewController.showSFTPConnectionActivity(_:)), target: target))
                }
                activity.submenu = activityMenu; menu.addItem(activity)
            }
            menu.addItem(item("Remembered Items…", #selector(BrowserViewController.showPrivateNames(_:)), target: target))
            menu.addItem(item("Storage Analysis…", #selector(BrowserViewController.showStorageAnalysis(_:)), target: target))
            if DriveManagementFeature.ordinaryEnabled {
                menu.addItem(item("Drives…", #selector(BrowserViewController.showDriveManagement(_:)), target: target))
            }
            menu.addItem(.separator())
            menu.addItem(item("Back", #selector(BrowserViewController.goBack(_:)), key: "[", target: target))
            menu.addItem(item("Forward", #selector(BrowserViewController.goForward(_:)), key: "]", target: target))
            menu.addItem(item("Up", #selector(BrowserViewController.goUp(_:)), key: String(UnicodeScalar(0xF700)!), target: target))
            menu.addItem(.separator())
            menu.addItem(item("This Mac", #selector(BrowserViewController.goComputer(_:)), key: "c", modifiers: [.command, .shift], target: target))
            menu.addItem(item("Home", #selector(BrowserViewController.goHome(_:)), key: "h", modifiers: [.command, .shift], target: target))
            menu.addItem(item("Edit Location", #selector(BrowserViewController.focusLocation(_:)), key: "l", target: target))
            menu.addItem(item("Open Terminal Here", #selector(BrowserViewController.openTerminalHere(_:)), target: target))
            addSection("Keyboard Navigation", to: menu) { section in
                section.addItem(item("Next Browser Control", #selector(BrowserViewController.nextBrowserControl(_:)), target: target))
                section.addItem(item("Previous Browser Control", #selector(BrowserViewController.previousBrowserControl(_:)), target: target))
                section.addItem(item("Show Context Menu", #selector(BrowserViewController.showKeyboardContextMenu(_:)), target: target))
            }
            menu.addItem(.separator())
            menu.addItem(item("Pin Current Folder", #selector(BrowserViewController.pinCurrentFolder(_:)), target: target))
            menu.addItem(item("Rename Pin Label…", #selector(BrowserViewController.renameSelectedPin(_:)), target: target))
            menu.addItem(item("Remove Selected Pin", #selector(BrowserViewController.removeSelectedPin(_:)), target: target))
            menu.addItem(item("Move Pin Up", #selector(BrowserViewController.moveSelectedPinUp(_:)), target: target))
            menu.addItem(item("Move Pin Down", #selector(BrowserViewController.moveSelectedPinDown(_:)), target: target))
            menu.addItem(.separator())
            menu.addItem(item("Remember Folder Access…", #selector(BrowserViewController.rememberFolder(_:)), target: target))
            menu.addItem(item("Manage Folder Access…", #selector(BrowserViewController.manageFolderAccess(_:)), target: target))
            menu.addItem(item("Review Folder Privacy…", #selector(BrowserViewController.openPrivacySettings(_:)), target: target))
            menu.addItem(item("Operation Recovery…", #selector(BrowserViewController.showOperationRecovery(_:)), target: target))
            if OwnedTrashFeature.browseAvailable {
                menu.addItem(item("Traverse Trash…", #selector(BrowserViewController.showOwnedTrash(_:)), target: target))
            }
        case .settings:
            menu.addItem(item("Settings…", #selector(BrowserViewController.showSettings(_:)), key: ",", target: target))
            menu.addItem(.separator())
            menu.addItem(item("Show Title Bar Menus", #selector(BrowserViewController.toggleCommandRow(_:)), target: target))
        case .help:
            menu.addItem(item("What's New…", #selector(BrowserViewController.showWhatsNew(_:)), target: target))
            menu.addItem(item("Check for Updates…", #selector(BrowserViewController.showAppUpdates(_:)), target: target))
            menu.addItem(item("App Logs…", #selector(BrowserViewController.showDiagnosticHistory(_:)), target: target))
            menu.addItem(item("Crash Reports & Feedback…", #selector(BrowserViewController.showCrashReports(_:)), target: target))
            menu.addItem(item("About Traverse…", #selector(BrowserViewController.showTraverseAbout(_:)), target: target))
            menu.addItem(item("Support Details…", #selector(BrowserViewController.showSupportDetails(_:)), target: target))
            menu.addItem(item("Receive with AirDrop…", #selector(BrowserViewController.showAirDropReceivingHelp(_:)), target: target))
            menu.addItem(.separator())
            menu.addItem(item("Get Help ↗", #selector(BrowserViewController.openTraverseSupport(_:)), target: target))
            menu.addItem(item("Support Traverse…", #selector(BrowserViewController.showCommunitySupport(_:)), target: target))
            menu.addItem(item("Source Code on GitHub ↗", #selector(BrowserViewController.openTraverseSource(_:)), target: target))
            menu.addItem(item("Respawn Studios Discord ↗", #selector(BrowserViewController.openTraverseDiscord(_:)), target: target))
            menu.addItem(item("Report a Bug…", #selector(BrowserViewController.openTraverseBugReport(_:)), target: target))
            menu.addItem(item("Send Feedback ↗", #selector(BrowserViewController.openTraverseFeedback(_:)), target: target))
            menu.addItem(.separator())
            menu.addItem(item("Find a Command…", #selector(BrowserViewController.findCommand(_:)), target: target))
            menu.addItem(item("Show Me Around…", #selector(BrowserViewController.showTraverseTour(_:)), target: target))
        }
        BrowserShortcutMenus.bind(menu, to: target)
        return menu
    }

    static func viewModeMenu(target: BrowserViewController) -> NSMenu {
        let menu = NSMenu(title: "View")
        for (index, mode) in BrowserViewMode.allCases.enumerated() {
            let entry = item(mode.rawValue, #selector(BrowserViewController.changeViewMode(_:)), target: target)
            entry.tag = index
            entry.image = symbol(mode.symbolName, mode.rawValue)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            menu.addItem(entry)
        }
        BrowserShortcutMenus.bind(menu, to: target)
        return menu
    }

    static func openWithItem(target: BrowserViewController) -> NSMenuItem {
        // Let AppKit install submenuAction/its native target. A custom action
        // opens a second popup on click instead of the same native child menu.
        let entry = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        entry.submenu = target.openAndShare.makeOpenWithMenu()
        return entry
    }

    static func columnMenu(target: BrowserViewController) -> NSMenu {
        let menu = NSMenu(title: "Columns")
        for column in BrowserColumn.allCases {
            let entry = item(column.title, #selector(BrowserViewController.toggleColumn(_:)), target: target)
            entry.tag = column.toggleTag
            menu.addItem(entry)
        }
        BrowserShortcutMenus.bind(menu, to: target)
        return menu
    }

    static func fileContextMenu(target: BrowserViewController) -> NSMenu {
        let menu = NSMenu()
        func command(_ title: String, _ action: Selector) -> NSMenuItem {
            item(title, action, target: target)
        }
        func group(_ items: [NSMenuItem], keepClipboard: Bool = false) {
            let visible = items.filter { entry in
                entry.submenu != nil || target.commandEnabled(entry.action)
                    || keepClipboard && [#selector(BrowserViewController.cutFileURLs(_:)),
                        #selector(BrowserViewController.copyFileURLs(_:)), #selector(BrowserViewController.pasteFileURLs(_:))].contains(entry.action)
            }
            guard !visible.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for entry in visible { menu.addItem(entry) }
        }
        guard !target.selectedURLs.isEmpty else {
            var creation = [newFolderItem(target: target)]
            if !target.isRemoteLocation && !target.isArchiveLocation { creation.append(newFolderItem(target: target, named: true)) }
            group(creation + [
                command(FilenamePrompt.newFileTitle + "…", #selector(BrowserViewController.createTextFile(_:)))])
            group([command("Paste", #selector(BrowserViewController.pasteFileURLs(_:))),
                command("Paste with Options…", #selector(BrowserViewController.pasteWithOptions(_:)))], keepClipboard: true)
            group([command("Select by Name…", #selector(BrowserViewController.selectByName(_:))),
                command("Compare with Other Pane…", #selector(BrowserViewController.compareFolders(_:))),
                command("Compare Git Revisions…", #selector(BrowserViewController.compareGitRevisions(_:))),
                command("Git Folder History…", #selector(BrowserViewController.showGitFolderHistory(_:))),
                command("Open Terminal Here", #selector(BrowserViewController.openTerminalHere(_:))),
                command("Refresh", #selector(BrowserViewController.refresh(_:)))])
            return menu
        }
        group([command("Open", #selector(BrowserViewController.openSelection(_:))),
            command("Open in New Tab", #selector(BrowserViewController.openSelectionInNewTab(_:))),
            command("Edit in Traverse", #selector(BrowserViewController.editTextInTraverse(_:))),
            command("Compare Files", #selector(BrowserViewController.compareSelectedFiles(_:))),
            command(target.textComparisonTitle, #selector(BrowserViewController.compareTextFiles(_:))),
            command("Compare File Across Revisions…", #selector(BrowserViewController.compareSelectedGitFileRevisions(_:))),
            command("Git File History…", #selector(BrowserViewController.showGitFileHistory(_:))),
            command(target.selectedItemCount == 2 ? "Compare Folders…" : "Compare with Other Pane…",
                #selector(BrowserViewController.compareFolders(_:))),
            command("Open in Terminal", #selector(BrowserViewController.openSelectedFolderInTerminal(_:)))])
        group(gitIndexItems(target: target))
        if target.orderedSelectedURLs.count == 1 && target.commandEnabled(#selector(BrowserViewController.openSelectedFileInDefaultApp(_:))) {
            menu.addItem(openWithItem(target: target))
        }
        group([command("Cut", #selector(BrowserViewController.cutFileURLs(_:))),
            command("Copy", #selector(BrowserViewController.copyFileURLs(_:))),
            command("Copy Path", #selector(BrowserViewController.copyPath(_:))),
            command("Duplicate", #selector(BrowserViewController.duplicateSelection(_:))),
            command("New Folder with Selection", #selector(BrowserViewController.newFolderWithSelection(_:))),
            command("Select by Name…", #selector(BrowserViewController.selectByName(_:))),
            command("Copy to Other Pane", #selector(BrowserViewController.copyToOtherPane(_:))),
            command("Move to Other Pane", #selector(BrowserViewController.moveToOtherPane(_:))),
            command("Paste Into Folder", #selector(BrowserViewController.pasteIntoSelection(_:)))], keepClipboard: true)
        let tools = [command("Share…", #selector(BrowserViewController.shareSelection(_:))),
            command("Send via AirDrop…", #selector(BrowserViewController.sendViaAirDrop(_:))),
            command("Quick Look", #selector(BrowserViewController.showQuickLook(_:))),
            command(ArchiveActionNames.extractionTitle(for: target.selectedArchiveURL), #selector(BrowserViewController.extractArchiveDirect(_:))),
            command("Extract…", #selector(BrowserViewController.extractArchive(_:))),
            command(target.quickCompressionCommandTitle, #selector(BrowserViewController.compressSelection(_:))),
            command(ArchiveCreationActivation.commandTitle, #selector(BrowserViewController.createZIP(_:))),
            command("Pin Folder", #selector(BrowserViewController.toggleSelectedFolderPin(_:)))]
        group(tools)
        let rename = target.orderedSelectedURLs.count > 1
            ? command("Rename Items…", #selector(BrowserViewController.batchRenameSelection(_:)))
            : command("Rename…", #selector(BrowserViewController.renameSelection(_:)))
        group([rename, command(target.trashCommandTitle, #selector(BrowserViewController.trashSelection(_:)))])
        let copy = NSMenuItem(title: "Copy Details", action: nil, keyEquivalent: "")
        let details = NSMenu()
        for entry in [command("Copy Names", #selector(BrowserViewController.copyNames(_:))),
            command("Copy Relative Paths", #selector(BrowserViewController.copyRelativePaths(_:)))] where target.commandEnabled(entry.action) {
            details.addItem(entry)
        }
        if !details.items.isEmpty { copy.submenu = details }
        var information = [command("Properties…", #selector(BrowserViewController.showProperties(_:))),
            command("Names & Labels…", #selector(BrowserViewController.editPrivateNames(_:))),
            command("Open Containing Folder", #selector(BrowserViewController.openContainingFolder(_:)))]
        if copy.submenu != nil { information.insert(copy, at: 0) }
        group(information)
        return menu
    }

    static func applicationMenu(target: BrowserViewController) -> NSMenu {
        ApplicationRemoteSavedVersions.shared.bind(browser: target)
        let main = NSMenu()
        let app = NSMenu(title: "Traverse")
        app.addItem(item("About Traverse", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApplication.shared))
        app.addItem(item("Third-Party Notices…", #selector(BrowserViewController.showBundledNotices(_:)), target: target))
        app.addItem(item("Support Details…", #selector(BrowserViewController.showSupportDetails(_:)), target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(BrowserViewController.showSettings(_:)), key: ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Hide Traverse", #selector(NSApplication.hide(_:)), key: "h", target: NSApplication.shared))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApplication.shared))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApplication.shared))
        app.addItem(.separator())
        app.addItem(item("Quit Traverse", #selector(NSApplication.terminate(_:)), key: "q", target: NSApplication.shared))
        add(app, to: main)
        add(menu(.file, target: target), to: main)
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", #selector(FileTableView.undo(_:)), key: "z", target: nil))
        edit.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], target: nil))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x", target: nil))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c", target: nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v", target: nil))
        edit.addItem(item("Paste with Options…", #selector(BrowserViewController.pasteWithOptions(_:)), target: target))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a", target: nil))
        edit.addItem(item("Select by Name…", #selector(BrowserViewController.selectByName(_:)), target: target))
        add(edit, to: main)
        add(menu(.view, target: target), to: main)
        add(menu(.go, target: target), to: main)
        let window = NativeWindowMenu.make()
        window.insertItem(item("Show Next Tab", #selector(BrowserViewController.nextBrowserTab(_:)),
            key: "\t", modifiers: .control, target: target), at: 2)
        window.insertItem(item("Show Previous Tab", #selector(BrowserViewController.previousBrowserTab(_:)),
            key: "\t", modifiers: [.control, .shift], target: target), at: 3)
        add(window, to: main)
        NativeWindowMenu.bind(window)
        let help = menu(.help, target: target)
        add(help, to: main)
        NSApplication.shared.helpMenu = help
        BrowserShortcutMenus.bind(main, to: target)
        return main
    }

    private static func add(_ menu: NSMenu, to parent: NSMenu) {
        let entry = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        parent.addItem(entry)
    }
}
