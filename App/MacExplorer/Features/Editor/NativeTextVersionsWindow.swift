import AppKit
import FileOperations

struct EditorGrantedDirectory: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let access: any Sendable
    var description: String { "<chosen editor recovery directory>" }
    var debugDescription: String { description }
}

@MainActor struct EditorVersionInteractions {
    var acquireInspection: () throws -> UUID
    var finishInspection: (UUID) -> Void
    var acquireMutation: () async throws -> UUID
    var finishMutation: (UUID) -> Void
    var chooseDirectory: (NSWindow) async -> EditorGrantedDirectory?
    var confirmUndo: (NSWindow) async -> Bool
    var confirmRetirement: (NSWindow, RecoveryRetentionRecord) async -> Bool
    var showOperationResults: (UUID) -> Bool
    var allowsRetirement = true
    var confirmUndoSection: ((NSWindow, LocalTextCheckpointReview) async -> Bool)? = nil
}

/// An attached, bounded version review. Opening lists metadata; selecting a
/// change verifies only that change. Recovery always copies to fresh names.
/// Retiring versions is a separate sealed, confirmed operation that ends Undo;
/// unresolved changes are never treated as safe cleanup or automatic expiry.
@MainActor final class NativeTextVersionsWindow: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let files: LocalEditorFileSession
    private let actions: EditorVersionInteractions
    private let table = NSTableView()
    private let details = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "Loading saved changes…")
    private let attempts = NSPopUpButton()
    private let undoButton = NSButton(title: "Undo Saved Change…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Both Versions…", target: nil, action: nil)
    private let retireButton = NSButton(title: "Move Versions to Trash…", target: nil, action: nil)
    private let resultsButton = NSButton(title: "View Results", target: nil, action: nil)
    private let sectionButton = NSButton(title: "Start New Undo Section…", target: nil, action: nil)
    private let capacityLabel = NSTextField(wrappingLabelWithString: "")
    private let previousCopiesButton = NSButton(title: "Previous Copies", target: nil, action: nil)
    private let nextCopiesButton = NSButton(title: "More Copies", target: nil, action: nil)
    private let copiesPageLabel = NSTextField(labelWithString: "Recovered copies")
    private var capacity: LocalTextCapacityInspection?
    private var sectionPreparationAvailable = false
    private var exportPage: LocalTextRecoveryExportPage?
    private var exportCursor: Int?
    private var earlierExportCursors: [Int?] = []
    private let earlierButton = NSButton(title: "Earlier Changes", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var records: [LocalTextDocumentRevisionSummary] = []
    private var singleRecordID: UUID?
    private var dates: [UUID: Date] = [:]
    private var otherRecord: OperationRecoveryRecord?
    private var selected: LocalTextRevisionInspection?
    #if DEBUG
    // Observations only. Verification selects the actual NSTableView row.
    var recordIDsForVerification: [UUID] { records.map(\.recordID) }
    var selectedRecordIDForVerification: UUID? { selected?.recordID }
    var hasPendingWorkForVerification: Bool { worker != nil }
    var resultsAffinityIDForVerification: UUID? { resultsAffinityID }
    #endif
    private var resultsAffinityID: UUID?
    private var next: UUID?
    private var loadedPageCursor: UUID?
    private var worker: Task<Void, Never>?
    private var finished: CheckedContinuation<Void, Never>?
    private var closing = false
    private var rowFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    init(files: LocalEditorFileSession, publication: EditorUnresolvedPublication? = nil, interactions: EditorVersionInteractions,
         installChrome: (NSWindow) -> Void) {
        self.files = files; actions = interactions
        let window = ToolWindowChrome.makePanel(title: "Saved Versions",
            size: .init(width: 900, height: 700), minimumSize: .init(width: 720, height: 600))
        super.init(window: window); window.delegate = self
        let intro = NSTextField(wrappingLabelWithString: "Review changes saved by Traverse. Undo Saved Change affects the file; text Undo remains in the editor.")
        intro.textColor = .secondaryLabelColor
        let publicationNotice = NSTextField(wrappingLabelWithString: "")
        publicationNotice.isHidden = publication == nil; publicationNotice.isSelectable = true
        publicationNotice.maximumNumberOfLines = 4
        if let publication {
            switch publication.kind {
            case .originalSave:
                publicationNotice.stringValue = "This Save is unconfirmed. The reported document is:\n" + publication.intendedURL.path
            case .freshCopyUnconfirmed:
                publicationNotice.stringValue = "A new copy may exist at the location below. This editor still belongs to the original document; this location is not proof of a completed Save.\n" + publication.intendedURL.path
            case .freshCopyPublishedNeedsRead:
                publicationNotice.stringValue = "A new copy was published, but it changed before the editor could follow it. This editor still belongs to the original document.\n" + publication.intendedURL.path
            }
            publicationNotice.toolTip = publicationNotice.stringValue
        }
        table.addTableColumn({ let column = NSTableColumn(identifier: .init("change")); column.title = "Saved change"; column.width = 380; return column }())
        table.addTableColumn({ let column = NSTableColumn(identifier: .init("state")); column.title = "Status"; column.width = 180; return column }())
        table.dataSource = self; table.delegate = self
        table.allowsMultipleSelection = false; table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Saved text changes")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.isRichText = false
        details.drawsBackground = false; details.font = .systemFont(ofSize: 12)
        details.textColor = .labelColor
        details.string = "Select a saved change to review its versions."
        details.textContainer?.widthTracksTextView = true
        details.textContainer?.containerSize = .init(width: 820, height: CGFloat.greatestFiniteMagnitude)
        details.textContainerInset = .init(width: 8, height: 6)
        details.minSize = .zero; details.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        details.autoresizingMask = [.width]
        details.isHorizontallyResizable = false; details.isVerticallyResizable = true
        details.setAccessibilityLabel("Saved version details and recovered copies")
        let detailsScroll = NSScrollView(); detailsScroll.documentView = details
        detailsScroll.hasVerticalScroller = true; detailsScroll.drawsBackground = false
        detailsScroll.borderType = .bezelBorder
        status.maximumNumberOfLines = 3; status.textColor = .secondaryLabelColor
        attempts.target = self; attempts.action = #selector(attemptChanged)
        attempts.setAccessibilityLabel("Saved or Undo attempt")
        for button in [undoButton, copyButton, retireButton, resultsButton, earlierButton, refreshButton, stopButton, doneButton, sectionButton, previousCopiesButton, nextCopiesButton] {
            button.target = self; button.bezelStyle = .rounded
        }
        undoButton.action = #selector(undoChange); copyButton.action = #selector(copyVersions)
        retireButton.action = #selector(retireVersions); resultsButton.action = #selector(viewResults)
        retireButton.isHidden = !actions.allowsRetirement || !NativeLocalProtectionPolicy.editorVersionRetirementAvailable
        sectionButton.action = #selector(startUndoSection)
        previousCopiesButton.action = #selector(previousCopies); nextCopiesButton.action = #selector(nextCopies)
        sectionButton.isHidden = actions.confirmUndoSection == nil || files.selectedHistoricalRecordID != nil
        capacityLabel.textColor = .secondaryLabelColor; capacityLabel.maximumNumberOfLines = 2
        copiesPageLabel.textColor = .secondaryLabelColor
        earlierButton.action = #selector(earlier); refreshButton.action = #selector(reloadList)
        stopButton.action = #selector(stop); doneButton.action = #selector(done)
        let actionRow = NSStackView(views: [undoButton, copyButton, retireButton])
        actionRow.orientation = .horizontal; actionRow.spacing = 8
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [earlierButton, refreshButton, resultsButton, spacer, stopButton, doneButton])
        bottom.orientation = .horizontal; bottom.spacing = 8
        let copySpacer = NSView(); copySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let copyPager = NSStackView(views: [copiesPageLabel, copySpacer, previousCopiesButton, nextCopiesButton])
        copyPager.orientation = .horizontal; copyPager.spacing = 8
        let sectionRow = NSStackView(views: [sectionButton, capacityLabel])
        sectionRow.orientation = .horizontal; sectionRow.alignment = .centerY; sectionRow.spacing = 12
        let layout = NSStackView(views: [intro, publicationNotice, scroll, detailsScroll, copyPager, attempts, actionRow, sectionRow, status, bottom])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            detailsScroll.heightAnchor.constraint(equalToConstant: 110)
        ])
        for view in [intro, publicationNotice, scroll, detailsScroll, copyPager, sectionRow, status, bottom] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        installChrome(window)
        rowFont = doneButton.font ?? rowFont
        let scale = max(1, rowFont.pointSize / NSFont.systemFontSize)
        table.rowHeight = ceil(max(30, rowFont.pointSize * 2))
        for column in table.tableColumns { column.headerCell.font = rowFont }
        if let header = table.headerView {
            var frame = header.frame; frame.size.height = ceil(28 * scale); header.frame = frame
        }
        details.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        let requiredWidth = max(720, max(bottom.fittingSize.width, actionRow.fittingSize.width) + 36)
        window.contentMinSize = .init(width: requiredWidth, height: max(600, layout.fittingSize.height + 32))
        refreshControls()
    }
    required init?(coder: NSCoder) { nil }

    func present(from parent: NSWindow, focus recordID: UUID?) async {
        guard let window, finished == nil else { return }
        await withCheckedContinuation { continuation in
            finished = continuation; parent.beginSheet(window)
            load(after: nil, focus: recordID)
        }
    }
    private var textRowCount: Int { records.count + (singleRecordID == nil ? 0 : 1) }
    func numberOfRows(in tableView: NSTableView) -> Int { textRowCount + (otherRecord == nil ? 0 : 1) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < numberOfRows(in: tableView) else { return nil }
        let label = NSTextField(labelWithString: "")
        label.font = rowFont
        label.lineBreakMode = .byTruncatingTail
        if row < records.count {
            let record = records[row]
            if tableColumn?.identifier.rawValue == "state" { label.stringValue = Self.stateLabel(record.state, retention: record.retention, undo: record.undoDisposition) }
            else if let date = dates[record.recordID] {
                label.stringValue = date.formatted(date: .abbreviated, time: .shortened) + (record.isCurrentHead ? " · Current" : "")
            } else { label.stringValue = "Saved change \(row + 1)" + (record.isCurrentHead ? " · Current" : "") }
        } else if row < textRowCount {
            label.stringValue = tableColumn?.identifier.rawValue == "state"
                ? selected.map { Self.stateLabel($0.state, retention: $0.retention, undo: $0.undoDisposition) } ?? "Select to inspect" : "Selected saved change"
        } else { label.stringValue = tableColumn?.identifier.rawValue == "state" ? "Operation results" : "Save As copy" }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard worker == nil else { return }
        inspectSelection()
    }

    private func load(after cursor: UUID?, focus: UUID?) {
        guard worker == nil else { return }
        status.stringValue = "Loading saved changes…"; selected = nil; resultsAffinityID = nil
        sectionPreparationAvailable = false
        worker = Task { [weak self] in
            guard let self else { return }
            var token: UUID?
            var inspectAfterRead = false
            defer {
                if let token { self.actions.finishInspection(token) }
                self.worker = nil; self.refreshControls()
                if inspectAfterRead { self.inspectSelection() }
            }
            do {
                token = try self.actions.acquireInspection()
                if self.files.sectionNeedsReview { _ = try? await self.files.reconcileUndoSection() }
                let records: [LocalTextDocumentRevisionSummary]
                let next: UUID?
                if self.files.selectedHistoricalRecordID != nil { records = []; next = nil }
                else {
                    let page = try await self.files.revisions(after: cursor)
                    records = page.records; next = page.nextRecordID
                }
                try Task.checkCancellation()
                var history: OperationRecoveryInspection?
                if let focus, self.files.selectedHistoricalRecordID == nil, !records.contains(where: { $0.recordID == focus }) {
                    history = try await self.files.historySummaries()
                }
                if self.files.selectedHistoricalRecordID == nil { self.capacity = try? await self.files.writeCapacity() }
                else { self.capacity = nil }
                var canPrepareSection = false
                if self.files.selectedHistoricalRecordID == nil, self.actions.confirmUndoSection != nil {
                    // Ordinary capacity intentionally refuses a changed source.
                    // Only an explicit Reload lets the concrete session prepare
                    // the dedicated baseline plan. Never infer permission from
                    // a generic sourceChanged result. This observational plan
                    // is discarded; clicking prepares and reviews a fresh one.
                    do { _ = try await self.files.prepareUndoSection(); canPrepareSection = true }
                    catch { canPrepareSection = false }
                }
                try Task.checkCancellation()
                self.sectionPreparationAvailable = canPrepareSection
                self.loadedPageCursor = cursor
                self.records = records; self.next = next; self.singleRecordID = self.files.selectedHistoricalRecordID
                self.dates = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0.createdAt) })
                self.otherRecord = focus.flatMap { id in history?.records.first { $0.id == id && $0.kind != .textRevision } }
                self.capacityLabel.stringValue = self.capacity.map(Self.capacityDescription) ?? ""
                if canPrepareSection && self.files.requiresUnchangedCheckpoint {
                    self.capacityLabel.stringValue = "The reloaded file can be the next section’s starting point. Earlier copies are kept."
                }
                if self.files.sectionNeedsReview {
                    self.capacityLabel.stringValue = "A previous section change needs review. Use Refresh before continuing."
                }
                self.table.reloadData()
                self.status.stringValue = self.textRowCount == 0 && self.otherRecord == nil
                    ? "No text changes have been saved by Traverse for this file yet." : "Select a change to inspect it."
                let focusedIndex = focus.flatMap { id in
                    self.records.firstIndex { $0.recordID == id }
                        ?? (self.singleRecordID == id ? self.records.count : nil)
                        ?? (self.otherRecord?.id == id ? self.textRowCount : nil)
                }
                let index = focusedIndex ?? (self.numberOfRows(in: self.table) == 0 ? nil : 0)
                if let index { self.table.selectRowIndexes(.init(integer: index), byExtendingSelection: false) }
                // The current real read must finish before the selection read.
                inspectAfterRead = index != nil
            } catch { self.status.stringValue = Task.isCancelled ? "Stopped" : "Saved changes are unavailable. No versions were changed." }
        }
        refreshControls()
    }
    private func inspectSelection() {
        guard worker == nil else { return }
        selected = nil; attempts.removeAllItems(); resultsAffinityID = nil
        exportPage = nil; exportCursor = nil; earlierExportCursors = []
        let row = table.selectedRow
        guard row >= 0 else { refreshControls(); return }
        guard row < textRowCount else {
            details.string = "Save As created a new file. Its file Undo and any interrupted copy are managed in Results."
            resultsAffinityID = otherRecord?.id
            refreshControls(); return
        }
        guard let id = row < records.count ? records[row].recordID : singleRecordID else { refreshControls(); return }
        resultsAffinityID = id
        worker = Task { [weak self] in
            guard let self else { return }
            var token: UUID?
            defer { if let token { self.actions.finishInspection(token) }; self.worker = nil; self.refreshControls() }
            do {
                token = try self.actions.acquireInspection()
                let value = try await self.files.inspectRevision(id)
                try Task.checkCancellation()
                let exports: LocalTextRecoveryExportPage?
                do { exports = try await self.files.recoveryExportPage(id) }
                catch { exports = nil }
                try Task.checkCancellation()
                guard self.table.selectedRow == row,
                      (row < self.records.count ? self.records[row].recordID : self.singleRecordID) == id else { return }
                self.selected = value
                self.table.reloadData(forRowIndexes: .init(integer: row), columnIndexes: .init(integersIn: 0..<self.table.tableColumns.count))
                self.attempts.addItems(withTitles: value.attempts.enumerated().map { index, attempt in
                    (attempt.direction == .forward ? "Save" : "Undo") + " attempt \(index + 1)"
                        + (attempt.preparationAborted ? " · Stopped before file change" : "")
                })
                if !value.attempts.isEmpty { self.attempts.selectItem(at: value.attempts.count - 1) }
                self.exportPage = exports
                self.details.string = Self.detail(value) + Self.exportDetails(exports?.exports)
                self.status.stringValue = "Before and submitted versions are independent of the editor’s visible text."
            } catch { self.details.string = "This change could not be verified. Its retained files remain protected."; self.status.stringValue = "No versions were changed." }
        }
        refreshControls()
    }
    @objc private func reloadList() { load(after: nil, focus: selected?.recordID) }
    @objc private func earlier() { if let next { load(after: next, focus: nil) } }
    @objc private func attemptChanged() { refreshControls() }
    @objc private func viewResults() {
        if let resultsAffinityID, !actions.showOperationResults(resultsAffinityID) {
            status.stringValue = "Results are unavailable while the file browser is busy. The selected change and its recorded locations remain here. Try again after the current work finishes."
        }
    }
    @objc private func stop() { worker?.cancel(); status.stringValue = "Stopping… Waiting for the current request to finish." }
    @objc private func done() { if worker == nil { finish() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if worker != nil { status.stringValue = "Finish or Stop the current request before closing."; return false }
        finish(); return false
    }
    private func finish() {
        guard !closing, worker == nil else { return }
        closing = true
        if let window { window.sheetParent?.endSheet(window); window.close() }
        let completion = finished; finished = nil; completion?.resume()
    }
    /// The current mutator retains its writer permit until these observations
    /// drain. A failed refresh never revises the already returned operation result.
    private func refreshAfterMutation(_ id: UUID, reportedDetails: String = "") async {
        let outcome = status.stringValue
        defer { status.stringValue = outcome }
        selected = nil; attempts.removeAllItems(); exportPage = nil; exportCursor = nil; earlierExportCursors = []
        records = []; dates = [:]; next = nil; singleRecordID = nil; otherRecord = nil
        capacity = nil; sectionPreparationAvailable = false; capacityLabel.stringValue = ""
        details.string = (reportedDetails.isEmpty ? "" : reportedDetails + "\n\n") + "Refreshing recorded versions…"
        table.reloadData(); table.deselectAll(nil)
        do {
            let page: LocalTextDocumentRevisionPage?
            if files.selectedHistoricalRecordID != nil { page = nil }
            else { page = try await files.revisions(after: loadedPageCursor) }
            let value = try await files.inspectRevision(id)
            guard value.metadataIsDurable else { throw FileOperationFailure.recoveryUncertain }
            try Task.checkCancellation()
            let exports = try? await files.recoveryExportPage(id)
            if files.selectedHistoricalRecordID == nil {
                capacity = try? await files.writeCapacity()
                if actions.confirmUndoSection != nil {
                    sectionPreparationAvailable = (try? await files.prepareUndoSection()) != nil
                }
            }
            try Task.checkCancellation()
            records = page?.records ?? []; next = page?.nextRecordID
            dates = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0.createdAt) })
            singleRecordID = files.selectedHistoricalRecordID ?? (records.contains { $0.recordID == id } ? nil : id)
            selected = value; exportPage = exports
            attempts.addItems(withTitles: value.attempts.enumerated().map { index, attempt in
                (attempt.direction == .forward ? "Save" : "Undo") + " attempt \(index + 1)"
                    + (attempt.preparationAborted ? " · Stopped before file change" : "")
            })
            if !value.attempts.isEmpty { attempts.selectItem(at: value.attempts.count - 1) }
            details.string = Self.detail(value) + Self.exportDetails(exports?.exports)
                + (reportedDetails.isEmpty ? "" : "\n\n" + reportedDetails)
            capacityLabel.stringValue = capacity.map(Self.capacityDescription) ?? ""
            if files.mustReloadBeforeOriginalSave { capacityLabel.stringValue = "Reopen or reload the file before starting a new Undo section." }
            if sectionPreparationAvailable && files.requiresUnchangedCheckpoint {
                capacityLabel.stringValue = "The reloaded file can be the next section’s starting point. Earlier copies are kept."
            }
            if files.sectionNeedsReview { capacityLabel.stringValue = "A previous section change needs review. Use Refresh before continuing." }
            table.reloadData()
            if let row = records.firstIndex(where: { $0.recordID == id }) ?? (singleRecordID == id ? records.count : nil) {
                table.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } catch {
            selected = nil; records = []; dates = [:]; next = nil; singleRecordID = nil; otherRecord = nil
            capacity = nil; sectionPreparationAvailable = false; capacityLabel.stringValue = ""
            details.string = (reportedDetails.isEmpty ? "" : reportedDetails + "\n\n")
                + "Saved-version metadata could not refresh. The recorded outcome above is unchanged. Use Refresh to review it."
            table.reloadData(); table.deselectAll(nil)
        }
    }
    @objc private func undoChange() {
        guard let selected, selected.canUndo, let native = window, worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var permit: UUID?
            defer { if let permit { self.actions.finishMutation(permit) }; self.worker = nil; self.refreshControls() }
            guard await self.actions.confirmUndo(native), !Task.isCancelled else { return }
            do {
                permit = try await self.actions.acquireMutation(); try Task.checkCancellation()
                let result = try await self.files.undoSavedOperation(selected.recordID)
                self.resultsAffinityID = selected.recordID
                self.selected = nil
                self.status.stringValue = result.result.disposition == .succeeded
                    ? "Saved change undone. Reopen or reload the file to see the restored version." : "Undo needs review. Keep any open editor text and check Results."
                await self.refreshAfterMutation(selected.recordID)
            } catch { self.status.stringValue = "Undo did not complete. No outcome was assumed; check Results if the request started." }
        }; refreshControls()
    }
    @objc private func copyVersions() {
        guard let selected, let native = window, worker == nil,
              attempts.indexOfSelectedItem >= 0, attempts.indexOfSelectedItem < selected.attempts.count else { return }
        let attempt = selected.attempts[attempts.indexOfSelectedItem]
        guard attempt.beforeVersionAvailable, attempt.submittedVersionAvailable else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var permit: UUID?
            defer { if let permit { self.actions.finishMutation(permit) }; self.worker = nil; self.refreshControls() }
            guard let chosen = await self.actions.chooseDirectory(native), !Task.isCancelled else { return }
            do {
                try self.files.retainAccess(chosen.access)
                permit = try await self.actions.acquireMutation(); try Task.checkCancellation()
                let suffix = UUID().uuidString.prefix(8)
                let result = try await self.files.copyVersions(recordID: selected.recordID, attemptID: attempt.attemptID,
                    directory: chosen.url, beforeName: "Before-\(suffix).txt", submittedName: "Submitted-\(suffix).txt")
                self.resultsAffinityID = selected.recordID
                self.status.stringValue = result.status == .succeeded
                    ? "Both versions were copied into the chosen folder. The original Save outcome is unchanged."
                    : "Some copies could not be confirmed. Review each reported result; the original Save outcome is unchanged."
                self.details.string = result.outcomes.map { outcome in
                    let name = outcome.version == .before ? "Before" : "Submitted"
                    let state = outcome.state == .verified ? "Confirmed copy" : outcome.state == .publicationUnconfirmed ? "Copy may exist · not confirmed" : "Not copied"
                    return name + ": " + state + "\n" + outcome.intendedURL.path
                }.joined(separator: "\n")
            } catch { self.status.stringValue = "The versions could not be copied. Retained versions stay protected." }
        }; refreshControls()
    }
    @objc private func retireVersions() {
        guard NativeLocalProtectionPolicy.editorVersionRetirementAvailable else {
            status.stringValue = OrdinaryNativeTrashFeature.retirementHoldMessage
            return
        }
        guard let selected, selected.metadataIsDurable, selected.retention == .retained,
              let native = window, worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var permit: UUID?
            defer { if let permit { self.actions.finishMutation(permit) }; self.worker = nil; self.refreshControls() }
            do {
                permit = try await self.actions.acquireMutation(); try Task.checkCancellation()
                let plan = try await self.files.prepareRetirement(selected.recordID)
                guard await self.actions.confirmRetirement(native, plan.review), !Task.isCancelled else { return }
                let result = try await self.files.retire(plan)
                self.resultsAffinityID = selected.recordID
                self.selected = nil
                self.status.stringValue = result.status == .succeeded && result.retention == .retired
                    ? "Retained versions moved to Trash. Undo has ended for this saved change; your document was not changed."
                    : "Moving versions to Trash could not be confirmed. Review the reported locations; do not retry this change automatically."
                func displayLocations(_ locations: [URL], prefix: String) -> [String] {
                    var displayed = Set<String>()
                    // Deduplicate presentation only. Distinct URL representations
                    // and their recorded authority remain untouched in recovery.
                    return locations.compactMap { location in
                        displayed.insert(location.path).inserted ? prefix + location.path : nil
                    }
                }
                self.details.string = (displayLocations(result.knownLocations, prefix: "Recorded location: ")
                    + displayLocations(result.unconfirmedReportedLocations, prefix: "Reported by macOS · not verified: ")).joined(separator: "\n")
                await self.refreshAfterMutation(selected.recordID, reportedDetails: self.details.string)
            } catch { self.status.stringValue = "These versions could not be safely retired. They remain protected." }
        }; refreshControls()
    }
    @objc private func startUndoSection() {
        guard let native = window, worker == nil, let confirm = actions.confirmUndoSection,
              files.selectedHistoricalRecordID == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var inspection: UUID?, permit: UUID?
            defer {
                if let inspection { self.actions.finishInspection(inspection) }
                if let permit { self.actions.finishMutation(permit) }
                self.worker = nil; self.refreshControls()
            }
            do {
                inspection = try self.actions.acquireInspection()
                let plan = try await self.files.prepareUndoSection()
                if let current = inspection { self.actions.finishInspection(current); inspection = nil }
                guard await confirm(native, plan.review), !Task.isCancelled else {
                    self.status.stringValue = "The Undo section was not changed."; return
                }
                permit = try await self.actions.acquireMutation(); try Task.checkCancellation()
                switch try await self.files.startUndoSection(plan) {
                case .completed:
                    self.sectionPreparationAvailable = false
                    self.selected = nil; self.attempts.removeAllItems()
                    self.exportPage = nil; self.exportCursor = nil; self.earlierExportCursors = []
                    self.table.deselectAll(nil)
                    do {
                        let page = try await self.files.revisions()
                        self.loadedPageCursor = nil
                        self.records = page.records; self.next = page.nextRecordID
                        self.dates = Dictionary(uniqueKeysWithValues: page.records.map { ($0.recordID, $0.createdAt) })
                        self.table.reloadData()
                        self.status.stringValue = "New Undo section ready. Earlier copies are kept; your editor text has not been saved by this action."
                    } catch {
                        self.status.stringValue = "The new section is confirmed, but its list could not refresh. Use Refresh; your editor text has not been saved by this action."
                    }
                    self.details.string = "File Undo ended for the reviewed section. Select an earlier change to recover its available copies."
                case .refused(let reason):
                    self.sectionPreparationAvailable = false
                    self.status.stringValue = Self.sectionRefusal(reason)
                case .uncertain:
                    self.sectionPreparationAvailable = false
                    self.status.stringValue = "The section change could not be confirmed. Keep the editor open and use Refresh to review it before trying again. This action did not save your text."
                }
                self.capacity = try? await self.files.writeCapacity()
                self.capacityLabel.stringValue = self.capacity.map(Self.capacityDescription) ?? ""
            } catch let reason as LocalTextCapacityReason {
                self.sectionPreparationAvailable = false
                self.status.stringValue = Self.sectionRefusal(reason)
            } catch {
                self.sectionPreparationAvailable = false
                self.status.stringValue = Task.isCancelled ? "Stopped. Refresh to review the recorded section before continuing." : "Saved versions could not be checked. Your visible text is still here; no Save was assumed."
            }
        }
        refreshControls()
    }
    @objc private func nextCopies() {
        guard let next = exportPage?.nextOrdinal else { return }
        loadCopies(after: next, movingBack: false)
    }
    @objc private func previousCopies() {
        guard !earlierExportCursors.isEmpty else { return }
        loadCopies(after: earlierExportCursors.last!, movingBack: true)
    }
    private func loadCopies(after cursor: Int?, movingBack: Bool) {
        guard worker == nil, let selected else { return }
        let recordID = selected.recordID
        worker = Task { [weak self] in
            guard let self else { return }
            var inspection: UUID?
            defer { if let inspection { self.actions.finishInspection(inspection) }; self.worker = nil; self.refreshControls() }
            do {
                inspection = try self.actions.acquireInspection()
                let page = try await self.files.recoveryExportPage(recordID, after: cursor)
                try Task.checkCancellation()
                if movingBack { _ = self.earlierExportCursors.popLast() }
                else {
                    guard self.earlierExportCursors.count < 160 else { return }
                    self.earlierExportCursors.append(self.exportCursor)
                }
                self.exportCursor = cursor; self.exportPage = page
                self.details.string = Self.detail(selected) + Self.exportDetails(page.exports)
                self.status.stringValue = "Recovered copies are shown one bounded page at a time. Your file and editor text are unchanged."
            } catch { self.status.stringValue = "These recovered copies could not be checked. Earlier locations and file outcomes were not changed." }
        }
        refreshControls()
    }
    private static func capacityDescription(_ value: LocalTextCapacityInspection) -> String {
        if value.saveRefusal == .checkpointRequired { return "Saved versions need a new Undo section before another Save." }
        if value.checkpointRefusal == .pendingMaintenance { return "A previous versions action needs review first." }
        return "Earlier versions stay available when you start a new section."
    }
    private static func sectionRefusal(_ reason: LocalTextCapacityReason) -> String {
        switch reason {
        case .sourceChanged: "The file changed. Close this review and explicitly Reload the editor before reviewing a new starting point."
        case .unfinishedPreparation, .unknownNativePrefix, .pendingMaintenance: "A previous action needs review. Retained copies are protected; no new section or Save was assumed."
        case .storeCapacity: "Space for saved versions is unavailable. Free space and Refresh; your visible text is still here."
        case .stalePlan: "The saved versions changed while this review was open. Refresh and review the new section again."
        case .upgradeRequired: "Enable saving for this history before starting a new section."
        case .nothingToCheckpoint: "There are no saved changes in this section yet."
        case .legacyHistoryRequiresReview: "This file has older saved versions that need review before another Save. You can review those versions or keep your current text with Save a Text Copy."
        case .checkpointRequired, .metadataUnavailable: "The saved versions could not be checked. Refresh before trying again; your visible text is still here."
        }
    }
    private func refreshControls() {
        let busy = worker != nil
        table.isEnabled = !busy; attempts.isEnabled = !busy && !(selected?.attempts.isEmpty ?? true)
        refreshButton.isEnabled = !busy; earlierButton.isEnabled = !busy && next != nil
        doneButton.isEnabled = !busy; stopButton.isHidden = !busy
        let unresolvedSection = files.sectionNeedsReview
        undoButton.isEnabled = !busy && !unresolvedSection && selected?.canUndo == true
        let index = attempts.indexOfSelectedItem
        let available = selected.map { index >= 0 && index < $0.attempts.count
            && $0.attempts[index].beforeVersionAvailable && $0.attempts[index].submittedVersionAvailable } ?? false
        copyButton.isEnabled = !busy && !unresolvedSection && available
        let retirementStateAllows = selected.map { value in
            let eligible: [LocalTextRevisionState] = [.committed, .undone, .notApplied]
            return eligible.contains(value.state)
        } ?? false
        retireButton.isEnabled = NativeLocalProtectionPolicy.editorVersionRetirementAvailable && actions.allowsRetirement
            && !busy && !unresolvedSection && selected?.metadataIsDurable == true
            && selected?.retention == .retained && retirementStateAllows
        resultsButton.isEnabled = !busy && resultsAffinityID != nil
        sectionButton.isEnabled = !busy && actions.confirmUndoSection != nil && files.selectedHistoricalRecordID == nil
            && sectionPreparationAvailable && !files.sectionNeedsReview
        previousCopiesButton.isEnabled = !busy && !earlierExportCursors.isEmpty
        nextCopiesButton.isEnabled = !busy && exportPage?.nextOrdinal != nil
        if let exportPage {
            copiesPageLabel.stringValue = exportPage.exports.isEmpty ? "No recovered copies" : "Recovered copies · page \(earlierExportCursors.count + 1)"
        } else { copiesPageLabel.stringValue = "Recovered copies unavailable" }
    }
    private static func stateLabel(_ state: LocalTextRevisionState, retention: LocalTextRetentionState, undo: LocalTextUndoDisposition) -> String {
        if case .endedByCheckpoint = undo { return "Earlier Undo section" }
        if undo == .epochCapacityReached { return "Undo section full" }
        if retention == .retired { return "Versions in Trash" }
        if retention == .pending || retention == .unknown { return "Needs review" }
        return switch state {
        case .committed: "Saved"
        case .undone: "Undone"
        case .notApplied: "Stopped before change"
        case .preparing, .prepared, .undoPrepared: "Preparation interrupted"
        case .nativePending, .undoPending, .uncertain: "Needs review"
        }
    }
    private static func detail(_ value: LocalTextRevisionInspection) -> String {
        if !value.metadataIsDurable { return "The recorded outcome could not be read reliably. No Save, baseline change or cleanup is assumed." }
        if value.retention == .retired { return "Versions were moved to Trash. This change can no longer be Undone." }
        if value.retention == .pending || value.retention == .unknown { return "Moving these versions to Trash is unconfirmed. Keep the reported locations and review Results." }
        if case .endedByCheckpoint = value.undoDisposition { return "File Undo ended when a new section was started. Available before/submitted copies remain recoverable." }
        if value.undoDisposition == .epochCapacityReached { return "This Undo section is full. File Undo cannot be started; available copies remain recoverable. Starting a new section ends its remaining file Undo." }
        if value.canUndo { return "This is the current saved change. You can Undo it, or copy both versions into a separate folder." }
        return "You can inspect or copy available versions. Undo is unavailable when the file or its current saved change no longer matches."
    }
    private static func exportDetails(_ exports: [LocalTextRecoveryExportInspection]?) -> String {
        guard let exports else { return "\n\nEarlier recovered copies could not be inspected. No copy locations or successful outcomes are assumed." }
        guard !exports.isEmpty else { return "" }
        let lines = exports.flatMap { record in
            record.outcomes.map { outcome in
                let version = outcome.version == .before ? "Before" : "Submitted"
                let state = outcome.state == .verified ? "Confirmed copy" : outcome.state == .publicationUnconfirmed ? "Copy may exist · unconfirmed" : "Not copied"
                let current = outcome.currentlyAvailable == true ? " · available now" : outcome.currentlyAvailable == false ? " · unavailable now" : " · current availability unknown"
                return version + ": " + state + current + "\n" + outcome.intendedURL.path
            }
        }
        return "\n\nEarlier recovery copies\n" + lines.joined(separator: "\n\n")
    }
}
