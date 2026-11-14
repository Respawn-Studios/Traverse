import AppKit
import FileOperations

/// A bounded, virtualized queue inspector hosted in the existing compact card.
/// It is session UI; closing it never cancels or resumes work.
@MainActor
final class TransferQueueInspectionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var motion = BrowserMotionPreferences()
    var onClose: (() -> Void)?
    var onProgress: (() -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onPauseOrResume: ((_ resume: Bool, _ reviewResultID: UUID?) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onMoveWaiting: ((UUID, Int, [UUID]) -> Bool)?
    var onResult: ((UUID) -> Void)?
    private let titleField = label("Transfer queue", size: 13, weight: .semibold)
    private let summary = label("", size: 11, color: .secondaryLabelColor)
    private let pauseButton = NSButton(title: "Pause Queue", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let table = QueueInspectionTableView()
    private let earlierButton = NSButton(title: "", target: nil, action: nil)
    private let laterButton = NSButton(title: "", target: nil, action: nil)
    private let progressButton = NSButton(title: "Progress", target: nil, action: nil)
    private let sessionNote = label("Waiting jobs stay in this session only.", size: 10, color: .secondaryLabelColor)
    private var rows: [Row] = []
    private var permitsResultInspection = false
    private var displayedResumeIntent = false
    private var displayedReviewResultID: UUID?
    private var displayedActiveID: UUID?
    private var displayedWaitingOrder: [UUID] = []
    #if DEBUG
    private(set) var fullReloadsForVerification = 0
    private(set) var movedRowsForVerification = 0
    var tableForVerification: NSTableView { table }
    var rowIDsForVerification: [UUID] { rows.map(\.id) }
    func menuForVerification(row: Int) -> NSMenu? { movementMenu(row: row) }
    #endif

    private struct Row: Equatable {
        let id: UUID
        let title: String
        let detail: String
        let waiting: Bool
        let review: Bool
    }
    private struct PriorityIntent { let id: UUID; let offset: Int; let order: [UUID] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let closeButton = ActionButton(title: "Close") { [weak self] in self?.onClose?() }
        for button in [pauseButton, stopButton, closeButton, progressButton, earlierButton, laterButton] {
            button.controlSize = .small; button.font = .systemFont(ofSize: 11); button.bezelStyle = .rounded
        }
        pauseButton.target = self; pauseButton.action = #selector(pauseOrResume(_:))
        stopButton.target = self; stopButton.action = #selector(stop(_:))
        progressButton.target = self; progressButton.action = #selector(progress(_:))
        for (button, image, name, selector) in [
            (earlierButton, "arrow.up", "Move waiting transfer earlier", #selector(earlier(_:))),
            (laterButton, "arrow.down", "Move waiting transfer later", #selector(later(_:)))
        ] {
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: name)
            button.imagePosition = .imageOnly; button.setAccessibilityLabel(name)
            button.toolTip = name + (button === earlierButton ? " (Option-Up)" : " (Option-Down)")
            button.target = self; button.action = selector
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = stack([titleField, spacer, pauseButton, stopButton, closeButton], orientation: .horizontal, spacing: 5)
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        summary.maximumNumberOfLines = 2; summary.lineBreakMode = .byWordWrapping
        summary.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for (id, width) in [("job", 266.0), ("action", 68.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.width = width; table.addTableColumn(column)
        }
        table.headerView = nil; InterfaceMetrics.setRowHeight(table, base: 42); table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 4, height: 2)
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Waiting transfers and recent results")
        table.setAccessibilityHelp("Select a waiting transfer. Option-Up or Option-Down changes its priority. Running work stays in place.")
        table.onMoveKey = { [weak self] in self?.moveSelection(offset: $0) ?? false }
        table.onRowMenu = { [weak self] in self?.movementMenu(row: $0) }
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        sessionNote.lineBreakMode = .byTruncatingTail
        sessionNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = stack([sessionNote, NSView(), earlierButton, laterButton, progressButton], orientation: .horizontal, spacing: 5)
        bottom.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let content = stack([header, summary, scroll, bottom], orientation: .vertical, spacing: 5)
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        pin(content, inside: self, inset: 12)
    }

    required init?(coder: NSCoder) { nil }
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    func consumeShortcut(_ event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, window?.firstResponder === table, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option,
              event.keyCode == 126 || event.keyCode == 125 else { return false }
        table.keyDown(with: event); return true
    }

    func update(_ queue: ApplicationTransferQueue) {
        let state = queue.state
        displayedResumeIntent = state.isPaused
        displayedReviewResultID = queue.reviewResultID
        displayedActiveID = state.active?.id; displayedWaitingOrder = state.waiting.map(\.id)
        titleField.stringValue = queue.reviewResult != nil ? "Needs attention" : (state.isPaused ? "Queue paused" : "Transfer queue")
        if let active = state.active, let job = queue.waitingDescription(active.id) {
            summary.stringValue = "\(active.stopRequested ? "Stopping" : "Running"): \(job.title) · \(state.waiting.count) waiting"
                + (queue.reviewResult != nil ? " · Needs attention" : "")
            summary.toolTip = job.detail
        } else {
            summary.stringValue = state.isPaused ? queue.pausedSummary
                : (state.waiting.isEmpty ? "No waiting transfers. Recent results are below."
                    : "\(state.waiting.count) waiting · Checking captured items.")
            summary.toolTip = nil
        }
        pauseButton.title = state.isPaused ? "Resume Queue" : "Pause Queue"
        pauseButton.toolTip = state.isPaused ? "Start only waiting transfers. The reviewed job is preserved and is not retried."
            : "Let the running transfer finish, then hold waiting jobs."
        pauseButton.isEnabled = state.active?.stopRequested != true
            && (state.isPaused ? queue.canResume : state.outstandingCount > 0)
        stopButton.isHidden = state.active == nil
        stopButton.isEnabled = state.active?.stopRequested == false
        let actionsChanged = permitsResultInspection != queue.canInspectResults
        permitsResultInspection = queue.canInspectResults
        progressButton.isEnabled = queue.presentation != nil
        sessionNote.stringValue = queue.reviewResult != nil && !queue.canInspectResults
            ? "Review actions wait for the current operation."
            : (state.isPaused ? "Resume starts waiting jobs; review stays protected."
                : "Waiting jobs stay in this session only.")
        sessionNote.toolTip = queue.reviewResult != nil && !queue.canInspectResults
            ? "The current operation is finishing. Review actions become available after its worker drains."
            : "Resume Queue does not retry, recover or change the reviewed job. Continue Remaining and Recovery are separate guarded actions."
        let waiting = state.waiting.compactMap { item -> Row? in
            guard let job = queue.waitingDescription(item.id) else { return nil }
            return Row(id: item.id, title: job.title + (item.phase == .preparing ? " · checking" : ""),
                detail: job.detail, waiting: true, review: false)
        }
        let recent = Array(queue.results.reversed())
        func resultRow(_ result: QueuedTransferResult) -> Row {
            let review = result.id == queue.reviewResultID
            return Row(id: result.id,
                title: (review ? "Review: " : "") + result.title + " · " + OperationResultDescription(result: result.outcome.result).summary,
                detail: "\(copyExecutionDescription(request: result.copyExecution, decision: result.executionDecision, completed: true)) · From \(result.originDescription) → \(result.destination.path)", waiting: false, review: review)
        }
        let next = recent.filter { $0.id == queue.reviewResultID }.map(resultRow)
            + waiting + recent.filter { $0.id != queue.reviewResultID }.map(resultRow)
        apply(next, actionsChanged: actionsChanged)
        updateMovementControls()
    }

    private func apply(_ next: [Row], actionsChanged: Bool) {
        let previous = rows
        let selected = previous.indices.contains(table.selectedRow) ? previous[table.selectedRow].id : nil
        let oldIDs = previous.map(\.id), newIDs = next.map(\.id)
        rows = next
        if oldIDs != newIDs {
            let animates = motion.allows(.pages) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if animates && oldIDs.count == newIDs.count && Set(oldIDs) == Set(newIDs) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = animates ? 0.22 * motion.mode.durationScale : 0
                    context.allowsImplicitAnimation = animates
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    var current = oldIDs
                    table.beginUpdates()
                    for index in newIDs.indices where current[index] != newIDs[index] {
                        guard let from = current.firstIndex(of: newIDs[index]) else { continue }
                        table.moveRow(at: from, to: index)
                        let id = current.remove(at: from); current.insert(id, at: index)
                        #if DEBUG
                        movedRowsForVerification += 1
                        #endif
                    }
                    table.endUpdates()
                }
            } else {
                // AppKit still slides moveRow in a zero-duration context. Off
                // and system Reduce Motion therefore replace this bounded list
                // immediately, retaining its selected identity below.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0; context.allowsImplicitAnimation = false
                    table.reloadData()
                }
                #if DEBUG
                fullReloadsForVerification += 1
                #endif
            }
            if let selected, let row = next.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
        }
        let byID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changed = IndexSet(next.indices.filter { byID[next[$0].id] != next[$0] || (actionsChanged && !next[$0].waiting) })
        if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateMovementControls() }
    private var selectedWaiting: UUID? {
        guard rows.indices.contains(table.selectedRow), rows[table.selectedRow].waiting else { return nil }
        return rows[table.selectedRow].id
    }
    private func updateMovementControls() {
        let index = selectedWaiting.flatMap { displayedWaitingOrder.firstIndex(of: $0) }
        earlierButton.isEnabled = index.map { $0 > 0 } ?? false
        laterButton.isEnabled = index.map { $0 + 1 < displayedWaitingOrder.count } ?? false
    }
    @discardableResult private func moveSelection(offset: Int) -> Bool {
        guard let id = selectedWaiting, let index = displayedWaitingOrder.firstIndex(of: id),
              displayedWaitingOrder.indices.contains(index + offset) else { return false }
        return move(.init(id: id, offset: offset, order: displayedWaitingOrder))
    }
    private func move(_ intent: PriorityIntent) -> Bool {
        guard onMoveWaiting?(intent.id, intent.offset, intent.order) == true else {
            sessionNote.stringValue = "Queue changed. Select the transfer again."; return false
        }
        return true
    }
    private func movementMenu(row: Int) -> NSMenu? {
        guard rows.indices.contains(row), rows[row].waiting,
              let index = displayedWaitingOrder.firstIndex(of: rows[row].id) else { return nil }
        let menu = NSMenu(title: "Waiting transfer priority"); menu.autoenablesItems = false
        for (title, offset) in [("Move Earlier", -1), ("Move Later", 1)] {
            let item = menu.addItem(withTitle: title, action: #selector(performPriority(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = PriorityIntent(id: rows[row].id, offset: offset, order: displayedWaitingOrder)
            item.isEnabled = displayedWaitingOrder.indices.contains(index + offset)
        }
        return menu
    }
    @objc private func performPriority(_ item: NSMenuItem) {
        guard item.isEnabled, let intent = item.representedObject as? PriorityIntent else { return }; _ = move(intent)
    }
    @objc private func earlier(_ sender: Any?) { _ = moveSelection(offset: -1) }
    @objc private func later(_ sender: Any?) { _ = moveSelection(offset: 1) }

    func focusPrimaryAction() { window?.makeFirstResponder(pauseButton.isEnabled ? pauseButton : table) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        if tableColumn?.identifier.rawValue == "action" {
            let button = ActionButton(title: item.waiting ? "Cancel" : (item.review ? "Review" : "Results")) { [weak self] in
                if item.waiting { self?.onCancel?(item.id) } else { self?.onResult?(item.id) }
            }
            button.controlSize = .small; button.bezelStyle = .recessed; button.font = .systemFont(ofSize: 11)
            button.isEnabled = item.waiting || permitsResultInspection
            button.setAccessibilityLabel((item.waiting ? "Cancel waiting " : "Inspect result ") + item.title)
            return button
        }
        let title = label(item.title, size: 11)
        let detail = label(item.detail, size: 10, color: .secondaryLabelColor)
        title.lineBreakMode = .byTruncatingMiddle; detail.lineBreakMode = .byTruncatingMiddle
        let content = stack([title, detail], orientation: .vertical, spacing: 2)
        content.toolTip = item.title + "\n" + item.detail
        return content
    }

    @objc private func pauseOrResume(_ sender: Any?) { onPauseOrResume?(displayedResumeIntent, displayedReviewResultID) }
    @objc private func stop(_ sender: Any?) { if let displayedActiveID, stopButton.isEnabled { onStop?(displayedActiveID) } }
    @objc private func progress(_ sender: Any?) { onProgress?() }
}

@MainActor private final class QueueInspectionTableView: NSTableView {
    var onMoveKey: ((Int) -> Bool)?
    var onRowMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option,
           event.keyCode == 126 || event.keyCode == 125 {
            _ = onMoveKey?(event.keyCode == 126 ? -1 : 1); return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return onRowMenu?(row)
    }
}
