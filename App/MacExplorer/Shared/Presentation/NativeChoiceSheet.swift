import AppKit
import SwiftUI

/// The parent owns the choice. Cancelling its work ends the exact sheet and
/// returns without delivering a selection.
@MainActor final class NativeChoiceSheet<Value: Sendable> {
    struct Row {
        let title: String
        let detail: String
        let value: Value
        var isEnabled = true
        var help: String?
    }

    struct Button {
        let title: String
        var identifier: String?
        var isEnabled = true
        let resolve: (Value, Bool) -> Value
    }

    struct Option {
        let title: String
        let help: String
        let initial: Bool
    }

    struct SelectionPreview {
        let height: CGFloat
        let makeView: (Value) -> NSView
    }

    private let window: NSWindow
    private var value: Value?

    private init(title: String, size: NSSize) {
        window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
    }

    convenience init<Content: View>(title: String, content: (@escaping (Value?) -> Void) -> Content) {
        self.init(title: title, size: .init(width: 418, height: 451))
        window.contentViewController = InterfaceHostingController(rootView: content { [weak self] in self?.finish($0) })
    }

    convenience init(title: String, heading: String, confirm: String, rows: [Row], initialSelection: Int = 0,
                     preview: SelectionPreview? = nil, size: NSSize? = nil, note: String? = nil) {
        self.init(title: title, heading: heading, rows: rows, primary: .init(title: confirm) { value, _ in value },
                  note: note, initialSelection: initialSelection, preview: preview,
                  size: size ?? .init(width: 480, height: note == nil ? 245 : 285))
    }

    convenience init(title: String, heading: String, rows: [Row], primary: Button, alternate: Button? = nil,
                     option: Option? = nil, note: String? = nil, initialSelection: Int = 0,
                     preview: SelectionPreview? = nil, size: NSSize) {
        self.init(title: title, size: size)
        let list = NativeChoiceList(heading: heading, rows: rows, primary: primary, alternate: alternate,
            option: option, note: note, initialSelection: initialSelection, preview: preview) { [weak self] in self?.finish($0) }
        window.contentViewController = list
        window.contentMinSize = size
        window.setContentSize(size)
        window.initialFirstResponder = list.table
    }

    func choose(in parent: NSWindow) async -> Value? {
        guard !Task.isCancelled, parent.isKeyWindow, parent.attachedSheet == nil, window.sheetParent == nil else { return nil }
        let chosen: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                parent.beginSheet(window) { [self] response in
                    window.orderOut(nil)
                    let chosen = response == .OK ? value : nil
                    value = nil
                    continuation.resume(returning: chosen)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
        return Task.isCancelled ? nil : chosen
    }

    private func finish(_ choice: Value?) {
        guard let parent = window.sheetParent else { return }
        value = choice
        parent.endSheet(window, returnCode: choice == nil ? .cancel : .OK)
    }
}

@MainActor private final class NativeChoiceList<Value: Sendable>: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private final class ChoiceTable: NSTableView {
        var choose: (() -> Void)?
        var cancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: choose?()
            case 53: cancel?()
            default: super.keyDown(with: event)
            }
        }
    }

    typealias Row = NativeChoiceSheet<Value>.Row
    typealias Button = NativeChoiceSheet<Value>.Button
    typealias Option = NativeChoiceSheet<Value>.Option
    typealias Preview = NativeChoiceSheet<Value>.SelectionPreview
    let table: NSTableView
    private let rows: [Row]
    private let finish: (Value?) -> Void
    private let primary: Button
    private let alternate: Button?
    private let confirmButton = NSButton()
    private let alternateButton = NSButton()
    private var optionButton: NSButton?
    private let preview: Preview?
    private let previewHost: NSView?
    private var previewedRow: Int?

    init(heading: String, rows: [Row], primary: Button, alternate: Button?, option: Option?, note: String?, initialSelection: Int,
         preview: Preview?, finish: @escaping (Value?) -> Void) {
        let choices = ChoiceTable()
        table = choices
        self.rows = rows
        self.finish = finish
        self.primary = primary
        self.alternate = alternate
        self.preview = preview
        previewHost = preview.map { _ in NSView() }
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        let column = NSTableColumn(identifier: .init("choice"))
        column.width = 450
        column.resizingMask = .autoresizingMask
        choices.addTableColumn(column)
        choices.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        choices.autoresizingMask = [.width]
        choices.style = .plain
        choices.headerView = nil
        choices.allowsColumnReordering = false
        choices.allowsColumnResizing = false
        choices.allowsEmptySelection = !rows.contains(where: \.isEnabled)
        choices.setAccessibilityLabel(heading)
        InterfaceMetrics.setRowHeight(choices, base: 36)
        choices.dataSource = self
        choices.delegate = self
        choices.target = self
        choices.doubleAction = #selector(activateClickedRow(_:))
        choices.choose = { [weak self] in self?.accept(nil) }
        choices.cancel = { [weak self] in self?.cancel(nil) }

        let scroll = CommandDiscoveryPresentation.ResultsScrollView()
        scroll.documentView = choices
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 108).interfaceScaled.isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        InterfaceMetrics.setFont(cancel, base: .systemFont(ofSize: 12))
        configure(confirmButton, for: primary, selector: #selector(accept(_:)))
        confirmButton.keyEquivalent = "\r"
        var footerViews: [NSView] = [NSView(), cancel]
        if let alternate {
            configure(alternateButton, for: alternate, selector: #selector(acceptAlternate(_:)))
            footerViews.append(alternateButton)
        }
        footerViews.append(confirmButton)
        let footer = NSStackView(views: footerViews)
        let title = label(heading, size: 12, color: .secondaryLabelColor)
        title.lineBreakMode = .byTruncatingMiddle
        var contents: [NSView] = [title, scroll]
        if let previewHost, let preview {
            previewHost.clipsToBounds = true
            previewHost.heightAnchor.constraint(equalToConstant: preview.height).interfaceScaled.isActive = true
            contents.append(previewHost)
        }
        if let option {
            let check = NSButton(checkboxWithTitle: option.title, target: nil, action: nil)
            check.state = option.initial ? .on : .off
            check.toolTip = option.help
            InterfaceMetrics.setFont(check, base: .systemFont(ofSize: 12))
            optionButton = check
            contents.append(check)
        }
        if let note {
            let detail = label(note, size: 11, color: .secondaryLabelColor)
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 3
            contents.append(detail)
        }
        contents.append(footer)
        let stack = NSStackView(views: contents)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = .init(top: 12, left: 14, bottom: 12, right: 14)
        pin(stack, inside: view)
        for child in contents {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        choices.reloadData()
        let selection = rows.indices.contains(initialSelection) && rows[initialSelection].isEnabled
            ? initialSelection : rows.firstIndex(where: \.isEnabled)
        if let first = selection {
            choices.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            choices.scrollRowToVisible(first)
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let cell = CommandDiscoveryPresentation.row(title: item.title, category: item.detail, shortcut: "", enabled: item.isEnabled)
        cell.toolTip = item.help
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].isEnabled }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func configure(_ button: NSButton, for command: Button, selector: Selector) {
        button.title = command.title
        button.bezelStyle = .rounded
        InterfaceMetrics.setFont(button, base: .systemFont(ofSize: 12))
        button.target = self
        button.action = selector
        if let identifier = command.identifier { button.setAccessibilityIdentifier(identifier) }
    }

    private var selected: Row? {
        let row = table.selectedRow
        return rows.indices.contains(row) && rows[row].isEnabled ? rows[row] : nil
    }

    private func updateSelection() {
        let row = selected
        confirmButton.isEnabled = row != nil && primary.isEnabled
        alternateButton.isEnabled = row != nil && alternate?.isEnabled == true
        optionButton?.isEnabled = row != nil
        if let preview, let previewHost, previewedRow != table.selectedRow {
            previewedRow = table.selectedRow
            previewHost.subviews.forEach { $0.removeFromSuperview() }
            if let row { pin(preview.makeView(row.value), inside: previewHost) }
        }
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }
    @objc private func accept(_ sender: Any?) { chooseSelection(with: primary) }
    @objc private func acceptAlternate(_ sender: Any?) { if let alternate { chooseSelection(with: alternate) } }
    @objc private func activateClickedRow(_ sender: Any?) {
        if table.clickedRow == table.selectedRow { chooseSelection(with: primary) }
    }
    private func chooseSelection(with command: Button) {
        guard command.isEnabled, let selected else { return }
        finish(command.resolve(selected.value, optionButton?.state == .on))
    }
}
