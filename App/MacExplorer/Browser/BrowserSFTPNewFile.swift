import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// One explicit New File command. Uses the existing exclusive upload, durable
/// outcome and operation lifetime; no private URL enters ordinary Upload.
@MainActor final class BrowserSFTPNewFile {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?
    init(browser: BrowserViewController) { self.browser = browser }
    func canRequest(from owner: SFTPTabController) -> Bool {
        guard SFTPRemoteActionFeature.available, work == nil, let browser,
              !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand, browser.hasFileCommandFocus,
              browser.view.window?.attachedSheet == nil, browser.sftpTabs[browser.activeID] === owner,
              !owner.isClosing, owner.uploads != nil, owner.newTextStorage != nil,
              owner.session.allowsFreshUploads, owner.sealedActionSnapshot != nil else { return false }
        return true
    }
    func request(from owner: SFTPTabController) {
        guard canRequest(from: owner), let browser, let storage = owner.newTextStorage,
              let uploads = owner.uploads, let captured = owner.sealedActionSnapshot else { return }
        let tab = browser.activeID, visit = browser.sessionID, location = browser.location
        let coordinator = browser.operationCoordinator, preparation = UUID()
        guard coordinator.beginPreparation(owner: preparation) else { return }
        let diagnostics = ApplicationDiagnostics.shared
        let trace = diagnostics.begin(.fileOperation)
        diagnostics.event(.fileOperation, .presenting, trace: trace, context: .init(.newTextFile))
        browser.operationPreparationID = preparation
        work = Task { [self, browser, owner] in
            var started = false
            var terminalRecorded = false
            var source: SFTPEditedTextSnapshot?
            var createdName: String?
            @MainActor func finishPresentation() {
                if started { browser.finishOperationPresentation(); started = false }
                else if browser.operationPreparationID == preparation {
                    coordinator.finishPreparation(owner: preparation)
                    browser.operationPreparationTask = nil; browser.operationPreparationID = nil
                }
            }
            defer {
                if !terminalRecorded { diagnostics.event(.fileOperation, .cancelled, trace: trace, context: .init(.newTextFile)) }
                finishPresentation(); work = nil
            }
            @MainActor func current() -> Bool {
                !Task.isCancelled && !browser.isBrowserSuspended && browser.activeID == tab
                    && browser.sessionID == visit && browser.location == location && browser.sftpTabs[tab] === owner
                    && !owner.isClosing && owner.session.latest.failure == nil
            }
            do {
                guard let name = await browser.promptForName(title: FilenamePrompt.newFileTitle,
                    initial: owner.rows.suggestedNewName(FilenamePrompt.newFileDefaultName),
                    message: FilenamePrompt.newFileInstructions,
                    validating: { candidate in
                        guard current(), owner.sealedActionSnapshot?.generation == captured.generation else { return "This folder changed. Cancel and try again." }
                        guard let name = try? SFTPRemoteName(Data(candidate.utf8)) else { return "Choose a valid server filename." }
                        return owner.rows.hasLoadedName(name) ? "That name already exists. Choose another name." : nil
                    }) else { return }
                guard current(), owner.sealedActionSnapshot?.generation == captured.generation else { throw SFTPBrowserFailure.stale }
                diagnostics.event(.fileOperation, .preparing, trace: trace, context: .init(.newTextFile))
                let staged = try await storage.stageGeneratedEmpty(session: owner.connectionID, destinationGeneration: captured.generation)
                source = staged
                try Task.checkCancellation()
                guard current(), owner.sealedActionSnapshot?.generation == captured.generation else { throw SFTPBrowserFailure.stale }
                let request = try SFTPRequestedEditedTextUpload(destinationGeneration: captured.generation, snapshot: staged, name: name)
                guard browser.startOperationPresentation("Creating server file…", preparation: preparation, diagnosticTrace: trace) else { throw SFTPBrowserFailure.busy }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil; browser.operationTask = work
                diagnostics.event(.fileOperation, .transferring, trace: trace, context: .init(.newTextFile))
                _ = try await owner.session.uploadEditedText(request, storage: uploads)
                createdName = request.name.displayName
                let cleaned = await staged.closeAndDrain(); source = nil
                diagnostics.event(.fileOperation, .completed, trace: trace, context: .init(.newTextFile)); terminalRecorded = true
                finishPresentation()
                owner.showTransferOutcome(cleaned ? "Created “\(request.name.displayName)”." : "File created. Temporary local cleanup could not finish; the server file is intact.")
                guard current(), case .sftp(let folder) = location else { return }
                owner.refreshAfterUpload(at: folder)
                // Wait only for the ordinary visible metadata page, never a
                // recursive search or body read to locate the created name.
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while current(), ContinuousClock.now < deadline {
                    if owner.sealedActionSnapshot != nil, owner.rows.selectCreatedEmptyFile(named: request.name) {
                        browser.focusBrowserContent()
                        if ApplicationRemoteTextEditors.shared.canOpen(from: browser) {
                            ApplicationRemoteTextEditors.shared.open(from: browser)
                        } else { owner.showTransferOutcome("Created “\(request.name.displayName)”. Open it from the file list when an editor is available.") }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if current() { owner.showTransferOutcome("Created “\(request.name.displayName)”. Open it from the file list to edit.") }
            } catch {
                var drained = true
                if started, !(error is SFTPUploadOpenRefusal) { drained = await owner.close().value.localResourcesEnded }
                if let source {
                    if drained { _ = await source.closeAndDrain() }
                    else { SFTPBrowserLifetimes.shared.retainNewTextAfterUncertainClose(source, session: owner.session) }
                }
                if !terminalRecorded {
                    diagnostics.event(.fileOperation, Task.isCancelled ? .cancelled : .failed,
                        trace: trace, error: DiagnosticErrors.project(error), context: .init(.newTextFile))
                    terminalRecorded = true
                }
                let message = createdName.map { "Created “\($0)”. Open it from the file list to edit." }
                    ?? BrowserSFTPUpload.message(error, stopped: Task.isCancelled)
                if started, owner.drain?.localResourcesEnded == true {
                    browser.recordClosedSFTPUpload(tab, message: message, showHistory: owner.showUploadHistory)
                }
                owner.showTransferOutcome(message)
            }
        }
        browser.operationPreparationTask = work
    }
}
