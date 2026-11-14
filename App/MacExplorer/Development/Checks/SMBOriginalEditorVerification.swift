#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

/// One additional journey in the existing ordinary SMB Connect check. It uses
/// the real native document/session owners and never starts a server or mints
/// a selected-file capability. Its caller owns the finite runtime/secret scope.
@MainActor enum SMBOriginalEditorVerification {
    static let initial = "before\n"
    static let first = "before\nfirst edit\n"
    static let second = "before\nfirst edit\naway\n"
    static let other = "before\nother editor\n"
    static let refused = "before\nfirst edit\naway\nsecond local edit\n"

    static func prepare(_ browser: BrowserViewController, root: URL) throws {
        try SMBConnectLiveVerification.require(ApplicationRemoteTextEditors.shared.reservationCount == 0,
            "An earlier generated text document remains owned")
        browser.recoverableFileOperations = RecoverableFileOperations(
            journalDirectory: root.appendingPathComponent("state/Unused Local Copies"))
    }

    static func warm(_ browser: BrowserViewController, owner: SMBTabController, root: URL) async throws -> [String: Any] {
        let editors = ApplicationRemoteTextEditors.shared
        try SMBConnectLiveVerification.require(owner.session.allowsInPlaceTextEdit,
            "SMB in-place editing was not admitted")
        // Browse & transfer keeps its existing session capabilities. The
        // publication UI has a separate product gate; editing must neither
        // disable that capability nor enter the received-Download pipeline.
        let downloadPermissionBefore = owner.session.allowsSelectedDownloads
        let downloadHistoryBefore = try await owner.downloads?.inspect()
        let a = try await open(browser, owner: owner)
        try SMBConnectLiveVerification.require(a.window.surface.textView.string == initial, "Initial generated text differs")
        // The retained Open source survives both a fresh directory generation
        // and navigation away from the editor's source folder.
        let generation = owner.rows.cache.snapshot?.readID
        owner.refreshAfterUpload()
        try await SMBConnectLiveVerification.wait { owner.uploadDestination != nil
            && owner.rows.cache.snapshot?.readID != generation }
        replace(a, with: first); try await save(a, boundary: "saved")
        let away = try owner.directoryLocation(components: [SMBRemoteName("CreatedFolder")])
        let refreshed = owner.rows.cache.snapshot?.readID
        browser.navigate(to: .smb(away))
        try await SMBConnectLiveVerification.wait { owner.currentBrowserLocation == .smb(away)
            && owner.rows.cache.snapshot?.readID != refreshed
            && owner.rows.cache.snapshot?.state == .complete
            && owner.rows.cache.loadedEntries.isEmpty && !owner.hasPendingPages }
        replace(a, with: second); try await save(a, boundary: "saved")
        let awayGeneration = owner.rows.cache.snapshot?.readID
        browser.navigate(to: .smb(owner.root))
        try await SMBConnectLiveVerification.wait { owner.currentBrowserLocation == .smb(owner.root)
            && owner.rows.cache.snapshot?.readID != awayGeneration
            && owner.rows.cache.loadedEntries.contains { $0.row.name.displayName == "Editor.txt" }
            && !owner.hasPendingPages }

        // B opens independently after A's second verified Save. Its Save
        // advances only B; A must refuse its now stale Before snapshot.
        let b = try await open(browser, owner: owner)
        try SMBConnectLiveVerification.require(a !== b && b.window.surface.textView.string == second,
            "Second captured document did not read the saved original")
        replace(b, with: other); try await save(b, boundary: "saved")
        replace(a, with: refused); try await save(a, boundary: "refused.smb.changed")
        try SMBConnectLiveVerification.require(a.saveRefusal == .smb(.changed) && a.state.isDirty
            && !a.window.saveButton.isEnabled && !a.needsReview && !a.disconnected
            && owner.session.latest.failure == nil, "Changed Save did not retain a definite refusal on the healthy connection")
        guard let refusedGeneration = a.refusedSaveGeneration else {
            throw UIVerification.Failure(message: "Definite refusal lost its actual captured generation")
        }
        let retained = try await a.remote.recoveryChoicesAfterExplicitRequest()
        guard let exact = RemoteRetainedTextChoice.refusedChoice(in: retained, generation: refusedGeneration) else {
            throw UIVerification.Failure(message: "Definite refusal has no single matching retained record")
        }
        try SMBConnectLiveVerification.require(retained.count > 1
            && RemoteRetainedTextChoice.refusedChoice(in: retained, generation: UUID()) == nil
            && RemoteRetainedTextChoice.refusedChoice(in: retained + [exact], generation: refusedGeneration) == nil,
            "Missing or duplicate refused captures selected an older or ambiguous version")
        // Later visible typing must not replace either exact retained capture.
        let laterVisible = refused + "newer visible text only\n"
        replace(a, with: laterVisible)
        try await SMBConnectLiveVerification.wait { !a.isBusy }
        var reviewingVersion: RemoteTextRecoveryController?
        RemoteTextRecoveryController.viewerForVerification = { reviewingVersion = $0 }
        defer { RemoteTextRecoveryController.viewerForVerification = nil }
        for (button, expected) in [(a.window.beforeSaveButton, second), (a.window.editedSaveButton, refused)] {
            a.window.window?.makeKeyAndOrderFront(nil)
            try SMBConnectLiveVerification.require(!button.isHidden && button.isEnabled,
                "Exact refused-version action is unavailable")
            button.performClick(nil)
            try await SMBConnectLiveVerification.wait { reviewingVersion != nil }
            guard let viewer = reviewingVersion else {
                throw UIVerification.Failure(message: "Exact refused-version native viewer is missing")
            }
            try SMBConnectLiveVerification.require(viewer.window.surface.textView.string == expected
                && !viewer.window.surface.textView.isEditable && !viewer.window.saveButton.isEnabled
                && a.window.surface.textView.string == laterVisible,
                "Refused Save review substituted later typing, an older record, or writable text")
            await viewer.closeAndDrain()
            try await SMBConnectLiveVerification.wait { reviewingVersion == nil && !a.isBusy }
            try SMBConnectLiveVerification.require(viewer.closed,
                "Exact refused-version viewer did not confirm its native close and pin drain")
        }
        if let native = a.window.window, CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(native,
                to: root.appendingPathComponent("evidence/smb-editor-changed.png"))
        }
        try await close(a); try await close(b)
        try SMBConnectLiveVerification.require(editors.reservationCount == 0,
            "Remote native document or failed-open reservation did not drain")
        let downloadHistoryAfter = try await owner.downloads?.inspect()
        try SMBConnectLiveVerification.require(downloadHistoryBefore == downloadHistoryAfter
            && owner.session.allowsSelectedDownloads == downloadPermissionBefore,
            "In-place editing changed Download history or session permission")
        return ["editorSavesVerified": 3, "changedSaveRefusedBeforeSubmission": true, "downloadHistoryUnchanged": true,
            "expectedFinalEditorSHA256": SHA256.hash(data: Data(other.utf8)).map { String(format: "%02x", $0) }.joined(),
            "checks": ["Retained native SMB Open Saves after Refresh and navigation away; B independently Saves",
                "Changed-baseline Save refuses without disconnect or overwrite; native close retains versions",
                "Direct Before/Edited review selects the exact unsubmitted capture despite older records and later typing; missing/duplicate matches refuse and actual viewer pins drain"]]
    }

    static func cold(_ browser: BrowserViewController, service: ApplicationSMBConnections, root: URL) async throws -> [String: Any] {
        let library = ApplicationRemoteSavedVersions.shared
        try SMBConnectLiveVerification.require(service.installPersistentSavedVersionsLoader(),
            "Existing persistent Saved Versions loader was not installed")
        library.bind(browser: browser); library.showSavedVersions(nil)
        guard let model = library.controller else { throw UIVerification.Failure(message: "Ordinary Saved Versions window missing") }
        try await SMBConnectLiveVerification.wait { model.work == nil }
        try SMBConnectLiveVerification.require(model.allChoices.count == 4,
            "Cold SMB saved-version inventory differs")
        guard let row = model.allChoices.firstIndex(where: {
            if case .smb(let choice) = $0 { return choice.outcome == .notStarted }; return false
        }) else { throw UIVerification.Failure(message: "Changed Save's retained record is missing") }
        let choice = model.allChoices[row]
        guard let generation = choice.capturedEditorGeneration else {
            throw UIVerification.Failure(message: "Cold retained refusal lost its capture generation")
        }
        try SMBConnectLiveVerification.require(
            RemoteRetainedTextChoice.refusedChoice(in: model.allChoices, generation: generation) != nil
            && RemoteRetainedTextChoice.refusedChoice(in: model.allChoices, generation: UUID()) == nil
            && RemoteRetainedTextChoice.refusedChoice(in: model.allChoices + [choice], generation: generation) == nil,
            "Cold exact-generation review accepted an absent or duplicate capture")
        model.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        for (title, expected) in [("Edited Text (Save capture)", refused), ("Before Save", second)] {
            model.version.selectItem(withTitle: title)
            try SMBConnectLiveVerification.require(model.review.isEnabled, "Retained version lacks explicit Review admission")
            model.review.performClick(nil)
            try await SMBConnectLiveVerification.wait { model.viewer?.window.surface.textView.string == expected }
            guard let viewer = model.viewer else { throw UIVerification.Failure(message: "Retained native viewer missing") }
            try SMBConnectLiveVerification.require(!viewer.window.surface.textView.isEditable
                && !viewer.window.saveButton.isEnabled, "Retained server version became writable")
            await viewer.closeAndDrain()
            try await SMBConnectLiveVerification.wait { model.work == nil && library.reservationCount == 0 }
            try SMBConnectLiveVerification.require(viewer.closed, "Retained viewer's actual close/pin drain is unconfirmed")
        }
        if let native = model.window, CGPreflightScreenCaptureAccess() {
            try await GlassVerification.captureOwnedWindow(native, to: root.appendingPathComponent("evidence/smb-editor-cold.png"))
        }
        await model.closeAndDrain()
        try SMBConnectLiveVerification.require(library.controller == nil && library.reservationCount == 0,
            "Cold library did not release its native owner")
        return ["retainedRecords": 4, "coldVersionsReviewed": 2, "networkConnections": 0,
            "checks": ["Ordinary server-off Saved Versions discovers all SMB records and reviews exact Before/Edited captures"]]
    }

    private static func open(_ browser: BrowserViewController, owner: SMBTabController) async throws -> RemoteTextDocumentController {
        guard let window = browser.view.window else { throw UIVerification.Failure(message: "Generated browser window missing") }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(owner.rows.table)
        try await SMBConnectLiveVerification.wait { owner.rows.cache.loadedEntries.contains { $0.row.name.displayName == "Editor.txt" } }
        guard let row = (0..<owner.rows.table.numberOfRows).first(where: {
            owner.rows.cache.entry(at: Int64($0))?.name.displayName == "Editor.txt"
        }) else { throw UIVerification.Failure(message: "Generated text row missing") }
        owner.rows.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let editors = ApplicationRemoteTextEditors.shared
        let earlier = Set(editors.documentsForVerification.map(\.id))
        try SMBConnectLiveVerification.require(browser.canEditTextInTraverse, "Ordinary SMB Edit command is unavailable")
        browser.editTextInTraverse(nil)
        try await SMBConnectLiveVerification.wait { editors.documentsForVerification.contains { !earlier.contains($0.id) } }
        guard let document = editors.documentsForVerification.first(where: { !earlier.contains($0.id) }) else {
            throw UIVerification.Failure(message: "Ordinary remote editor missing")
        }
        try await SMBConnectLiveVerification.wait { !document.isBusy }
        return document
    }
    private static func replace(_ document: RemoteTextDocumentController, with value: String) {
        document.show()
        let text = document.window.surface.textView
        document.window.window?.makeFirstResponder(text)
        let range = NSRange(location: 0, length: text.string.utf16.count)
        text.setSelectedRange(range); text.insertText(value, replacementRange: range); text.breakUndoCoalescing()
    }
    private static func save(_ document: RemoteTextDocumentController, boundary: String) async throws {
        try await SMBConnectLiveVerification.wait { !document.isBusy }
        try SMBConnectLiveVerification.require(document.state.isDirty && document.window.saveButton.isEnabled,
            "Generated edit is not ready for its next Save")
        let completed = document.verificationSaveTerminalCount
        document.window.saveButton.performClick(nil)
        try await SMBConnectLiveVerification.wait(seconds: 45) {
            document.verificationSaveTerminalCount == completed + 1 && !document.isBusy
        }
        try SMBConnectLiveVerification.require(document.verificationSaveBoundary == boundary,
            "SMB original Save reached " + document.verificationSaveBoundary)
    }
    static func close(_ document: RemoteTextDocumentController) async throws {
        var result: Bool?
        let work = Task { result = await document.closeForTermination() }
        try await SMBConnectLiveVerification.wait { result != nil || document.window.window?.attachedSheet != nil }
        if let sheet = document.window.window?.attachedSheet, let content = sheet.contentView {
            guard let discard = SMBConnectLiveVerification.buttons(content).first(where: { $0.title == "Don't Save" }) else {
                throw UIVerification.Failure(message: "Generated text close review differs")
            }
            discard.performClick(nil)
        }
        await work.value
        try SMBConnectLiveVerification.require(result == true && document.closed,
            "Generated text native close or retained owner did not drain")
    }
}
#endif
