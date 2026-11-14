#if DEBUG
import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) @testable import LocalStorage

@MainActor enum RemoteItemPropertiesVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ condition: Bool,_ line: UInt = #line) throws { if !condition { throw Failure.check(line) } }
    private static func wait(_ condition: () async -> Bool,_ line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        while !(await condition()) { try require(ProcessInfo.processInfo.systemUptime < deadline,line); try await Task.sleep(for:.milliseconds(5)) }
    }
    private static func verifyConnectionReservations() throws {
        let prior = RemoteTextEditorFeature.qualifying
        RemoteTextEditorFeature.qualifying = true
        let editors = ApplicationRemoteTextEditors.shared
        var reservations: [UUID] = []
        defer {
            reservations.forEach { editors.releasePreparedConnection($0) }
            RemoteTextEditorFeature.qualifying = prior
        }
        try require(editors.registeredConnectionCountForVerification == 0)
        for _ in 0..<2 {
            guard let reservation = editors.reservePreparedConnection() else { throw Failure.scope }
            reservations.append(reservation)
        }
        try require(editors.reservePreparedConnection() == nil)
        editors.releasePreparedConnection(reservations.removeFirst())
        guard let replacement = editors.reservePreparedConnection() else { throw Failure.scope }
        reservations.append(replacement)
        try require(editors.reservePreparedConnection() == nil)
    }
    static func run() async {
        var root: URL?, host: NSWindow?, browser: BrowserViewController?, connection: SFTPTabController?, logger: DiagnosticRecorder?
        var details: ListedItemPropertiesController?, board: NSPasteboard?, checks: [String] = [], clips: [[String:Any]] = [], failure: UInt?, failureType: String?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let admitted = URL(fileURLWithPath:raw), repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:admitted.appendingPathComponent("reservation.json")))as?[String:Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"]as?String == "remote-item-properties" && UUID(uuidString:admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = admitted
            try verifyConnectionReservations()
            checks.append("Two pending editor connections reserve capacity; a third stays without editing; releasing one permits reuse")
            let settings = BrowserSettings(persist:false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false; settings.appearance = .dark; settings.motion.mode = .full
            settings.navigationStyle = .glass; InterfacePresentation.shared.bind(settings)
            let service = DiagnosticRecorder(directory:admitted.appendingPathComponent("state/logs"),limits:try .init(bytes:512<<10,segmentBytes:64<<10),recording:true)
            logger = service; ApplicationDiagnostics.shared.configureForVerification(service)
            let owner = BrowserViewController(settings:settings); browser = owner; owner.permitsBackgroundVerification = true
            let parent = NSWindow(contentRect:.init(x:140,y:130,width:960,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            parent.isReleasedWhenClosed = false; parent.contentViewController = owner; parent.title = "Remote item checks · generated review"
            parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); host = parent
            let privateBoard = NSPasteboard.withUniqueName(); board = privateBoard; owner.transferPasteboard = privateBoard
            var copies = 0, fileURLPublications = 0
            owner.clipboardWriter = { text,urls in
                copies += 1; fileURLPublications += urls.count
                return BrowserClipboard.publish(text,urls:urls,to:privateBoard)
            }
            let spy = PropertiesSpy()
            owner.propertiesController = FilePropertiesWindowController(reader:spy,settings:settings,copyPaths:{ _ in })
            let file = SFTPStoredRow(observation:2,entry:.init(name:try .init(Data("PRIVATE-REMOTE-Cafe\u{301} #50%.txt".utf8)),logicalBytes:UInt64.max,modifiedSeconds:0,permissions:0o100640))
            let folder = SFTPStoredRow(observation:1,entry:.init(name:try .init(Data("Folder".utf8)),logicalBytes:4096,modifiedSeconds:nil,permissions:0o040755))
            let transport = Transport(rows:[folder,file])
            let session = SFTPBrowserSession(id:UUID(),transport:transport)
            var uploadHistoryRequests = 0
            let tab = SFTPTabController(session:session,address:try .init("sftp://generated.invalid/"),title:"Generated server",
                showUploadHistory: { _, _ in uploadHistoryRequests += 1 })
            connection = tab; owner.installSFTPTab(tab)
            try await wait { tab.rows.cache.retainedCount == 2 && !tab.hasPendingPages }
            tab.rows.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            guard let observed = owner.observedRemoteItem else { throw Failure.scope }
            try require(observed.name == file.entry.name.displayName && observed.copyPath == "/PRIVATE-REMOTE-Cafe\u{301} #50%.txt"
                && owner.commandEnabled(#selector(BrowserViewController.showProperties(_:)))
                && owner.commandEnabled(#selector(BrowserViewController.copyNames(_:))) && owner.commandEnabled(#selector(BrowserViewController.copyPath(_:))))
            checks.append("Real SFTP tab/controller and page cache admit exact current selected metadata")
            for action in [#selector(BrowserViewController.trashSelection(_:)),#selector(BrowserViewController.pasteFileURLs(_:)),#selector(BrowserViewController.showQuickLook(_:)),#selector(BrowserViewController.copyFileURLs(_:))] {
                try require(!owner.commandEnabled(action))
            }
            checks.append("Remote inspection gains no local Trash, Paste, Quick Look or file-URL Copy authority")
            let editorMenu = tab.rows.table.menu!
            let editIndex = editorMenu.items.firstIndex { $0.title == "Edit in Traverse" }!
            try require(editorMenu.items[editIndex].isHidden && !tab.rows.canOpenSelectedItem)
            var editActions = 0, editingAllowed = false, nativeOpening = true
            tab.rows.onEditText = { editActions += 1 }
            tab.rows.editTextAllowed = { editingAllowed }
            tab.rows.nativeOpenAllowed = { nativeOpening }
            tab.rows.openSelectedItem()
            try require(editActions == 0 && !tab.rows.validateMenuItem(editorMenu.items[editIndex]))
            editingAllowed = true
            let table = tab.rows.table
            let point = table.convert(NSPoint(x: 100, y: table.rect(ofRow: 1).midY), to: nil)
            func doubleClickEvent(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: parent.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 2, pressure: 1) else { throw Failure.scope }
                return event
            }
            NSApp.postEvent(try doubleClickEvent(.leftMouseUp), atStart: true)
            table.mouseDown(with: try doubleClickEvent(.leftMouseDown))
            try require(editActions == 1 && tab.rows.validateMenuItem(editorMenu.items[editIndex]))
            nativeOpening = false
            tab.rows.openSelectedItem()
            editorMenu.performActionForItem(at: editIndex)
            try require(editActions == 2 && !tab.rows.canOpenSelectedItem)
            tab.rows.onEditText = nil; tab.rows.editTextAllowed = nil; tab.rows.nativeOpenAllowed = nil
            checks.append("Actual SFTP table doubleAction honors the native opening choice; explicit Edit requires capability; callbacks use no body backend")
            let before = await transport.counts()
            let menu = NSMenu()
            for (title,action) in [("Properties",#selector(BrowserViewController.showProperties(_:))),("Copy Name",#selector(BrowserViewController.copyNames(_:))),("Copy Server Path",#selector(BrowserViewController.copyPath(_:)))] {
                menu.addItem(withTitle:title,action:action,keyEquivalent:"").target = owner
            }
            menu.performActionForItem(at:0)
            guard let presentation = owner.listedItemPropertiesController, let initialWindow = presentation.window else { throw Failure.scope }
            var window = initialWindow
            details = presentation
            try require(window.isVisible && presentation.item == observed && !(owner.propertiesController.window?.isVisible ?? false))
            menu.performActionForItem(at:1)
            try require(Data((privateBoard.string(forType:.string) ?? "").utf8) == file.entry.name.wireUTF8)
            menu.performActionForItem(at:2)
            try require(privateBoard.string(forType:.string) == observed.copyPath && privateBoard.availableType(from:[.fileURL]) == nil && fileURLPublications == 0)
            let afterMetadataActions = await transport.counts(), readsAfterMetadataActions = await spy.count
            try require(afterMetadataActions == before && readsAfterMetadataActions == 0)
            checks.append("Native menu selectors open Properties and copy exact text without new transport/local metadata reads or file URLs")

            let rowMenu = tab.rows.table.menu!
            let inspectIndex = rowMenu.items.firstIndex { $0.title == "Properties…" }!
            try require(tab.rows.validateMenuItem(rowMenu.items[inspectIndex]))
            tab.rows.invalidatePages(); tab.rows.table.deselectAll(nil)
            try require(owner.observedRemoteItem == nil && !owner.commandEnabled(#selector(BrowserViewController.showProperties(_:))))
            let copyCount = copies
            menu.performActionForItem(at:0); menu.performActionForItem(at:1); menu.performActionForItem(at:2); rowMenu.performActionForItem(at:inspectIndex)
            let readsAfterRefusal = await spy.count
            try require(copies == copyCount && presentation.item == observed && readsAfterRefusal == 0)
            checks.append("Unloaded selection refuses direct/menu entry points instead of using stale local selection")
            tab.rows.requestVisiblePage(); try await wait { tab.rows.cache.retainedCount == 2 && !tab.hasPendingPages }
            tab.rows.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            tab.rows.disconnected("Generated offline state",retainingObservedRows:true)
            try require(tab.rows.cache.retainedCount == 2 && owner.observedRemoteItem == nil && !tab.rows.validateMenuItem(rowMenu.items[inspectIndex]))
            checks.append("Disconnected retained rows cannot publish a new current Properties selection")
            tab.rows.observe(session.latest); tab.rows.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            try require(owner.observedRemoteItem != nil)

            let smb = SMBRemoteRowsView(frame:.init(x:0,y:0,width:700,height:300))
            let smbSnapshot = SMBDirectorySnapshot(readID:UUID(),revision:1,count:1,folders:0,state:.complete)
            let smbRow = SMBDirectoryObservation(id:1,name:try .init("PRIVATE-SMB-report.txt"),attributes:0,logicalBytes:19,modifiedFileTime:116_444_736_000_000_000)
            let smbItem = try RemoteItemObservation(smb:smbRow,directory:[.init("Reports")],share:.init("Studio"),listingComplete:true)
            smb.observe(smbSnapshot); try smb.accept(.init(request:.init(snapshot:smbSnapshot,offset:0),entries:[smbRow]))
            let smbNameCell = smb.tableView(smb.table, viewFor: smb.table.tableColumns[0], row: 0) as? NSTableCellView
            let sftpNameCell = tab.rows.tableView(tab.rows.table, viewFor: tab.rows.table.tableColumns[0], row: 0) as? NSTableCellView
            try require(smbNameCell?.imageView?.image != nil && sftpNameCell?.imageView?.image != nil
                && smbNameCell?.textField?.stringValue == smbRow.name.displayName)
            checks.append("SMB and SFTP loaded name rows share native file/folder symbols and scaled local-cell geometry without filesystem icon reads")
            let smbKind = smb.tableView(smb.table, viewFor: smb.table.tableColumns.first { $0.identifier.rawValue == "kind" }, row: 0) as? NSTableCellView
            let sftpKind = tab.rows.tableView(tab.rows.table, viewFor: tab.rows.table.tableColumns.first { $0.identifier.rawValue == "kind" }, row: 1) as? NSTableCellView
            let sftpSize = tab.rows.tableView(tab.rows.table, viewFor: tab.rows.table.tableColumns.first { $0.identifier.rawValue == "size" }, row: 1) as? NSTableCellView
            try require(smbKind?.textField?.stringValue == "TXT file" && sftpKind?.textField?.stringValue == "TXT file"
                && sftpSize?.textField?.stringValue == "\(UInt64.max.formatted()) bytes"
                && FileSizeText.unsigned(0) == FileSizeText.string(0))
            checks.append("Local and remote Kind/Size labels share extension and zero-byte formatting; full unsigned remote sizes remain safe")
            let beforeIconPaint = await transport.counts(), readsBeforeIconPaint = await spy.count
            let columns = try await verifyResponsiveColumns(owner: owner, sftp: tab.rows, smb: smb, window: parent)
            try JSONSerialization.data(withJSONObject: ["passed": true, "observations": columns], options: [.prettyPrinted, .sortedKeys])
                .write(to: admitted.appendingPathComponent("evidence/remote-columns-responsive.json"), options: .withoutOverwriting)
            let afterColumnLayout = await transport.counts(), readsAfterColumnLayout = await spy.count
            try require(afterColumnLayout == beforeIconPaint && readsAfterColumnLayout == readsBeforeIconPaint)
            checks.append("Real SFTP tab and loaded SMB table share readable scaled Name/default metadata widths through normal/narrow100/150% allocation and restore without transport/local metadata reads or selection changes; constrained columns remain horizontally scrollable")
            let textEntry = SFTPWorkerEntry(name: try .init(Data("Editor.txt".utf8)), logicalBytes: 19,
                modifiedSeconds: nil, permissions: 0o100640)
            var openingPreferences = EditorPreferences()
            let openingCue = SFTPTabController.openingAppearance(for: textEntry,
                preferences: openingPreferences, allowsEditing: true)
            try require(openingCue.cue == .editor && openingCue.isEmphasized && openingCue.badge == .none)
            let brightCell = FileTableCell.remote(in: smb.table, column: "name", text: "Editor.txt", role: .document,
                opening: openingCue)
            try require(brightCell.imageView?.contentTintColor == .labelColor
                && brightCell.toolTip == "Opens in Traverse Editor"
                && brightCell.accessibilityHelp() == "Opens in Traverse Editor")
            openingPreferences.openingIndicator = .badge
            let badge = SFTPTabController.openingAppearance(for: textEntry, preferences: openingPreferences, allowsEditing: true)
            try require(badge.badge == .editor && FileOpeningSymbol.image(role: .document, appearance: badge) != nil)
            let readOnlyCue = SFTPTabController.openingAppearance(for: textEntry, preferences: openingPreferences,
                allowsEditing: false, allowsViewing: true)
            try require(readOnlyCue.badge == .viewer && readOnlyCue.explanation == "Opens read-only in Traverse"
                && FileOpeningSymbol.image(role: .document, appearance: readOnlyCue) != nil)
            try openingPreferences.setTarget(.systemDefault, forExtension: "txt")
            try require(SFTPTabController.openingAppearance(for: textEntry, preferences: openingPreferences, allowsEditing: true).cue == .none)
            try openingPreferences.clearTarget(forExtension: "txt")
            openingPreferences.openingIndicator = .off
            try require(!SFTPTabController.openingAppearance(for: textEntry, preferences: openingPreferences, allowsEditing: true).isEmphasized)
            openingPreferences.openingIndicator = .subtle
            try require(SFTPTabController.openingAppearance(for: textEntry, preferences: openingPreferences, allowsEditing: false).cue == .none
                && SFTPTabController.openingAppearance(for: file.entry, preferences: openingPreferences, allowsEditing: true).cue == .none
                && SFTPTabController.openingAppearance(for: folder.entry, preferences: openingPreferences, allowsEditing: true).cue == .none)
            let selectionBeforePaint = tab.rows.table.selectedRowIndexes
            tab.rows.refreshOpeningPresentation()
            try require(tab.rows.table.selectedRowIndexes == selectionBeforePaint
                && tab.rows.openingAppearanceForEntry == nil && smbNameCell?.toolTip == nil)
            let afterIconPaint = await transport.counts(), readsAfterIconPaint = await spy.count
            try require(afterIconPaint == beforeIconPaint && readsAfterIconPaint == readsBeforeIconPaint)
            checks.append("Remote native-opening cues share local preferences, brightness, badge and accessibility help; read-only/oversize/folder rows stay ordinary with selection and transport counts unchanged")
            var smbActions = 0
            smb.canInspect = { [weak smb] in smb?.selectedObservation != nil }; smb.onProperties = { smbActions += 1 }
            smb.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            let smbMenu = smb.table.menu!, index = smbMenu.items.firstIndex { $0.title == "Properties…" }!
            try require(smb.validateMenuItem(smbMenu.items[index])); smbMenu.performActionForItem(at:index)
            smb.loading(); smbMenu.performActionForItem(at:index)
            try require(smbActions == 1 && !smb.validateMenuItem(smbMenu.items[index]))
            checks.append("Actual SMB row-menu callbacks require a loaded selection and stop after cache invalidation")

            let groupSnapshot = SMBDirectorySnapshot(readID: UUID(), revision: 2, count: 4, folders: 1, state: .complete)
            let groupRows = try [
                SMBDirectoryObservation(id: 1, name: .init("Folder"), attributes: 16, logicalBytes: 0, modifiedFileTime: 1),
                SMBDirectoryObservation(id: 2, name: .init("First.txt"), attributes: 32, logicalBytes: 7, modifiedFileTime: 1),
                SMBDirectoryObservation(id: 3, name: .init("Second.json"), attributes: 32, logicalBytes: 11, modifiedFileTime: 1),
                SMBDirectoryObservation(id: 4, name: .init("Third.txt"), attributes: 32, logicalBytes: 13, modifiedFileTime: 1)
            ]
            smb.downloadsAvailable = true
            smb.observe(groupSnapshot); try smb.accept(.init(request: .init(snapshot: groupSnapshot, offset: 0), entries: groupRows))
            smb.table.selectRowIndexes(IndexSet(integersIn: 1..<4), byExtendingSelection: false)
            let connectionID = UUID(), group = smb.selectedDownloadBatch(connection: connectionID)
            try require(group?.connection == connectionID && group?.snapshot == groupSnapshot
                && group?.items.map(\.localName) == ["First.txt", "Second.json", "Third.txt"] && group?.logicalBytes == 31)
            smb.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
            try require(smb.selectedDownloadBatch(connection: connectionID) == nil)
            smb.table.selectRowIndexes(IndexSet(integersIn: 1..<4), byExtendingSelection: false)
            smb.downloadsAvailable = false
            try require(smb.selectedDownloadBatch(connection: connectionID) == nil)
            smb.downloadsAvailable = true; smb.loading()
            try require(smb.selectedDownloadBatch(connection: connectionID) == nil)
            try require(DiagnosticErrors.project(SMBDownloadBatchIssue.tooLarge).symbol == "smb.downloadGroup.tooLarge")
            checks.append("Native SMB multiselection seals all selected cached files against one complete snapshot; folder mixtures, disabled actions and unloaded rows refuse without a body request")

            tab.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            owner.showObservedRemoteProperties()
            try require(presentation.canCalculateSize && presentation.item?.kind == .folder)
            presentation.calculateSize()
            try await wait { !presentation.isCalculatingSize }
            try require(presentation.folderSize?.logicalBytes == 8 << 30 && presentation.folderSize?.excludedLinks == 1
                && presentation.sizeFailure == nil && session.latest.failure == nil)
            presentation.calculateSize()
            try await wait { !presentation.isCalculatingSize }
            try require(presentation.sizeFailure == .denied && presentation.folderSize?.logicalBytes == 8 << 30
                && session.latest.failure == nil)
            presentation.calculateSize()
            try await wait { await transport.sizeCount() == 3 }
            tab.rows.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            await transport.releaseSize()
            try await wait { !presentation.isCalculatingSize }
            try require(presentation.sizeFailure == .stale && session.latest.failure == nil)
            tab.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            owner.showObservedRemoteProperties(); presentation.calculateSize()
            try await wait { await transport.sizeCount() == 4 }
            presentation.close()
            try await wait { presentation.item == nil }
            owner.showObservedRemoteProperties()
            try require(presentation.hasFolderSizeAction && presentation.isWaitingForConnection && !presentation.canCalculateSize)
            await transport.releaseSize()
            try await wait { await transport.sizeInFlight() == false }
            try await wait { presentation.canCalculateSize }
            let afterSizes = await transport.counts()
            try require(!presentation.isCalculatingSize && afterSizes.last == 0 && session.latest.failure == nil)
            let sizesAfterReopen = await transport.sizeCount()
            try require(presentation.folderSize?.logicalBytes == 8 << 30 && !presentation.isCalculatingSize && sizesAfterReopen == 4)
            checks.append("Folder Properties uses one metadata-only session request, accepts large logical sizes, preserves a dated measurement on denial, drops reselected/closed-window results and keeps the connection usable")

            let unsafeRow = SFTPStoredRow(observation:3,entry:.init(name:try .init(Data("PRIVATE-unsafe\nname".utf8)),logicalBytes:19,modifiedSeconds:nil,permissions:0o100644))
            let unsafe = try RemoteItemObservation(sftp:unsafeRow,directory:[],homeRelative:true,listingComplete:false)
            presentation.show(unsafe,relativeTo:parent); let countBeforeUnsafe = copies
            guard let reopenedWindow = presentation.window else { throw Failure.scope }; window = reopenedWindow
            presentation.copyName(); presentation.copyPath()
            try require(copies == countBeforeUnsafe && unsafe.copyName == nil && unsafe.copyPath == nil && !unsafe.name.contains("\n"))
            checks.append("Escaped control names remain inspectable and cannot publish unsafe clipboard text")

            let failedConnection = SFTPBrowserUpdate(generation: session.latest.generation, snapshot: session.latest.snapshot,
                paused: false, reading: false, failure: .unavailable)
            tab.showTransferOutcome("Generated download completed", showsUploadHistory: false)
            owner.renderSFTPStatus(failedConnection)
            try require(owner.status.stringValue != "Generated download completed")
            let attention = "Generated download needs review. Open Results for details."
            tab.showTransferOutcome(attention, needsAttention: true, showsUploadHistory: false)
            owner.renderSFTPStatus(failedConnection)
            try require(owner.status.stringValue == attention && owner.status.toolTip == attention
                && tab.operationNotice?.showsUploadHistory == false)
            owner.renderSFTPStatus(session.latest)
            try require(owner.status.stringValue == attention)
            tab.clearTransferOutcome(); owner.renderSFTPStatus(failedConnection)
            try require(owner.status.stringValue != attention && tab.operationNotice == nil)
            let sharedNotice = ConnectionOperationNotice(message: attention, needsAttention: true)
            try require(sharedNotice.footerMessage(isIdle: false, connectionHasProblem: true) == attention
                && ConnectionOperationNotice(message: "Completed", needsAttention: false)
                    .footerMessage(isIdle: true, connectionHasProblem: true) == nil)
            tab.showTransferOutcome(attention, needsAttention: true, showsUploadHistory: false)
            checks.append("Connection refresh preserves an operation needing attention; successful results cannot hide a later disconnect, and the next operation can clear the shared notice")
            presentation.show(observed,relativeTo:parent)
            let closing = tab.close(); _ = await closing.value
            let counts = await transport.counts()
            try require(counts[2] == 1 && presentation.item == observed && owner.status.stringValue == attention
                && owner.sftpClosedUploadNotices[owner.activeID]?.message == attention
                && owner.sftpClosedUploadNotices[owner.activeID]?.showHistory == nil && uploadHistoryRequests == 0)
            presentation.copyPath(); try require(privateBoard.string(forType:.string) == observed.copyPath)
            checks.append("Immutable observed facts can be copied after session closure without retaining its transport authority")
            checks.append("The actual connection close/drain retains the operation attention message on its closed tab without a new server read")

            let recording = ProcessInfo.processInfo.arguments.contains("--record-remote-properties")
            if recording {
                settings.appearance = .dark; settings.interfaceSize = .init(100); settings.motion.mode = .full; settings.navigationStyle = .glass
                let folderItem = try RemoteItemObservation(sftp: folder, directory: [], homeRelative: false, listingComplete: true)
                let sizeAction = RemoteFolderSizeAction(cacheKey: .sftp(connection: UUID(), generation: UUID(),
                    snapshot: .init(read: 1, revision: 1, count: 1, folders: 1, state: .complete), observation: 1),
                    isCurrent: { true }, calculate: {
                        try await Task.sleep(for: .milliseconds(180))
                        return try .init(logicalBytes: 32 << 30, files: 1_234, folders: 19, excludedLinks: 2)
                    })
                presentation.show(folderItem, relativeTo: parent, folderSizeAction: sizeAction)
                window.setFrame(.init(x: 280, y: 160, width: 620, height: 580), display: true)
                let label = "remote-folder-size-full-100"
                window.title = label + " · generated review"; NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(80))
                let sizeMovie = try await NativeMotionRecorder.record(window: window, root: admitted, label: label,
                    sampling: .diagnostic(for: window)) { presentation.calculateSize() }
                try await wait { !presentation.isCalculatingSize }
                try require(presentation.folderSize?.logicalBytes == 32 << 30 && presentation.sizeFailure == nil)
                try JSONEncoder().encode(sizeMovie).write(to: admitted.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip(label, report: sizeMovie, field: nil, window: window))
                for (label,appearance,percent,mode,style) in [
                    ("remote-dark-full-100",BrowserAppearance.dark,100,BrowserMotionMode.full,NavigationStyle.glass),
                    ("remote-light-reduced-150",.light,150,.reduced,.glass),
                    ("remote-solid-off-150",.dark,150,.off,.solid)] {
                    settings.appearance = appearance; settings.interfaceSize = .init(percent); settings.motion.mode = mode; settings.navigationStyle = style
                    presentation.show(observed,relativeTo:parent)
                    window.setFrame(.init(x:280,y:160,width:percent == 150 ? 780 : 620,height:percent == 150 ? 700 : 550),display:true)
                    window.title = label + " · generated review"; NSApp.activate(ignoringOtherApps:true)
                    try await Task.sleep(for:.milliseconds(80))
                    let movie = try await NativeMotionRecorder.record(window:window,root:admitted,label:label,sampling:.diagnostic(for:window)) {
                        presentation.show(smbItem,relativeTo:parent)
                    }
                    try JSONEncoder().encode(movie).write(to:admitted.appendingPathComponent("evidence/\(label).json"),options:.withoutOverwriting)
                    var clip = DevelopmentMotionVerification.clip(label,report:movie,field:nil,window:window)
                    clip["interfacePercent"] = percent; clip["mode"] = mode.rawValue; clip["style"] = style.rawValue
                    clips.append(clip)
                    let expected: NSAppearance.Name = appearance == .light ? .aqua : .darkAqua
                    try require(window.effectiveAppearance.name == expected && window.contentView?.effectiveAppearance.name == expected
                        && window.isOpaque && window.styleMask.contains(.resizable))
                    try require(presentation.item == smbItem)
                }
            }
            checks.append(recording ? "Actual generated-only glass/light/solid100/150% Full/Reduced/Off transitions record and drain" : "Functional mode does not claim animation capture")
            var selectionStillCurrent = true
            let lostFolder = try RemoteItemObservation(sftp: folder, directory: [], homeRelative: false, listingComplete: true)
            presentation.show(lostFolder, relativeTo: parent, folderSizeAction: .init(cacheKey: .sftp(connection: UUID(), generation: UUID(),
                snapshot: .init(read: 1, revision: 1, count: 1, folders: 1, state: .complete), observation: 1),
                isCurrent: { selectionStillCurrent }, calculate: { throw RemoteFolderSizeFailure.connectionLost }))
            presentation.calculateSize(); selectionStillCurrent = false
            try await wait { !presentation.isCalculatingSize }
            try require(presentation.sizeFailure == .connectionLost && presentation.folderSize == nil)
            checks.append("A terminal connection-loss failure remains explicit even when its selection is no longer current; no total or stale-selection success is substituted")
            let localReads = await spy.count; try require(localReads == 0 && fileURLPublications == 0)
            presentation.close(); try require(presentation.item == nil && presentation.window == nil)
            checks.append("Closing releases private item facts and the independent window owner")
            for protocolKind in ExplorerConnectionProtocol.allCases {
                let readOnly = RemoteTextSnapshotController(contents: try .original(Data("Generated read-only text.\nSecond line.\n".utf8)),
                    name: "Snapshot.txt", connection: UUID(),
                    location: .remoteSnapshot(server: "Generated server", path: "/fixture/Snapshot.txt", captured: Date()),
                    settings: settings, retainedCopy: false, protocolKind: protocolKind)
                var snapshotClosed = false, writeActions = 0
                readOnly.didClose = { _ in snapshotClosed = true }
                readOnly.window.onSave = { writeActions += 1 }; readOnly.window.onSaveAs = { writeActions += 1 }
                readOnly.show()
                try await wait { readOnly.window.window?.isKeyWindow == true && readOnly.window.surface.canGoToLine }
                readOnly.window.window?.contentView?.layoutSubtreeIfNeeded()
                try require(readOnly.window.surface.frame.height > (readOnly.window.window?.contentLayoutRect.height ?? 650) * 0.7)
                try require(!readOnly.window.surface.textView.isEditable && !readOnly.window.saveButton.isEnabled
                    && !readOnly.window.saveAsButton.isEnabled && readOnly.window.saveAsButton.isHidden
                    && readOnly.window.onTextCopy == nil && readOnly.window.onReload == nil)
                guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else { throw Failure.scope }
                fileMenu.update()
                for item in fileMenu.items where item.title == "Save" || item.title == "Save As…" {
                    try require(!item.isEnabled); fileMenu.performActionForItem(at: fileMenu.index(of: item))
                }
                try require(writeActions == 0)
                if CGPreflightScreenCaptureAccess(), let native = readOnly.window.window {
                    try await GlassVerification.captureOwnedWindow(native, to: admitted.appendingPathComponent("evidence/read-only-snapshot-\(protocolKind.rawValue.lowercased()).png"))
                }
                readOnly.connectionClosed()
                try require(!readOnly.window.saveAsButton.isEnabled && !readOnly.window.surface.textView.isEditable)
                await readOnly.closeAndDrain()
                try require(snapshotClosed && readOnly.closed && readOnly.window.window?.isVisible != true && writeActions == 0)
            }
            checks.append("Both protocol labels reuse the same native read-only text window: writing/Save As are disabled, captured context and line navigation remain, and close drains without a network or export handler")
            clips += try await OwnedTrashWindowVerification.run(root: admitted, settings: settings, parent: parent, recording: recording)
            checks.append("The generated native Trash view preserves whole-group IDs, disables busy/review/unavailable actions, reflows at150%, retains its frame and clears on close; no Trash or file action is installed")
            let export = admitted.appendingPathComponent("evidence/remote-properties-logs.jsonl")
            guard case let .saved(records,_,incomplete) = await service.export(to:export,retainingAccess:"Generated remote-item log destination") else { throw Failure.scope }
            let text = try await Task.detached { try String(contentsOf:export,encoding:.utf8) }.value
            try require(records > 0 && !incomplete && !text.contains("PRIVATE-") && !text.contains(observed.displayPath)
                && !text.contains(Data(observed.displayPath.utf8).base64EncodedString()) && !text.contains("generated.invalid"))
            checks.append("Actual action-log export contains no remote name, path, hostname or encoded input")
        } catch {
            if case let Failure.check(line) = error { failure = line } else { failure = 0 }
            failureType = String(reflecting:type(of:error))
        }
        if let connection { _ = await connection.close().value }
        details?.close(); browser?.suspendBrowser(); host?.close(); board?.releaseGlobally()
        ApplicationDiagnostics.shared.configureForVerification(nil); await logger?.closeAndDrain()
        if let root {
            let report: [String:Any] = ["passed":failure == nil,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":failureType.map { $0 as Any } ?? NSNull(),
                "checks":checks,"clips":clips,"activityDrained":ApplicationFileActivity.gate.activeCount == 0,
                "transport":"Explicit generated SFTP actor double; no helper/network/security qualification", "smb":"Native loaded-row callback component; no live SMB session",
                "networkRequests":0,"personalFiles":0,"physicalKeyboardExercised":false]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                .write(to:root.appendingPathComponent("evidence/native-remote-properties.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func verifyResponsiveColumns(owner: BrowserViewController, sftp: SFTPRemoteRowsView,
        smb: SMBRemoteRowsView, window: NSWindow) async throws -> [[String: Any]] {
        let settings = owner.settings, initial = window.contentView!.bounds.size, originalSize = settings.interfaceSize
        let smbSize = smb.frame.size, selection = sftp.table.selectedRowIndexes
        var observations: [[String: Any]] = [], wideDates: [String: CGFloat] = [:]
        defer {
            settings.interfaceSize = originalSize
            window.setContentSize(initial); window.contentView?.layoutSubtreeIfNeeded()
            smb.setFrameSize(smbSize); smb.needsLayout = true; smb.layoutSubtreeIfNeeded()
        }
        for (percent, narrow) in [(100, false), (100, true), (150, true), (150, false), (100, false)] {
            settings.interfaceSize = .init(percent)
            await Task.yield()
            window.setContentSize(narrow ? .init(width: 760, height: initial.height) : initial)
            window.contentView?.layoutSubtreeIfNeeded()
            smb.setFrameSize(.init(width: narrow ? 420 : 700, height: smbSize.height))
            smb.needsLayout = true; smb.layoutSubtreeIfNeeded()
            sftp.needsLayout = true; sftp.layoutSubtreeIfNeeded()
            for (label, table, scroll) in [("sftp", sftp.table, sftp.scroll), ("smb", smb.table, smb.scroll)] {
                guard let name = table.tableColumn(withIdentifier: .init("name")),
                      let date = table.tableColumn(withIdentifier: .init("modified")) else { throw Failure.scope }
                let visible = table.tableColumns.filter { !$0.isHidden }
                let edge = visible.reduce(CGFloat.zero) { $0 + $1.width + table.intercellSpacing.width }
                try require(name.width >= 180 * InterfaceMetrics.scale - 1 && table.frame.width >= edge - 1
                    && scroll.hasHorizontalScroller && sftp.table.selectedRowIndexes == selection)
                if percent == 100 {
                    if narrow, let wide = wideDates[label] { try require(date.width < wide - 1) }
                    else { wideDates[label] = date.width }
                }
                observations.append(["surface": label, "percent": percent, "narrow": narrow,
                    "viewport": scroll.contentSize.width, "name": name.width, "date": date.width,
                    "document": table.frame.width, "columnsEdge": edge])
            }
        }
        return observations
    }

    private actor PropertiesSpy: FilePropertiesReading {
        private(set) var count = 0
        func read(_ urls: [URL]) async throws -> FilePropertiesReport { count += 1; throw Failure.scope }
    }
    private actor Transport: SFTPDirectoryTransport {
        nonisolated let allowsFolderSizeSummary = true
        private let rows: [SFTPStoredRow], generation = UUID()
        private var opens = 0, pages = 0, closes = 0
        private var sizes = 0, heldSize: CheckedContinuation<Void, Never>?, sizeActive = false
        init(rows: [SFTPStoredRow]) { self.rows = rows }
        func counts() -> [Int] { [opens,pages,closes] }
        func sizeCount() -> Int { sizes }
        func sizeInFlight() -> Bool { sizeActive }
        func summarizeSelectedFolder(_ selection: SFTPFolderSizeSelection) async throws -> RemoteFolderSizeSummary {
            guard selection.generation == generation, selection.snapshot.state == .complete,
                  selection.row == rows.first else { throw Failure.scope }
            sizes += 1; sizeActive = true; defer { sizeActive = false }
            if sizes == 2 { throw RemoteFolderSizeFailure.denied }
            if sizes >= 3 { await withCheckedContinuation { heldSize = $0 } }
            return try .init(logicalBytes: 8 << 30, files: 1, folders: 1, excludedLinks: 1)
        }
        func releaseSize() { let held = heldSize; heldSize = nil; held?.resume() }
        func openStoredDirectory(_ path: String) async throws -> (UUID,SFTPStoredSnapshot) {
            guard path == "/" else { throw Failure.scope }; opens += 1
            return (generation,.init(read:1,revision:1,count:UInt64(rows.count),folders:1,state:.complete))
        }
        func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { throw Failure.scope }
        func page(_ generation: UUID,snapshot: SFTPStoredSnapshot,offset: UInt64,sort: SFTPStoredSort,descending: Bool) async throws -> SFTPStoredPage? {
            guard generation == self.generation,offset == 0,sort == .name,!descending else { throw Failure.scope }; pages += 1
            return .init(request:UUID(),generation:generation,snapshot:snapshot,offset:0,rows:rows)
        }
        func close() async -> SFTPWorkerClose {
            closes += 1; releaseSize()
            return .init(actualExit:true,exitStatus:0,ipcEOF:true,contained:false,protocolValid:true,terminal:nil,temporaryStoreRemoved:nil)
        }
    }
}
#endif
