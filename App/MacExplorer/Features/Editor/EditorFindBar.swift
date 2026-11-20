import AppKit

/// Only native controls and layout. Matching and replacement admission live in
/// the separate owner; this view never reads files or changes document text.
@MainActor
final class EditorFindBar: NSView, NSSearchFieldDelegate {
    let query = NSSearchField()
    let replacement = NSTextField()
    let previous = NSButton()
    let next = NSButton()
    let replace = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAll = NSButton(title: "Replace All", target: nil, action: nil)
    let done = NSButton(title: "Done", target: nil, action: nil)
    let options = NSPopUpButton(frame: .zero, pullsDown: true)
    let count = NSTextField(labelWithString: "")
    let notice = NSTextField(labelWithString: "")
    let secondRow = NSStackView()
    var onQuery: (() -> Void)?
    var onReplacement: (() -> Void)?
    var onCommand: ((NSTextFinder.Action) -> Void)?
    var onOptions: ((EditorFindOptions) -> Void)?
    var onSelectionScope: (() -> Void)?
    var onWholeDocument: (() -> Void)?
    private var selectedOptions = EditorFindOptions()
    private var scopeLabel: EditorFindScopeLabel?
    private var selectionScopeAvailable = false
    private(set) var interfaceScale: CGFloat = 1
    private var layoutMetrics: [(NSLayoutConstraint, CGFloat)] = []
    private var rows: [NSStackView] = []
    var presentationHeight: CGFloat { (secondRow.isHidden ? 38 : 70) * interfaceScale }
    var queryHasMarkedText: Bool { (query.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    var replacementHasMarkedText: Bool { (replacement.currentEditor() as? NSTextView)?.hasMarkedText() == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; clipsToBounds = true; layer?.masksToBounds = true
        query.placeholderString = "Find in Document"
        query.sendsSearchStringImmediately = true; query.sendsWholeSearchString = false
        query.delegate = self
        query.setAccessibilityLabel("Find in document"); query.setAccessibilityIdentifier("editor-find-query")
        replacement.placeholderString = "Replace With"
        replacement.delegate = self
        replacement.setAccessibilityLabel("Replacement text"); replacement.setAccessibilityIdentifier("editor-find-replacement")
        for field in [query as NSTextField, replacement] {
            field.isEditable = true; field.isSelectable = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        previous.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous match")
        next.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next match")
        previous.toolTip = "Previous match (Shift-Command-G)"; next.toolTip = "Next match (Command-G)"
        previous.setAccessibilityLabel("Previous match"); next.setAccessibilityLabel("Next match")
        previous.setAccessibilityIdentifier("editor-find-previous"); next.setAccessibilityIdentifier("editor-find-next")
        for (button, action) in [(previous, NSTextFinder.Action.previousMatch), (next, .nextMatch),
                                  (replace, .replace), (replaceAll, .replaceAll), (done, .hideFindInterface)] {
            button.bezelStyle = .rounded; button.target = self; button.action = #selector(command(_:)); button.tag = action.rawValue
        }
        replace.setAccessibilityIdentifier("editor-find-replace"); replaceAll.setAccessibilityIdentifier("editor-find-replace-all")
        done.setAccessibilityIdentifier("editor-find-done")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setAccessibilityLabel("Match count")
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        notice.lineBreakMode = .byTruncatingTail
        notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        options.bezelStyle = .rounded; rebuildOptions()
        options.setAccessibilityLabel("Find options")
        let firstRow = NSStackView(views: [query, count, previous, next, options, done])
        firstRow.orientation = .horizontal; firstRow.spacing = 6; firstRow.alignment = .centerY
        for view in [replacement, replace, replaceAll, notice] { secondRow.addArrangedSubview(view) }
        secondRow.orientation = .horizontal; secondRow.spacing = 6; secondRow.alignment = .centerY
        firstRow.translatesAutoresizingMaskIntoConstraints = false
        secondRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(firstRow); addSubview(secondRow)
        layoutMetrics = [
            (firstRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), 2),
            (firstRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), -2),
            (firstRow.topAnchor.constraint(equalTo: topAnchor, constant: 5), 5),
            (firstRow.heightAnchor.constraint(equalToConstant: 28), 28),
            (secondRow.topAnchor.constraint(equalTo: firstRow.bottomAnchor, constant: 4), 4),
            (secondRow.heightAnchor.constraint(equalToConstant: 28), 28),
            (query.widthAnchor.constraint(greaterThanOrEqualToConstant: 90), 90),
            (replacement.widthAnchor.constraint(greaterThanOrEqualToConstant: 90), 90),
            (previous.widthAnchor.constraint(equalToConstant: 27), 27),
            (next.widthAnchor.constraint(equalToConstant: 27), 27)
        ]
        NSLayoutConstraint.activate(layoutMetrics.map { $0.0 } + [
            secondRow.leadingAnchor.constraint(equalTo: firstRow.leadingAnchor),
            secondRow.trailingAnchor.constraint(equalTo: firstRow.trailingAnchor),
            replacement.widthAnchor.constraint(equalTo: query.widthAnchor)
        ])
        rows = [firstRow, secondRow]
        secondRow.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    @discardableResult
    func applyInterfaceScale(_ proposed: CGFloat) -> Bool {
        guard proposed.isFinite else { return false }
        let scale = max(0.75, min(1.5, proposed))
        guard interfaceScale != scale else { return false }
        interfaceScale = scale
        for (constraint, base) in layoutMetrics { constraint.constant = base * scale }
        for row in rows { row.spacing = 6 * scale }
        for field in [query as NSTextField, replacement] { field.font = .systemFont(ofSize: 13 * scale) }
        for button in [previous, next, replace, replaceAll, done, options] {
            button.font = .systemFont(ofSize: 13 * scale)
        }
        for button in [previous, next] {
            button.symbolConfiguration = .init(pointSize: 10 * scale, weight: .medium)
        }
        count.font = .monospacedDigitSystemFont(ofSize: 11 * scale, weight: .regular)
        notice.font = .systemFont(ofSize: 11 * scale)
        return true
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === query { onQuery?() }
        else if notification.object as? NSTextField === replacement { onReplacement?() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCommand?(.hideFindInterface); return true
        }
        if control === replacement && commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommand?(.replaceAndFind); return true
        }
        if control === query && commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommand?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .previousMatch : .nextMatch)
            return true
        }
        return false
    }
    func setOptions(_ value: EditorFindOptions) { selectedOptions = value; rebuildOptions() }
    func setScope(_ label: EditorFindScopeLabel?, canSelect: Bool) {
        guard scopeLabel != label || selectionScopeAvailable != canSelect else { return }
        scopeLabel = label
        selectionScopeAvailable = canSelect
        query.placeholderString = "Find in \(label?.title ?? "Document")"
        query.setAccessibilityLabel(query.placeholderString)
        options.toolTip = label.map { "Search only in \($0.title)" }
        options.setAccessibilityLabel(options.toolTip ?? "Find options")
        rebuildOptions()
    }
    func clear() {
        query.stringValue = ""; replacement.stringValue = ""; count.stringValue = ""; notice.stringValue = ""
        onQuery = nil; onReplacement = nil; onCommand = nil; onOptions = nil; onSelectionScope = nil; onWholeDocument = nil
    }
    @objc private func command(_ sender: NSButton) {
        guard let action = NSTextFinder.Action(rawValue: sender.tag) else { return }
        onCommand?(action)
    }
    private func rebuildOptions() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = switch scopeLabel {
        case .selection: "Selection"
        case .outline(let name): "In " + name.prefix(14) + (name.count > 14 ? "…" : "")
        case nil: "Options"
        }
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        func item(_ title: String, tag: Int, checked: Bool, enabled: Bool = true) {
            let value = NSMenuItem(title: title, action: #selector(changeOption(_:)), keyEquivalent: "")
            value.target = self; value.tag = tag; value.state = checked ? .on : .off; value.isEnabled = enabled
            menu.addItem(value)
        }
        item("Match Case", tag: 0, checked: selectedOptions.matchesCase)
        item("Wrap Around", tag: 1, checked: selectedOptions.wraps)
        item("Find in Selection", tag: 2, checked: scopeLabel == .selection, enabled: selectionScopeAvailable)
        if case .outline = scopeLabel { item("Search Whole Document", tag: 3, checked: false) }
        menu.addItem(.separator())
        for (index, mode) in EditorFindMatchMode.allCases.enumerated() {
            item(mode.title, tag: index + 10, checked: selectedOptions.matchMode == mode)
        }
        options.menu = menu
    }
    @objc private func changeOption(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: selectedOptions.matchesCase.toggle()
        case 1: selectedOptions.wraps.toggle()
        case 2: onSelectionScope?(); return
        case 3: onWholeDocument?(); return
        default:
            guard EditorFindMatchMode.allCases.indices.contains(sender.tag - 10) else { return }
            selectedOptions.matchMode = EditorFindMatchMode.allCases[sender.tag - 10]
        }
        rebuildOptions(); onOptions?(selectedOptions)
    }
}
