import AppKit
import ExplorerCore

/// Project the exact comparison's line spans into one reading order. A
/// collapsed section keeps its original offsets on both sides.
struct EditorDiffContextPlan: Sendable {
    struct Section: Sendable {
        let before: Int?
        let after: Int?
        let count: Int
        let change: Int?
        let canFold: Bool

        func start(from side: EditorComparisonPlan.Side) -> Int? {
            side == .before ? before : after
        }
    }

    let sections: [Section]

    init?(_ plan: EditorComparisonPlan) {
        guard plan.whitespace == .exact, !plan.grouped else { return nil }
        let limits = (before: plan.beforeIndex.contentLineCount, after: plan.currentIndex.contentLineCount)
        guard max(limits.before, limits.after) <= TextAlignment.maximumLineCount else { return nil }
        var built: [Section] = []
        var before = 0, after = 0

        func append(_ left: Int?, _ right: Int?, count: Int, change: Int? = nil, canFold: Bool = false) {
            if count > 0 { built.append(.init(before: left, after: right, count: count, change: change, canFold: canFold)) }
        }
        func appendUnchanged(to nextBefore: Int, _ nextAfter: Int) -> Bool {
            let count = nextBefore - before
            guard count >= 0, count == nextAfter - after else { return false }
            let context = 3
            if count <= 2 * context + 2 {
                append(before, after, count: count)
            } else {
                append(before, after, count: context)
                append(before + context, after + context, count: count - 2 * context, canFold: true)
                append(nextBefore - context, nextAfter - context, count: context)
            }
            return true
        }
        for (index, change) in plan.changes.enumerated() {
            let firstBefore = min(change.beforeLines.lowerBound, limits.before)
            let firstAfter = min(change.currentLines.lowerBound, limits.after)
            guard appendUnchanged(to: firstBefore, firstAfter) else { return nil }
            before = min(change.beforeLines.upperBound, limits.before)
            after = min(change.currentLines.upperBound, limits.after)
            append(firstBefore, nil, count: before - firstBefore, change: index)
            append(nil, firstAfter, count: after - firstAfter, change: index)
        }
        guard appendUnchanged(to: limits.before, limits.after) else { return nil }
        sections = built
    }
}

@MainActor final class EditorDiffContextView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Location {
        let side: EditorComparisonPlan.Side
        let range: NSRange
    }
    private struct Row: Equatable {
        let section: Int
        let offset: Int?
    }
    private struct Match {
        let row: Row
        let location: Location
    }

    private let scroll = NSScrollView()
    private let table = EditorDiffContextTable()
    private let beforeColumn = NSTableColumn(identifier: .init("before"))
    private let afterColumn = NSTableColumn(identifier: .init("after"))
    private let textColumn = NSTableColumn(identifier: .init("text"))
    private var source: EditorComparisonPlan?
    private var context: EditorDiffContextPlan?
    private var beforeText = "" as NSString, afterText = "" as NSString
    private var expanded = Set<Int>()
    private var rowCount = 0
    private var firstRows: [Int] = []
    private var match: Match?
    private var pointSize: CGFloat = 12
    private var scale: CGFloat = 1
    private var findColor = NSColor.systemBlue
    private var focusesOnAttach = false
    var didSelectChange: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Unified diff")
        table.setAccessibilityIdentifier("editor-unified-diff")
        beforeColumn.title = "Before"
        afterColumn.title = "After"
        textColumn.title = "Text"
        textColumn.minWidth = 160
        for column in [beforeColumn, afterColumn, textColumn] { table.addTableColumn(column) }
        table.dataSource = self
        table.delegate = self
        table.toggleContext = { [weak self] in self?.toggleSelectedContext() ?? false }
        table.copyLine = { [weak self] in self?.selectedLineText }
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        addSubview(scroll)
        updateMetrics(pointSize: pointSize, scale: scale, findColor: findColor)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            ToolContentMotion.reveal(self, movesContent: false)
            if focusesOnAttach { focusesOnAttach = false; window.makeFirstResponder(table) }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let currentMatch = match.flatMap { selectedRow == $0.row ? table.selectedRow : nil }
        let keepsMatchVisible = currentMatch.map { table.rect(ofRow: $0).intersects(scroll.documentVisibleRect) } ?? false
        super.resizeSubviews(withOldSize: oldSize)
        if let currentMatch, keepsMatchVisible { refreshMatchRow(currentMatch) }
    }

    func updateMetrics(pointSize: CGFloat, scale: CGFloat, findColor: NSColor) {
        let selection = selectedRow
        let visible = table.rows(in: scroll.documentVisibleRect)
        let anchor = (0..<rowCount).contains(visible.location) ? visible.location : nil
        let offset = anchor.map { scroll.documentVisibleRect.minY - table.rect(ofRow: $0).minY } ?? 0
        let previousHeight = table.rowHeight
        self.pointSize = pointSize
        self.scale = scale
        self.findColor = findColor
        for column in [beforeColumn, afterColumn] {
            let width = max(68 * scale, pointSize * 4.6)
            column.minWidth = width
            column.maxWidth = width
            column.width = width
        }
        table.rowHeight = max(22 * scale, ceil(pointSize * 1.5) + 3)
        table.reloadData()
        if let selection, let index = rowIndex(of: selection), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if let anchor {
            restoreViewport(at: anchor, offset: offset * table.rowHeight / max(1, previousHeight))
        }
        if let selection, selection == match?.row, let index = rowIndex(of: selection) {
            refreshMatchRow(index)
        }
    }

    private func refreshMatchRow(_ row: Int) {
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 2))
        table.scrollRowToVisible(row)
    }

    private func restoreViewport(at row: Int, offset: CGFloat) {
        let y = table.rect(ofRow: row).minY + offset
        scroll.contentView.scroll(to: NSPoint(x: scroll.documentVisibleRect.minX, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func install(_ plan: EditorComparisonPlan, context: EditorDiffContextPlan, changingFile: Bool = false) {
        let resetsViewport = changingFile || source?.snapshot != plan.snapshot
        if resetsViewport {
            expanded = []
            match = nil
            table.deselectAll(nil)
        }
        source = plan
        self.context = context
        beforeText = plan.before.text as NSString
        afterText = plan.current.text as NSString
        reloadRows()
        if resetsViewport { scroll.contentView.scroll(to: .zero) }
    }

    func clear() {
        source = nil; context = nil; match = nil
        beforeText = ""; afterText = ""; expanded = []
        reloadRows()
    }

    func focusTable() {
        if let window { window.makeFirstResponder(table) }
        else { focusesOnAttach = true }
    }

    var selectedLocation: Location? {
        guard let row = selectedRow else { return nil }
        return match?.row == row ? match?.location : location(of: row)
    }

    private var selectedLineText: String? {
        guard let row = selectedRow, let location = location(of: row) else { return nil }
        return text(from: location.side).substring(with: location.range)
    }

    private var selectedRow: Row? { row(at: table.selectedRow) }

    var canToggleSelectedContext: Bool { selectedRow?.offset == nil && selectedRow != nil }

    @discardableResult func toggleSelectedContext() -> Bool {
        guard let row = selectedRow, row.offset == nil else { return false }
        toggle(row.section)
        return true
    }

    var hasFoldableSections: Bool { context?.sections.contains(where: \.canFold) == true }
    var allContextVisible: Bool {
        guard !expanded.isEmpty, let sections = context?.sections else { return false }
        return sections.indices.allSatisfy { !sections[$0].canFold || expanded.contains($0) }
    }

    func toggleAllContext() {
        guard let sections = context?.sections, hasFoldableSections else { return }
        let selection = selectedRow
        let top = table.rows(in: scroll.documentVisibleRect).location
        let anchor = row(at: top)
        let offset = anchor == nil ? 0 : scroll.documentVisibleRect.minY - table.rect(ofRow: top).minY
        if allContextVisible {
            expanded.removeAll()
            if let match, sections[match.row.section].canFold { self.match = nil }
        } else {
            expanded = Set(sections.indices.filter { sections[$0].canFold })
        }
        reloadRows()
        if let selection {
            table.selectRowIndexes(IndexSet(integer: rowIndex(of: selection) ?? firstRows[selection.section]),
                byExtendingSelection: false)
        }
        if let anchor { restoreViewport(at: rowIndex(of: anchor) ?? firstRows[anchor.section], offset: offset) }
        focusTable()
    }

    func navigate(toChange index: Int) {
        guard let context, let section = context.sections.firstIndex(where: { $0.change == index }) else { return }
        reveal(firstRows[section])
    }

    @discardableResult func revealMatch(side: EditorComparisonPlan.Side, range: NSRange) -> Bool {
        guard let source, let context else { return false }
        let index = side == .before ? source.beforeIndex : source.currentIndex
        guard let line = index.location(at: range.location)?.line else { return false }
        let target = line - 1
        guard let section = context.sections.firstIndex(where: {
            guard let start = $0.start(from: side) else { return false }
            return target >= start && target - start < $0.count
        }), let start = context.sections[section].start(from: side) else { return false }
        let row = Row(section: section, offset: target - start)
        let previous = match?.row
        match = .init(row: row, location: .init(side: side, range: range))
        if context.sections[section].canFold { setExpanded(true, for: section) }
        guard let resolved = rowIndex(of: row) else { return false }
        let changed = IndexSet([resolved, previous.flatMap(rowIndex) ?? resolved])
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 2))
        reveal(resolved)
        return true
    }

    private func rowIndex(of row: Row) -> Int? {
        guard let sections = context?.sections, sections.indices.contains(row.section) else { return nil }
        let section = sections[row.section]
        guard let offset = row.offset else { return firstRows[row.section] }
        guard !section.canFold || expanded.contains(row.section) else { return nil }
        return firstRows[row.section] + (section.canFold ? 1 : 0) + offset
    }

    private func row(at index: Int) -> Row? {
        guard let sections = context?.sections, (0..<rowCount).contains(index) else { return nil }
        var lower = 0, upper = firstRows.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if firstRows[middle] <= index { lower = middle + 1 }
            else { upper = middle }
        }
        let section = lower - 1
        let offset = index - firstRows[section]
        let folded = sections[section].canFold
        return .init(section: section, offset: folded && offset == 0 ? nil : offset - (folded ? 1 : 0))
    }

    private func rebuildRows() {
        rowCount = 0
        firstRows.removeAll(keepingCapacity: true)
        for (index, section) in (context?.sections ?? []).enumerated() {
            firstRows.append(rowCount)
            if section.canFold { rowCount += 1 }
            if !section.canFold || expanded.contains(index) { rowCount += section.count }
        }
    }

    private func reloadRows() {
        rebuildRows()
        table.reloadData()
    }

    private func reveal(_ row: Int) {
        guard (0..<rowCount).contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func toggle(_ section: Int) {
        guard let context, context.sections.indices.contains(section), context.sections[section].canFold else { return }
        setExpanded(!expanded.contains(section), for: section)
        reveal(firstRows[section])
        focusTable()
    }

    private func setExpanded(_ enabled: Bool, for index: Int) {
        guard let section = context?.sections[index], expanded.contains(index) != enabled else { return }
        let header = firstRows[index]
        let contents = IndexSet(integersIn: (header + 1)..<(header + 1 + section.count))
        if enabled { expanded.insert(index) }
        else {
            expanded.remove(index)
            if match?.row.section == index { match = nil }
        }
        rebuildRows()
        let motion = (window?.contentViewController as? ToolWindowChrome)?.motion ?? InterfacePresentation.shared.motion
        let duration = section.count <= 512 ? ToolPageMotionPolicy.crossfadeDuration(motion) * 0.75 : 0
        let animation: NSTableView.AnimationOptions = duration > 0 ? .effectFade : []
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = duration
            if enabled { table.insertRows(at: contents, withAnimation: animation) }
            else { table.removeRows(at: contents, withAnimation: animation) }
            table.reloadData(forRowIndexes: IndexSet(integer: header), columnIndexes: IndexSet(integer: 2))
        }
    }

    @objc private func toggleFold(_ sender: NSButton) { toggle(sender.tag) }

    private func text(from side: EditorComparisonPlan.Side) -> NSString {
        side == .before ? beforeText : afterText
    }

    private func location(of row: Row, on requestedSide: EditorComparisonPlan.Side? = nil) -> Location? {
        guard let source, let section = context?.sections[row.section], let offset = row.offset else { return nil }
        let side = requestedSide ?? (section.after == nil ? .before : .current)
        let index = side == .before ? source.beforeIndex : source.currentIndex
        guard let line = section.start(from: side), let range = index.contentRange(at: line + offset) else { return nil }
        return .init(side: side, range: range)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard let item = self.row(at: row), let section = context?.sections[item.section],
              section.change != nil else { return nil }
        return EditorDiffContextRow(accent: section.after == nil ? .removed : .inserted)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let row = selectedRow, let index = context?.sections[row.section].change { didSelectChange?(index) }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
        guard let context, let row = row(at: index) else { return nil }
        let section = context.sections[row.section]
        if column === beforeColumn || column === afterColumn {
            let start = column === beforeColumn ? section.before : section.after
            let number = row.offset.flatMap { offset in start.map { $0 + offset + 1 } }
            let field = NSTextField(labelWithString: number.map(String.init) ?? "")
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: pointSize * 0.86, weight: .regular)
            field.textColor = .secondaryLabelColor
            return field
        }
        let found = match?.row == row ? match?.location : nil
        guard let location = location(of: row, on: found?.side) else {
            let verb = expanded.contains(row.section) ? "Hide" : "Show"
            let button = NSButton(title: "\(verb) \(section.count) unchanged lines", target: self, action: #selector(toggleFold(_:)))
            button.tag = row.section
            button.bezelStyle = .inline
            button.alignment = .left
            button.font = .systemFont(ofSize: 12 * scale, weight: .medium)
            return button
        }
        let displayed = linePreview(at: location, highlighting: found?.range)
        let accent: EditorComparisonBackground.Accent? = section.change == nil ? nil : section.after == nil ? .removed : .inserted
        let prefix = (accent?.sign ?? " ") + "  "
        let field = NSTextField(labelWithString: "")
        let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        field.font = font
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = displayed.text
        let content = NSMutableAttributedString(string: prefix + displayed.text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let accent {
            content.addAttribute(.foregroundColor, value: accent.color, range: .init(location: 0, length: 1))
        }
        if let highlight = displayed.highlight {
            content.addAttribute(.backgroundColor, value: findColor.withAlphaComponent(0.36),
                range: .init(location: prefix.utf16.count + highlight.location, length: highlight.length))
        }
        field.attributedStringValue = content
        return field
    }

    private func linePreview(at location: Location, highlighting found: NSRange?) -> (text: String, highlight: NSRange?) {
        let source = text(from: location.side), range = location.range
        guard range.length > 0 else { return ("", nil) }
        let visible = max(12, Int(textColumn.width / (pointSize * 0.68)) - 6)
        let overlap = found.map { NSIntersectionRange($0, range) }.flatMap { $0.length > 0 ? $0 : nil }
        let focus = overlap?.location ?? found.flatMap {
            (range.location...NSMaxRange(range)).contains($0.location) ? $0.location : nil
        }
        let from: Int
        if let focus, focus - range.location >= visible - 4 {
            from = max(range.location, focus - min(8, visible / 4))
        } else {
            from = range.location
        }
        let end = min(NSMaxRange(range), from + (from > range.location ? min(visible, 512) : 512))
        let exact = source.rangeOfComposedCharacterSequences(for: .init(location: from, length: end - from))
        // One malformed or enormous grapheme must not set the cost of every
        // visible table row. The exact line remains available in Split Diff.
        guard exact.length <= 1024 else { return ("…", nil) }
        let prefix = exact.location == range.location ? "" : "…"
        let suffix = NSMaxRange(exact) == NSMaxRange(range) ? "" : "…"
        let visibleMatch = overlap.map { NSIntersectionRange($0, exact) }.flatMap { $0.length > 0 ? $0 : nil }
        let highlight = visibleMatch.map { NSRange(location: prefix.utf16.count + $0.location - exact.location, length: $0.length) }
        return (prefix + source.substring(with: exact) + suffix, highlight)
    }

    #if DEBUG
    var tableForVerification: NSTableView { table }
    var foldedSectionsForVerification: Int {
        (context?.sections.indices ?? 0..<0).count { context?.sections[$0].canFold == true && !expanded.contains($0) }
    }
    #endif
}

@MainActor private final class EditorDiffContextTable: NSTableView {
    var toggleContext: (() -> Bool)?
    var copyLine: (() -> String?)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           [36, 49, 76].contains(event.keyCode), toggleContext?() == true { return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let line = copyLine?() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }
}

@MainActor private final class EditorDiffContextRow: NSTableRowView {
    private let accent: EditorComparisonBackground.Accent
    init(accent: EditorComparisonBackground.Accent) {
        self.accent = accent
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        EditorComparisonBackground.Tint(accent, appearance: effectiveAppearance).fill(bounds, clippedTo: dirtyRect)
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (contrast ? NSColor.labelColor : NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 1 : 0.65)).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1),
                                xRadius: 3, yRadius: 3)
        path.lineWidth = contrast ? 2 : 1
        path.stroke()
    }
}
