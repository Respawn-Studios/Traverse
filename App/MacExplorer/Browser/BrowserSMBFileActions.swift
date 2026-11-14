import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor extension BrowserViewController {
    @objc func moveServerSelection(_ sender: Any?) {
        if isSFTPLocation, let owner = sftpTabs[activeID] { sftpFileActions.requestMove(from: owner); return }
        guard isSMBLocation, let owner = smbTabs[activeID] else { return }
        smbFileActions.request(.move, from: owner)
    }

    @objc func copyServerSelection(_ sender: Any?) {
        if isSFTPLocation, let owner = sftpTabs[activeID] { sftpFileActions.requestCopy(from: owner); return }
        guard isSMBLocation, let owner = smbTabs[activeID] else { return }
        smbFileActions.requestCopy(from: owner)
    }
}

@MainActor enum SMBRemoteActionFeature {
    #if DEBUG
    static var qualifying = false
    static var qualifyingDirectories = false
    static var qualifyingMoves = false
    static var qualifyingCopies = false
    #endif
    // Qualified same-share regular-file Copy uses the server's copy command.
    // It never falls back through Download or replaces an occupied name.
    private static let serverCopyAccepted = true
    static var copiesAvailable: Bool {
        #if DEBUG
        if qualifying && qualifyingCopies { return true }
        #endif
        return available && serverCopyAccepted
    }
    static var directoriesAvailable: Bool {
        #if DEBUG
        if qualifying && qualifyingDirectories { return true }
        #endif
        return available && AppFeatureAvailability.allows(.serverDirectoryActions)
    }
    static var movesAvailable: Bool {
        #if DEBUG
        if qualifying && qualifyingMoves { return true }
        #endif
        return available && AppFeatureAvailability.allows(.serverMove)
    }
    static var available: Bool {
        #if DEBUG
        if qualifying { return true }
        #endif
        return AppFeatureAvailability.allows(.serverActions)
    }
}

/// The native command owner delegates all mutation and durable outcomes to the
/// authenticated SMB session. Displayed names/paths never become local file URLs.
@MainActor final class BrowserSMBFileActions {
    private weak var browser: BrowserViewController?
    private var work: Task<Void, Never>?
    private var remoteUndoBarrier = false, localRecordAtBarrier: UUID?
    var blocksImplicitUndo: Bool { remoteUndoBarrier && browser?.lastRecoveryRecordID == localRecordAtBarrier }
    #if DEBUG
    var confirmDeleteForVerification: (() async -> Bool)?
    var destinationForVerification: ((RemoteMoveDestinationModel) async -> String?)?
    private(set) var lastOutcome: SMBActionOutcome?
    #endif
    init(browser: BrowserViewController) { self.browser = browser }

    func requestClipboardPaste(_ context: ScopedItemPaste, from owner: SMBTabController) {
        guard context.intent.smbOwner === owner, let browser,
              context.isCurrent(), context.intent.canPaste(in: browser) else { return }
        request(context.intent.operation == .copy ? .copy : .move, from: owner, clipboard: context)
    }

    func canRequest(from owner: SMBTabController) -> Bool {
        guard SMBRemoteActionFeature.available, work == nil, let browser,
              !browser.isBrowserSuspended, browser.canRunExclusiveFileCommand, browser.hasFileCommandFocus,
              browser.view.window?.attachedSheet == nil, browser.smbTabs[browser.activeID] === owner,
              let value = owner.sealedFileAction, !value.row.isReparsePoint,
              !value.row.isDirectory || SMBRemoteActionFeature.directoriesAvailable,
              value.row.attributes & 0x450 == (value.row.isDirectory ? 0x10 : 0),
              let object = value.row.objectID, object > 0, object != UInt64.max,
              let parent = value.row.parentID, parent > 0, parent != UInt64.max, parent != object else { return false }
        return true
    }

    func canCopy(from owner: SMBTabController) -> Bool {
        guard SMBRemoteActionFeature.copiesAvailable, canRequest(from: owner),
              let captured = owner.sealedFileAction, !captured.row.isDirectory else { return false }
        // A long original name may need editing in Copy To. Admission must not
        // depend on whether the convenience Duplicate suffix fits that name.
        let probeName = captured.row.name.displayName.caseInsensitiveCompare("Copy") == .orderedSame ? "Copy 2" : "Copy"
        return (try? SMBSelectedActionRequest(connection: owner.connectionID, snapshot: captured.snapshot,
            directory: captured.components, observation: captured.row,
            copyTo: captured.components, as: probeName)) != nil
    }

    private typealias Selection = (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName], row: SMBDirectoryObservation)
    private static func copyName(_ name: String, owner: SMBTabController,
                                 snapshot: SMBDirectorySnapshot) -> String {
        let original = name as NSString
        let ext = original.pathExtension
        let candidate = original.deletingPathExtension + " copy" + (ext.isEmpty ? "" : "." + ext)
        return owner.rows.suggestedNewName(candidate, in: snapshot)
    }

    func requestCopy(from owner: SMBTabController, duplicate: Bool = false) {
        guard canCopy(from: owner) else { return }
        request(.copy, from: owner, duplicate: duplicate)
    }

    func request(_ kind: SMBActionOperation, from owner: SMBTabController, clipboard: ScopedItemPaste? = nil,
                 duplicate: Bool = false) {
        guard kind == .rename || kind == .delete || kind == .move && SMBRemoteActionFeature.movesAvailable
                || kind == .copy && SMBRemoteActionFeature.copiesAvailable && (clipboard != nil || canCopy(from: owner)),
              !duplicate || kind == .copy,
              let browser, work == nil,
              clipboard.map({ (kind == .move && $0.intent.operation == .move || kind == .copy && $0.intent.operation == .copy)
                    && $0.isCurrent() && $0.intent.smbOwner === owner && $0.intent.canPaste(in: browser) })
                ?? canRequest(from: owner),
              let storage = owner.remoteActions, case .smb = browser.location else { return }
        let clipboardSource: SMBClipboardSource? = clipboard.flatMap { if case .smb(let source) = $0.intent.source { source } else { nil } }
        let destinationAtPaste = clipboard == nil ? nil : owner.clipboardDestination
        let captured: (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName], row: SMBDirectoryObservation)
        if let clipboardSource, let destination = owner.clipboardDestination {
            captured = (destination.snapshot, clipboardSource.directory, clipboardSource.row)
        } else if let selected = owner.sealedFileAction { captured = selected }
        else { return }
        let folder = captured.row.isDirectory, connection = owner.connectionID
        let tab = browser.activeID, visit = browser.sessionID, preparation = UUID()
        let coordinator = browser.operationCoordinator
        guard coordinator.beginPreparation(owner: preparation) else { return }
        let renameRequest = kind == .rename ? browser.inlineRename.reserveRemote(owner: owner) : nil
        browser.operationPreparationID = preparation
        let action: DiagnosticAction = kind == .rename ? .rename : kind == .move ? .move : kind == .copy ? .copy : .fileOperation
        let diagnostics = ApplicationDiagnostics.shared, trace = diagnostics.begin(action)
        #if DEBUG
        lastOutcome = nil
        #endif
        work = Task<Void, Never> { [self, browser, owner] in
            var started = false, recorded = false, diagnosticRequestID: UUID?
            var captured = captured
            var observedClipboardSource = false, retainClipboard = false, clipboardFinished = false
            defer {
                if !clipboardFinished { clipboard?.finish(confirmed: false, canRetain: retainClipboard && !Task.isCancelled && owner.session.latest.failure == nil) }
                if observedClipboardSource { owner.restoreAfterClipboardSourceObservation() }
                if !recorded { diagnostics.event(action, .cancelled, trace: trace, context: .init(.queueTerminal)) }
                if let renameRequest { browser.inlineRename.cancel(requestID: renameRequest) }
                work = nil
                if started { browser.finishOperationPresentation() }
                else { coordinator.finishPreparation(owner: preparation); browser.operationPreparationTask = nil; browser.operationPreparationID = nil }
            }
            @MainActor func inputCurrent() -> Bool {
                guard !Task.isCancelled, !browser.isBrowserSuspended, browser.activeID == tab,
                      browser.sessionID == visit, browser.smbTabs[tab] === owner,
                      !owner.isClosing, owner.session.latest.failure == nil, clipboard?.isCurrent() ?? true else { return false }
                return true
            }
            @MainActor func current() -> Bool {
                guard inputCurrent() else { return false }
                if clipboard != nil, observedClipboardSource {
                    return owner.session.latest.idle && owner.session.latest.snapshot == captured.snapshot
                }
                guard let value = owner.sealedFileAction else { return false }
                return value.snapshot == captured.snapshot && value.components == captured.components && value.row == captured.row
            }
            func makeRenameRequest(to name: String) throws -> SMBSelectedActionRequest {
                if folder {
                    return try .init(connection: connection, snapshot: captured.snapshot,
                        directory: captured.components, observation: captured.row, renameDirectoryTo: name)
                }
                return try .init(connection: connection, snapshot: captured.snapshot,
                    directory: captured.components, observation: captured.row, renameTo: name)
            }
            do {
                if let clipboardSource {
                    observedClipboardSource = true
                    captured = try await owner.reobserveClipboardSource(clipboardSource, preparation: preparation,
                        operation: clipboard?.intent.operation ?? .move, current: inputCurrent)
                    guard current() else { return }
                    retainClipboard = true
                }
                let request: SMBSelectedActionRequest
                if kind == .rename {
                    guard let renameRequest else { return }
                    let original = captured.row.name.displayName
                    let validate: (String) -> String? = { name in
                        guard current(), let checked = try? SMBRemoteName(name) else { return "The selection changed or the name is unavailable. Cancel and try again." }
                        if checked.wireUTF16 == captured.row.name.wireUTF16 { return nil }
                        do {
                            _ = try makeRenameRequest(to: name)
                        } catch SMBActionFailure.caseOnlyRename {
                            return "Changing only letter case is not available here yet. No server change will be sent."
                        } catch {
                            return "Choose a valid filename without path separators or control characters."
                        }
                        return owner.rows.hasLoadedName(checked, in: captured.snapshot) ? "That name already exists. Choose another name." : nil
                    }
                    let answer: String?
                    if let prompt = browser.operationNamePrompt { answer = await prompt("Rename", original) }
                    else { answer = await browser.inlineRename.beginRemote(owner: owner, name: original, requestID: renameRequest, validating: validate) }
                    guard let name = answer, current(), validate(name) == nil,
                          browser.inlineRename.consumeRemote(requestID: renameRequest) else { return }
                    guard (try? SMBRemoteName(name).wireUTF16) != captured.row.name.wireUTF16 else { return }
                    request = try makeRenameRequest(to: name)
                } else if kind == .copy {
                    guard let answer = try await chooseCopyRequest(from: owner, selection: captured,
                        duplicate: duplicate, requestedDestination: destinationAtPaste,
                        browser: browser, current: current) else { return }
                    request = answer
                } else if kind == .move {
                    guard let window = browser.view.window else { return }
                    if clipboard != nil, !owner.reviewsUploads {
                        guard current(), let destinationAtPaste else { return }
                        request = try .init(connection: connection, snapshot: captured.snapshot,
                            directory: captured.components, observation: captured.row, moveTo: destinationAtPaste.components)
                    } else {
                    let original = "/" + captured.components.map(\.displayName).joined(separator: "/")
                    let model = RemoteMoveDestinationModel(name: captured.row.name.displayName, isFolder: folder,
                        server: owner.root.displayHint, currentFolder: original,
                        suggestions: owner.moveDestinationSuggestions(excluding: captured.components),
                        initialPath: destinationAtPaste.map { "/" + $0.components.map(\.displayName).joined(separator: "/") },
                        validate: { path in
                            guard current() else { return "The selection changed. Cancel and choose the item again." }
                            guard let destination = try? SMBMoveDestination(field: path) else {
                                return "Enter /folder within this share, or choose Share Root."
                            }
                            if destination.components == captured.components { return "Choose a different folder." }
                            guard (try? SMBSelectedActionRequest(connection: connection, snapshot: captured.snapshot,
                                directory: captured.components, observation: captured.row,
                                moveTo: destination.components)) != nil else {
                                return "Choose another destination outside this folder and its contents."
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
                          let destination = try? SMBMoveDestination(field: path) else { return }
                    request = try .init(connection: connection, snapshot: captured.snapshot,
                        directory: captured.components, observation: captured.row, moveTo: destination.components)
                    }
                } else {
                    guard let window = browser.view.window else { return }
                    let confirmed: Bool
                    #if DEBUG
                    if let confirmDeleteForVerification { confirmed = await confirmDeleteForVerification() }
                    else { confirmed = await RemoteDeleteConfirmation.confirm(name: captured.row.name.displayName, destination: owner.uploadDestinationDescription, emptyFolder: folder, in: window) }
                    #else
                    confirmed = await RemoteDeleteConfirmation.confirm(name: captured.row.name.displayName, destination: owner.uploadDestinationDescription, emptyFolder: folder, in: window)
                    #endif
                    guard confirmed, current() else { return }
                    if folder {
                        request = try .init(connection: owner.connectionID, snapshot: captured.snapshot,
                            directory: captured.components, observation: captured.row, permanentlyDeleteEmptyDirectory: true)
                    } else {
                        request = try .init(connection: owner.connectionID, snapshot: captured.snapshot,
                            directory: captured.components, observation: captured.row, permanentlyDelete: true)
                    }
                }
                diagnosticRequestID = request.request
                let subject = folder ? "folder" : "file"
                let progress = kind == .rename ? "Renaming server \(subject)…"
                    : kind == .move ? "Moving server \(subject)…"
                    : kind == .copy ? "Copying file on server…" : "Deleting server \(subject)…"
                guard current(), browser.startOperationPresentation(progress, preparation: preparation, diagnosticTrace: trace) else { return }
                started = true; browser.operationPreparationTask = nil; browser.operationPreparationID = nil; browser.operationTask = work
                diagnostics.event(action, .preparing, trace: trace, context: .init(.queueMutation), relatedTrace: request.request)
                let result = try await perform(request, storage: storage, owner: owner,
                    browser: browser, name: captured.row.name.displayName)
                let confirmed = result.outcome == .confirmed
                if let clipboard {
                    clipboard.finish(confirmed: confirmed, canRetain: result.outcome == .collision && owner.session.latest.failure == nil)
                    clipboardFinished = true
                }
                if confirmed { remoteUndoBarrier = true; localRecordAtBarrier = browser.lastRecoveryRecordID }
                let message: String
                switch result.outcome {
                case .confirmed:
                    message = kind == .rename ? "Server \(subject) renamed."
                        : kind == .move ? "Server \(subject) moved."
                        : kind == .copy ? "Server file copied. The original was kept." : "Server \(subject) deleted permanently."
                case .collision: message = "That name already exists. Both existing items were kept."
                case .stageCollision: message = "A temporary copy already exists. No existing file was changed. Review File Actions in Connection Activity."
                case .finalCollision: message = "The destination name became occupied. The original and temporary copy were kept. Review File Actions in Connection Activity."
                case .notEmpty: message = "The folder is not empty. No items were deleted."
                default: throw SMBActionFailure.reviewRequired
                }
                diagnostics.event(action, confirmed ? .completed : .blocked, trace: trace, context: .init(.queueTerminal), relatedTrace: result.id)
                recorded = true
                owner.showTransferOutcome(message, needsAttention: result.outcome == .stageCollision || result.outcome == .finalCollision,
                    showsUploadHistory: false)
                if browser.smbTabs[browser.activeID] === owner { browser.status.stringValue = message }
                if confirmed, kind == .move, folder {
                    owner.invalidateMovedDescendants(directory: captured.components, name: captured.row.name)
                }
                if clipboard == nil, owner.session.latest.failure == nil { owner.refreshAfterUpload() }
                #if DEBUG
                lastOutcome = result.outcome
                #endif
            } catch {
                retainClipboard = false
                let uncertain = error as? SMBActionFailure == .reviewRequired
                if uncertain { remoteUndoBarrier = true; localRecordAtBarrier = browser.lastRecoveryRecordID }
                let message: String
                if !started, let failure = error as? RemoteSourceObservationFailure {
                    message = failure.userMessage
                } else if uncertain {
                    message = "The server action could not be confirmed. Review File Actions in Connection Activity before trying again."
                    owner.uploadNotice = message
                    _ = await owner.close().value
                } else if error as? RemoteSettingsFailure == .capacity {
                    message = "File Action History is full. Review old local records in Connection Activity."
                } else if error as? RemoteSettingsFailure == .recoveryRequired {
                    message = "A local action-history update was interrupted. Review Connection Activity before trying again."
                } else if error as? SMBActionFailure == .destinationUnavailable,
                          owner.session.latest.failure == nil {
                    message = "The destination folder is missing or access was denied. No change was sent. Choose another folder."
                } else if case .preflightRefused = error as? SMBActionFailure {
                    message = "The server item’s details could not be verified. No change was sent. Reconnect to inspect it before trying again."
                    owner.uploadNotice = message
                    _ = await owner.close().value
                } else if owner.session.latest.failure != nil {
                    message = "This connection ended before the action could be confirmed. Reconnect to inspect the item and review Connection Activity."
                    owner.uploadNotice = message
                    _ = await owner.close().value
                } else { message = Task.isCancelled ? "Server action stopped." : "The selected item could not be changed. Refresh and try again." }
                if kind == .move || kind == .copy, let diagnosticRequestID,
                   let checkpoint = owner.session.actionDiagnosticCheckpoint(for: diagnosticRequestID) {
                    // Fixed worker checks and local completion boundaries; no paths or server data.
                    diagnostics.event(action, .interrupted, trace: trace,
                        error: .init(domain: .network, code: (kind == .copy ? 1650 : 1640) + Int64(checkpoint)),
                        context: .init(.queueMutation), relatedTrace: diagnosticRequestID)
                }
                diagnostics.event(action, uncertain ? .interrupted : .failed, trace: trace,
                    error: Self.diagnosticError(error), context: .init(.queueTerminal))
                recorded = true
                owner.uploadNotice = message
                if browser.smbTabs[browser.activeID] === owner { browser.status.stringValue = message }
            }
        }
        browser.operationPreparationTask = work
    }
    private func chooseCopyRequest(from owner: SMBTabController, selection: Selection, duplicate: Bool,
        requestedDestination: (snapshot: SMBDirectorySnapshot, components: [SMBRemoteName])? = nil,
        browser: BrowserViewController, current: @escaping @MainActor () -> Bool) async throws -> SMBSelectedActionRequest? {
        let connection = owner.connectionID
        let visibleSnapshot = requestedDestination?.snapshot ?? selection.snapshot
        let visibleDirectory = requestedDestination?.components ?? selection.components
        let inPlace = duplicate || requestedDestination?.components == selection.components
        let suggested = Self.copyName(selection.row.name.displayName, owner: owner, snapshot: visibleSnapshot)
        if !owner.reviewsUploads, let destination = requestedDestination?.components ?? (duplicate ? selection.components : nil),
           let automatic = try? SMBSelectedActionRequest(connection: connection, snapshot: selection.snapshot,
                directory: selection.components, observation: selection.row,
                copyTo: destination, as: inPlace ? suggested : selection.row.name.displayName) {
            return current() ? automatic : nil
        }
        guard let window = browser.view.window else { return nil }
        let original = "/" + selection.components.map(\.displayName).joined(separator: "/")
        let model = RemoteMoveDestinationModel(name: selection.row.name.displayName,
            server: owner.root.displayHint, currentFolder: original,
            suggestions: owner.moveDestinationSuggestions(excluding: selection.components),
            initialPath: requestedDestination.map { "/" + $0.components.map(\.displayName).joined(separator: "/") },
            destinationNotice: "The original stays here. Existing items are kept.",
            operation: inPlace ? .duplicate : .copy,
            initialName: inPlace ? suggested : selection.row.name.displayName,
            validateCopy: { path, name in
                guard current(), let destination = try? SMBMoveDestination(field: path),
                      let checked = try? SMBRemoteName(name) else {
                    return "Enter a valid filename without path separators or control characters."
                }
                guard (try? SMBSelectedActionRequest(connection: connection, snapshot: selection.snapshot,
                    directory: selection.components, observation: selection.row,
                    copyTo: destination.components, as: name)) != nil else {
                    return "Choose a different name or folder for the copy."
                }
                return destination.components == visibleDirectory
                    && owner.rows.hasLoadedName(checked, in: visibleSnapshot)
                    ? "That name already exists. Choose another name." : nil
            }, validate: { path in
                guard current() else { return "The selection changed. Cancel and choose the file again." }
                return (try? SMBMoveDestination(field: path)) == nil
                    ? "Enter /folder within this share, or choose Share Root." : nil
            })
        let answer: String?
        #if DEBUG
        if let destinationForVerification { answer = await destinationForVerification(model) }
        else { answer = await RemoteMoveDestination(model: model, settings: browser.settings).choose(in: window) }
        #else
        answer = await RemoteMoveDestination(model: model, settings: browser.settings).choose(in: window)
        #endif
        guard let path = answer, path == model.path, current(), model.canMove,
              let destination = try? SMBMoveDestination(field: path) else { return nil }
        return try .init(connection: connection, snapshot: selection.snapshot,
            directory: selection.components, observation: selection.row,
            copyTo: destination.components, as: model.destinationName)
    }

    private func perform(_ request: SMBSelectedActionRequest, storage: SMBActionStorage,
        owner: SMBTabController, browser: BrowserViewController, name: String) async throws -> SMBCompletedAction {
        guard request.operation == .copy else { return try await owner.session.perform(request, storage: storage) }
        let updates = AsyncStream.makeStream(of: (UInt64, UInt64).self, bufferingPolicy: .bufferingNewest(1))
        let progress = Task<Void, Never> { [weak browser] in
            for await (copied, total) in updates.stream {
                guard let browser, !browser.operationStopRequested else { continue }
                let finishing = copied >= total
                browser.operationPresentation = .init(phaseTitle: finishing ? "Finishing copy" : "Copy on server",
                    percentage: total == 0 || finishing ? nil : min(1, Double(copied) / Double(total)),
                    summary: "Original kept · existing names are kept.", currentItem: name,
                    completedText: FileSizeText.string(Int64(clamping: copied)) + " copied on server")
                browser.updateOperationProgressControls()
            }
        }
        defer { updates.continuation.finish(); progress.cancel() }
        do {
            let result = try await owner.session.perform(request, storage: storage, progress: { copied, total in
                _ = updates.continuation.yield((copied, total))
            })
            updates.continuation.finish(); await progress.value
            return result
        } catch {
            updates.continuation.finish(); await progress.value
            throw error
        }
    }

    private static func diagnosticError(_ error: Error) -> DiagnosticErrorCode {
        if error is RemoteSettingsFailure { return DiagnosticErrors.project(error) }
        let code: Int64
        switch error {
        case SMBActionFailure.invalidInput: code = 1601
        case SMBActionFailure.caseOnlyRename: code = 1602
        case SMBActionFailure.unavailable: code = 1603
        case SMBActionFailure.busy: code = 1604
        case SMBActionFailure.stopped: code = 1605
        case SMBActionFailure.collision: code = 1606
        case SMBActionFailure.destinationUnavailable: code = 1631
        case SMBActionFailure.reviewRequired: code = 1607
        case let SMBActionFailure.preflightRefused(reason): code = 1620 + Int64(reason.rawValue)
        case SMBBrowserFailure.invalidInput: code = 1601
        case SMBBrowserFailure.invalidOutput: code = 1608
        case SMBBrowserFailure.busy: code = 1604
        case SMBBrowserFailure.stopped: code = 1605
        case SMBBrowserFailure.authentication: code = 1615
        case SMBBrowserFailure.denied: code = 1616
        case SMBBrowserFailure.security: code = 1617
        case SMBBrowserFailure.storage: code = 1612
        case SMBBrowserFailure.quota: code = 1613
        case SMBBrowserFailure.deadline: code = 1610
        case SMBBrowserFailure.containment: code = 1618
        case SMBBrowserFailure.remote: code = 1611
        default: code = error is CancellationError ? 1605 : 1603
        }
        return .init(domain: .network, code: code)
    }
}
