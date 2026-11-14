#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
@_spi(ArchiveProduction) import FileOperations
@_spi(ArchiveProduction) @_spi(Qualification) @testable import LocalStorage

@MainActor enum SMBSelectedDownloadVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static var retained: BrowserWindowController?
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, seconds: Double = 15, _ line: UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end, line); try await Task.sleep(for: .milliseconds(5)) }
    }
    private static func password() async throws -> SMBPassword {
        let data = try await Task.detached {
            var bytes = Data()
            while bytes.count <= 64 {
                var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                guard poll(&fd, 1, 2000) > 0 else { throw Failure.scope }
                var byte: UInt8 = 0; guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { throw Failure.scope }
                if byte == 10 { return bytes }; bytes.append(byte)
            }; throw Failure.scope
        }.value
        guard data.count == 64, data.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), let text = String(data: data, encoding: .ascii) else { throw Failure.scope }
        return try SMBPassword(text)
    }
    private final class StopBarrier: @unchecked Sendable {
        private let lock = NSLock(), resume = DispatchSemaphore(value: 0)
        private var reached = false
        var pending: Bool { lock.withLock { reached } }
        func observe(_ bytes: UInt64) {
            guard bytes >= 32768, lock.withLock({ if reached { return false }; reached = true; return true }) else { return }
            _ = resume.wait(timeout: .now() + 3)
        }
        func release() { resume.signal() }
    }
    private final class CredentialObservation: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func record() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    static func run() async {
        var root: URL?, session: SMBBrowserSession?, tab: SMBTabController?, bodies: SMBDownloadStorage?, metadata: SMBTemporaryStorage?
        var stage = "scope", checks: [String] = [], failureLine: UInt?, failureType: String?, errorCode: Int64?
        var closed: SMBBrowserDrainResult?, clips: [[String:Any]] = [], peer: BrowserViewController?
        var groupFacts: [String: Any] = [:]
        var reportName = "native-smb-download.json"
        let credentials = CredentialObservation()
        var barrier: StopBarrier?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let args = ProcessInfo.processInfo.arguments
            guard let at = args.firstIndex(of: "--smb-download-scenario"), args.indices.contains(at + 1),
                  let portAt = args.firstIndex(of: "--generated-port"), args.indices.contains(portAt + 1),
                  let port = UInt16(args[portAt + 1]), port > 1024 else { throw Failure.scope }
            let scenario = args[at + 1]
            let menuControl = scenario == "menus"
            let groupControl = ["group-preflight", "group-success", "group-stop", "group-review"].contains(scenario)
            let action = groupControl ? (scenario == "group-preflight" ? "smb-selected-download-group-native-preflight" : "smb-selected-download-group-native") : menuControl ? "smb-selected-download-ordinary-native" : ["preflight","layout"].contains(scenario) ? "smb-selected-download-live-native-preflight" : "smb-selected-download-live-native"
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(["menus","preflight","layout","success","stop","group-preflight","group-success","group-stop","group-review"].contains(scenario) && area.resolvingSymlinksInPath() == area
                && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development") && marker?["action"] as? String == action
                && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == (menuControl || groupControl ? "development" : "qualification"))
            root = area
            if menuControl {
                stage = "native-menu-controls"
                try require(SMBUploadFeature.groupsAvailable && SMBUploadFeature.selectionLimit == SMBUploadGroupPlan.maximumRoots
                    && SMBUploadFeature.pasteAvailable && SMBUploadFeature.dropAvailable
                    && SMBFolderUploadFeature.available)
                checks.append("Ordinary file/folder inputs share the product policy and bounded serial planner; source grants stay separate")
                let rows = SMBRemoteRowsView(frame: .init(x: 0,y: 0,width: 800,height: 400))
                guard let menu = rows.table.menu, let direct = menu.items.first(where: { $0.title == "Download…" }),
                      let other = menu.items.first(where: { $0.title == "Download to Other Pane…" }),
                      let directAction = direct.action, let otherAction = other.action else { throw Failure.scope }
                var downloads = 0, paneDownloads = 0, allow = false, paneAllow = false
                rows.onDownload = { downloads += 1 }; rows.onDownloadToPane = { paneDownloads += 1 }
                rows.downloadAllowed = { allow }; rows.paneDownloadAllowed = { paneAllow }
                func invoke(_ item: NSMenuItem) { if let action = item.action { _ = NSApp.sendAction(action,to: item.target,from: item) } }
                try require(direct.isHidden && other.isHidden && !rows.validateMenuItem(direct) && !rows.validateMenuItem(other))
                allow = true; paneAllow = true; invoke(direct); invoke(other)
                try require(downloads == 0 && paneDownloads == 0)
                checks.append("Unavailable menus stay hidden and stale selector dispatch cannot request either Download")
                rows.downloadsAvailable = true; allow = false; paneAllow = false
                try require(!direct.isHidden && !other.isHidden && !rows.validateMenuItem(direct) && !rows.validateMenuItem(other))
                invoke(direct); invoke(other); try require(downloads == 0 && paneDownloads == 0)
                allow = true; try require(rows.validateMenuItem(direct) && !rows.validateMenuItem(other))
                menu.performActionForItem(at: menu.index(of: direct)); try require(downloads == 1 && paneDownloads == 0)
                allow = false; paneAllow = true; try require(!rows.validateMenuItem(direct) && rows.validateMenuItem(other))
                menu.performActionForItem(at: menu.index(of: other)); try require(downloads == 1 && paneDownloads == 1)
                checks.append("Actual NSMenu actions reach their distinct callbacks only after current per-destination admission")
                rows.onDownload = nil; rows.onDownloadToPane = nil
                try require(!rows.validateMenuItem(direct) && !rows.validateMenuItem(other))
                rows.onDownload = { downloads += 1 }; rows.onDownloadToPane = { paneDownloads += 1 }
                rows.downloadsAvailable = false; invoke(direct); invoke(other)
                try require(downloads == 1 && paneDownloads == 1 && direct.action == directAction && other.action == otherAction)
                try require(ApplicationSMBActivity.gate.activeCount == 0)
                checks.append("Removing callbacks or disabling the feature closes both entries without a helper, credential or body request")
                // A newly created rows view starts with folder capability off;
                // its initial title must follow that view state, not the app's
                // now-shared product policy before a tab configures the view.
                guard let upload = menu.items.first(where: { $0.title == "Upload Files Here…" }),
                      let outcomes = menu.items.first(where: { $0.title == "Upload Outcomes…" }) else { throw Failure.scope }
                var uploadCalls = 0, historyCalls = 0, uploadAllowed = false
                rows.onUpload = { uploadCalls += 1 }; rows.uploadAllowed = { uploadAllowed }
                rows.onUploadHistory = { historyCalls += 1 }
                try require(upload.isHidden && outcomes.isHidden && !rows.validateMenuItem(upload))
                uploadAllowed = true; invoke(upload); try require(uploadCalls == 0)
                rows.uploadsAvailable = true; uploadAllowed = false
                try require(!upload.isHidden && !outcomes.isHidden && !rows.validateMenuItem(upload))
                invoke(upload); try require(uploadCalls == 0)
                uploadAllowed = true
                menu.performActionForItem(at: menu.index(of: upload))
                menu.performActionForItem(at: menu.index(of: outcomes))
                try require(uploadCalls == 1 && historyCalls == 1)
                rows.uploadsAvailable = false; invoke(upload); try require(uploadCalls == 1)
                rows.onUpload = nil; rows.onUploadHistory = nil
                try require(!rows.validateMenuItem(upload) && !rows.validateMenuItem(outcomes))
                checks.append("SMB Upload uses current capability admission; real menu dispatch reaches Upload and local Outcomes without any network request")
                guard let newFile = menu.items.first(where: { $0.title == FilenamePrompt.newFileTitle + "…" }),
                      let newFolder = menu.items.first(where: { $0.title == "New Folder…" }) else { throw Failure.scope }
                var createdFiles = 0, createdFolders = 0, allowCreation = true
                rows.onNewFile = { createdFiles += 1 }; rows.onNewFolder = { createdFolders += 1 }
                rows.newFileAllowed = { allowCreation }; rows.newFolderAllowed = { allowCreation }
                try require(newFile.isHidden && newFolder.isHidden)
                invoke(newFile); invoke(newFolder); try require(createdFiles == 0 && createdFolders == 0)
                rows.uploadsAvailable = true
                try require(!newFile.isHidden && newFolder.isHidden && rows.validateMenuItem(newFile)
                    && !rows.validateMenuItem(newFolder))
                menu.performActionForItem(at: menu.index(of: newFile))
                rows.folderUploadsAvailable = true
                try require(upload.title == "Upload Here…")
                try require(!newFolder.isHidden && rows.validateMenuItem(newFolder))
                menu.performActionForItem(at: menu.index(of: newFolder))
                try require(createdFiles == 1 && createdFolders == 1)
                allowCreation = false; invoke(newFile); invoke(newFolder)
                try require(!rows.validateMenuItem(newFile) && !rows.validateMenuItem(newFolder)
                    && createdFiles == 1 && createdFolders == 1)
                rows.onNewFile = nil; rows.onNewFolder = nil; rows.newFileAllowed = nil; rows.newFolderAllowed = nil
                try require(newFile.isHidden && newFolder.isHidden)
                checks.append("SMB New Text File and New Folder use distinct capabilities; native callbacks refuse unavailable or stale creation without a source or network request")
                guard let paste = menu.items.first(where: { $0.title == "Paste" }) else { throw Failure.scope }
                var pasteCalls = 0, allowPaste = false
                rows.onPaste = { pasteCalls += 1 }; rows.pasteAllowed = { allowPaste }
                rows.uploadsAvailable = true
                try require(!paste.isHidden && !rows.validateMenuItem(paste))
                invoke(paste); try require(pasteCalls == 0)
                allowPaste = true; menu.performActionForItem(at: menu.index(of: paste))
                try require(pasteCalls == 1)
                rows.onPaste = nil; invoke(paste)
                try require(paste.isHidden && !rows.validateMenuItem(paste) && pasteCalls == 1)
                guard let copy = menu.items.first(where: { $0.title == "Copy" }),
                      let copyTo = menu.items.first(where: { $0.title == "Copy To…" }) else { throw Failure.scope }
                var clipboardCopies = 0, explicitCopies = 0, allowClipboardCopy = false
                rows.onCopyFile = { clipboardCopies += 1 }; rows.copyFileAllowed = { allowClipboardCopy }
                rows.onCopy = { explicitCopies += 1 }; rows.copyAllowed = { true }
                try require(!copy.isHidden && !rows.validateMenuItem(copy) && rows.validateMenuItem(copyTo))
                invoke(copy); try require(clipboardCopies == 0)
                allowClipboardCopy = true
                menu.performActionForItem(at: menu.index(of: copy))
                menu.performActionForItem(at: menu.index(of: copyTo))
                try require(clipboardCopies == 1 && explicitCopies == 1)
                rows.table.onCopy = rows.onCopyFile; rows.table.copyAllowed = rows.copyFileAllowed
                let copyCommand = NSMenuItem(title: "Copy", action: #selector(RemoteFileTableView.copy(_:)), keyEquivalent: "c")
                try require(rows.table.validateMenuItem(copyCommand))
                rows.table.copy(nil); try require(clipboardCopies == 2)
                allowClipboardCopy = false; rows.table.copy(nil); invoke(copy)
                try require(!rows.table.validateMenuItem(copyCommand) && clipboardCopies == 2)
                rows.onCopyFile = nil; rows.table.onCopy = nil
                try require(copy.isHidden && !rows.validateMenuItem(copy) && !rows.table.validateMenuItem(copyCommand))
                rows.onCopy = nil; rows.copyAllowed = nil; rows.copyFileAllowed = nil; rows.table.copyAllowed = nil
                checks.append("SMB native Copy and responder Copy use the clipboard callback independently of Copy To, and refuse unavailable or removed admission without a network request")
                let dropWindow = ToolWindowChrome.makeWindow(title: "Generated SMB input check", size: .init(width: 800, height: 400),
                    minimumSize: .init(width: 500, height: 300))
                dropWindow.contentView = rows
                dropWindow.contentView?.layoutSubtreeIfNeeded()
                defer { dropWindow.close() }
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                let info = FixtureDraggingInfo(board: board, source: nil, sequence: 101, allowed: .copy)
                info.destinationWindow = dropWindow
                info.location = rows.scroll.contentView.convert(NSPoint(x: 60, y: 120), to: nil)
                var dropCalls = 0, allowDrop = true
                rows.onDropPreview = { _ in allowDrop }; rows.onDropFiles = { _ in dropCalls += 1; return true }
                rows.observe(.init(readID: UUID(), revision: 1, count: 0, folders: 0, state: .complete))
                try require(rows.draggingEntered(info) == .copy && rows.prepareForDragOperation(info))
                try require(rows.performDragOperation(info) && dropCalls == 1)
                allowDrop = false
                try require(rows.draggingUpdated(info).isEmpty && !rows.performDragOperation(info) && dropCalls == 1)
                allowDrop = true; rows.loading()
                try require(rows.draggingUpdated(info).isEmpty && !rows.performDragOperation(info))
                rows.onDropPreview = nil; rows.onDropFiles = nil; rows.uploadsAvailable = false
                try require(rows.draggingUpdated(info).isEmpty && dropCalls == 1)
                checks.append("SMB Paste and current-folder Copy drops respect live callbacks, completed-listing admission, refusal and callback removal without a network request")
                let names = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 512, folders: 0, state: .complete)
                let existing = try SMBRemoteName("Existing.bin"), composed = try SMBRemoteName("caf\u{e9}.txt")
                let decomposed = try SMBRemoteName("cafe\u{301}.txt")
                rows.observe(names)
                let namesPage = try SMBDirectoryPage(request: .init(snapshot: names, offset: 0), entries: [
                    .init(id: 1, name: existing, attributes: 0, logicalBytes: 1, modifiedFileTime: 0),
                    .init(id: 2, name: composed, attributes: 0, logicalBytes: 1, modifiedFileTime: 0)
                ])
                try rows.accept(namesPage)
                guard let open = menu.items.first(where: { $0.title == "Open" }),
                      let view = menu.items.first(where: { $0.title == "View in Traverse" }) else { throw Failure.scope }
                rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                var textViews = 0, allowTextView = false, nativeTextOpen = false
                rows.onViewText = { textViews += 1 }; rows.viewTextAllowed = { allowTextView }
                rows.nativeOpenAllowed = { nativeTextOpen }
                try require(!rows.validateMenuItem(open) && !rows.validateMenuItem(view))
                invoke(view); invoke(open); try require(textViews == 0)
                allowTextView = true
                try require(rows.validateMenuItem(view) && !rows.validateMenuItem(open))
                menu.performActionForItem(at: menu.index(of: view)); try require(textViews == 1)
                nativeTextOpen = true
                try require(rows.validateMenuItem(open))
                menu.performActionForItem(at: menu.index(of: open)); try require(textViews == 2)
                rows.onViewText = nil; rows.viewTextAllowed = nil; rows.nativeOpenAllowed = nil
                invoke(view); invoke(open)
                try require(view.isHidden && !rows.validateMenuItem(open) && textViews == 2)
                checks.append("SMB explicit View and ordinary Open keep separate current admission; a system-app preference blocks ordinary text Open without disabling explicit View, and removing callbacks admits no read")
                guard let edit = menu.items.first(where: { $0.title == "Edit in Traverse" }) else { throw Failure.scope }
                var textEdits = 0, allowTextEdit = false
                try require(edit.isHidden && !rows.validateMenuItem(edit))
                rows.onEditText = { textEdits += 1 }; rows.editTextAllowed = { allowTextEdit }
                rows.nativeOpenAllowed = { nativeTextOpen }
                invoke(edit); invoke(open); try require(textEdits == 0)
                allowTextEdit = true
                try require(!edit.isHidden && rows.validateMenuItem(edit) && rows.validateMenuItem(open))
                menu.performActionForItem(at: menu.index(of: edit))
                menu.performActionForItem(at: menu.index(of: open)); try require(textEdits == 2)
                nativeTextOpen = false
                try require(rows.validateMenuItem(edit) && !rows.validateMenuItem(open))
                rows.onEditText = nil; rows.editTextAllowed = nil; rows.nativeOpenAllowed = nil
                invoke(edit); invoke(open)
                try require(edit.isHidden && !rows.validateMenuItem(open) && textEdits == 2)
                checks.append("SMB Edit shares native Open only after current edit admission; system-app preference and callback removal keep explicit Edit, ordinary Open and held Download distinct")
                try require(rows.suggestedNewName("Existing.bin", in: names) == "Existing 2.bin"
                    && rows.suggestedNewName("New folder", in: names) == "New folder")
                try require(rows.hasLoadedName(existing, in: names) && rows.hasLoadedName(composed, in: names)
                    && !rows.hasLoadedName(decomposed, in: names)
                    && !rows.hasLoadedName(try SMBRemoteName("existing.bin"), in: names)
                    && !rows.hasLoadedName(try SMBRemoteName("Unobserved.bin"), in: names))
                // Server Find changes the requested page space. The old rows
                // are no longer current observations until a new page arrives.
                rows.setFindQuery("not visible")
                try require(!rows.hasLoadedName(existing, in: names) && rows.cache.loadedEntries.isEmpty)
                rows.setFindQuery(""); try rows.accept(namesPage)
                try require(rows.hasLoadedName(existing, in: names))
                let sourceURL = area.appendingPathComponent("source/Existing.bin")
                try Data("Generated name review only.\n".utf8).write(to: sourceURL, options: .withoutOverwriting)
                let source = try await SFTPUploadSourceReview.inspect(sourceURL, excluding: [])
                let settings = BrowserSettings(persist: false)
                let review = FileUploadReview(source: source, destination: "Generated share", settings: settings,
                    policy: .stagedSMB, nameIsValid: SMBRequestedUpload.isSupportedName,
                    nameIsOccupied: { name in
                        guard let value = try? SMBRemoteName(name) else { return false }
                        return rows.hasLoadedName(value, in: names)
                    })
                try require(review.model.occupied && !review.model.valid)
                if !args.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = review.window {
                    ToolWindowChrome.position(dropWindow)
                    dropWindow.makeKeyAndOrderFront(nil)
                    let choosing = Task { await review.choose(in: dropWindow) }
                    try await wait { dropWindow.attachedSheet === window }
                    try await UIVerification.snapshot(window, to: area.appendingPathComponent("evidence/upload-name-occupied.png"))
                    try await GlassVerification.captureOwnedWindow(window, to: area.appendingPathComponent("evidence/upload-name-occupied-window.png"))
                    review.finish(nil)
                    try require(await choosing.value == nil)
                }
                review.model.name = "New.bin"
                try require(!review.model.occupied && review.model.valid)
                review.model.name = ""
                try require(!review.model.valid)
                review.close()
                rows.observe(.init(readID: UUID(), revision: 1, count: 512, folders: 0, state: .complete))
                try require(!rows.hasLoadedName(existing, in: names))
                rows.loading()
                try require(!rows.hasLoadedName(existing, in: names))
                let unicodeName = String(repeating: "界", count: 100) + ".txt"
                try require(SMBRequestedUpload.isSupportedName(unicodeName)
                    && FilenamePrompt.LengthLimit.utf16Units(255).allows(unicodeName)
                    && !FilenamePrompt.LengthLimit.utf8Bytes(255).allows(unicodeName)
                    && !FilenamePrompt.LengthLimit.utf16Units(255).allows(String(repeating: "界", count: 256)))
                checks.append("Loaded-name lookup preserves exact UTF16 spelling and case; a changed server Find/page space or stale/loading rows supplies no name knowledge. Fresh pages restore positive knowledge; the shared review refuses an observed name without network work")
                checks.append("SMB name entry uses its UTF16 length limit while local/SFTP prompts keep their UTF8 limit; valid multibyte names are not needlessly refused")
                if !args.contains("--offscreen"), CGPreflightScreenCaptureAccess() {
                    settings.interfaceSize = .init(150); InterfacePresentation.shared.bind(settings)
                    let prompt = FilenamePrompt(title: "New Folder", initial: "New folder",
                        message: "Create an empty folder here. Existing folders will be kept.", validation: nil)
                    dropWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    let choosing = Task { await prompt.choose(in: dropWindow) }
                    try await wait { NSApp.isActive && dropWindow.attachedSheet?.isKeyWindow == true }
                    guard let sheet = dropWindow.attachedSheet else { throw Failure.scope }
                    sheet.contentView?.layoutSubtreeIfNeeded(); sheet.displayIfNeeded()
                    try await UIVerification.snapshot(sheet, to: area.appendingPathComponent("evidence/new-item-name-150-view.png"))
                    try await GlassVerification.captureOwnedWindow(sheet, to: area.appendingPathComponent("evidence/new-item-name-150.png"))
                    // Reuse the existing interactive review mode when a real
                    // native click is needed; the runner retains its deadline.
                    if !args.contains("--interactive-sidebar-review") { dropWindow.endSheet(sheet, returnCode: .cancel) }
                    try require(await choosing.value == nil)
                    checks.append("The shared 150% native name sheet gains key focus, retains view/exact-window captures and Cancel returns without a source or network request; visual acceptance requires image review")
                }
                stage = "move-destination-sheet"
                try await verifyMoveDestination(rows: rows, parent: dropWindow, settings: settings,
                    root: area, offscreen: args.contains("--offscreen"), clips: &clips)
                checks.append("SMB Move remains gated; its native menu, exact destination validation, Cancel/Move and normal/enlarged sheet reuse current controls without network or mutation")
                checks.append("SMB Copy uses that same sheet with an editable new name, refuses a same-path copy/invalid name/stale selection, and supports Cancel/Copy at normal and enlarged sizing without a server")
                stage = "finished"; throw PreflightComplete.done
            }
            SMBDownloadFeature.qualifying = true
            let profile = area.appendingPathComponent("source/Profile"), bodyRoot = profile.appendingPathComponent("remote-downloads")
            let publicGroups = groupControl && RemoteDownloadPublicationFeature.qualifiesPublicQuarantineGroupDownload
            let publicDownload = publicGroups || !groupControl && RemoteDownloadPublicationFeature.qualifiesSMBPublicQuarantineDownload
            let storage: SMBDownloadStorage
            if publicGroups {
                storage = try SMBDownloadStorage(directory: bodyRoot, publicQuarantinePolicy: .sourceQualification,
                    selectedGroupPublicQuarantinePolicy: .sourceQualification)
            } else {
                storage = try publicDownload
                    ? SMBDownloadStorage(directory: bodyRoot, publicQuarantinePolicy: .sourceQualification)
                    : SMBDownloadStorage(directory: bodyRoot)
            }
            bodies = storage
            let catalogs = try SMBTemporaryStorage(directory: profile.appendingPathComponent("smb-browsing"), sessionByteLimit: 8 << 20, poolByteLimit: SMBTemporaryStorage.maximumSessionBytes); metadata = catalogs
            if scenario == "group-review" {
                reportName = "native-smb-group-review.json"; stage = "offline-retained-group"
                let earlier = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("evidence/native-smb-download.json"))) as? [String: Any]
                try require(earlier?["passed"] as? Bool == false && earlier?["stage"] as? String == "selected-group"
                    && earlier?["actualExit"] as? Bool == true && earlier?["pipeDrained"] as? Bool == true
                    && earlier?["socketAndCatalogDrained"] as? Bool == true && earlier?["remainingBodies"] as? Int == 2
                    && FileManager().fileExists(atPath: area.appendingPathComponent("evidence/stopped-spools-before-discard.tar.gz").path))
                let pending = try await storage.inspect(), lengths = try await groupPayloadLengths(pending, root: bodyRoot)
                try require(pending.count == 2 && pending.allSatisfy { !$0.active }
                    && lengths.values.sorted() == [1, 32768])
                let settings = BrowserSettings(persist: false); settings.navigationStyle = .glass
                InterfacePresentation.shared.bind(settings)
                let discarded = try await discardGroup(pending, settings: settings, storage: storage, catalogs: catalogs,
                    profile: profile, owner: nil, credentialLookup: { credentials.record() })
                groupFacts = ["scenario": scenario, "retainedBeforeDiscard": pending.count, "payloadBytes": lengths.values.reduce(0, +),
                    "storageBytes": pending.reduce(UInt64(0)) { $0 + $1.observedBytes }, "explicitlyDiscarded": discarded,
                    "serverConnections": 0, "earlierNativeRunPassed": false]
                checks.append("The exact archived stopped group is inactive after process exit; Connection Storage explicitly discards both local copies offline")
                stage = "finished"; throw PreflightComplete.done
            }
            let address = try SMBConnectionAddress(server: "127.0.0.1", port: port, share: "DownloadEncryptedQA", startingFolder: "/")
            let request = try SMBServerDraft(name: "Generated Download", address: address, account: "nobody", domain: "", security: .encrypted)
            stage = "signed-helper-preparation"
            let endpoint = try await SMBPreparedConnection.prepareValidated(address, bundleURL: Bundle.main.bundleURL, activity: ApplicationSMBActivity.gate)
            if scenario == "preflight" {
                let reserved = try await SMBTemporaryCatalogPool(storage: catalogs).reserve(); try require(await reserved.finishWithoutWorker())
                let empty = try await storage.inspect(); try require(empty.isEmpty && ApplicationSMBActivity.gate.activeCount == 0)
                stage = "native-contract-controls"
                let needsName = try SMBDownloadSelection(connection: UUID(), snapshot: .init(readID: UUID(), revision: 2, count: 1, folders: 0, state: .complete),
                    observation: .init(id: 1, name: SMBRemoteName("Generated:Name.txt"), attributes: 32, logicalBytes: 0, modifiedFileTime: 300))
                try require(needsName.proposedLocalName == nil)
                var rejectedControl = false
                do { _ = try SMBRemoteName("Generated\u{202e}.txt") } catch { rejectedControl = true }
                try require(rejectedControl)
                checks.append("Signed helper, current catalog reserve/drain, passive body inspection, unsafe-control refusal and explicit local-name requirement pass without network/credentials")
                stage = "finished"; throw PreflightComplete.done
            }
            stage = "browser-layout"
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = scenario == "stop" ? .light : .dark
            InterfacePresentation.shared.bind(settings)
            let host = BrowserWindowController(settings: settings); retained = host; let browser = host.browser
            browser.permitsBackgroundVerification = true; browser.readVolumesForVerification = { [] }
            let journal = profile.appendingPathComponent("operation-recovery")
            let engine = RecoverableFileOperations(journalDirectory: journal, protecting: [bodyRoot,catalogs.directory],
                receivedDownloadPublicQuarantinePolicy: publicDownload ? .sourceQualification : .held)
            browser.recoverableFileOperations = engine
            browser.privateNames = ApplicationPrivateNames(directory: profile.appendingPathComponent("private-names"), settings: settings)
            browser.tabs = [BrowserTab(location: .directory(area.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id
            browser.loadLocation(); guard let window = host.window else { throw Failure.scope }
            window.setContentSize(.init(width: 1140,height: 740)); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            window.contentView?.superview?.layoutSubtreeIfNeeded(); await Task.yield()
            host.workspace.willStartBrowserForVerification = { next in
                next.permitsBackgroundVerification = true; next.readVolumesForVerification = { [] }
                next.tabs = [BrowserTab(location: .directory(area.appendingPathComponent("source/Destination")))]; next.activeID = next.tabs[0].id
            }
            let layoutFacts: [String:Any] = ["workspacePresentation":host.isWorkspacePresentation,
                "workspaceHasWindow":host.workspace.view.window != nil,"canChange":host.workspace.canChangePaneLayout,
                "trailing":host.workspace.canSplitActive(at:.trailing),"bottom":host.workspace.canSplitActive(at:.bottom),
                "workspaceWidth":host.workspace.view.bounds.width,"workspaceHeight":host.workspace.view.bounds.height,
                "paneWidth":host.workspace.paneTreeHost.bounds.width,"paneHeight":host.workspace.paneTreeHost.bounds.height,
                "suspended":browser.isBrowserSuspended,"exclusiveOperation":browser.hasExclusiveBrowserOperation]
            try JSONSerialization.data(withJSONObject:layoutFacts,options:[.prettyPrinted,.sortedKeys]).write(to:area.appendingPathComponent("evidence/pane-layout.json"),options:.withoutOverwriting)
            try require(host.isWorkspacePresentation)
            let edge: PaneDropEdge = host.workspace.canSplitActive(at: .trailing) ? .trailing : .bottom
            try require(host.workspace.splitActive(at: edge)); peer = host.workspace.activeBrowser
            try await wait { peer?.isLoading == false }; host.workspace.activate(browser)
            if scenario == "layout" || scenario == "group-preflight" {
                try require(host.workspace.browsers.count == 2 && peer?.location.directoryURL == area.appendingPathComponent("source/Destination"))
                checks.append("Actual generated two-pane layout settles before split admission, with a real local Destination and no connection")
                if groupControl {
                    checks += try await verifyGroupPreflight(root: area, engine: engine)
                    window.title = "SMB selected files · generated review"
                    try NativeMotionRecorder.validateScope(window: window, root: area, label: "smb-group-preflight")
                    checks.append("The exact generated window/recorder scope is admitted before any server or sign-in")
                    groupFacts = ["scenario": scenario, "selected": 2, "published": 0, "coldUndone": 0,
                        "stoppedAfterBytes": 0, "retainedBeforeDiscard": 0, "explicitlyDiscarded": 0, "encrypted": false]
                }
                stage = "finished"; throw PreflightComplete.done
            }
            stage = "connect"
            let secret = try await password()
            // Re-prepare after layout; local preparation/identity expires after30s.
            let liveEndpoint = try await SMBPreparedConnection.prepareValidated(address, bundleURL: Bundle.main.bundleURL, activity: ApplicationSMBActivity.gate)
            _ = endpoint
            let opened = try await SMBBrowserSession.connectPrepared(bundleURL: Bundle.main.bundleURL, request: request, endpoint: liveEndpoint,
                storage: catalogs, activity: ApplicationSMBActivity.gate, password: secret, selectedDownloads: true); session = opened
            let owner = SMBTabController(session: opened, share: address.share, title: "Generated Download", downloads: storage); tab = owner
            browser.installSMBTab(owner)
            try await wait {
                guard let snapshot = opened.latest.snapshot else { return false }
                // A server with following disabled may omit the generated link.
                return (7...8).contains(snapshot.count) && snapshot.state == .complete
                    && owner.rows.cache.retainedCount == snapshot.count && !owner.hasPendingPages && opened.latest.idle
            }
            try require(opened.latest.security == .encrypted && opened.allowsSelectedDownloads)
            if groupControl {
                stage = "selected-group"
                checks += try await verifyGroup(scenario: scenario, root: area, browser: browser, owner: owner,
                    window: window, storage: storage, catalogs: catalogs, profile: profile, journal: journal,
                    clips: &clips, facts: &groupFacts, credentialLookup: { credentials.record() })
            } else {
            func select(_ name: String) throws {
                guard let row = (0..<owner.rows.table.numberOfRows).first(where: { owner.rows.cache.entry(at: Int64($0))?.name.displayName == name }) else { throw Failure.scope }
                owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            try select("Nested"); try require(owner.selectedDownload == nil)
            try select("One.bin"); try require(owner.selectedDownload?.logicalBytes == 1 && browser.smbDownload.canRequest(from: owner, toPane: true))
            let occupied = area.appendingPathComponent("source/Destination/Existing.txt")
            browser.smbDownload.chooseForVerification = { _ in occupied }; browser.smbDownload.request(from: owner,toPane: false)
            try await wait { browser.operationPreparationTask == nil && browser.operationTask == nil }
            let unused = try await storage.inspect(); try require(unused.isEmpty && browser.smbDownload.bodyRequestsForQualification == 0)
            checks.append("Encrypted native rows bind one complete observation; folders and an occupied destination issue no body request")
            let selectedName = scenario == "stop" ? "Large.bin" : "One.bin"
            try select(selectedName); window.title = "SMB Download · generated review"
            if scenario == "stop" {
                let stopped = StopBarrier(); barrier = stopped; browser.smbDownload.didReceiveBytesForQualification = { stopped.observe($0) }
                browser.smbDownload.request(from: owner,toPane: true)
                try await wait { stopped.pending }; browser.cancelFileOperation(nil); stopped.release()
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                let pending = try await storage.inspect()
                try require(pending.count == 1 && !pending[0].active && pending[0].observedBytes > 0 && pending[0].observedBytes < 4 << 20
                    && browser.smbDownload.lastOutcome == nil && !FileManager().fileExists(atPath: area.appendingPathComponent("source/Destination/Large.bin").path))
                closed = await owner.close().value
                try require(closed?.actualExit == true && closed?.ownerReleased == true && closed?.forcedContainment == false)
                checks.append("Stop after an actual32KiB append cancels the native operation, publishes nothing and retains inactive partial staging through real helper exit")
                let vault = SMBPasswordVault.refusingQualification { credentials.record() }
                let coordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: catalogs,
                    servers: SMBSavedServerStore(directory: profile.appendingPathComponent("smb-servers")), passwords: vault, activity: ApplicationSMBActivity.gate)
                let storageWindow = SMBConnectionStorageWindow(settings: settings, coordinator: coordinator, storage: catalogs, downloads: storage)
                storageWindow.present(relativeTo: window); try await wait { !storageWindow.model.busy }
                try require(storageWindow.model.downloads.count == 1 && !storageWindow.model.downloads[0].active)
                storageWindow.model.discardDownload(pending[0].id); try await wait { !storageWindow.model.busy }
                try require(storageWindow.model.downloads.isEmpty); await storageWindow.closeAndDrain(); await coordinator.drain()
                checks.append("Connection Storage shows the exact inactive partial; explicit discard removes only it, with no credential lookup")
            } else {
                browser.smbDownload.request(from: owner,toPane: true)
                try await wait { browser.smbDownload.lastOutcome != nil && browser.operationTask == nil && browser.operationPreparationTask == nil }
                guard let outcome = browser.smbDownload.lastOutcome, let record = outcome.recordID else { throw Failure.scope }
                let destination = area.appendingPathComponent("source/Destination/One.bin")
                try require(outcome.result.disposition == .succeeded && browser.lastRecoveryRecordID == record)
                let exact = try await Task.detached { try Data(contentsOf: destination) == Data([0]) && destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil }.value
                try require(exact); let empty = try await storage.inspect(); try require(empty.isEmpty)
                browser.openOperationRecovery(recordID: record)
                try await wait { browser.recoveryWindow?.selectedRecordID == record && browser.recoveryRecords.contains { $0.id == record && $0.canUndo } }
                browser.recoveryWindow?.close()
                let cold = RecoverableFileOperations(journalDirectory: journal, protecting: [bodyRoot,catalogs.directory],
                    receivedDownloadPublicQuarantinePolicy: publicDownload ? .sourceQualification : .held)
                let undone = await cold.undo(recordID: record)
                try require(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: destination.path))
                checks.append("Download to Other Pane publishes exact quarantined bytes, selects exact Results and cold-Undoes after body staging removal")
                try select("Large.bin"); window.title = "SMB Download · generated review"
                let report = try await NativeMotionRecorder.record(window: window,root: area,label: "smb-download",sampling: .diagnostic(for: window)) { browser.smbDownload.request(from: owner,toPane: true) }
                try JSONEncoder().encode(report).write(to: area.appendingPathComponent("evidence/smb-download-motion.json"),options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip("smb-download",report: report,field: nil,window: window))
                try await wait { browser.operationTask == nil && browser.operationPreparationTask == nil }
                guard let large = browser.smbDownload.lastOutcome, let largeID = large.recordID, largeID != record else { throw Failure.scope }
                let target = area.appendingPathComponent("source/Destination/Large.bin")
                let correct = try await Task.detached {
                    let bytes = try Data(contentsOf: target); return bytes.count == 4 << 20 && bytes.enumerated().allSatisfy { $0.element == UInt8($0.offset % 251) }
                }.value
                try require(large.result.disposition == .succeeded && correct)
                let secondUndo = await cold.undo(recordID: largeID); try require(secondUndo.result.disposition == .succeeded)
                checks.append("A4MiB real native receive remains frame-recordable, verifies all bytes, publishes and cold-Undoes through the same engine")
            }
            }
            stage = "drain"; if closed == nil { closed = await owner.close().value }
            try require(closed?.actualExit == true && closed?.pipeDrained == true && closed?.ownerReleased == true && closed?.forcedContainment == false)
            let remaining = try await storage.inspect(), catalogsEmpty = try await SMBTemporaryCatalogPool(storage: catalogs).inspect().isEmpty
            try require(remaining.isEmpty && catalogsEmpty && ApplicationSMBActivity.gate.activeCount == 0 && credentials.value == 0)
            let counts = opened.commandCounts; try require(counts?.count == 19 && [7,9,10,11,15,17,18].allSatisfy { counts?[$0] == 0 })
            checks.append("Actual child/IPC/socket/catalog/body/activity owners drain and no remote mutation command is sent")
            stage = "finished"
        } catch PreflightComplete.done {} catch {
            if case let Failure.check(line) = error { failureLine = line } else { failureLine = 0 }
            failureType = String(reflecting: type(of: error)); errorCode = DiagnosticErrors.project(error).code
            if let motion = error as? NativeMotionRecorder.Failure { failureType = "NativeMotionRecorder." + motion.rawValue }
        }
        barrier?.release()
        if let tab { let value = await tab.close().value; if closed == nil { closed = value } }
        else if let session { let value = await session.close(); if closed == nil { closed = value } }
        retained?.browser.suspendBrowser(); retained?.window?.close(); retained = nil; SMBDownloadFeature.qualifying = false
        if let root {
            let pending = try? await bodies?.inspect(), catalogs = try? await metadata.map { SMBTemporaryCatalogPool(storage: $0) }?.inspect()
            let value: [String:Any] = ["passed":failureLine == nil,"stage":stage,"checks":checks,"failureLine":failureLine as Any? ?? NSNull(),
                "failureType":failureType as Any? ?? NSNull(),"failureCode":errorCode as Any? ?? NSNull(),"keychainCalls":credentials.value,
                "actualExit":closed?.actualExit as Any? ?? NSNull(),"pipeDrained":closed?.pipeDrained as Any? ?? NSNull(),
                "socketAndCatalogDrained":closed?.socketAndCatalogDrained as Any? ?? NSNull(),"contained":closed?.forcedContainment as Any? ?? NSNull(),
                "activityDrained":ApplicationSMBActivity.gate.activeCount == 0,"remainingBodies":pending?.count as Any? ?? NSNull(),
                "remainingCatalogs":catalogs?.count as Any? ?? NSNull(),"commandCounts":session?.commandCounts as Any? ?? NSNull(),"clips":clips,
                "groupFacts": groupFacts]
            try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/" + reportName),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
    private static func verifyMoveDestination(rows: SMBRemoteRowsView, parent: NSWindow,
        settings: BrowserSettings, root: URL, offscreen: Bool, clips: inout [[String: Any]]) async throws {
        guard let menu = rows.table.menu, let move = menu.items.first(where: { $0.title == "Move To…" }) else { throw Failure.scope }
        var callbacks = 0, allowed = false
        rows.onMove = { callbacks += 1 }; rows.fileActionsAllowed = { allowed }
        defer { rows.onMove = nil; rows.fileActionsAllowed = nil }
        try require(!move.isHidden && !rows.validateMenuItem(move))
        if let action = move.action { _ = NSApp.sendAction(action, to: move.target, from: move) }
        try require(callbacks == 0)
        allowed = true; menu.performActionForItem(at: menu.index(of: move))
        try require(callbacks == 1)
        rows.onMove = nil
        try require(move.isHidden && !rows.validateMenuItem(move))
        let folder = SMBDirectoryObservation(id: 1, name: try SMBRemoteName("Generated Project"), attributes: 0x10,
            logicalBytes: 0, modifiedFileTime: 1, objectID: 42, parentID: 7)
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 1, state: .complete)
        let directory = [try SMBRemoteName("Source")], connection = UUID()
        var current = true
        for percent in [100, 150] {
            settings.interfaceSize = .init(percent); InterfacePresentation.shared.bind(settings)
            let model = RemoteMoveDestinationModel(name: folder.name.displayName, isFolder: true, server: "Generated SMB share",
                currentFolder: "/Source", suggestions: [.init(title: "/Destination", path: "/Destination")]) { field in
                guard current, let value = try? SMBMoveDestination(field: field),
                      (try? SMBSelectedActionRequest(connection: connection, snapshot: snapshot,
                          directory: directory, observation: folder, moveTo: value.components)) != nil else { return "Choose another folder." }
                return nil
            }
            try require(!model.canMove)
            model.path = "/Source/Generated Project/Child"; try require(!model.canMove)
            model.path = "/Destination"; try require(model.canMove)
            current = false; try require(!model.canMove); current = true
            if offscreen { continue }
            let review = RemoteMoveDestination(model: model, settings: settings)
            guard let panel = review.window else { throw Failure.scope }
            panel.title = "Move To · generated review"
            parent.title = "SMB Move · generated review"
            parent.setContentSize(.init(width: percent == 150 ? 1060 : 900, height: percent == 150 ? 740 : 620))
            ToolWindowChrome.position(parent)
            parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let choosing = Task { await review.choose(in: parent) }
            defer { review.finish(nil) }
            try await wait { parent.attachedSheet === panel && panel.isVisible }
            panel.setContentSize(panel.contentMinSize)
            try await Task.sleep(for: .milliseconds(200))
            panel.contentView?.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
            try await UIVerification.snapshot(panel, to: root.appendingPathComponent("evidence/move-destination-\(percent)-view.png"))
            if CGPreflightScreenCaptureAccess() {
                try await GlassVerification.captureOwnedWindow(panel, to: root.appendingPathComponent("evidence/move-destination-\(percent).png"))
                if percent == 100 {
                    // macOS composites a native sheet into its parent. Reuse
                    // the upload review's parent-window capture route; a sheet
                    // filter alone scales the parent's pixels to sheet bounds.
                    let capture = try await NativeMotionRecorder.record(window: parent, root: root,
                        label: "smb-move-destination", sampling: .diagnostic(for: parent)) {
                            model.path = "/Source/Generated Project" // Invalid descendant; visible feedback only.
                        }
                    try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/smb-move-destination-motion.json"), options: .withoutOverwriting)
                    clips.append(DevelopmentMotionVerification.clip("smb-move-destination", report: capture, field: nil, window: parent))
                }
            }
            model.path = "/Destination"
            try await Task.sleep(for: .milliseconds(180))
            try require(SFTPFolderUploadPreviewVerification.pressMove(in: review, cancel: percent == 100))
            let choice = await choosing.value
            try require(percent == 100 ? choice == nil : choice == "/Destination")
            try require(parent.attachedSheet == nil)
        }
        let file = SMBDirectoryObservation(id: 2, name: try SMBRemoteName("Generated.txt"), attributes: 0x20,
            logicalBytes: 7, modifiedFileTime: 1, objectID: 43, parentID: 7)
        let fileSnapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 2, folders: 1, state: .complete)
        for percent in [100, 150] {
            settings.interfaceSize = .init(percent); InterfacePresentation.shared.bind(settings)
            let model = RemoteMoveDestinationModel(name: file.name.displayName, server: "Generated SMB share",
                currentFolder: "/Source", destinationNotice: "The original stays here. Existing items are kept.",
                operation: .copy, validateCopy: { field, name in
                    guard current, let destination = try? SMBMoveDestination(field: field),
                          (try? SMBSelectedActionRequest(connection: connection, snapshot: fileSnapshot,
                            directory: directory, observation: file, copyTo: destination.components, as: name)) != nil else {
                        return "Choose another name or folder."
                    }
                    return nil
                }, validate: { field in (try? SMBMoveDestination(field: field)) == nil ? "Choose a valid folder." : nil })
            try require(!model.canMove)
            model.path = "/Destination"; try require(model.canMove)
            model.destinationName = "../invalid"; try require(!model.canMove)
            model.destinationName = "Generated Copy.txt"; try require(model.canMove)
            current = false; try require(!model.canMove); current = true
            if offscreen { continue }
            let review = RemoteMoveDestination(model: model, settings: settings)
            guard let panel = review.window else { throw Failure.scope }
            parent.title = "SMB Copy · generated review"
            ToolWindowChrome.position(parent); parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let choosing = Task { await review.choose(in: parent) }
            defer { review.finish(nil) }
            try await wait { parent.attachedSheet === panel && panel.isVisible }
            panel.setContentSize(panel.contentMinSize)
            try await Task.sleep(for: .milliseconds(200))
            panel.contentView?.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
            try await UIVerification.snapshot(panel, to: root.appendingPathComponent("evidence/copy-destination-\(percent)-view.png"))
            if CGPreflightScreenCaptureAccess() {
                try await GlassVerification.captureOwnedWindow(panel, to: root.appendingPathComponent("evidence/copy-destination-\(percent).png"))
                if percent == 100 {
                    let capture = try await NativeMotionRecorder.record(window: parent, root: root,
                        label: "smb-copy-destination", sampling: .diagnostic(for: parent)) {
                            model.destinationName = "" // Visible validation; no request is submitted.
                        }
                    try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/smb-copy-destination-motion.json"), options: .withoutOverwriting)
                    clips.append(DevelopmentMotionVerification.clip("smb-copy-destination", report: capture, field: nil, window: parent))
                }
            }
            model.destinationName = "Generated Copy.txt"
            try await Task.sleep(for: .milliseconds(180))
            try require(SFTPFolderUploadPreviewVerification.pressMove(in: review, cancel: percent == 100))
            let choice = await choosing.value
            try require(percent == 100 ? choice == nil : choice == "/Destination" && model.destinationName == "Generated Copy.txt")
            try require(parent.attachedSheet == nil)
        }
    }
    private static func verifyGroupPreflight(root: URL, engine: RecoverableFileOperations) async throws -> [String] {
        let rows = SMBRemoteRowsView(frame: .init(x: 0, y: 0, width: 700, height: 300))
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 3, folders: 1, state: .complete)
        let observations = try [
            SMBDirectoryObservation(id: 1, name: .init("Nested"), attributes: 16, logicalBytes: 0, modifiedFileTime: 1),
            SMBDirectoryObservation(id: 2, name: .init("One.bin"), attributes: 32, logicalBytes: 1, modifiedFileTime: 1),
            SMBDirectoryObservation(id: 3, name: .init("Boundary.bin"), attributes: 32, logicalBytes: 32769, modifiedFileTime: 1)
        ]
        rows.downloadsAvailable = true; rows.observe(snapshot)
        try rows.accept(.init(request: .init(snapshot: snapshot, offset: 0), entries: observations))
        rows.table.selectRowIndexes(IndexSet(integersIn: 1..<3), byExtendingSelection: false)
        try require(rows.selectedDownloadBatch(connection: UUID())?.logicalBytes == 32770)
        rows.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        try require(rows.selectedDownloadBatch(connection: UUID()) == nil)
        let parent = root.appendingPathComponent("source/Destination")
        _ = try await engine.checkReceivedFileDestinations(parent: parent, names: ["One.bin", "Boundary.bin"])
        var refused = false
        do { _ = try await engine.checkReceivedFileDestinations(parent: parent, names: ["One.bin", "Existing.txt"]) }
        catch FileOperationFailure.conflict { refused = true }
        try require(refused && ApplicationSMBActivity.gate.activeCount == 0)
        return ["Current native SMB rows seal two selected files and refuse a folder mixture",
                "All local names preflight together; an occupied name refuses before a connection or body"]
    }

    private static func verifyGroup(scenario: String, root: URL, browser: BrowserViewController, owner: SMBTabController,
        window: NSWindow, storage: SMBDownloadStorage, catalogs: SMBTemporaryStorage, profile: URL, journal: URL,
        clips: inout [[String: Any]], facts: inout [String: Any], credentialLookup: @escaping @Sendable () -> Void) async throws -> [String] {
        let stopped = scenario == "group-stop", names = ["One.bin", stopped ? "Large.bin" : "Boundary.bin"]
        // Preserve One as the completed prefix before the second-body Stop.
        owner.rows.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        try await wait { owner.rows.lastPageDescending == true && !owner.hasPendingPages }
        var indexes = IndexSet()
        for name in names {
            guard let row = (0..<owner.rows.table.numberOfRows).first(where: { owner.rows.cache.entry(at: Int64($0))?.name.displayName == name }) else { throw Failure.scope }
            indexes.insert(row)
        }
        owner.rows.table.selectRowIndexes(indexes, byExtendingSelection: false)
        try require(owner.sealedBatchDownload?.items.map(\.localName) == names
            && browser.remoteBatchDownload.canRequest(from: owner, toPane: true))
        facts = ["scenario": scenario, "selected": 2, "published": 0, "coldUndone": 0,
            "stoppedAfterBytes": 0, "retainedBeforeDiscard": 0, "explicitlyDiscarded": 0, "encrypted": true]
        let parent = root.appendingPathComponent("source/Destination")
        window.title = "SMB selected files · generated review"
        if stopped {
            let barrier = StopBarrier(); defer { barrier.release(); browser.remoteBatchDownload.receiveProgressForVerification = nil }
            browser.remoteBatchDownload.receiveProgressForVerification = { if $0.completedFiles == 1 { barrier.observe($0.receivedBytes) } }
            browser.remoteBatchDownload.request(from: owner, toPane: true)
            try await wait { barrier.pending }
            browser.cancelFileOperation(nil); barrier.release()
            try await wait { browser.remoteBatchDownload.work == nil && browser.operationTask == nil && browser.operationPreparationTask == nil }
            let pending = try await storage.inspect()
            let lengths = try await groupPayloadLengths(pending, root: profile.appendingPathComponent("remote-downloads"))
            try require(pending.count == 2 && pending.allSatisfy { !$0.active }
                && pending.contains { $0.expectedBytes == 1 && lengths[$0.id] == 1 }
                && pending.contains { $0.expectedBytes == 4 << 20 && lengths[$0.id].map { $0 >= 32768 && $0 < 4 << 20 } == true })
            for name in names { try require(!FileManager().fileExists(atPath: parent.appendingPathComponent(name).path)) }
            try require(browser.operationHistory.downloadBatch?.completed == 0)
            facts["retainedBeforeDiscard"] = pending.count
            facts["stoppedAfterBytes"] = lengths.values.reduce(0, +)
            facts["retainedStorageBytes"] = pending.reduce(UInt64(0)) { $0 + $1.observedBytes }
            facts["explicitlyDiscarded"] = try await discardGroup(pending, settings: browser.settings, storage: storage,
                catalogs: catalogs, profile: profile, owner: window, credentialLookup: credentialLookup)
            return ["Stop during the second actual SMB body publishes no file, retains both inactive allocations and drains the helper",
                    "Connection Storage explicitly discards only the two generated inactive copies"]
        }
        let capture = try await NativeMotionRecorder.record(window: window, root: root, label: "smb-group-download", sampling: .diagnostic(for: window)) {
            browser.remoteBatchDownload.request(from: owner, toPane: true)
        }
        try JSONEncoder().encode(capture).write(to: root.appendingPathComponent("evidence/smb-group-download-motion.json"), options: .withoutOverwriting)
        clips.append(DevelopmentMotionVerification.clip("smb-group-download", report: capture, field: nil, window: window))
        try await wait { browser.remoteBatchDownload.work == nil && browser.operationTask == nil && browser.operationPreparationTask == nil }
        guard let batch = browser.operationHistory.downloadBatch else { throw Failure.scope }
        try require(batch.completed == 2 && batch.items.count == 2)
        facts["published"] = batch.completed
        let exact = try await Task.detached {
            try names.allSatisfy { name in
                let file = parent.appendingPathComponent(name), data = try Data(contentsOf: file)
                let expected = name == "One.bin" ? 1 : 32769
                let quarantine = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
                return data.count == expected && data.enumerated().allSatisfy { $0.element == UInt8($0.offset % 251) }
                    && quarantine != nil
            }
        }.value
        try require(exact); let empty = try await storage.inspect(); try require(empty.isEmpty)
        browser.showLastOperationResult(nil); try await wait { window.attachedSheet != nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        try await wait { window.attachedSheet == nil }
        let cold = RecoverableFileOperations(journalDirectory: journal, protecting: [profile.appendingPathComponent("remote-downloads"), catalogs.directory])
        for item in batch.items {
            guard let id = item.outcome?.recordID else { throw Failure.scope }
            let result = await cold.undo(recordID: id)
            try require(result.result.disposition == .succeeded && !FileManager().fileExists(atPath: item.destination.path))
        }
        facts["coldUndone"] = 2
        return ["One native group receives two actual encrypted SMB files, publishes exact quarantined bytes and drains body staging",
                "Shared Results opens the group; both distinct recorded local downloads cold-Undo independently"]
    }
    private static func groupPayloadLengths(_ items: [SMBDownloadStorageSummary], root: URL) async throws -> [UUID: UInt64] {
        try await Task.detached {
            var result: [UUID: UInt64] = [:]
            for item in items {
                let url = root.appendingPathComponent("download-" + item.id.uuidString).appendingPathComponent("payload")
                let value = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard value.isRegularFile == true, value.isSymbolicLink == false,
                      let bytes = value.fileSize, bytes >= 0, UInt64(bytes) <= item.expectedBytes else { throw Failure.scope }
                result[item.id] = UInt64(bytes)
            }
            return result
        }.value
    }
    private static func discardGroup(_ pending: [SMBDownloadStorageSummary], settings: BrowserSettings,
        storage: SMBDownloadStorage, catalogs: SMBTemporaryStorage, profile: URL, owner: NSWindow?,
        credentialLookup: @escaping @Sendable () -> Void) async throws -> Int {
        let vault = SMBPasswordVault.refusingQualification { credentialLookup() }
        let coordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: catalogs,
            servers: SMBSavedServerStore(directory: profile.appendingPathComponent("smb-servers")), passwords: vault,
            activity: ApplicationSMBActivity.gate)
        let review = SMBConnectionStorageWindow(settings: settings, coordinator: coordinator, storage: catalogs, downloads: storage)
        review.present(relativeTo: owner); try await wait { !review.model.busy }
        try require(Set(review.model.downloads.map(\.id)) == Set(pending.map(\.id)) && pending.allSatisfy { !$0.active })
        for item in pending { review.model.discardDownload(item.id); try await wait { !review.model.busy } }
        try require(review.model.downloads.isEmpty); await review.closeAndDrain(); await coordinator.drain()
        return pending.count
    }
    private enum PreflightComplete: Error { case done }
}
#endif
