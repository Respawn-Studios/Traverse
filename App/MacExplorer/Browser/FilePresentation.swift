import AppKit
import ExplorerCore

enum FileSizeText {
    static func unsigned(_ bytes: UInt64) -> String {
        guard let signed = Int64(exactly: bytes) else { return "\(bytes.formatted()) bytes" }
        return string(signed)
    }
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

enum BrowserColumn: String, CaseIterable {
    case name, modified, kind, size, created, accessed, `extension`

    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .kind: "Kind"
        case .size: "Size"
        case .created: "Date Created"
        case .accessed: "Date Accessed"
        case .extension: "Extension"
        }
    }
    var width: CGFloat {
        switch self {
        case .name: 360
        case .modified, .created, .accessed: 175
        case .kind: 125
        case .size: 95
        case .extension: 105
        }
    }
    var toggleTag: Int {
        switch self {
        case .name: -1
        case .modified: 0
        case .kind: 1
        case .size: 2
        case .created: 3
        case .accessed: 4
        case .extension: 5
        }
    }
    var sortField: SortField {
        switch self {
        case .name: .name
        case .modified: .modified
        case .kind: .kind
        case .size: .size
        case .created: .created
        case .accessed: .accessed
        case .extension: .extension
        }
    }
    static func toggled(by tag: Int) -> Self? { allCases.first { $0.toggleTag == tag } }
}

@MainActor
protocol FileColumnSizingTable: AnyObject {
    var columnSizing: FileColumnSizing { get }
}

/// One native-table lifetime: automatic layout never becomes a user choice.
/// Optional defaults yield first; explicit header widths remain logical points.
@MainActor final class FileColumnSizing {
    private struct Default { let width: CGFloat, minimum: CGFloat }
    private var defaults: [NSUserInterfaceItemIdentifier: Default] = [:]
    private var userWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    private var applying = false, trackingHeader = false

    func fit(_ table: NSTableView) {
        guard !applying, !trackingHeader, let scroll = table.enclosingScrollView,
              let name = table.tableColumns.first(where: { $0.identifier.rawValue == "name" }), !name.isHidden else { return }
        // Fit the columns against the current native clip allocation.
        let viewport = scroll.contentView.bounds.width, scale = InterfaceMetrics.scale
        guard viewport > 0, scale > 0 else { return }
        applying = true; defer { applying = false }
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in table.tableColumns {
            if defaults[column.identifier] == nil { defaults[column.identifier] = .init(width: column.width, minimum: column.minWidth) }
            column.resizingMask = .userResizingMask
        }
        let visible = table.tableColumns.filter { !$0.isHidden }
        let spacing = CGFloat(visible.count) * table.intercellSpacing.width
        func minimum(_ column: NSTableColumn) -> CGFloat {
            let floor: CGFloat
            switch column.identifier.rawValue {
            case "name": floor = 180
            case "modified", "created", "accessed": floor = 90
            case "kind": floor = 70
            case "size": floor = 65
            default: floor = 70
            }
            return min(column.maxWidth, max(defaults[column.identifier]?.minimum ?? 0, floor) * scale)
        }
        func preferred(_ column: NSTableColumn) -> CGFloat {
            let base = userWidths[column.identifier] ?? defaults[column.identifier]?.width ?? column.width / scale
            return max(minimum(column), min(column.maxWidth, base * scale))
        }
        let others = visible.filter { $0 !== name }
        let nameReserve = userWidths[name.identifier].map { max(minimum(name), $0 * scale) }
            ?? max(minimum(name), min(preferred(name), viewport * 0.55))
        let total = others.reduce(CGFloat.zero) { $0 + preferred($1) }
        let flexible = others.filter { userWidths[$0.identifier] == nil }
            .reduce(CGFloat.zero) { $0 + preferred($1) - minimum($1) }
        let deficit = max(0, total - max(0, viewport - spacing - nameReserve))
        let fraction = flexible > 0 ? min(1, deficit / flexible) : 0
        func assign(_ column: NSTableColumn, _ width: CGFloat) {
            let lower = minimum(column)
            if abs(column.minWidth - lower) > 0.5 { column.minWidth = lower }
            let fitted = max(lower, min(column.maxWidth, width))
            if abs(column.width - fitted) > 0.5 { column.width = fitted }
        }
        for column in others {
            let width = preferred(column)
            assign(column, userWidths[column.identifier] == nil ? width - (width - minimum(column)) * fraction : width)
        }
        let otherWidth = others.reduce(CGFloat.zero) { $0 + $1.width }
        assign(name, userWidths[name.identifier].map { $0 * scale } ?? (viewport - otherWidth - spacing))
        let width = max(viewport, visible.reduce(CGFloat.zero) { $0 + $1.width } + spacing)
        // AppKit can retain a point of document padding during clip layout.
        // Cover all columns, but do not force that harmless surplus smaller
        // on every layout pass. Keep native width/height autoresizing intact.
        let delta = width - table.frame.width
        if delta > 0.5 || delta < -1.001 { table.setFrameSize(.init(width: width, height: table.frame.height)) }
    }

    func beginHeaderInteraction(_ table: NSTableView) -> [NSUserInterfaceItemIdentifier: CGFloat]? {
        guard table.tableColumns.contains(where: { $0.identifier.rawValue == "name" }) else { return nil }
        fit(table); trackingHeader = true
        return Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier, $0.width) })
    }
    func endHeaderInteraction(_ table: NSTableView, before: [NSUserInterfaceItemIdentifier: CGFloat]) {
        for column in table.tableColumns {
            if let old = before[column.identifier], abs(old - column.width) > 0.5 {
                userWidths[column.identifier] = column.width / InterfaceMetrics.scale
            }
        }
        trackingHeader = false; fit(table)
    }
}

/// Native header tracking shared by file listings and recorded-item tables.
/// It adds no selection, drag, menu or file-operation behavior.
@MainActor
class ColumnSizingHeaderView: NSTableHeaderView {
    override func mouseDown(with event: NSEvent) {
        let table = tableView, sizing = (table as? any FileColumnSizingTable)?.columnSizing
        let before = table.flatMap { sizing?.beginHeaderInteraction($0) }
        super.mouseDown(with: event)
        if let table, let before { sizing?.endHeaderInteraction(table, before: before) }
    }
}

@MainActor
final class FileTableHeaderView: ColumnSizingHeaderView {
    var columnMenu: NSMenu?
    var usesGlass = false {
        didSet {
            backdrop.isHidden = !usesGlass
            needsDisplay = true
        }
    }
    private let backdrop = FileHeaderBackdrop()
    var motionEnabled = true { didSet { updateIndicators() } }
    var motionMode = BrowserMotionMode.full { didSet {
        if motionMode != oldValue {
            for indicator in indicators.values { indicator.finishMotion() }
            updateIndicators()
        }
    } }
    private var hoverTracking: NSTrackingArea?
    private var hoveredColumn: NSUserInterfaceItemIdentifier?
    private var indicators: [NSUserInterfaceItemIdentifier: FileHeaderSortIndicator] = [:]
    private var indicatorStroke: CGColor?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }
    override func menu(for event: NSEvent) -> NSMenu? { columnMenu ?? super.menu(for: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A stable sibling material supplies the translucent header's backing even
    // while native labels redraw. AppKit retains every column interaction.
    override var isOpaque: Bool { !usesGlass }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        backdrop.removeFromSuperview()
        if let superview {
            backdrop.frame = frame
            backdrop.autoresizingMask = autoresizingMask
            backdrop.isHidden = !usesGlass
            superview.addSubview(backdrop, positioned: .below, relativeTo: self)
        }
    }
    override func layout() {
        super.layout(); backdrop.frame = frame
        reconcileIndicatorLayers(); updateIndicators()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); updateIndicators(); needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); indicatorStroke = nil; needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hoveredColumn = nil; updateIndicators() }
    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), index = column(at: point)
        if visibleRect.contains(point), let tableView, tableView.tableColumns.indices.contains(index),
           tableView.tableColumns[index].sortDescriptorPrototype != nil {
            hoveredColumn = tableView.tableColumns[index].identifier
        } else { hoveredColumn = nil }
        updateIndicators()
    }
    private func reconcileIndicatorLayers() {
        guard let tableView, let layer else { return }
        var visible = Set<NSUserInterfaceItemIdentifier>()
        for column in tableView.tableColumns where !column.isHidden && column.sortDescriptorPrototype != nil {
            visible.insert(column.identifier)
        }
        for key in Array(indicators.keys) where !visible.contains(key) {
            indicators.removeValue(forKey: key)?.remove()
        }
        for (index, column) in tableView.tableColumns.enumerated() where visible.contains(column.identifier) {
            let cell = headerRect(ofColumn: index)
            let glyph = NSRect(x: cell.maxX - 18, y: cell.midY - 8, width: 16, height: 16)
            let indicator: FileHeaderSortIndicator
            if let existing = indicators[column.identifier] { indicator = existing }
            else {
                indicator = FileHeaderSortIndicator()
                indicators[column.identifier] = indicator
            }
            indicator.install(in: layer)
            indicator.place(in: convertToLayer(glyph))
        }
    }
    private func updateIndicators(strokeColor: CGColor? = nil) {
        guard let tableView else { return }
        guard let backingLayer = layer else { needsLayout = true; return }
        if let strokeColor { indicatorStroke = strokeColor }
        let stroke = indicatorStroke ?? NSColor.labelColor.withAlphaComponent(0.85).cgColor
        let scale = window?.backingScaleFactor ?? 1
        let allowed = motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let descriptors = tableView.sortDescriptors
        var visible = Set<NSUserInterfaceItemIdentifier>()
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden && column.sortDescriptorPrototype != nil {
            visible.insert(column.identifier)
            let cell = headerRect(ofColumn: index)
            let glyph = NSRect(x: cell.maxX - 18, y: cell.midY - 8, width: 16, height: 16)
            guard let indicator = indicators[column.identifier], indicator.containerLayer.superlayer === backingLayer else {
                needsLayout = true; continue
            }
            if indicator.containerLayer.frame != convertToLayer(glyph) { needsLayout = true }
            indicator.apply(strokeColor: stroke, contentsScale: scale)
            // AppKit retains previous columns as secondary descriptors. The
            // browser orders by one field, so only its primary arrow is active.
            let sort: NSSortDescriptor?
            if let first = descriptors.first, first.key == column.sortDescriptorPrototype?.key { sort = first }
            else { sort = nil }
            var previous: NSSortDescriptor?
            for descriptor in descriptors where descriptor.key == column.sortDescriptorPrototype?.key {
                previous = descriptor; break
            }
            // Drawing labels ourselves bypasses the native header's cached
            // sort presentation. Keep its public accessibility property in
            // sync with the same primary descriptor, clearing secondary keys.
            let direction: NSAccessibilitySortDirection
            if let sort { direction = sort.ascending ? .ascending : .descending }
            else { direction = .unknown }
            if column.headerCell.accessibilitySortDirection() != direction {
                column.headerCell.setAccessibilitySortDirection(direction)
                NSAccessibility.post(element: column.headerCell, notification: .valueChanged)
            }
            indicator.present(ascending: sort?.ascending ?? previous?.ascending ?? column.sortDescriptorPrototype?.ascending ?? true,
                opacity: sort != nil ? 1 : (hoveredColumn == column.identifier ? 0.55 : 0), motion: allowed, mode: motionMode)
        }
        // A hidden column may request a redraw before AppKit lays out its
        // header. Hide obsolete ink now; detach only in the next layout pass.
        for (key, indicator) in indicators where !visible.contains(key) {
            indicator.present(ascending: true, opacity: 0, motion: false, mode: .off)
            needsLayout = true
        }
    }
    #if DEBUG
    func indicatorForVerification(_ column: NSTableColumn) -> FileHeaderSortIndicator? { indicators[column.identifier] }
    #endif
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(usesGlass ? 0.12 : 1).setFill()
        NSBezierPath.fill(dirtyRect)
        guard let tableView else { return }
        // AppKit establishes the drawing appearance here. Resolve the color
        // synchronously; no actor-crossing appearance block or geometry edit.
        updateIndicators(strokeColor: NSColor.labelColor.withAlphaComponent(0.85).cgColor)
        // NSTableHeaderView's full draw includes an opaque floating background.
        // Draw native labels and decorative chevrons over our material instead.
        // The original header still owns tracking, geometry and accessibility.
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            // Header-cell interiors retain AppKit's old arrow state when its
            // full floating-header draw is bypassed. Render a plain native
            // label and the explicit current sort indicator independently.
            let font = InterfaceMetrics.font(NSFont.smallSystemFontSize)
            let height = min(rect.height, ceil(font.ascender - font.descender + font.leading))
            let title = NSRect(x: rect.minX + 7, y: rect.minY + (rect.height - height) / 2,
                width: max(0, rect.width - (column.sortDescriptorPrototype == nil ? 14 : 28)), height: height)
            let label = NSTextFieldCell(textCell: column.title)
            label.font = font; label.textColor = .labelColor; label.alignment = column.headerCell.alignment
            label.isBordered = false; label.drawsBackground = false
            label.lineBreakMode = .byTruncatingTail; label.usesSingleLineMode = true
            label.drawInterior(withFrame: title, in: self)
            NSColor.separatorColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.maxX - 0.5, y: 5))
            line.line(to: NSPoint(x: rect.maxX - 0.5, y: bounds.height - 5))
            line.stroke()
        }
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1))
    }
}

@MainActor
private final class FileHeaderBackdrop: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let surface = NavigationGlassSurface(contentView: NSView(), opaqueColor: .controlBackgroundColor)
        pin(surface, inside: self)
    }
    required init?(coder: NSCoder) { nil }
}

/// A fixed template canvas prevents NSPathControl from stretching symbol
/// alignment bounds. Draw the source proportionally inside that canvas.
@MainActor
func breadcrumbSymbol(_ name: String, _ description: String) -> NSImage? {
    guard let source = symbol(name, description)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return nil }
    let canvas: CGFloat = 16
    let ratio = min(canvas / max(1, source.size.width), canvas / max(1, source.size.height))
    let size = NSSize(width: source.size.width * ratio, height: source.size.height * ratio)
    let rect = NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height)
    let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
}
