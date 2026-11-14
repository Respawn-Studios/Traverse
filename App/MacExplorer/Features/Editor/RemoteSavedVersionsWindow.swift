import AppKit
import FileOperations
@_spi(Qualification) import LocalStorage

/// A native source list of validated metadata. Selecting a row/version never
/// reads text. Only Review opens one checked body in the read-only editor.
@MainActor final class RemoteSavedVersionsWindow: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let source: RemoteSavedVersionsLoader?
    private let context: RemoteSavedVersionsContext
    private unowned let libraryOwner: ApplicationRemoteSavedVersions
    let table = NSTableView()
    let version = NSPopUpButton()
    let review = NSButton(title: "Review Version…", target: nil, action: nil)
    let retainedDocument = NSPopUpButton()
    let removeCopies = NSButton(title: "Remove Local Versions…", target: nil, action: nil)
    private var removalChoices: [SFTPRetainedDocumentChoice] = []
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let fileLabel = NSTextField(wrappingLabelWithString: "Select a retained file")
    private let identityLabel = NSTextField(wrappingLabelWithString: "")
    private let outcomeLabel = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private(set) var allChoices: [RemoteRetainedTextChoice] = []
    /// Preserve the existing SFTP native observer's concrete read capabilities.
    var choices: [SFTPInPlaceRecoveryChoice] {
        allChoices.compactMap { if case .sftp(let choice) = $0 { choice } else { nil } }
    }
    private(set) var work: Task<Void, Never>?, draining: Task<Void, Never>?
    private(set) var viewer: RemoteTextRecoveryController?
    private var metadataCurrent = false, closing = false, closed = false
    private var retirementMetadataCurrent = false
    private var metadataEpoch = UUID(), refreshAfterWork = false
    #if DEBUG
    var gateAReviewVisible = true
    #endif
    private var closingTask: Task<Void, Never>?
    var didClose: (() -> Void)?

    init(source: RemoteSavedVersionsLoader?, context: RemoteSavedVersionsContext,
         owner: ApplicationRemoteSavedVersions) {
        self.source = source; self.context = context; self.libraryOwner = owner
        let native = ToolWindowChrome.makeWindow(title: "Saved Versions", size: .init(width: 840, height: 550),
            minimumSize: .init(width: 700, height: 450))
        super.init(window: native)
        native.delegate = self
        buildContent(in: native)
        ToolWindowChrome.install(in: native, settings: context.settings)
        ToolWindowChrome.position(native, relativeTo: NSApp.mainWindow); update()
    }
    required init?(coder: NSCoder) { nil }

    private func buildContent(in native: NSWindow) {
        let heading = NSTextField(labelWithString: "Saved Versions")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString:
            "Retained server text · Review a local before/edited version. This does not connect to the server or confirm an earlier Save.")
        introduction.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        table.style = .sourceList; table.headerView = nil
        table.backgroundColor = .clear; table.focusRingType = .default
        table.selectionHighlightStyle = .regular
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        InterfaceMetrics.setRowHeight(table, base: 54)
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: .init("retained-file")))
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("Retained server files")
        scroll.documentView = table
        fileLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        identityLabel.textColor = .secondaryLabelColor
        let warning = NSTextField(wrappingLabelWithString:
            "The result describes the earlier operation. It does not describe the current server file. Export is available inside the read-only review.")
        warning.textColor = .secondaryLabelColor
        version.setAccessibilityLabel("Retained version")
        version.target = self; version.action = #selector(changeVersion(_:))
        review.target = self; review.action = #selector(reviewSelected(_:))
        review.setAccessibilityLabel("Review selected retained version")
        let detail = NSStackView(views: [fileLabel, identityLabel, outcomeLabel, version, review, warning])
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 14
        let columns = NSStackView(views: [scroll, detail]); columns.spacing = 24; columns.alignment = .top
        scroll.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            scroll.heightAnchor.constraint(equalTo: columns.heightAnchor),
            detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 290)])
        refreshButton.target = self; refreshButton.action = #selector(refreshPressed(_:))
        stopButton.target = self; stopButton.action = #selector(stopPressed(_:))
        retainedDocument.setAccessibilityLabel("Closed document local copies")
        retainedDocument.target = self; retainedDocument.action = #selector(removalSelectionChanged(_:))
        removeCopies.target = self; removeCopies.action = #selector(removeSelectedCopies(_:))
        let removal = NSStackView(views: [retainedDocument, removeCopies]); removal.spacing = 10
        removal.isHidden = source?.documents == nil || source?.removeDocument == nil
        let actions = NSStackView(views: [refreshButton, stopButton]); actions.spacing = 10
        status.textColor = .secondaryLabelColor
        let content = NSStackView(views: [heading, introduction, columns, status, removal, actions])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(); host.addSubview(content); native.contentView = host
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22),
            columns.widthAnchor.constraint(equalTo: content.widthAnchor),
            columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            introduction.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)])
    }
    func numberOfRows(in tableView: NSTableView) -> Int { allChoices.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard allChoices.indices.contains(row) else { return nil }
        let display = allChoices[row].presentation
        let primary = NSTextField(labelWithString: display.fileName)
        InterfaceMetrics.setFont(primary, base: .systemFont(ofSize: NSFont.systemFontSize))
        primary.lineBreakMode = .byTruncatingMiddle
        let secondary = NSTextField(labelWithString: allChoices[row].protocolName + " · " + rowOutcome(allChoices[row].outcome)
            + " · " + display.account + " · " + display.server)
        InterfaceMetrics.setFont(secondary, base: .systemFont(ofSize: 11))
        secondary.textColor = .secondaryLabelColor
        secondary.lineBreakMode = .byTruncatingTail
        secondary.toolTip = secondary.stringValue
        let stack = NSStackView(views: [primary, secondary]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 3
        let cell = NSTableCellView(); cell.textField = primary
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    private func rowOutcome(_ outcome: RemoteRetainedTextChoice.Outcome) -> String {
        switch outcome {
        case .retainedRead: "Original copy"
        case .notStarted: "Not saved to server"
        case .needsReview: "Save needs review"
        case .verified: "Saved earlier"
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectedMetadataChanged() }
    private var selected: RemoteRetainedTextChoice? {
        allChoices.indices.contains(table.selectedRow) ? allChoices[table.selectedRow] : nil
    }
    private func selectedMetadataChanged() {
        version.removeAllItems()
        guard let selected else {
            fileLabel.stringValue = "Select a retained file"; identityLabel.stringValue = ""
            outcomeLabel.stringValue = ""; update(); return
        }
        fileLabel.stringValue = selected.presentation.fileName
        identityLabel.stringValue = selected.protocolName + " · " + selected.presentation.account + " · " + selected.presentation.server
        switch selected.outcome {
        case .retainedRead: outcomeLabel.stringValue = "Retained original · no Save result"
        case .notStarted: outcomeLabel.stringValue = "Earlier Save was not submitted"
        case .needsReview: outcomeLabel.stringValue = "Earlier remote Save needs review"
        case .verified: outcomeLabel.stringValue = "Earlier Save was verified at the time"
        }
        for value in selected.availableVersions {
            version.addItem(withTitle: value == .before ? "Before Save" : "Edited Text (Save capture)")
        }
        update()
    }
    private func update() {
        let ready = !closing && !closed && work == nil && draining == nil && libraryOwner.acceptsDemand
        refreshButton.isEnabled = ready && source != nil
        retainedDocument.isEnabled = ready && metadataCurrent && retirementMetadataCurrent && !removalChoices.isEmpty
        removeCopies.isEnabled = ready && metadataCurrent && retirementMetadataCurrent && source?.removeDocument != nil
            && removalChoices.indices.contains(retainedDocument.indexOfSelectedItem)
        if removalChoices.indices.contains(retainedDocument.indexOfSelectedItem) {
            removeCopies.title = removalChoices[retainedDocument.indexOfSelectedItem].removalPending
                ? "Resume Local Removal…" : "Remove Local Versions…"
        }
        table.isEnabled = ready
        version.isEnabled = ready && metadataCurrent && selected != nil
        review.isEnabled = ready && metadataCurrent && selected != nil && !version.itemTitles.isEmpty
        stopButton.isEnabled = !closing && !closed && work != nil && draining == nil
    }
    @objc private func changeVersion(_ sender: Any?) { update() }
    @objc private func refreshPressed(_ sender: Any?) { refreshChoices() }
    @objc private func stopPressed(_ sender: Any?) { stop() }
    /// A committed workspace upgrade changes the location witness. Existing
    /// viewers keep their actual pins; obsolete metadata cannot admit a read.
    func workspaceDidChange() {
        metadataEpoch = UUID(); metadataCurrent = false; retirementMetadataCurrent = false
        refreshAfterWork = true
        if work == nil && draining == nil { finishedWork() } else { update() }
    }
    private func finishedWork() {
        work = nil
        if refreshAfterWork, !closing, !closed, draining == nil {
            refreshAfterWork = false; refreshChoices()
        } else { update() }
    }
    func refreshChoices() {
        guard !closing, !closed, libraryOwner.acceptsDemand, work == nil, draining == nil else { return }
        guard let source else {
            metadataCurrent = false
            status.stringValue = "Persistent Saved Versions storage has not been admitted. Existing retained data stays protected."
            update(); return
        }
        metadataCurrent = false; retirementMetadataCurrent = false; status.stringValue = "Checking retained metadata…"
        metadataEpoch = UUID(); let epoch = metadataEpoch
        let logger = ApplicationDiagnostics.shared
        let trace = logger.begin(.fileOperation)
        work = Task { [self] in
            var checkpoint = DiagnosticCheckpoint.textRecordProjection
            do {
                logger.event(.fileOperation, .reading, trace: trace, context: .init(checkpoint))
                var retainedDocuments: [SFTPRetainedDocumentChoice]?
                var result: [SFTPInPlaceRecoveryChoice] = []
                var incompleteCount = 0, sftpMetadataUnavailable = false, smbMetadataUnavailable = false
                do {
                    if let listing = source.listing {
                        let snapshot = try await listing()
                        result = snapshot.choices; incompleteCount = snapshot.incompleteReceiveCount
                    } else {
                        result = try await source.load(); incompleteCount = 0
                    }
                }
                catch {
                    try Task.checkCancellation()
                    checkpoint = .textRecordHead
                    logger.event(.fileOperation, .reading, trace: trace, context: .init(checkpoint))
                    let documents: [SFTPRetainedDocumentChoice]
                    do { documents = try await source.documents?() ?? [] }
                    catch { try Task.checkCancellation(); documents = [] }
                    if documents.contains(where: { $0.removalPending }) {
                        // A committed partial removal excludes ordinary readers.
                        // Its exact document is still offered for explicit Resume.
                        retainedDocuments = documents.filter(\.removalPending)
                    } else {
                        sftpMetadataUnavailable = true
                        logger.event(.fileOperation, .partial, trace: trace, error: DiagnosticErrors.project(error),
                            context: .init(checkpoint))
                    }
                    result = []; incompleteCount = 0
                }
                try Task.checkCancellation()
                var available = result.map(RemoteRetainedTextChoice.sftp)
                if let loadSMB = source.smbLoad {
                    do { available += try await loadSMB().map(RemoteRetainedTextChoice.smb) }
                    catch {
                        try Task.checkCancellation(); smbMetadataUnavailable = true
                        logger.event(.fileOperation, .partial, trace: trace, error: DiagnosticErrors.project(error),
                            context: .init(checkpoint))
                    }
                }
                guard (0...64).contains(incompleteCount) else { throw RemoteSettingsFailure.capacity }
                let documents: [SFTPRetainedDocumentChoice]
                if let retainedDocuments { documents = retainedDocuments }
                else if incompleteCount > 0 || sftpMetadataUnavailable {
                    // Read-only discovery qualified these incomplete siblings.
                    // Retirement keeps its strict admission and is not invoked.
                    documents = []
                } else {
                    checkpoint = .textRecordHead
                    logger.event(.fileOperation, .reading, trace: trace, context: .init(checkpoint))
                    do { documents = try await source.documents?() ?? [] }
                    catch {
                        try Task.checkCancellation(); sftpMetadataUnavailable = true; documents = []
                        logger.event(.fileOperation, .partial, trace: trace, error: DiagnosticErrors.project(error),
                            context: .init(checkpoint))
                    }
                }
                guard documents.count <= 64 else { throw RemoteSettingsFailure.capacity }
                removalChoices = documents; retainedDocument.removeAllItems()
                for choice in documents {
                    retainedDocument.addItem(withTitle: choice.presentation.fileName + " · " + String(choice.copyCount)
                        + " local copies" + (choice.removalPending ? " · removal pending" : ""))
                }
                guard !closing, libraryOwner.acceptsDemand, epoch == metadataEpoch else { throw CancellationError() }
                guard available.count <= 64 else {
                    allChoices = []; table.reloadData(); selectedMetadataChanged()
                    status.stringValue = "Too many retained records for this view. Nothing was hidden or removed."
                    finishedWork(); return
                }
                let partialMetadata = sftpMetadataUnavailable || smbMetadataUnavailable
                allChoices = available; metadataCurrent = !partialMetadata || !available.isEmpty
                retirementMetadataCurrent = !partialMetadata && incompleteCount == 0
                table.reloadData()
                if !allChoices.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                selectedMetadataChanged()
                if partialMetadata {
                    status.stringValue = allChoices.isEmpty
                        ? "Saved-version metadata could not be checked. Existing copies stay protected; Refresh to check again."
                        : "Some saved-version metadata could not be checked. Available versions can still be reviewed; existing data is kept."
                } else if incompleteCount > 0 {
                    let kept = incompleteCount == 1 ? "An unfinished download was kept." : "\(incompleteCount) unfinished downloads were kept."
                    status.stringValue = kept + (allChoices.isEmpty
                        ? " No complete saved versions are available yet."
                        : " You can review the available saved versions.")
                    logger.event(.fileOperation, .retaining, trace: trace, count: UInt64(incompleteCount),
                                 context: .init(.textRecordProjection))
                } else {
                    status.stringValue = !documents.isEmpty && allChoices.isEmpty
                    ? "Local removal pending · choose the closed document and Resume explicitly. The server is unchanged."
                    : allChoices.isEmpty ? "No retained server versions were found in this workspace."
                        : "Metadata checked · select a version, then Review"
                }
                logger.event(.fileOperation, incompleteCount > 0 || partialMetadata ? .partial : .completed,
                             trace: trace, count: UInt64(allChoices.count), context: .init(checkpoint))
            } catch {
                metadataCurrent = false
                status.stringValue = "Retained metadata could not be verified. Existing versions stay protected; no server connection or body read was started by discovery."
                logger.event(.fileOperation, error is CancellationError ? .cancelled : .failed,
                             trace: trace, error: DiagnosticErrors.project(error),
                             context: .init(checkpoint), causes: DiagnosticErrors.causes(error))
            }
            finishedWork()
        }
        update()
    }
    @objc private func removalSelectionChanged(_ sender: Any?) { update() }
    @objc private func removeSelectedCopies(_ sender: Any?) {
        guard !closing, !closed, libraryOwner.acceptsDemand, work == nil, draining == nil, metadataCurrent, retirementMetadataCurrent,
              removalChoices.indices.contains(retainedDocument.indexOfSelectedItem),
              let remove = source?.removeDocument else { return }
        let choice = removalChoices[retainedDocument.indexOfSelectedItem]
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = choice.removalPending ? "Resume removal of all local versions?" : "Remove all local versions of this closed document?"
        alert.informativeText = choice.presentation.fileName + " · " + choice.presentation.account + " · " + choice.presentation.server
            + "\n" + String(choice.copyCount) + " distinct local copies. This removes the whole retained document history. It does not change the server file or confirm an earlier Save. This cannot be undone."
        alert.addButton(withTitle: choice.removalPending ? "Resume Local Removal" : "Remove Local Versions")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        metadataCurrent = false; status.stringValue = "Removing selected local copies… server unchanged"
        work = Task { [self] in
            do {
                try await remove(choice); try Task.checkCancellation()
                status.stringValue = "Local versions removed · server unchanged. Refresh to check remaining documents."
            } catch {
                status.stringValue = "Local removal completion was not confirmed. References and charges are released only after exact cleanup is verified. Refresh to see any pending removal; Resume requires another explicit choice. The server is unchanged."
            }
            finishedWork()
        }
        update()
    }
    @objc func reviewSelected(_ sender: Any?) {
        guard !closing, !closed, libraryOwner.acceptsDemand, work == nil, draining == nil,
              metadataCurrent, let selected,
              selected.availableVersions.indices.contains(version.indexOfSelectedItem) else { return }
        guard libraryOwner.reserveBody() else {
            status.stringValue = "Close another text review or editor before opening this version. Up to four text documents can be open."; return
        }
        let chosen = selected.availableVersions[version.indexOfSelectedItem]
        status.stringValue = "Verifying selected retained text…"
        work = Task { [self] in
            defer { libraryOwner.releaseBody(); viewer = nil; finishedWork() }
            do {
                let viewed = try await selected.readPinnedVersion(chosen)
                guard !Task.isCancelled, !closing, libraryOwner.acceptsDemand else {
                    _ = await viewed.closeAndDrain(); throw CancellationError()
                }
                let view = RemoteTextRecoveryController(contents: viewed.contents, viewed: viewed, settings: context.settings,
                    locationContext: .retained(file: selected.presentation.fileName, server: selected.presentation.server,
                        version: chosen == .before ? "Before Save" : "Edited Text"),
                    acquire: context.acquire, finish: context.finish, choose: context.choose,
                    publish: context.publish, showResult: context.showResult)
                viewer = view
                InterfacePresentation.shared.register(view.window.surface)
                #if DEBUG
                await view.presentUntilClosed(visible: gateAReviewVisible)
                #else
                await view.presentUntilClosed()
                #endif
                status.stringValue = "Retained review closed · earlier remote result unchanged"
            } catch {
                status.stringValue = "Selected text could not be verified. No export or remote retry was assumed; existing retained data stays protected."
            }
        }
        update()
    }
    func stop() {
        guard draining == nil, !closed else { return }
        let held = work; held?.cancel()
        status.stringValue = "Stopping local review… waiting for actual readers and exports"
        draining = Task { [self] in
            if let source { await source.stopAndDrain() }
            if let held { await held.value }
            draining = nil
            status.stringValue = "Stopped · any incomplete local removal remains pending. Refresh before another explicit action. The server is unchanged."
            if refreshAfterWork { finishedWork() } else { update() }
        }
        update()
    }
    func closeAndDrain() async {
        guard !closed else { return }
        if let closingTask { await closingTask.value; return }
        closing = true
        let task = Task { [self] in
            stop()
            if let draining { await draining.value }
            if let work { await work.value }
            allChoices = []; removalChoices = []; retainedDocument.removeAllItems(); metadataCurrent = false; retirementMetadataCurrent = false; table.reloadData()
            closed = true; window?.close()
        }
        closingTask = task; await task.value; closingTask = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closed { return true }
        Task { [self] in await closeAndDrain() }; return false
    }
    func windowWillClose(_ notification: Notification) { didClose?() }
}
