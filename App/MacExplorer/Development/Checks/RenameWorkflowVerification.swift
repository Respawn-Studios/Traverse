#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import ExplorerCore
import FileOperations
import Darwin

/// Real native inline field/editor, recoverable engine and refreshed rows.
/// Every input and durable journal belongs to this generated fixture job.
@MainActor
enum RenameWorkflowVerification {
    static func run(in testRoot: URL, output: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Rename verification requires its unredirected generated fixture root")
        }
        let owned = testRoot.appendingPathComponent("rename-workflow-\(UUID().uuidString)", isDirectory: true)
        let cases: [(String, String, Int, Bool)] = [
            ("Report.txt", "Renamed", 0, false), ("Résumé 🪐.pdf", "Unicode", 0, false),
            ("archive.tar.gz", "Archive", 0, false), ("README", "Readme-renamed", 0, false),
            (".gitignore", "Dotfile", 0, false), ("Folder.with.dots", "Folder", 0, true),
            ("Payload.bin", "Payload-renamed", 32 * 1024 * 1024, false),
            ("Large.folder", "Large-renamed", 32 * 1024 * 1024, true),
        ]
        let modes = BrowserViewMode.allCases
        let spellingCases: [(String, String, Bool)] = [
            ("Case-only.txt", "case-only.txt", false), ("Case-only-folder", "case-only-folder", true),
            ("É-spelling.txt", "E\u{301}-spelling.txt", false),
        ]
        try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-inline-rename-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            for mode in modes {
                let listing = owned.appendingPathComponent(mode.rawValue, isDirectory: true)
                try manager.createDirectory(at: listing, withIntermediateDirectories: false)
                for name in ["New Folder", "New Folder 2"] {
                    try manager.createDirectory(at: listing.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
                }
                for (name, _, count, directory) in cases {
                    let url = listing.appendingPathComponent(name, isDirectory: directory)
                    if directory {
                        try manager.createDirectory(at: url, withIntermediateDirectories: false)
                        if count > 0 { try Data(repeating: 0x51, count: count).write(to: url.appendingPathComponent("generated.bin"), options: .withoutOverwriting) }
                    } else { try Data(repeating: 0x51, count: count).write(to: url, options: .withoutOverwriting) }
                }
                for (name, _, directory) in spellingCases {
                    if directory {
                        let folder = listing.appendingPathComponent(name, isDirectory: true)
                        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                        try Data("original child".utf8).write(to: folder.appendingPathComponent("original-child"), options: .withoutOverwriting)
                    } else { try createRawSpellingFile(in: listing, name: name) }
                }
            }
        }.value
        let settings = BrowserSettings(persist: false)
        settings.showsHiddenFiles = true
        settings.autoRefreshFolders = false
        settings.showsDockProgress = false
        settings.reviewsRecoveryAtStartup = false
        let browser = BrowserViewController(settings: settings)
        browser.permitsBackgroundVerification = true
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        let engine = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        browser.recoverableFileOperations = engine
        let tab = BrowserTab(location: .directory(owned.appendingPathComponent("Details", isDirectory: true)))
        browser.tabs = [tab]; browser.activeID = tab.id
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1080, height: 700))
        let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
        if !offscreen {
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
        var errors: [String] = []
        var resultTime: TimeInterval?
        var observingRefresh = false, refreshStayedVisible = false
        browser.operationResultPresenter = { _ in
            resultTime = ProcessInfo.processInfo.systemUptime
            if observingRefresh { refreshStayedVisible = browser.isBackgroundRefreshing && !browser.displayedEntries.isEmpty }
        }
        browser.operationErrorPresenter = { errors.append($0) }
        defer {
            browser.inlineRename.cancel()
            browser.operationPreparationTask?.cancel(); browser.operationTask?.cancel()
            browser.suspendBrowser()
            window.close()
        }
        do {
            browser.loadLocation()
            try await UIVerification.settled(browser)
            var samples: [[String: Any]] = []
            var spellingSamples: [[String: Any]] = []
            var failures: [String] = []
            func select(_ source: URL) {
                browser.renderFilePresentation(selection: [source]); browser.fileSelectionDidChange()
                window.makeFirstResponder(browser.activeFileView)
            }
            func editing(_ source: URL) async throws -> NSTextView {
                select(source)
                browser.renameSelection(nil)
                try await waitUntil("Inline filename editor") { browser.inlineRename.field?.currentEditor() is NSTextView }
                guard let editor = browser.inlineRename.field?.currentEditor() as? NSTextView else {
                    throw UIVerification.Failure(message: "Inline rename has no native field editor")
                }
                try UIVerification.require(window.attachedSheet == nil && (!offscreen || !window.isVisible), "Inline rename opened a sheet or exposed a controlled window")
                return editor
            }
            func key(_ code: UInt16, text: String, to editor: NSTextView) {
                editor.keyDown(with: UIVerification.key(text, code: code, flags: [], window: window))
            }
            func undoFolderAction(_ record: UUID) async throws {
                browser.inspectOperationRecovery()
                try await waitUntil("New Folder action available for Undo") {
                    browser.canUndoFileOperation && browser.recoveryRecords.first(where: \.canUndo)?.id == record
                }
                browser.undoFileOperation(nil)
                try await waitUntil("New Folder Undo and refreshed listing") {
                    browser.operationTask == nil && browser.operationPreparationTask == nil
                        && !browser.isLoading && browser.orderingTask == nil
                        && browser.recoveryRecords.first(where: { $0.id == record })?.state == "undone"
                }
            }
            func requireRecord(_ record: UUID?) throws -> UUID {
                guard let record else { throw UIVerification.Failure(message: "New Folder operation history missing") }
                return record
            }
            for mode in modes {
                let listing = owned.appendingPathComponent(mode.rawValue, isDirectory: true)
                browser.setPaneViewMode(mode)
                browser.navigate(to: .directory(listing))
                try await waitUntil("Inline rename presentation mode") { browser.presentedFileViewMode == mode && !browser.isLoading && browser.orderingTask == nil }
                let automaticFolder = listing.appendingPathComponent("New Folder 3", isDirectory: true)
                window.makeFirstResponder(browser.activeFileView)
                observingRefresh = true; refreshStayedVisible = false
                browser.createFolder(nil)
                try await waitUntil("New Folder selects, reveals and edits its numbered destination") {
                    browser.inlineRename.field?.currentEditor() is NSTextView
                }
                guard let createEditor = browser.inlineRename.field?.currentEditor() as? NSTextView,
                      let createRecord = browser.lastRecoveryRecordID else {
                    throw UIVerification.Failure(message: "Immediate New Folder did not reach its ordinary editor/history")
                }
                observingRefresh = false
                try UIVerification.require(refreshStayedVisible, "New Folder cleared the current rows before its replacement listing")
                try UIVerification.require(createEditor.string == "New Folder 3"
                    && browser.selectedURLs.first?.path == automaticFolder.path && browser.selectedURLs.count == 1
                    && createEditor.selectedRange() == NSRange(location: 0, length: createEditor.string.utf16.count)
                    && window.attachedSheet == nil, "Immediate New Folder lost numbering, selection or full-name editing")
                createEditor.insertText("Created and Renamed", replacementRange: createEditor.selectedRange())
                observingRefresh = true; refreshStayedVisible = false
                key(36, text: "\r", to: createEditor)
                let renamedFolder = listing.appendingPathComponent("Created and Renamed", isDirectory: true)
                try await waitUntil("New Folder Rename and visible result") {
                    browser.operationTask == nil && browser.operationPreparationTask == nil && browser.inlineRename.field == nil
                        && !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL.keys.contains { $0.path == renamedFolder.path }
                }
                observingRefresh = false
                try UIVerification.require(refreshStayedVisible, "Rename cleared the current rows before its replacement listing")
                let renameRecord = try requireRecord(browser.lastRecoveryRecordID)
                try UIVerification.require(renameRecord != createRecord && browser.lastOperationResult?.disposition == .succeeded,
                    "Create and Rename did not retain their independent guarded history")
                try await undoFolderAction(renameRecord)
                try UIVerification.require(browser.displayedEntries.contains { $0.url.path == automaticFolder.path }, "Rename Undo lost the automatically created folder")
                try await undoFolderAction(createRecord)
                try UIVerification.require(!browser.displayedEntries.contains { $0.url.path == automaticFolder.path }, "Creation Undo did not remove its unchanged folder")

                window.makeFirstResponder(browser.activeFileView)
                browser.createFolder(nil)
                try await waitUntil("New Folder Escape editor") { browser.inlineRename.field?.currentEditor() is NSTextView }
                guard let escapeEditor = browser.inlineRename.field?.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "New Folder Escape editor absent") }
                let escapeRecord = try requireRecord(browser.lastRecoveryRecordID)
                key(53, text: "\u{1b}", to: escapeEditor)
                try await waitUntil("New Folder Escape leaves creation intact") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                try UIVerification.require(browser.displayedEntries.contains { $0.url.path == automaticFolder.path }
                    && browser.lastRecoveryRecordID == escapeRecord, "Escape removed the created folder or added another operation")
                try await undoFolderAction(escapeRecord)

                window.makeFirstResponder(browser.activeFileView)
                browser.createFolder(nil)
                try await waitUntil("New Folder occupied-name editor") { browser.inlineRename.field?.currentEditor() is NSTextView }
                guard let occupiedEditor = browser.inlineRename.field?.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "New Folder conflict editor absent") }
                let conflictCreation = try requireRecord(browser.lastRecoveryRecordID)
                occupiedEditor.insertText("New Folder", replacementRange: occupiedEditor.selectedRange())
                resultTime = nil
                key(36, text: "\r", to: occupiedEditor)
                try await waitUntil("New Folder rename refuses existing directory") {
                    resultTime != nil && browser.operationTask == nil && browser.operationPreparationTask == nil
                        && !browser.isLoading && browser.orderingTask == nil
                }
                try UIVerification.require(browser.lastOperationResult?.items.first?.status == .failed(.conflict)
                    && browser.displayedEntries.contains { $0.name == "New Folder" }
                    && browser.displayedEntries.contains { $0.name == "New Folder 2" }
                    && browser.displayedEntries.contains { $0.name == "New Folder 3" }, "New Folder conflict replaced or merged an existing item")
                try await undoFolderAction(conflictCreation)
                if !offscreen && mode == .details {
                    let source = listing.appendingPathComponent("Report.txt")
                    select(source)
                    guard let anchor = browser.inlineFilenameAnchor(for: source) else { throw UIVerification.Failure(message: "Selected-name click anchor missing") }
                    let point = anchor.view.convert(NSPoint(x: anchor.rect.minX + 8, y: anchor.rect.midY), to: nil)
                    guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                          let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { throw UIVerification.Failure(message: "Selected-name click input unavailable") }
                    NSApp.postEvent(up, atStart: true)
                    browser.table.mouseDown(with: down)
                    try await waitUntil("Selected-name click opens the ordinary Rename field") { browser.inlineRename.field?.currentEditor() is NSTextView }
                    browser.inlineRename.cancel()
                    try await waitUntil("Selected-name Rename cancellation drains") { browser.operationPreparationTask == nil }
                    settings.renamesSelectedNameOnClick = false
                    NSApp.postEvent(up, atStart: true); browser.table.mouseDown(with: down)
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
                    try UIVerification.require(browser.inlineRename.field == nil && browser.operationPreparationTask == nil,
                        "Selected-name click ignored the preference")
                    settings.renamesSelectedNameOnClick = true
                    NSApp.postEvent(up, atStart: true); browser.table.mouseDown(with: down)
                    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
                    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.2))
                    try UIVerification.require(browser.inlineRename.field == nil && browser.operationPreparationTask == nil,
                        "A pending selected-name Rename interrupted menu tracking")
                }
                for (name, replacement, bytes, directory) in cases {
                    let source = listing.appendingPathComponent(name)
                    select(source)
                    guard let anchor = browser.inlineFilenameAnchor(for: source) else { throw UIVerification.Failure(message: "Actual filename label is unavailable") }
                    let started = ProcessInfo.processInfo.systemUptime
                    browser.renameSelection(nil)
                    try await waitUntil("Native inline rename editor") { browser.inlineRename.field?.currentEditor() is NSTextView }
                    guard let field = browser.inlineRename.field, let editor = field.currentEditor() as? NSTextView else {
                        throw UIVerification.Failure(message: "Inline rename did not create a native field editor")
                    }
                    let appeared = ProcessInfo.processInfo.systemUptime
                    try UIVerification.require(field.superview === anchor.view && abs(field.frame.minX - anchor.rect.minX) < 1
                        && window.attachedSheet == nil && (!offscreen || !window.isVisible), "Inline editor missed the actual filename or exposed a controlled window")
                    let range = editor.selectedRange(), prefilled = editor.string
                    let expectedRange: NSRange
                    if !directory, let dot = prefilled.lastIndex(of: "."), dot != prefilled.startIndex, prefilled.index(after: dot) != prefilled.endIndex {
                        expectedRange = NSRange(prefilled.startIndex..<dot, in: prefilled)
                    } else { expectedRange = NSRange(location: 0, length: prefilled.utf16.count) }
                    if prefilled != name { failures.append("\(mode.rawValue)/\(name): full name missing") }
                    if range != expectedRange { failures.append("\(mode.rawValue)/\(name): selection \(range) should be \(expectedRange)") }
                    if name == "Report.txt" { try await UIVerification.snapshot(window, to: output.appendingPathComponent("inline-rename-\(mode.rawValue).png")) }
                    editor.insertText(replacement, replacementRange: range)
                    let entered = editor.string
                    let expectedName = replacement + (prefilled as NSString).substring(from: NSMaxRange(expectedRange))
                    let confirmed = ProcessInfo.processInfo.systemUptime
                    resultTime = nil
                    key(36, text: "\r", to: editor)
                    let retired = ProcessInfo.processInfo.systemUptime
                    try UIVerification.require(field.superview == nil && !anchor.label.isHidden, "Inline retirement left the actual filename hidden")
                    try await waitUntil("Recoverable inline rename and visible rows") {
                        browser.inlineRename.field == nil && browser.operationPreparationTask == nil && browser.operationTask == nil
                            && !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[listing.appendingPathComponent(entered)] != nil
                    }
                    let visible = ProcessInfo.processInfo.systemUptime
                    if entered != expectedName { failures.append("\(mode.rawValue)/\(name): stem typing lost extension") }
                    try UIVerification.require(browser.lastOperationResult?.disposition == .succeeded && errors.isEmpty, "Inline rename failed")
                    let preserved = try await Task.detached {
                        let destination = listing.appendingPathComponent(entered, isDirectory: directory)
                        let payload = directory ? destination.appendingPathComponent("generated.bin") : destination
                        guard !FileManager().fileExists(atPath: source.path) else { return false }
                        if bytes == 0 && directory { return true }
                        return try Data(contentsOf: payload) == Data(repeating: 0x51, count: bytes)
                    }.value
                    try UIVerification.require(preserved, "Inline rename changed generated payload")
                    samples.append(["mode": mode.rawValue, "name": name, "payloadBytes": bytes, "directory": directory,
                        "selectionLocation": range.location, "selectionLength": range.length, "fullNamePrefilled": prefilled == name,
                        "enteredName": entered, "expectedName": expectedName, "commandToEditorMilliseconds": (appeared - started) * 1000,
                        "confirmToEditorRetiredMilliseconds": (retired - confirmed) * 1000,
                        "confirmToVisibleMilliseconds": (visible - confirmed) * 1000,
                        "confirmToResultMilliseconds": ((resultTime ?? visible) - confirmed) * 1000,
                        "resultToVisibleMilliseconds": (visible - (resultTime ?? visible)) * 1000,
                        "recoverableRecord": browser.lastRecoveryRecordID?.uuidString ?? "missing"])
                }
                for (name, replacement, directory) in spellingCases {
                    let source = listing.appendingPathComponent(name), destination = listing.appendingPathComponent(replacement)
                    let originalBytes = try await Task.detached { try storedNameBytes(in: listing, lookup: name) }.value
                    try UIVerification.require(originalBytes == Data(name.utf8), "Spelling fixture did not retain its requested native name")
                    let editor = try await editing(source)
                    let prefilledBytes = Data(editor.string.utf8)
                    let expectedTab = browser.activeID, expectedVisit = browser.sessionID, expectedPresentation = browser.filePresentationID
                    let diagnostic: () -> String = {
                        "case=\(mode.rawValue)/\(name); originalUTF8=\(Array(originalBytes)); prefilledUTF8=\(Array(prefilledBytes)); requestedUTF8=\(Array(replacement.utf8)); urlNameUTF8=\(Array(source.lastPathComponent.utf8)); "
                        + "resultReceived=\(resultTime != nil); result=\(String(describing: browser.lastOperationResult?.items.map(\.status))); errors=\(errors); record=\(String(describing: browser.lastRecoveryRecordID)); "
                        + "activeOwner=\(String(describing: browser.operationCoordinator.activeOwner)); preparationOwner=\(String(describing: browser.operationCoordinator.preparationOwner)); activePane=\(browser.isActiveCommandPane); suspended=\(browser.isBrowserSuspended); "
                        + "tab=\(browser.activeID)/expected=\(expectedTab); visit=\(browser.sessionID)/expected=\(expectedVisit); presentation=\(browser.filePresentationID)/expected=\(expectedPresentation); "
                        + "inlineField=\(browser.inlineRename.field != nil); pending=\(browser.hasPendingFileOperation); loading=\(browser.isLoading); ordering=\(browser.orderingTask != nil); targetRow=\(String(describing: browser.rowsByURL[destination])); rowsUTF8=\(browser.displayedEntries.map { Array($0.name.utf8) })"
                    }
                    try UIVerification.require(prefilledBytes == originalBytes, "Editor did not prefill actual stored spelling: \(diagnostic())")
                    editor.selectAll(nil); editor.insertText(replacement, replacementRange: editor.selectedRange())
                    try UIVerification.require(Data(editor.string.utf8) == Data(replacement.utf8), "Native editor normalized the requested spelling: \(diagnostic())")
                    resultTime = nil
                    key(36, text: "\r", to: editor)
                    try await waitUntil("\(mode.rawValue)/\(name) → \(replacement): spelling-only Rename and refreshed rows", diagnostics: diagnostic) {
                        resultTime != nil && browser.inlineRename.field == nil && !browser.hasPendingFileOperation
                            && !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[destination] != nil
                    }
                    guard let id = browser.lastRecoveryRecordID else { throw UIVerification.Failure(message: "Spelling change did not create Undo history") }
                    try UIVerification.require(browser.lastOperationResult?.disposition == .succeeded && errors.isEmpty, "Spelling-only inline Rename failed")
                    let renamedBytes = try await Task.detached { try storedNameBytes(in: listing, lookup: name) }.value
                    try UIVerification.require(renamedBytes == Data(replacement.utf8), "Inline Rename did not publish exact stored spelling")
                    if name.hasPrefix("Case-only") {
                        try UIVerification.require(browser.displayedEntries.contains { Data($0.name.utf8) == Data(replacement.utf8) }, "Refreshed view retained old filename case")
                    }
                    let edited = Data("generated edit after inline Rename".utf8)
                    try await Task.detached {
                        if directory {
                            try edited.write(to: destination.appendingPathComponent("added-after-rename"), options: .withoutOverwriting)
                        } else {
                            let handle = try FileHandle(forWritingTo: destination)
                            try handle.truncate(atOffset: 0); try handle.write(contentsOf: edited); try handle.close()
                        }
                    }.value
                    await browser.recoveryInspectionTask?.value
                    browser.focusBrowserContent()
                    try await waitUntil("\(mode.rawValue)/\(name): name-only Undo capability for the latest Rename", diagnostics: diagnostic) {
                        browser.canUndoFileOperation && browser.recoveryRecords.first(where: \.canUndo)?.id == id
                    }
                    resultTime = nil
                    browser.undoFileOperation(nil)
                    try await waitUntil("\(mode.rawValue)/\(name): native name-only Undo and refreshed rows", diagnostics: diagnostic) {
                        resultTime != nil && !browser.hasPendingFileOperation && !browser.isLoading
                            && browser.orderingTask == nil && browser.rowsByURL[source] != nil
                    }
                    await browser.recoveryInspectionTask?.value
                    let restored = try await Task.detached {
                        let actual = try storedNameBytes(in: listing, lookup: name)
                        let kept = directory ? source.appendingPathComponent("added-after-rename") : source
                        let originalChildKept = !directory || FileManager().fileExists(atPath: source.appendingPathComponent("original-child").path)
                        let contents = try Data(contentsOf: kept)
                        return actual == originalBytes && originalChildKept && contents == edited
                    }.value
                    try UIVerification.require(restored && browser.lastOperationResult?.disposition == .succeeded && errors.isEmpty
                        && browser.recoveryRecords.first(where: { $0.id == id })?.state == "undone", "Native Undo lost current contents or original stored spelling")
                    if name.hasPrefix("Case-only") {
                        try UIVerification.require(browser.displayedEntries.contains { Data($0.name.utf8) == originalBytes }, "Undo left old case in the refreshed view")
                    }
                    spellingSamples.append(["mode": mode.rawValue, "originalUTF8": Array(originalBytes), "renamedUTF8": Array(renamedBytes),
                        "prefilledUTF8": Array(prefilledBytes), "commandURLNameUTF8": Array(source.lastPathComponent.utf8),
                        "directory": directory, "recordID": id.uuidString, "undoKeptEdits": true, "restoredExactSpelling": true])
                }
                let source = listing.appendingPathComponent("Renamed.txt")
                let baselineRecords = try await engine.recoveryRecords().records.count
                select(source)
                let revoked = browser.inlineRename.reserve(source: source)
                browser.setFileSelection([listing.appendingPathComponent("Readme-renamed")]); browser.fileSelectionDidChange()
                browser.setFileSelection([source]); browser.fileSelectionDidChange()
                var late: String?
                var lateAnswered = false, lateOpened = false
                let lateTask = Task { @MainActor in
                    late = await browser.inlineRename.begin(source: source, name: "Renamed.txt", ordinaryFile: true, requestID: revoked)
                    lateAnswered = true
                }
                let lateDeadline = ProcessInfo.processInfo.systemUptime + 8
                while !lateAnswered && !lateOpened && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < lateDeadline {
                    lateOpened = browser.inlineRename.field != nil
                    if !lateOpened { try? await Task.sleep(for: .milliseconds(5)) }
                }
                lateOpened = lateOpened || browser.inlineRename.field != nil
                // Capture the verdict before cancellation: draining an erroneously
                // admitted editor must never turn its nil cancellation into a pass.
                let revokedPassed = lateAnswered && late == nil && !lateOpened
                let revokedFacts = "answered=\(lateAnswered); openedField=\(lateOpened); returnedName=\(late != nil); deadlineReached=\(ProcessInfo.processInfo.systemUptime >= lateDeadline)"
                if !revokedPassed {
                    lateTask.cancel()
                    browser.inlineRename.cancel(requestID: revoked)
                }
                await lateTask.value
                try UIVerification.require(revokedPassed,
                    "An away-and-back selection resurrected preflight rename authority: \(revokedFacts)")
                let escape = try await editing(source)
                escape.insertText("Cancelled", replacementRange: escape.selectedRange())
                key(53, text: "\u{1b}", to: escape)
                try await waitUntil("Escape retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                _ = try await editing(source)
                if offscreen {
                    // Address editing deliberately requires a visible window. The
                    // controlled check uses the ordinary inline filter focus route;
                    // it does not claim that hidden address editing was exercised.
                    try UIVerification.require(!browser.folderFilter.isCompact, "Controlled focus check requires the inline filter")
                    browser.focusFilter(nil)
                    try await waitUntil("Filter focus retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                    try UIVerification.require(browser.folderFilter.displayedField.currentEditor() != nil, "Rename cancellation stole filter focus")
                } else {
                    browser.focusLocation(nil)
                    try await waitUntil("Address focus retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                    try UIVerification.require(browser.pathField.currentEditor() != nil, "Rename cancellation stole address focus")
                }
                window.makeFirstResponder(browser.activeFileView)
                _ = try await editing(source)
                browser.setFileSelection([listing.appendingPathComponent("Readme-renamed")]); browser.fileSelectionDidChange()
                try await waitUntil("Changed selection retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                _ = try await editing(source)
                browser.navigate(to: .directory(owned))
                try await waitUntil("Navigation retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil && !browser.isLoading && browser.orderingTask == nil }
                browser.navigate(to: .directory(listing)); try await UIVerification.settled(browser)
                _ = try await editing(source)
                browser.newTab(nil)
                try await waitUntil("New tab retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil && !browser.isLoading && browser.orderingTask == nil }
                try UIVerification.require(browser.tabs.count == 2, "Inline text editing unnecessarily blocked New Tab")
                browser.selectTab(tab.id); try await UIVerification.settled(browser)
                browser.tabs = [browser.tabs[browser.activeIndex]]
                _ = try await editing(source)
                browser.metadataSearch.show()
                try await waitUntil("Search retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                browser.metadataSearch.cancel(); window.makeFirstResponder(browser.activeFileView)
                _ = try await editing(source)
                browser.suspendBrowser()
                try await waitUntil("Suspension retires rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
                browser.resumeBrowser(); try await UIVerification.settled(browser)
                let afterRecords = try await engine.recoveryRecords().records.count
                let exists = await Task.detached { FileManager().fileExists(atPath: source.path) }.value
                try UIVerification.require(exists && afterRecords == baselineRecords && errors.isEmpty, "Cancelled or retired inline editing changed files/journal")
                let editable = try await editing(source)
                editable.selectAll(nil); editable.insertText("Changed.data", replacementRange: editable.selectedRange())
                key(36, text: "\r", to: editable)
                try await waitUntil("Explicit extension edit") { browser.operationPreparationTask == nil && browser.operationTask == nil && !browser.isLoading && browser.orderingTask == nil && browser.rowsByURL[listing.appendingPathComponent("Changed.data")] != nil }
                try UIVerification.require(browser.lastOperationResult?.disposition == .succeeded && errors.isEmpty, "Filename extension was not editable")
                let changed = listing.appendingPathComponent("Changed.data")
                let conflict = listing.appendingPathComponent("Conflict-existing.txt")
                let conflictBytes = Data("generated destination stays intact".utf8)
                try await Task.detached { try conflictBytes.write(to: conflict, options: .withoutOverwriting) }.value
                let beforeRefusals = try await engine.recoveryRecords().records.count
                let conflictEditor = try await editing(changed)
                conflictEditor.selectAll(nil); conflictEditor.insertText(conflict.lastPathComponent, replacementRange: conflictEditor.selectedRange())
                resultTime = nil
                key(36, text: "\r", to: conflictEditor)
                try await waitUntil("Existing destination refuses inline rename") {
                    (resultTime != nil || !errors.isEmpty) && browser.operationPreparationTask == nil && browser.operationTask == nil
                        && !browser.isLoading && browser.orderingTask == nil
                }
                try UIVerification.require(errors.isEmpty && browser.lastOperationResult?.items.first?.status == .failed(.conflict), "Existing destination did not produce a guarded conflict refusal")
                let conflictPreserved = try await Task.detached {
                    try Data(contentsOf: conflict) == conflictBytes && Data(contentsOf: changed).isEmpty
                }.value
                try UIVerification.require(conflictPreserved, "Inline rename overwrote an existing destination")
                errors.removeAll()
                let replacementEditor = try await editing(changed)
                let backup = listing.appendingPathComponent("Changed-original-backup.data")
                let replacementBytes = Data("generated replacement must not inherit rename consent".utf8)
                try await Task.detached {
                    try FileManager().moveItem(at: changed, to: backup)
                    try replacementBytes.write(to: changed, options: .withoutOverwriting)
                }.value
                let refusedName = "Refused-replacement.data"
                replacementEditor.selectAll(nil); replacementEditor.insertText(refusedName, replacementRange: replacementEditor.selectedRange())
                resultTime = nil
                key(36, text: "\r", to: replacementEditor)
                try await waitUntil("Replaced source refuses inline rename") {
                    (resultTime != nil || !errors.isEmpty) && browser.operationPreparationTask == nil && browser.operationTask == nil
                        && !browser.isLoading && browser.orderingTask == nil
                }
                try UIVerification.require(errors.isEmpty && browser.lastOperationResult?.items.first?.status == .failed(.sourceChanged), "Replacement did not produce a guarded source-change refusal")
                let replacementPreserved = try await Task.detached {
                    try Data(contentsOf: backup).isEmpty && Data(contentsOf: changed) == replacementBytes
                        && !FileManager().fileExists(atPath: listing.appendingPathComponent(refusedName).path)
                }.value
                let afterRefusals = try await engine.recoveryRecords().records.count
                try UIVerification.require(replacementPreserved && beforeRefusals == afterRefusals,
                                           "Replacement occupant inherited inline rename consent or refusal wrote journal history")
                errors.removeAll()
            }
            let closingSource = owned.appendingPathComponent("Icons/Changed.data")
            let beforeClose = try await engine.recoveryRecords().records.count
            let closing = try await editing(closingSource)
            closing.insertText("Uncommitted", replacementRange: closing.selectedRange())
            window.close()
            try await waitUntil("Window close retires inline rename") { browser.inlineRename.field == nil && browser.operationPreparationTask == nil }
            let afterClose = try await engine.recoveryRecords().records.count
            let closePreserved = await Task.detached { FileManager().fileExists(atPath: closingSource.path) }.value
            try UIVerification.require(closePreserved && beforeClose == afterClose, "Window close submitted an unconfirmed rename")
            let data = try JSONSerialization.data(withJSONObject: ["passed": failures.isEmpty, "mode": offscreen ? "controlled-inline" : "foreground-inline",
                "samples": samples, "spellingAndUndoSamples": spellingSamples, "failures": failures,
                "notExercised": offscreen ? ["Address-field focus requiring a visible window", "Physical keyboard/pointer delivery"] : ["Physical keyboard/pointer delivery"],
                "additionalChecks": ["Immediate numbered New Folder and inline Rename in every view", "Separate Rename and Creation Undo", "New Folder Escape keeps creation", "New Folder occupied-name refusal", "Revoked preflight reservation", "Escape", offscreen ? "Inline filter focus" : "Address focus", "Changed selection", "Navigation", "New Tab", "Search", "Suspension", "Window close", "Editable extension", "Existing destination preserved", "Replaced source refused with original backup and replacement intact", "Case-only file and folder Rename in every view", "Raw Unicode normalization-only Rename in every view", "Native Undo keeps file edits and current folder children"]], options: [.prettyPrinted, .sortedKeys])
            try await Task.detached { try data.write(to: output.appendingPathComponent("rename-workflow.json"), options: .withoutOverwriting) }.value
            try UIVerification.require(failures.isEmpty, failures.joined(separator: "; "))
            return ["Details/List/Icons inline rename uses actual filename frames, full editable names, UTF16 stem selection and native Return/Escape with the qualified name-only protocol (legacy strict fallback remains separate)",
                    "Immediate New Folder numbers occupied names, selects/reveals the current directory row and offers ordinary Rename; Escape retains creation, both Undos work separately and existing folders never merge",
                    "All 24 generated name/payload cases plus extension changes passed; focus/selection/navigation/tab/search/suspension cancellation made no file/journal changes",
                    "All 9 case-only/Unicode file and folder workflows preserve exact native spelling; native Undo restores names and keeps subsequent file edits/current children"]
        } catch {
            // This workflow owns a separate browser. Drain its cancelled
            // native text preparation before the outer check requests Quit.
            let preparation = browser.operationPreparationTask, operation = browser.operationTask
            browser.inlineRename.cancel(); preparation?.cancel(); operation?.cancel()
            await preparation?.value; await operation?.value
            throw error
        }
    }

    nonisolated private static func createRawSpellingFile(in parent: URL, name: String) throws {
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw UIVerification.Failure(message: "Cannot open generated spelling fixture") }
        defer { close(directory) }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UIVerification.Failure(message: "Cannot create generated spelling fixture") }
        defer { close(fd) }
        let bytes = Data("generated spelling fixture".utf8)
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
            throw UIVerification.Failure(message: "Cannot write generated spelling fixture")
        }
    }

    /// Observe the real entry spelling, independent of URL/String canonical equality.
    nonisolated private static func storedNameBytes(in parent: URL, lookup: String) throws -> Data {
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw UIVerification.Failure(message: "Cannot inspect generated spelling fixture") }
        defer { close(directory) }
        var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)
        var bytes = Data(count: 4096)
        let result = bytes.withUnsafeMutableBytes { getattrlistat(directory, lookup, &attributes, $0.baseAddress!, $0.count,
            UInt(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_REPORT_FULLSIZE)) }
        func u32(_ offset: Int) -> UInt32 { bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        guard result == 0, u32(0) >= 32, Int(u32(0)) <= bytes.count, u32(4) & attributes.commonattr == attributes.commonattr else {
            throw UIVerification.Failure(message: "Stored name attributes unavailable")
        }
        let offset = 24 + Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int32.self) })
        let count = Int(u32(28)), size = Int(u32(0))
        guard offset >= 32, count > 1, offset <= size, count <= size - offset, bytes[offset + count - 1] == 0 else {
            throw UIVerification.Failure(message: "Stored name attributes malformed")
        }
        return bytes.subdata(in: offset..<(offset + count - 1))
    }

    private static func waitUntil(_ description: String, diagnostics: (() -> String)? = nil, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline {
                throw UIVerification.Failure(message: "Timed out: \(description)" + (diagnostics.map { "\n" + $0() } ?? ""))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
#endif
