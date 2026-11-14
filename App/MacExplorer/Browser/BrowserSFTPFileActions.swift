import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Path-based server actions have their own durable outcomes. They never enter
/// the local Trash/Undo engine or obtain authority from a displayed path.
@MainActor enum SFTPRemoteActionFeature {
    #if DEBUG
    static var qualifying = false
    static var qualifyingMoves = false
    static var qualifyingDirectoryMoves = false
    static var qualifyingCopies = false
    #endif
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverActions)
    }
    static var routedAvailable: Bool { available }
    static var fileMoveAvailable: Bool {
        #if DEBUG
        if qualifying { return qualifyingMoves }
        #endif
        return available && AppFeatureAvailability.allows(.serverMove)
    }
    static var directoryMoveAvailable: Bool {
        #if DEBUG
        if qualifying { return qualifyingDirectoryMoves }
        #endif
        return available && AppFeatureAvailability.allows(.serverMove)
            && AppFeatureAvailability.allows(.serverDirectoryActions)
    }
    // Independent from received-file Download. Enable the normal product only
    // Signed build11 passes Copy/duplicates/collision, exact independent server
    // inventory and cold history. Each session still requires its extensions.
    private static let serverCopyAccepted = true
    static var copiesAvailable: Bool {
        #if DEBUG
        if qualifying { return qualifyingCopies }
        #endif
        return available && (serverCopyAccepted || GeneratedSandboxReview.conditionalServerCopyAdmitted)
    }
    static var movesAvailable: Bool { fileMoveAvailable || directoryMoveAvailable }
    static var emptyDirectoryDeleteAvailable: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return available && AppFeatureAvailability.allows(.serverDirectoryActions)
    }
    static var directoryRenameAvailable: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return available && AppFeatureAvailability.allows(.serverDirectoryActions)
    }
}

@MainActor final class BrowserSFTPFileActions {
    private enum InputFailure: Error { case invalidName }
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?
    private var remoteUndoBarrier = false, localRecordAtBarrier: UUID?
    var blocksImplicitUndo: Bool {
        guard remoteUndoBarrier, let browser else { return false }
        return browser.lastRecoveryRecordID == localRecordAtBarrier
    }
    #if DEBUG
    var confirmDeleteForVerification: (() async -> Bool)?
    var destinationForVerification: ((RemoteMoveDestinationModel) async -> String?)?
    private(set) var lastResult: SFTPRemoteActionResult?
    private(set) var lastNotice = ""
    #endif
    init(browser: BrowserViewController) { self.browser = browser }

    func canRequest(_ kind: SFTPRemoteActionKind, from owner: SFTPTabController) -> Bool {
        guard SFTPRemoteActionFeature.available, work == nil, let browser,
              !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand, browser.hasFileCommandFocus,
              browser.view.window?.attachedSheet == nil, browser.sftpTabs[browser.activeID] === owner,
              !owner.isClosing, owner.remoteActions != nil, owner.session.allowsRemoteActions,
              owner.sealedActionSnapshot != nil else { return false }
        if kind == .newFolder { return true }
        guard let captured = owner.sealedActionSnapshot, let row = owner.rows.selectedObservation else { return false }
        if kind == .copyFile {
            guard owner.allowsServerCopy,
                  ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation,
                  let root = try? SFTPDefaultDirectory(root: .server),
                  let name = try? Self.checkedName(row.entry.name.wireUTF8 == Data("Copy".utf8) ? "Copy 2" : "Copy") else { return false }
            return (try? SFTPRemoteActionIntent.copyFile(generation: captured.generation,
                snapshot: captured.snapshot, row: row, destinationDirectory: root, newName: name)) != nil
        }
        if kind == .moveFile || kind == .moveDirectory {
            guard kind == .moveFile ? owner.allowsFileMove : owner.allowsDirectoryMove,
                  ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation else { return false }
        }
        // Rename/Delete use metadata, so download body-size limits do not apply.
        if kind == .deleteEmptyDirectoryPermanently || kind == .renameDirectory || kind == .moveDirectory {
            if kind == .renameDirectory {
                guard owner.allowsDirectoryRename, ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation else { return false }
            } else if kind == .deleteEmptyDirectoryPermanently && !owner.allowsEmptyDirectoryDelete { return false }
            // Both commands require the same sealed directory metadata. The
            // actual Rename intent is constructed only after its name prompt;
            // only Delete asks the worker to inspect directory emptiness.
            return (try? SFTPRemoteActionIntent.deleteEmptyDirectoryPermanently(generation: captured.generation,
                snapshot: captured.snapshot, row: row)) != nil
        }
        return (try? SFTPRemoteActionIntent.deleteFilePermanently(generation: captured.generation,
            snapshot: captured.snapshot, row: row)) != nil
    }

    func canCopy(from owner: SFTPTabController) -> Bool { canRequest(.copyFile, from: owner) }
    func requestCopy(from owner: SFTPTabController, duplicate: Bool = false) {
        guard canCopy(from: owner) else { return }
        request(.copyFile, from: owner, duplicate: duplicate)
    }

    private func renameKind(from owner: SFTPTabController) -> SFTPRemoteActionKind? {
        guard let permissions = owner.rows.selectedObservation?.entry.permissions else { return nil }
        switch permissions & 0o170000 {
        case 0o100000: return .renameFile
        case 0o040000: return .renameDirectory
        default: return nil
        }
    }
    func canRename(from owner: SFTPTabController) -> Bool {
        guard let kind = renameKind(from: owner) else { return false }
        return canRequest(kind, from: owner)
    }
    func requestRename(from owner: SFTPTabController) {
        guard let kind = renameKind(from: owner) else { return }
        request(kind, from: owner)
    }
    private func moveKind(from owner: SFTPTabController) -> SFTPRemoteActionKind? {
        guard let mode = owner.rows.selectedObservation?.entry.permissions else { return nil }
        switch mode & 0o170000 {
        case 0o100000: return .moveFile
        case 0o040000: return .moveDirectory
        default: return nil
        }
    }
    func canMove(from owner: SFTPTabController) -> Bool {
        guard let kind = moveKind(from: owner) else { return false }
        return canRequest(kind, from: owner)
    }
    func requestMove(from owner: SFTPTabController) {
        guard let kind = moveKind(from: owner) else { return }
        request(kind, from: owner)
    }
    func requestClipboardPaste(_ context: ScopedItemPaste, from owner: SFTPTabController) {
        guard case .sftp(let source) = context.intent.source, context.intent.sftpOwner === owner,
              context.intent.operation != .copy || RemoteClipboardFeature.sftpCopyAvailable,
              let browser, context.isCurrent(), context.intent.canPaste(in: browser),
              let mode = source.row.entry.permissions else { return }
        request(context.intent.operation == .copy ? .copyFile : mode & 0o170000 == 0o040000 ? .moveDirectory : .moveFile,
            from: owner, clipboard: context)
    }
    func moveExplanation(from owner: SFTPTabController) -> String? {
        guard owner.allowsFileMove || owner.allowsDirectoryMove else { return "Move is not available on this connection yet." }
        if !ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation {
            return "Finish or close remote editors before moving a server item."
        }
        return nil
    }
    func renameExplanation(from owner: SFTPTabController) -> String? {
        guard renameKind(from: owner) == .renameDirectory else { return nil }
        if !owner.allowsDirectoryRename { return "Folder Rename is not available on this connection yet." }
        if !ApplicationRemoteTextEditors.shared.canBeginDirectoryMutation {
            return "Finish or close remote editors before renaming a server folder."
        }
        return nil
    }

    private func deletionKind(from owner: SFTPTabController) -> SFTPRemoteActionKind? {
        guard let permissions = owner.rows.selectedObservation?.entry.permissions else { return nil }
        switch permissions & 0o170000 {
        case 0o100000: return .deleteFilePermanently
        case 0o040000: return .deleteEmptyDirectoryPermanently
        default: return nil
        }
    }

    func canDelete(from owner: SFTPTabController) -> Bool {
        guard let kind = deletionKind(from: owner) else { return false }
        return canRequest(kind, from: owner)
    }

    func requestDelete(from owner: SFTPTabController) {
        guard let kind = deletionKind(from: owner) else { return }
        request(kind, from: owner)
    }

    func request(_ kind: SFTPRemoteActionKind, from owner: SFTPTabController, clipboard: ScopedItemPaste? = nil, duplicate: Bool = false) {
        guard let browser, work == nil, !duplicate || kind == .copyFile,
              clipboard.map({ $0.isCurrent() && $0.intent.sftpOwner === owner && $0.intent.canPaste(in: browser)
                && (kind == .copyFile && $0.intent.operation == .copy
                    || (kind == .moveFile || kind == .moveDirectory) && $0.intent.operation == .move) }) ?? canRequest(kind, from: owner),
              let store = owner.remoteActions,
              let captured = owner.sealedActionSnapshot, case .sftp(let folder) = browser.location else { return }
        let initialSelection = owner.rows.selectedObservation
        let clipboardSource: SFTPClipboardSource? = clipboard.flatMap { if case .sftp(let source) = $0.intent.source { source } else { nil } }
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID(), coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { return }
        let editorFence: UUID?
        if kind == .renameDirectory || kind == .moveFile || kind == .moveDirectory || kind == .copyFile {
            guard let token = ApplicationRemoteTextEditors.shared.beginDirectoryMutation() else {
                coordinator.finishPreparation(owner: preparation); return
            }
            editorFence = token
        } else { editorFence = nil }
        let renameRequest = (kind == .renameFile || kind == .renameDirectory) ? browser.inlineRename.reserveRemote(owner: owner) : nil
        browser.operationPreparationID = preparation
        #if DEBUG
        lastResult = nil; lastNotice = ""
        #endif
        let action: DiagnosticAction = kind == .copyFile ? .copy : kind == .newFolder ? .newFolder : (kind == .moveFile || kind == .moveDirectory) ? .move
            : (kind == .renameFile || kind == .renameDirectory) ? .rename : .fileOperation
        let diagnostics = ApplicationDiagnostics.shared, trace = diagnostics.begin(action)
        work = Task { [self, browser, owner] in
            var started = false, terminalRecorded = false
            var actionRecordID: UUID?
            var movedParents: (source: String, destination: String)?
            var captured = captured, selected = initialSelection
            var observedClipboardSource = false, retainClipboard = false, clipboardFinished = false
            defer {
                if !clipboardFinished { clipboard?.finish(confirmed: false, canRetain: retainClipboard && !Task.isCancelled && owner.session.latest.failure == nil) }
                if observedClipboardSource { owner.restoreAfterClipboardSourceObservation() }
                if !terminalRecorded { diagnostics.event(action, .cancelled, trace: trace, context: .init(.queueTerminal)) }
                work = nil
                if let renameRequest { browser.inlineRename.cancel(requestID: renameRequest) }
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
                if let editorFence { ApplicationRemoteTextEditors.shared.finishDirectoryMutation(editorFence) }
                if let movedParents {
                    refreshMoveParents(source: movedParents.source, destination: movedParents.destination,
                        owner: owner, coordinator: coordinator)
                }
            }
            @MainActor func inputCurrent() -> Bool {
                !Task.isCancelled && !browser.isBrowserSuspended && browser.activeID == tab && browser.sessionID == visit
                    && browser.sftpTabs[tab] === owner && !owner.isClosing && owner.session.latest.failure == nil
                    && (clipboard?.isCurrent() ?? true)
            }
            @MainActor func current() -> Bool {
                guard inputCurrent() else { return false }
                if clipboard != nil, observedClipboardSource {
                    return owner.session.latest.generation == captured.generation && owner.session.latest.snapshot == captured.snapshot
                }
                return owner.sealedActionSnapshot?.generation == captured.generation
                    && owner.sealedActionSnapshot?.snapshot == captured.snapshot
                    && (kind == .newFolder || owner.rows.selectedObservation?.observation == selected?.observation)
            }
            do {
                let requestedCopyDestination: SFTPDefaultDirectory?
                if clipboard?.intent.operation == .copy {
                    let probe = try SFTPRemoteActionIntent.newFolder(generation: captured.generation,
                        snapshot: captured.snapshot, name: Self.checkedName("Copy Destination"))
                    requestedCopyDestination = try await owner.session.observedActionDirectory(for: probe)
                    guard current() else { return }
                } else { requestedCopyDestination = nil }
                if let clipboardSource {
                    observedClipboardSource = true
                    let fresh = try await owner.reobserveClipboardSource(clipboardSource, preparation: preparation,
                        operation: clipboard?.intent.operation ?? .move, current: inputCurrent)
                    captured = (fresh.generation, fresh.snapshot); selected = fresh.row
                    guard current() else { return }
                    retainClipboard = true // A cancelled destination choice sent no mutation.
                }
                let intent: SFTPRemoteActionIntent
                switch kind {
                case .newFolder:
                    guard let name = await browser.promptForName(title: "New Folder", initial: owner.rows.suggestedNewName("New folder"), validating: { candidate in
                        guard current(), let name = try? SFTPRemoteName(Data(candidate.utf8)) else { return "This folder changed, or the name is unavailable. Cancel and try again." }
                        return owner.rows.hasLoadedName(name) ? "That name already exists. Choose another name." : nil
                    }), current() else { return }
                    intent = try .newFolder(generation: captured.generation, snapshot: captured.snapshot, name: Self.checkedName(name))
                case .renameFile, .renameDirectory:
                    guard let selected else { return }
                    let original = String(decoding: selected.entry.name.wireUTF8, as: UTF8.self)
                    let initial = selected.entry.name.isSafeForSingleLineEntry ? original : ""
                    let validate: (String) -> String? = { candidate in
                        guard current(), let name = try? SFTPRemoteName(Data(candidate.utf8)), !candidate.isEmpty,
                              !candidate.contains("\n"), !candidate.contains("\r"), name.wireUTF8.count <= 255 else { return "The selection changed, or this name is unavailable. Cancel and try again." }
                        return name.wireUTF8 != selected.entry.name.wireUTF8 && owner.rows.hasLoadedName(name)
                            ? "That name already exists. Choose another name." : nil
                    }
                    let answer: String?
                    if let prompt = browser.operationNamePrompt { answer = await prompt("Rename", initial) }
                    else if let renameRequest {
                        answer = await browser.inlineRename.beginRemote(owner: owner, name: initial, ordinaryFile: kind == .renameFile,
                            requestID: renameRequest, validating: validate)
                    } else { answer = nil }
                    guard let name = answer, current(), let renameRequest,
                          browser.inlineRename.consumeRemote(requestID: renameRequest), validate(name) == nil else { return }
                    guard Data(name.utf8) != selected.entry.name.wireUTF8 else { return }
                    let proposed = try Self.checkedName(name)
                    if kind == .renameDirectory {
                        intent = try .renameDirectory(generation: captured.generation, snapshot: captured.snapshot, row: selected, newName: proposed)
                    } else {
                        intent = try .renameFile(generation: captured.generation, snapshot: captured.snapshot, row: selected, newName: proposed)
                    }
                case .copyFile:
                    guard let selected,
                          let answer = try await chooseCopyIntent(from: owner, generation: captured.generation,
                            snapshot: captured.snapshot, row: selected, duplicate: duplicate,
                            requestedDestination: requestedCopyDestination, browser: browser, current: current) else { return }
                    intent = answer
                case .moveFile, .moveDirectory:
                    guard let selected, let window = browser.view.window,
                          let source = clipboardSource?.directory ?? owner.navigationDirectory(folder) else { return }
                    func makeMove(to destination: SFTPDefaultDirectory) throws -> SFTPRemoteActionIntent {
                        if kind == .moveDirectory {
                            return try .moveDirectory(generation: captured.generation, snapshot: captured.snapshot,
                                row: selected, destinationDirectory: destination)
                        }
                        return try .moveFile(generation: captured.generation, snapshot: captured.snapshot,
                            row: selected, destinationDirectory: destination)
                    }
                    if clipboard != nil, !owner.reviewsUploads {
                        guard current(), let destination = owner.navigationDirectory(folder), destination.root == .server else { return }
                        intent = try makeMove(to: destination)
                    } else {
                    let model = RemoteMoveDestinationModel(name: selected.entry.name.displayName, isFolder: kind == .moveDirectory,
                        server: owner.presentation?.name ?? owner.address.host,
                        currentFolder: (source.root == .home ? "~" : "") + "/" + source.components.map(\.displayName).joined(separator: "/"), rootTitle: "Server Root",
                        initialPath: clipboardSource == nil ? (source.root == .server ? source.editableFieldText ?? "" : "")
                            : owner.navigationDirectory(folder)?.editableFieldText ?? "",
                        destinationNotice: "Traverse checks the destination before moving. Concurrent server changes can affect the result.",
                        validate: { path in
                            guard current() else { return "The selection changed. Cancel and choose the file again." }
                            guard let destination = try? SFTPDefaultDirectory(field: path, root: .server) else {
                                return "Enter an existing /folder on this server, or choose Server Root."
                            }
                            if destination == source { return "Choose a different folder." }
                            if kind == .moveDirectory, source.root == .server,
                               destination.components.starts(with: source.components + [selected.entry.name]) {
                                return "Choose a destination outside this folder and its contents."
                            }
                            guard (try? makeMove(to: destination)) != nil else {
                                return "This destination is unavailable. Choose a shorter folder path."
                            }
                            return nil
                        })
                    let answer: String?
                    #if DEBUG
                    if let destinationForVerification { answer = await destinationForVerification(model) }
                    else { answer = await RemoteMoveDestination(model: model, settings: browser.settings).choose(in: window) }
                    #else
                    answer = await RemoteMoveDestination(model: model, settings: browser.settings).choose(in: window)
                    #endif
                    guard let path = answer, current(),
                          let destination = try? SFTPDefaultDirectory(field: path, root: .server) else { return }
                    intent = try makeMove(to: destination)
                    }
                case .deleteFilePermanently, .deleteEmptyDirectoryPermanently:
                    guard let selected, let window = browser.view.window else { return }
                    let destination = "\(owner.address.host):\(owner.address.port)\n\(owner.transferDestination(for: folder))"
                    let emptyFolder = kind == .deleteEmptyDirectoryPermanently
                    let confirmed: Bool
                    #if DEBUG
                    if let confirmDeleteForVerification { confirmed = await confirmDeleteForVerification() }
                    else { confirmed = await confirmDelete(selected.entry.name.displayName, destination: destination, emptyFolder: emptyFolder, in: window) }
                    #else
                    confirmed = await confirmDelete(selected.entry.name.displayName, destination: destination, emptyFolder: emptyFolder, in: window)
                    #endif
                    guard confirmed, current() else { return }
                    if emptyFolder {
                        intent = try .deleteEmptyDirectoryPermanently(generation: captured.generation, snapshot: captured.snapshot, row: selected)
                    } else {
                        intent = try .deleteFilePermanently(generation: captured.generation, snapshot: captured.snapshot, row: selected)
                    }
                }
                actionRecordID = intent.request
                guard current(), browser.startOperationPresentation(Self.title(kind), preparation: preparation, diagnosticTrace: trace) else { return }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil; browser.operationTask = work
                if kind == .copyFile {
                    browser.operationPresentation = .init(phaseTitle: "Copy on server",
                        summary: "The original stays here. Existing items are kept.",
                        currentItem: selected?.entry.name.displayName)
                    browser.updateOperationProgressControls()
                }
                diagnostics.event(action, .preparing, trace: trace, context: .init(.queueMutation), relatedTrace: intent.request)
                let result = try await owner.session.performRemoteAction(intent, store: store)
                if let clipboard {
                    let safeToRetry = result.record.outcome == .failedSafe && result.record.refusal != .sourceChanged
                        && owner.session.latest.failure == nil
                    clipboard.finish(confirmed: result.record.outcome == .confirmed, canRetain: safeToRetry)
                    clipboardFinished = true
                }
                let message = Self.message(result.record) + (result.completedAfterCancellation ? " The action completed while stopping." : "")
                if result.record.outcome == .confirmed || result.record.outcome == .needsReview {
                    remoteUndoBarrier = true; localRecordAtBarrier = browser.lastRecoveryRecordID
                }
                diagnostics.event(action, result.record.outcome == .confirmed ? .completed : result.record.outcome == .failedSafe ? .blocked : .interrupted,
                    trace: trace, level: result.record.outcome == .needsReview ? .warning : .information,
                    error: DiagnosticErrors.remoteFileAction(result.record),
                    context: .init(.queueTerminal, flags: result.completedAfterCancellation ? [.cancellationRequested] : []), relatedTrace: result.record.id)
                terminalRecorded = true
                if kind == .renameDirectory, let selected,
                   result.record.outcome == .confirmed || result.record.outcome == .needsReview {
                    invalidateDescendantViews(of: selected.entry.name, in: folder, owner: owner, coordinator: coordinator,
                        confirmed: result.record.outcome == .confirmed)
                }
                if (kind == .moveFile || kind == .moveDirectory || kind == .copyFile), let destination = result.record.destinationDirectory,
                   result.record.outcome == .confirmed || result.record.outcome == .needsReview {
                    movedParents = (result.record.remoteDirectory, destination)
                    if kind == .moveDirectory, let selected {
                        invalidateMovedDescendants(name: selected.entry.name, source: result.record.remoteDirectory,
                            destination: destination, owner: owner, coordinator: coordinator,
                            confirmed: result.record.outcome == .confirmed)
                    }
                }
                owner.showTransferOutcome(message)
                if browser.sftpTabs[browser.activeID] === owner { browser.status.stringValue = message }
                if result.record.outcome == .needsReview {
                    let drained = await owner.close().value
                    if drained.localResourcesEnded { browser.recordClosedSFTPUpload(tab, message: message, showHistory: owner.showUploadHistory) }
                } else if clipboard == nil, owner.session.latest.failure == nil { owner.refreshAfterUpload(at: folder) }
                #if DEBUG
                lastResult = result; lastNotice = message
                #endif
            } catch {
                retainClipboard = false
                if started { remoteUndoBarrier = true; localRecordAtBarrier = browser.lastRecoveryRecordID }
                if started && (Task.isCancelled || owner.session.latest.failure != nil) { _ = await owner.close().value }
                diagnostics.event(action, Task.isCancelled ? .interrupted : .failed, trace: trace,
                    error: DiagnosticErrors.project(error), context: .init(.queueTerminal), causes: DiagnosticErrors.causes(error), relatedTrace: actionRecordID)
                terminalRecorded = true
                let message = Self.failureMessage(error, started: started)
                owner.showTransferOutcome(message)
                if browser.sftpTabs[browser.activeID] === owner { browser.status.stringValue = message }
                #if DEBUG
                lastNotice = message
                #endif
            }
        }
        browser.operationPreparationTask = work
    }
    private func chooseCopyIntent(from owner: SFTPTabController, generation: UUID,
        snapshot: SFTPStoredSnapshot, row: SFTPStoredRow, duplicate: Bool,
        requestedDestination: SFTPDefaultDirectory? = nil, browser: BrowserViewController, current: @escaping @MainActor () -> Bool) async throws -> SFTPRemoteActionIntent? {
        let root = try SFTPDefaultDirectory(root: .server)
        let probeName = try Self.checkedName(row.entry.name.wireUTF8 == Data("Copy".utf8) ? "Copy 2" : "Copy")
        let probe = try SFTPRemoteActionIntent.copyFile(generation: generation, snapshot: snapshot,
            row: row, destinationDirectory: root, newName: probeName)
        // This asks only the retained authenticated catalog for its canonical
        // parent. A Home label or saved start path is never assumed to be it.
        let source = try await owner.session.observedActionDirectory(for: probe)
        guard current() else { return nil }
        let sourcePath = source.editableFieldText ?? "/"
        let original = String(decoding: row.entry.name.wireUTF8, as: UTF8.self)
        let base = original as NSString
        let ext = base.pathExtension
        let suggested = owner.rows.suggestedNewName(base.deletingPathExtension + " copy" + (ext.isEmpty ? "" : "." + ext))
        func makeCopy(to destination: SFTPDefaultDirectory, name: String) throws -> SFTPRemoteActionIntent {
            let checked = try Self.checkedName(name)
            guard destination != source || checked.wireUTF8 != row.entry.name.wireUTF8 else { throw InputFailure.invalidName }
            return try .copyFile(generation: generation, snapshot: snapshot, row: row,
                destinationDirectory: destination, newName: checked)
        }
        let inPlace = duplicate || requestedDestination == source
        if !owner.reviewsUploads, let destination = requestedDestination ?? (duplicate ? source : nil),
           let automatic = try? makeCopy(to: destination, name: inPlace ? suggested : original) {
            return current() ? automatic : nil
        }
        guard let window = browser.view.window else { return nil }
        let model = RemoteMoveDestinationModel(name: row.entry.name.displayName,
            server: owner.presentation?.name ?? owner.address.host,
            currentFolder: "/" + source.components.map(\.displayName).joined(separator: "/"),
            rootTitle: "Server Root", initialPath: requestedDestination?.editableFieldText ?? sourcePath,
            destinationNotice: "The original stays here. Existing items are kept.",
            operation: inPlace ? .duplicate : .copy,
            initialName: inPlace ? ((try? Self.checkedName(suggested)) == nil ? "" : suggested)
                : (row.entry.name.isSafeForSingleLineEntry ? original : ""),
            validateCopy: { path, name in
                guard current(), let destination = try? SFTPDefaultDirectory(field: path, root: .server),
                      let checked = try? Self.checkedName(name),
                      (try? makeCopy(to: destination, name: name)) != nil else {
                    return "Choose a different valid name or folder for the copy."
                }
                return destination == (requestedDestination ?? source) && owner.rows.hasLoadedName(checked)
                    ? "That name already exists. Choose another name." : nil
            }, validate: { path in
                guard current() else { return "The selection changed. Cancel and choose the file again." }
                return (try? SFTPDefaultDirectory(field: path, root: .server)) == nil
                    ? "Enter an existing /folder on this server, or choose Server Root." : nil
            })
        let answer: String?
        #if DEBUG
        if let destinationForVerification { answer = await destinationForVerification(model) }
        else { answer = await RemoteMoveDestination(model: model, settings: browser.settings).choose(in: window) }
        #else
        answer = await RemoteMoveDestination(model: model, settings: browser.settings).choose(in: window)
        #endif
        guard let path = answer, path == model.path, current(), model.canMove,
              let destination = try? SFTPDefaultDirectory(field: path, root: .server) else { return nil }
        return try makeCopy(to: destination, name: model.destinationName)
    }

    private func refreshMoveParents(source: String, destination: String, owner: SFTPTabController,
        coordinator: ApplicationOperationCoordinator) {
        let host = SFTPHostIdentity(address: owner.address), account = owner.presentation?.account
        var seen = Set<UUID>()
        // Matching display endpoints are cache hints only. Each existing owner
        // rereads through its own authenticated connection; none is retargeted.
        for browser in coordinator.liveBrowsers {
            for candidate in browser.sftpTabs.values where candidate !== owner && !candidate.isClosing
                && candidate.routeDescription == nil {
                guard seen.insert(candidate.connectionID).inserted,
                      SFTPHostIdentity(address: candidate.address) == host,
                      candidate.presentation?.account == account else { continue }
                candidate.refreshAfterFileMove(source: Data(source.utf8), destination: Data(destination.utf8))
            }
        }
    }
    private func invalidateMovedDescendants(name: SFTPRemoteName, source: String, destination: String,
        owner: SFTPTabController, coordinator: ApplicationOperationCoordinator, confirmed: Bool) {
        func prefix(_ path: String) -> SFTPDefaultDirectory? {
            guard let parts = try? path.split(separator: "/").map({ try SFTPRemoteName(Data($0.utf8)) }) else { return nil }
            return try? .init(root: .server, components: parts + [name])
        }
        guard let old = prefix(source), let new = prefix(destination),
              let home = try? SFTPDefaultDirectory(root: .home) else { return }
        let host = SFTPHostIdentity(address: owner.address), account = owner.presentation?.account
        var seen = Set<UUID>()
        for browser in coordinator.liveBrowsers {
            for candidate in browser.sftpTabs.values where candidate !== owner && !candidate.isClosing
                && candidate.routeDescription == nil {
                guard seen.insert(candidate.connectionID).inserted,
                      SFTPHostIdentity(address: candidate.address) == host,
                      candidate.presentation?.account == account else { continue }
                // Aliased Home paths cannot certify a different connection's
                // subtree identity. Invalidate conservatively; never retarget.
                candidate.invalidateObservedDirectory(home, confirmedRename: false)
                candidate.invalidateObservedDirectory(old, confirmedRename: confirmed)
                candidate.invalidateObservedDirectory(new, confirmedRename: false)
            }
        }
    }
    private func invalidateDescendantViews(of name: SFTPRemoteName, in parent: SFTPBrowserLocation,
        owner: SFTPTabController, coordinator: ApplicationOperationCoordinator, confirmed: Bool) {
        guard let folder = owner.navigationDirectory(parent),
              let prefix = try? SFTPDefaultDirectory(root: folder.root, components: folder.components + [name]) else { return }
        let host = SFTPHostIdentity(address: owner.address), account = owner.presentation?.account
        var seen = Set<UUID>()
        for browser in coordinator.liveBrowsers {
            for candidate in browser.sftpTabs.values where !candidate.isClosing && candidate.routeDescription == nil {
                guard seen.insert(candidate.connectionID).inserted,
                      SFTPHostIdentity(address: candidate.address) == host,
                      candidate.presentation?.account == account else { continue }
                candidate.invalidateObservedDirectory(prefix, confirmedRename: confirmed)
            }
        }
    }
    private static func failureMessage(_ error: Error, started: Bool) -> String {
        if !started, let failure = error as? RemoteSourceObservationFailure { return failure.userMessage }
        if error as? RemoteSettingsFailure == .capacity { return "File Action History is full. Review and forget old local records before continuing." }
        if error as? RemoteSettingsFailure == .recoveryRequired { return "Review the interrupted file-action update in Connection Activity before continuing." }
        if error is InputFailure { return "This name can’t be used. Choose a shorter name without / or control characters." }
        if error as? SFTPBrowserFailure == .stale { return "The folder or selected item changed. Refresh it before trying again." }
        return started ? "This server action did not finish. Review File Action History before trying again."
            : "The name or server selection is unavailable. Refresh the folder and try again."
    }
    private static func checkedName(_ value: String) throws -> SFTPRemoteName {
        guard let name = try? SFTPRemoteName(Data(value.utf8)), name.wireUTF8.count <= 255,
              name.isSafeForSingleLineEntry else { throw InputFailure.invalidName }
        return name
    }
    private func confirmDelete(_ name: String, destination: String, emptyFolder: Bool, in window: NSWindow) async -> Bool {
        await RemoteDeleteConfirmation.confirm(name: name, destination: destination, emptyFolder: emptyFolder, in: window)
    }
    private static func title(_ kind: SFTPRemoteActionKind) -> String {
        switch kind {
        case .newFolder: "Creating server folder…"
        case .renameFile: "Renaming server file…"
        case .renameDirectory: "Renaming server folder…"
        case .copyFile: "Copying file on server…"
        case .moveFile: "Moving server file…"
        case .moveDirectory: "Moving server folder…"
        case .deleteFilePermanently: "Deleting server file…"
        case .deleteEmptyDirectoryPermanently: "Deleting empty server folder…"
        }
    }
    static func message(_ record: SFTPRemoteActionRecord) -> String {
        switch record.outcome {
        case .confirmed:
            switch record.kind {
            case .newFolder: "Created “\(record.displayRemoteName)”."
            case .renameFile, .renameDirectory: "Renamed “\(record.displayRemoteName)” to “\(record.displayDestinationName ?? "")”."
            case .copyFile: "Copied “\(record.displayRemoteName)” to “\(record.displayDestinationName ?? "")”. The original was kept."
            case .moveFile, .moveDirectory: "Moved “\(record.displayRemoteName)”."
            case .deleteFilePermanently, .deleteEmptyDirectoryPermanently: "Deleted “\(record.displayRemoteName)” permanently."
            }
        case .failedSafe:
            switch record.refusal {
            case .targetExists?: (record.kind == .moveFile || record.kind == .moveDirectory)
                ? "The destination already contains an item with this name. Choose a different folder; nothing was changed."
                : "An item with that name already exists. Choose another name; nothing was changed."
            case .sourceChanged?: (record.kind == .moveFile || record.kind == .moveDirectory)
                ? "The selected item or destination changed or is unavailable. Refresh and choose an existing destination folder."
                : "The selected server item changed or moved. Refresh the folder before trying again."
            case .denied?: "Your server account does not have permission for this action. Nothing was changed."
            case .busy?: "An editor in this location is still open in Traverse. Finish or close it before trying again."
            case .notEmpty?: "This folder is not empty. Its contents were kept."
            case .unavailable?, nil: "The server could not perform this action. Nothing was changed."
            }
        case .prepared: "This server action was prepared but not sent. Review File Action History."
        case .needsReview: record.kind == .copyFile
            ? "The copy could not be confirmed. The original was kept; review the destination and temporary copy in File Action History."
            : "The server action could not be confirmed. Review File Action History before trying again."
        }
    }
}

@MainActor extension BrowserViewController {
    @objc func deleteRemoteFilePermanently(_ sender: Any?) {
        if let owner = smbTabs[activeID] { smbFileActions.request(.delete, from: owner); return }
        guard let owner = sftpTabs[activeID] else { return }
        sftpFileActions.requestDelete(from: owner)
    }
}
