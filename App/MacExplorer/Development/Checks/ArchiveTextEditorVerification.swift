#if DEBUG
import AppKit
import CryptoKit
import CoreServices
import ExplorerCore
import FileOperations
import LocalStorage

/// One complete ordinary editor flow within the existing generated preferences
/// check. It uses the real browser/ZIP reader/producer/journal and no new target.
@MainActor enum ArchiveTextEditorVerification {
    struct Failure: Error { let stage: String }
    static func need(_ value: Bool, _ stage: String) throws { if !value { throw Failure(stage: stage) } }
    static func wait(_ stage: String, seconds: Double = 10, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready() { try need(.now < deadline, stage); try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private struct ColdTAR: Codable, Sendable {
        let gzip: Bool
        let creation, firstSave: UUID
        let createdDigest, savedDigest, firstInputDigest, secondInputDigest: Data
    }
    private static func hash(_ url: URL) async throws -> Data {
        try await Task.detached { Data(SHA256.hash(data: try Data(contentsOf: url))) }.value
    }
    static func coldTAR(root: URL) async throws -> [String] {
        let gzip = ProcessInfo.processInfo.arguments.contains("--gzip-tar-editor")
        let packet = try await Task.detached {
            try JSONDecoder().decode(ColdTAR.self, from: Data(contentsOf: root.appendingPathComponent("evidence/tar-editor-cold-pending.json")))
        }.value
        try need(packet.gzip == gzip && packet.creation != packet.firstSave, "tar-cold-exact-profile")
        let parent = root.appendingPathComponent("source/Generated Documents")
        let source = parent.appendingPathComponent("Editor Archive." + (gzip ? "tar.gz" : "tar"))
        let engine = ApplicationOperationCoordinator.shared.engine(at: root.appendingPathComponent("state/history"))
        try await ApplicationOperationCoordinator.shared.prepareOperationState(for: engine)
        try need(try await hash(source) == packet.savedDigest, "tar-cold-current-bytes")
        let restored = await engine.undo(recordID: packet.firstSave)
        let restoredDigest = try await hash(source)
        try need(restored.result.disposition == .succeeded && restoredDigest == packet.createdDigest,
            "tar-cold-first-save-undo")
        let removed = await engine.undo(recordID: packet.creation)
        let exists = await Task.detached { FileManager().fileExists(atPath: source.path) }.value
        try need(removed.result.disposition == .succeeded && !exists, "tar-cold-create-undo")
        let firstDigest = try await hash(parent.appendingPathComponent("Generated.json"))
        let secondDigest = try await hash(parent.appendingPathComponent("Other.json"))
        try need(firstDigest == packet.firstInputDigest && secondDigest == packet.secondInputDigest, "tar-cold-original-inputs")
        return ["A separate native app process uses the ordinary Development engine to Undo the first text Save to exact earlier archive bytes, then Undo archive creation; generated inputs stay unchanged"]
    }
    private static func sheetButton(_ title: String, in window: NSWindow?) -> NSButton? {
        window?.attachedSheet?.contentView.flatMap { views($0).compactMap { $0 as? NSButton }.first { $0.title == title } }
    }
    private static func confirm(_ title: String, in window: NSWindow?) async throws {
        try await wait("archive-editor-sheet-" + title) { sheetButton(title, in: window) != nil }
        sheetButton(title, in: window)?.performClick(nil)
    }
    private static func close(_ doc: ArchiveTextDocumentController) async throws {
        doc.requestClose()
        if doc.isDirty || doc.needsReview {
            try await confirm(doc.needsReview ? "Close and Discard Visible Text" : "Don’t Save", in: doc.window.window)
        }
        try await wait("archive-editor-close-drain") { doc.isClosed }
    }
    private static func edit(_ text: String, in doc: ArchiveTextDocumentController) {
        doc.show()
        let view = doc.window.surface.textView
        view.insertText(text, replacementRange: .init(location: 0, length: view.string.utf16.count))
        view.breakUndoCoalescing()
    }
    static func prepareTARIfNeeded(_ source: URL, browser: BrowserViewController) async throws {
        guard TARBrowserModel.isCompressed(source) else { return }
        try await wait("tar-editor-preparation-page") {
            browser.currentArchive?.source == source && (browser.currentArchive?.hasRenderedCurrentRowsForVerification == true
                || browser.currentArchive?.tarModelForVerification?.canPrepareCompressed == true)
        }
        if browser.currentArchive?.tarModelForVerification?.canPrepareCompressed == true {
            browser.currentArchive?.tarModelForVerification?.prepareCompressed()
        }
        try await wait("tar-editor-prepared-page") { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
    }
    private static func acceptedNativeClose(_ settings: BrowserSettings) throws {
        let native = NativeTextEditorWindow(displayName: "Generated accepted close", installChrome: {
            ToolWindowChrome.install(in: $0, settings: settings)
        })
        defer { native.finishClose() }
        var acknowledgements = 0
        native.didClose = { acknowledgements += 1 }
        // Exercise a drained feature's synchronous close inside AppKit's user
        // close callback, rather than only calling the document owner directly.
        native.shouldClose = { [weak native] in native?.finishClose(); return false }
        native.showWindow(nil); native.window?.makeKeyAndOrderFront(nil)
        native.window?.performClose(nil)
        try need(acknowledgements == 1 && native.window?.isVisible == false,
            "accepted-close-inside-perform-close-must-acknowledge-once")
    }
    private static func createFile(source: URL, browser: BrowserViewController,
                                   cold: RecoverableFileOperations, root: URL, tar: Bool = false) async throws -> String {
        let before = try await Task.detached { try Data(contentsOf: source) }.value
        browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        browser.openSelection(nil)
        if tar { try await prepareTARIfNeeded(source, browser: browser) }
        try await wait("zip-new-file-current-page") { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
        try need(browser.canCreateTextFile, "zip-new-file-command-enabled")
        browser.createTextFile(nil)
        try await wait("zip-new-file-cancel-review") { ApplicationArchiveCreation.shared.controller != nil }
        await ApplicationArchiveCreation.shared.closeAndDrain()
        let afterCancel = try await Task.detached { try Data(contentsOf: source) }.value
        try need(before == afterCancel, "zip-new-file-cancel-changed-archive")
        browser.createTextFile(nil)
        try await wait("zip-new-file-review") { ApplicationArchiveCreation.shared.controller != nil }
        guard let creation = ApplicationArchiveCreation.shared.controller,
              let archive = browser.currentArchive else { throw Failure(stage: "archive-new-file-review-missing") }
        creation.model.memberName = "Created.json"
        try await wait("zip-new-file-plan") { !creation.model.isPreparing && !creation.model.previewIsPendingForVerification }
        try need(creation.model.isMemberNewFile && creation.model.canCreate
            && creation.model.summary?.files == 3, "zip-new-file-plan: " + creation.model.notice)
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = creation.window {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/zip-create-file.png"))
        }
        creation.model.create()
        let editors = ApplicationLocalTextEditors.shared
        try await wait("zip-new-file-created-editor") {
            !creation.model.isRunning && creation.model.outcome?.result.disposition == .succeeded
                && editors.archiveDocumentForVerification(source: source, path: "Created.json") != nil
        }
        guard let doc = editors.archiveDocumentForVerification(source: source, path: "Created.json") else {
            throw Failure(stage: "zip-new-file-auto-editor-missing")
        }
        let rowReady: Bool
        if tar, let model = archive.tarModelForVerification {
            rowReady = model.items.contains { $0.name == "Created.json" && $0.logicalBytes == 0 } && model.selection.count == 1
        } else if let model = archive.zipModelForVerification {
            rowReady = model.visibleItems.contains { $0.name == "Created.json" && $0.logicalBytes == 0 } && model.selection.count == 1
        } else { rowReady = false }
        try need(doc.opened.contents.text.isEmpty && rowReady, "archive-new-file-fresh-row-and-empty-text")
        edit("{\"created\":true}\n", in: doc); doc.window.saveButton.performClick(nil)
        try await wait("zip-new-file-editor-save") { !doc.isBusy && !doc.isDirty && doc.latestRecordID != nil }
        guard let saved = doc.latestRecordID else { throw Failure(stage: "zip-new-file-save-record") }
        try await close(doc)
        await browser.recoveryInspectionTask?.value
        let editUndo = await cold.undo(recordID: saved)
        try need(editUndo.result.disposition == .succeeded, "zip-new-file-editor-undo")
        creation.model.undo()
        try await wait("zip-new-file-create-undo") { !creation.model.isRunning && creation.model.undoOutcome != nil }
        let restored = try await Task.detached { try Data(contentsOf: source) }.value
        try need(creation.model.undoOutcome?.result.disposition == .succeeded && restored == before,
            "zip-new-file-original-exact-after-undo")
        await ApplicationArchiveCreation.shared.closeAndDrain()
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait("zip-new-file-return-browser") { !browser.isLoading && browser.rowsByURL[source] != nil }
        return "File → Create File inside the ordinary archive cancels without change, creates a fresh empty member, selects its live row and opens the native editor automatically; Save, cold Save Undo and creation Undo restore the exact original archive"
    }
    private static func extractFile(source: URL, member: URL, expected: String,
                                    browser: BrowserViewController, root: URL) async throws -> String {
        let before = try await Task.detached { (try Data(contentsOf: source), try Data(contentsOf: member)) }.value
        browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        browser.openSelection(nil)
        try await wait("zip-direct-extract-page") { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
        guard let model = browser.currentArchive?.zipModelForVerification,
              let item = model.visibleItems.first(where: { $0.name == member.lastPathComponent }) else {
            throw Failure(stage: "zip-direct-extract-member")
        }
        model.selection = [item.id]
        model.reviewExtraction([item.id])
        try await wait("zip-direct-extract-review") { ApplicationArchiveExtraction.shared.controller != nil }
        guard let controller = ApplicationArchiveExtraction.shared.controller else { throw Failure(stage: "zip-direct-extract-review-missing") }
        let review = controller.model
        try await wait("zip-direct-extract-collision") { !review.isPreparing && review.notice.contains("already exists") }
        try need(review.isFileExtraction && review.name == member.lastPathComponent && !review.canExtract,
            "zip-direct-extract-occupied-name-refuses")
        review.name = "Extracted.json"
        do { try await wait("zip-direct-extract-plan") { review.canExtract } }
        catch { throw Failure(stage: "zip-direct-extract-plan: " + review.notice) }
        let destination = source.deletingLastPathComponent().appendingPathComponent("Extracted.json")
        try need(review.plan?.destination == destination && review.plan?.files == 1 && review.plan?.folders == 0,
            "zip-direct-extract-no-wrapper")
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess(), let window = controller.window {
            try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/zip-extract-file.png"))
        }
        review.extract()
        try await wait("zip-direct-extract-publication") { !review.isRunning && review.outcome != nil }
        try need(review.outcome?.result.disposition == .succeeded, "zip-direct-extract-result: " + review.notice)
        let received = try await Task.detached { try Data(contentsOf: destination) }.value
        try need(received == Data(expected.utf8), "zip-direct-extract-exact-body")
        review.openFolder()
        try await wait("zip-direct-extract-reveal") { !browser.isLoading && browser.rowsByURL[destination] != nil }
        try need(browser.selectedURLs == [destination], "zip-direct-extract-reveal-selected-file")
        review.undo()
        try await wait("zip-direct-extract-undo") { !review.isRunning && review.undoOutcome != nil }
        let after = try await Task.detached {
            (try Data(contentsOf: source), try Data(contentsOf: member), FileManager().fileExists(atPath: destination.path))
        }.value
        try need(review.undoOutcome?.result.disposition == .succeeded && before.0 == after.0 && before.1 == after.1 && !after.2,
            "zip-direct-extract-undo-preserves-source-and-clash")
        await ApplicationArchiveExtraction.shared.closeAndDrain()
        return "One selected ZIP file uses the same Extract review, refuses its occupied sibling name, publishes exact bytes directly without a wrapper folder, reveals the selected output and Undoes only that verified file"
    }
    private static func interruptedRestore(source: URL, browser: BrowserViewController,
                                           engine: RecoverableFileOperations, root: URL) async throws -> [String] {
        let before = try await Task.detached { try Data(contentsOf: source) }.value
        browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
        browser.openSelection(nil)
        try await wait("archive-editor-recovery-inline-open") {
            browser.currentArchive?.hasRenderedCurrentRowsForVerification == true
        }
        guard let archive = browser.currentArchive?.zipModelForVerification,
              archive.createFolderInZIP(updateOriginal: true) else {
            throw Failure(stage: "archive-editor-recovery-new-folder-command")
        }
        try await wait("archive-editor-recovery-review") { ApplicationArchiveCreation.shared.controller != nil }
        guard let creation = ApplicationArchiveCreation.shared.controller else {
            throw Failure(stage: "archive-editor-recovery-review-missing")
        }
        creation.model.memberName = "Generated Recovery Folder"
        try await wait("archive-editor-recovery-preparation") {
            !creation.model.isPreparing && !creation.model.previewIsPendingForVerification
        }
        try need(creation.model.canCreate, "archive-editor-recovery-plan: " + creation.model.notice)
        creation.model.create()
        try await wait("archive-editor-recovery-checkpoint") {
            creation.model.outcome != nil && !creation.model.isRunning && browser.operationTask == nil
        }
        guard let outcome = creation.model.outcome, let id = outcome.recordID else {
            throw Failure(stage: "archive-editor-recovery-record-missing")
        }
        let originalAbsent = await Task.detached { !FileManager.default.fileExists(atPath: source.path) }.value
        let record = try await engine.recoveryRecords().records.first { $0.id == id }
        try need(GeneratedZIPRetainedCheckpoint.shared.hasStopped && originalAbsent
            && outcome.result.disposition != .succeeded && record?.canRestoreOriginalZIP == true
            && record?.canRecover == false, "archive-editor-recovery-safe-first-step")
        creation.model.viewResults()
        try await wait("archive-editor-recovery-selection") {
            browser.recoveryWindow?.selectedRecordID == id && browser.operationCoordinator.inspectionCount == 0
        }
        guard let recovery = browser.recoveryWindow, let window = recovery.window,
              let button = window.contentView.flatMap({ views($0).compactMap { $0 as? NSButton }
                  .first { $0.title == "Restore Original ZIP" && !$0.isHidden && $0.isEnabled } }) else {
            throw Failure(stage: "archive-editor-recovery-restore-button")
        }
        if !ProcessInfo.processInfo.arguments.contains("--offscreen"), CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(window,
                to: root.appendingPathComponent("evidence/editor-zip-restore.png"))
        }
        button.performClick(nil)
        try await confirm("Cancel", in: window)
        try await wait("archive-editor-recovery-cancel-sheet") { window.attachedSheet == nil }
        let stillAbsent = await Task.detached { !FileManager.default.fileExists(atPath: source.path) }.value
        try need(stillAbsent && browser.operationTask == nil, "archive-editor-recovery-cancel-keeps-original-retained")
        button.performClick(nil)
        try await confirm("Restore Original ZIP", in: window)
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let present = await Task.detached { FileManager.default.fileExists(atPath: source.path) }.value
            if present && browser.operationTask == nil && window.attachedSheet == nil
                && ApplicationFileActivity.gate.activeCount == 0 { break }
            try need(.now < deadline, "archive-editor-recovery-restore-drain")
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = try await Task.detached { try Data(contentsOf: source) }.value
        let final = try await engine.recoveryRecords().records.first { $0.id == id }
        try need(restored == before && final?.state == "undone"
            && final?.canRestoreOriginalZIP == false, "archive-editor-recovery-restores-exact-original")
        recovery.close()
        await ApplicationArchiveCreation.shared.closeAndDrain()
        browser.navigate(to: .directory(source.deletingLastPathComponent()))
        try await wait("archive-editor-recovery-return-listing") {
            !browser.isLoading && browser.rowsByURL[source] != nil
        }
        return ["A deliberate third native ZIP update stops after its durably qualified original move; the real Restore Original ZIP confirmation cancels without mutation, then restores the exact original through the ordinary browser owner"]
    }
    static func check(root: URL, browser: BrowserViewController, sources: [URL]) async throws -> [String] {
        guard let engine = browser.recoverableFileOperations, sources.count == 2,
              sources.allSatisfy({ $0.path.hasPrefix(root.appendingPathComponent("source").path + "/") }),
              let parent = sources.first?.deletingLastPathComponent() else { throw Failure(stage: "archive-editor-generated-scope") }
        let tar = ProcessInfo.processInfo.arguments.contains("--tar-editor")
        let gzip = ProcessInfo.processInfo.arguments.contains("--gzip-tar-editor")
        let format = gzip ? "TAR.gz" : tar ? "TAR" : "ZIP", suffix = gzip ? "tar.gz" : tar ? "tar" : "zip"
        if gzip { ApplicationCompressedArchives.shared.cacheDirectoryForVerification = root.appendingPathComponent("cache") }
        let settings = browser.settings, previous = browser.settings.editorPreferences
        let previousMotion = settings.motion
        defer { settings.updateEditorPreferences(previous); settings.motion = previousMotion }
        settings.motion = .init(mode: .full, windowClosing: true)
        try acceptedNativeClose(settings)
        var document: ArchiveTextDocumentController?
        do {
            let coordinator = ApplicationOperationCoordinator.shared
            try await coordinator.prepareOperationState(for: engine)
            if tar, ProcessInfo.processInfo.arguments.contains("--marked-archive-editor") {
                try await Task.detached {
                    for url in sources {
                        var values = URLResourceValues()
                        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Generated archive input",
                            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                            kLSQuarantineTimeStampKey as String: Date()]
                        var target = URL(fileURLWithPath: url.path); try target.setResourceValues(values)
                    }
                }.value
            }
            let observed = try await engine.observeSelection(sources)
            let plan: ArchiveCreationPlan
            if tar { plan = try await engine.prepareTARCreation(sources: sources, parent: parent,
                name: "Editor Archive." + suffix, compression: gzip ? .gzipBalanced : .none, observing: observed) }
            else { plan = try await engine.prepareZIPCreation(sources: sources, parent: parent, name: "Editor Archive.zip", observing: observed) }
            let created = await engine.performArchiveCreation(plan)
            try need(created.result.disposition == .succeeded,
                "archive-editor-generated-create: \(created.result.disposition), \(created.result.items.map(\.status))")
            let source = parent.appendingPathComponent("Editor Archive." + suffix)
            let originalBytes = try await Task.detached { try Data(contentsOf: source) }.value
            var native = previous; try native.setTarget(.traverse, forExtension: "json")
            settings.updateEditorPreferences(native)
            browser.navigate(to: .directory(parent))
            try await wait("archive-editor-generated-zip-listing") { browser.rowsByURL[source] != nil && !browser.isLoading }
            browser.setFileSelection([source]); browser.fileSelectionDidChange(); browser.focusBrowserContent()
            browser.openSelection(nil)
            if tar { try await prepareTARIfNeeded(source, browser: browser) }
            try await wait("archive-editor-inline-page") { browser.currentArchive?.hasRenderedCurrentRowsForVerification == true }
            let itemPath: String
            if tar {
                guard let model = browser.currentArchive?.tarModelForVerification,
                      let item = model.items.first(where: { $0.name == sources[0].lastPathComponent }) else {
                    throw Failure(stage: "archive-editor-real-tar-row-missing")
                }
                model.selection = [item.id]; itemPath = item.path
                try need(model.canEditSelectedText, "archive-editor-tar-row-command-not-admitted")
                model.openSelection()
            } else {
                guard let model = browser.currentArchive?.zipModelForVerification,
                      let item = model.visibleItems.first(where: { $0.name == sources[0].lastPathComponent }) else {
                    throw Failure(stage: "archive-editor-real-zip-row-missing")
                }
                model.selection = [item.id]; itemPath = item.path
                try need(model.canEditSelectedText, "archive-editor-zip-row-command-not-admitted")
                model.openSelection([item.id])
            }
            let editors = ApplicationLocalTextEditors.shared
            try await wait("archive-editor-open-owner") { editors.archiveDocumentForVerification(source: source, path: itemPath) != nil }
            guard let doc = editors.archiveDocumentForVerification(source: source, path: itemPath) else { throw Failure(stage: "archive-editor-native-window-missing") }
            document = doc
            let first = "{\"generated\":\"first archive edit\"}\n", second = "{\"generated\":\"second archive edit\"}\n"
            edit(first, in: doc); doc.window.saveButton.performClick(nil)
            try await wait("archive-editor-first-save") { !doc.isBusy && !doc.isDirty && doc.latestRecordID != nil }
            try need(doc.opened.contents.text == first && !doc.needsReview, "archive-editor-first-save-not-rebound")
            let firstRecord = try unwrap(doc.latestRecordID, "archive-editor-first-record")
            let firstBytes = try await Task.detached { try Data(contentsOf: source) }.value
            edit(second, in: doc); doc.window.saveButton.performClick(nil)
            try await wait("archive-editor-second-save") { !doc.isBusy && !doc.isDirty && doc.opened.contents.text == second }
            guard let secondRecord = doc.latestRecordID else { throw Failure(stage: "archive-editor-second-record-missing") }
            // A cold journal owner restores the earlier ZIP. The visible editor
            // still has its newer binding and must refuse to overwrite it.
            let nativeZIPUpdate = ProcessInfo.processInfo.arguments.contains("--native-original-update")
            let cold = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("state/history"),
                protecting: [root.appendingPathComponent("state")],
                authoredZIPMetadataPolicy: nativeZIPUpdate ? .nativeCreate : .exactSource,
                authoredZIPOriginalUpdateNativePolicy: nativeZIPUpdate ? .qualifiedNativeStage : .held,
                authoredTAROriginalUpdatePolicy: tar ? .developmentNativeStage : .held,
                authoredTARGzipOriginalUpdatePolicy: gzip ? .developmentNativeStage : .held)
            await browser.recoveryInspectionTask?.value
            let restored = await cold.undo(recordID: secondRecord)
            let afterUndo = try await Task.detached { try Data(contentsOf: source) }.value
            try need(restored.result.disposition == .succeeded && afterUndo == firstBytes,
                "archive-editor-cold-undo-not-exact: \(restored.result.disposition), \(restored.result.items.map(\.status)), bytesEqual=\(afterUndo == firstBytes)")
            let refused = "{\"generated\":\"keep this unsaved draft\"}\n"
            edit(refused, in: doc); doc.window.saveButton.performClick(nil)
            try await wait("archive-editor-conflict-drain") { !doc.isBusy }
            let afterRefusal = try await Task.detached { try Data(contentsOf: source) }.value
            try need(doc.isDirty && doc.window.surface.textView.string == refused && afterRefusal == firstBytes
                && doc.latestRecordID == secondRecord, "archive-editor-changed-zip-was-not-preserved")
            doc.reload(); try await confirm("Reload", in: doc.window.window)
            try await wait("archive-editor-reload") { !doc.isBusy && !doc.isDirty && doc.window.surface.textView.string == first }
            doc.show(); doc.window.saveAsButton.performClick(nil)
            try await confirm("Save Copy", in: doc.window.window)
            let copy = parent.appendingPathComponent("Editor Archive-edited." + suffix)
            try await wait("archive-editor-copy-follow") { !doc.isBusy && !doc.isDirty && doc.opened.archiveURL == copy }
            guard let copyRecord = doc.latestRecordID else { throw Failure(stage: "archive-editor-copy-record-missing") }
            let afterCopy = try await Task.detached { try Data(contentsOf: source) }.value
            try need(afterCopy == firstBytes && doc.opened.contents.text == first, "archive-editor-copy-changed-original")
            if CGPreflightScreenCaptureAccess(), !ProcessInfo.processInfo.arguments.contains("--offscreen"), let window = doc.window.window {
                try await GlassVerification.captureOwnedWindow(window, to: root.appendingPathComponent("evidence/editor-" + suffix + ".png"))
            }
            // Concurrent Close/Quit must join one native close, not reopen a
            // removed document after its preparation worker drains.
            try need(doc.window.window is ToolMotionWindow && settings.motion.allows(.windowClosing),
                "archive-editor-full-close-policy")
            doc.window.window?.performClose(nil)
            try need(await doc.closeForTermination(), "archive-editor-close-quit-did-not-join")
            try await wait("archive-editor-owner-release") { doc.isClosed && editors.documentCount == 0 }
            document = nil
            await browser.recoveryInspectionTask?.value
            let removedCopy = await cold.undo(recordID: copyRecord)
            let copyExists = await Task.detached { FileManager().fileExists(atPath: copy.path) }.value
            let finalOriginal = try await Task.detached { try Data(contentsOf: source) }.value
            try need(removedCopy.result.disposition == .succeeded && !copyExists && finalOriginal == firstBytes
                && originalBytes != firstBytes, "archive-editor-copy-undo-not-exact")
            browser.navigate(to: .directory(parent))
            try await wait("archive-editor-return-local-listing") {
                browser.location.directoryURL == parent && !browser.isLoading && browser.rowsByURL[sources[0]] != nil
            }
            var checks = ["Ordinary \(format) row Open uses the common native editor, Save twice rebinds the exact member, and cold archive Undo restores its prior bytes",
                "Changed \(format) Save refuses without touching the archive or draft; explicit Reload, archive Copy-follow, copy Undo and actual user performClose/joined Quit complete through existing owners with Full closing motion enabled",
                "A drained feature's accepted close acknowledges native willClose exactly once inside performClose without a deferred fade or implicit AppKit animation"]
            if tar {
                checks.append("\(format) shares native editor preferences, Save/Reload, metadata-preserving copy, and independent v\(gzip ? 19 : 18) original-update/cold Undo admission")
                checks.append(try await createFile(source: source, browser: browser, cold: cold, root: root, tar: true))
                checks += try await TARMemberVerification.check(source: source, browser: browser, cold: cold, root: root)
                let packet = ColdTAR(gzip: gzip, creation: try unwrap(created.recordID, "tar-cold-create-record"), firstSave: firstRecord,
                    createdDigest: Data(SHA256.hash(data: originalBytes)), savedDigest: Data(SHA256.hash(data: firstBytes)),
                    firstInputDigest: try await hash(sources[0]), secondInputDigest: try await hash(sources[1]))
                try await Task.detached {
                    try JSONEncoder().encode(packet).write(to: root.appendingPathComponent("evidence/tar-editor-cold-pending.json"), options: .withoutOverwriting)
                }.value
            } else if ProcessInfo.processInfo.arguments.contains("--interrupt-native-original-update") {
                checks += try await interruptedRestore(source: source, browser: browser, engine: engine, root: root)
            } else {
                checks.append(try await createFile(source: source, browser: browser, cold: cold, root: root))
                checks.append(try await extractFile(source: source, member: sources[0], expected: first, browser: browser, root: root))
            }
            return checks
        } catch {
            if let document, !document.isClosed {
                document.stop()
                try? await wait("archive-editor-failure-worker-drain") { !document.isBusy }
                try? await close(document)
            }
            browser.recoveryWindow?.close()
            await ApplicationArchiveCreation.shared.closeAndDrain()
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            throw error
        }
    }
    private static func unwrap<T>(_ value: T?, _ stage: String) throws -> T {
        guard let value else { throw Failure(stage: stage) }; return value
    }
}
#endif
