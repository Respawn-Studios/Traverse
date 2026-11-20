import AppKit
import ExplorerCore
import QuickLookUI

@MainActor
func symbol(_ name: String, _ label: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: label)
}

@MainActor
func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor,
           weight: NSFont.Weight = .regular) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    InterfaceMetrics.setFont(view, base: .systemFont(ofSize: size, weight: weight))
    view.textColor = color
    view.lineBreakMode = .byTruncatingMiddle
    return view
}

@MainActor
func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation,
           spacing: CGFloat = 8) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = orientation
    view.distribution = .fill
    view.spacing = spacing
    view.alignment = orientation == .horizontal ? .centerY : .leading
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

@MainActor
func pin(_ child: NSView, inside parent: NSView, inset: CGFloat = 0, belowTitlebar: Bool = false) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: belowTitlebar ? parent.safeAreaLayoutGuide.topAnchor : parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

@MainActor
final class FileNameCellView: NSTableCellView {
    let cutMarker = NSImageView()
    var nameTrailing: NSLayoutConstraint?
    private var gitLabel: NSTextField?
    private var gitTrailing: NSLayoutConstraint?
    private var nameToGit: NSLayoutConstraint?
    #if DEBUG
    private(set) static var createdCells = 0
    private(set) static var createdCutMarkers = 0
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if DEBUG
        Self.createdCells += 1; Self.createdCutMarkers += 1
        #endif
        cutMarker.image = BrowserCellSymbols.image(.cut)
        cutMarker.contentTintColor = .labelColor
        cutMarker.translatesAutoresizingMaskIntoConstraints = false
        cutMarker.isHidden = true
        addSubview(cutMarker)
        NSLayoutConstraint.activate([
            cutMarker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            cutMarker.centerYAnchor.constraint(equalTo: centerYAnchor),
            cutMarker.widthAnchor.constraint(equalToConstant: 12).interfaceScaled,
            cutMarker.heightAnchor.constraint(equalToConstant: 12).interfaceScaled
        ])
    }

    required init?(coder: NSCoder) { nil }

    func showCutMarker(_ visible: Bool) {
        cutMarker.isHidden = !visible
        updateTrailingAccessories()
    }

    func showGitBadge(_ badge: GitStatusBadge?) {
        guard let badge else {
            if let gitLabel, !gitLabel.isHidden {
                gitLabel.isHidden = true
                nameToGit?.isActive = false
                nameTrailing?.isActive = true
            }
            return
        }
        if gitLabel == nil, let textField {
            let note = label("", size: 10, color: .secondaryLabelColor)
            InterfaceMetrics.setFont(note, base: .monospacedSystemFont(ofSize: 10, weight: .semibold))
            note.translatesAutoresizingMaskIntoConstraints = false
            note.setAccessibilityHidden(true)
            note.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(note)
            let trailing = note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
            NSLayoutConstraint.activate([trailing, note.centerYAnchor.constraint(equalTo: centerYAnchor)])
            gitLabel = note; gitTrailing = trailing
            nameToGit = textField.trailingAnchor.constraint(equalTo: note.leadingAnchor, constant: -6)
        }
        gitLabel?.stringValue = badge.text
        gitLabel?.isHidden = false
        nameTrailing?.isActive = false
        nameToGit?.isActive = true
        updateTrailingAccessories()
    }

    private func updateTrailingAccessories() {
        let offset: CGFloat = cutMarker.isHidden ? -6 : -23
        nameTrailing?.constant = offset
        gitTrailing?.constant = offset
    }
}

/// Local and remote tables share native name/icon geometry. The caller supplies
/// presentation metadata only; creating a cell never inspects a file or server.
@MainActor enum FileTableCell {
    static func view(in table: NSTableView, column: String) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell.\(column)")
        if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = column == "name" ? FileNameCellView() : NSTableCellView()
        cell.identifier = identifier
        let text = label(""); text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text; cell.addSubview(text)
        var leading = cell.leadingAnchor, inset: CGFloat = 2
        if column == "name" {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setAccessibilityHidden(true); cell.imageView = icon; cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18).interfaceScaled,
                icon.heightAnchor.constraint(equalToConstant: 18).interfaceScaled
            ])
            leading = icon.trailingAnchor; inset = 8
        }
        let trailing = text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6)
        (cell as? FileNameCellView)?.nameTrailing = trailing
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: inset), trailing,
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    static func remote(in table: NSTableView, column: String, text: String, role: FileIconRole?,
                       opening: FileOpeningAppearance = .ordinary, cut: Bool = false) -> NSTableCellView {
        let cell = view(in: table, column: column)
        cell.textField?.stringValue = text
        cell.textField?.textColor = column == "name" ? .labelColor : .secondaryLabelColor
        cell.textField?.alignment = column == "size" ? .right : .left
        cell.imageView?.image = role.flatMap { FileOpeningSymbol.image(role: $0, appearance: opening) }
        cell.imageView?.contentTintColor = FileOpeningSymbol.tint(opening, directory: role == .directory)
        if let name = cell as? FileNameCellView {
            name.showCutMarker(cut); name.showGitBadge(nil)
        }
        cell.alphaValue = 1; cell.toolTip = opening.explanation; cell.setAccessibilityLabel(text)
        cell.setAccessibilityHelp(cut ? "Cut: ready to move when pasted in this connection." : opening.explanation)
        return cell
    }
}

@MainActor
class FileTableView: NSTableView, NSMenuItemValidation, FileColumnSizingTable {
    let columnSizing = FileColumnSizing()
    private let pointerSelection = BrowserPointerSelection()
    private let nameClick = SelectedNameClickRename()
    var nameClickRenameEnabled: (() -> Bool)?
    var marquee: TableMarqueeSelection?
    private var marqueeOwnsMouseSequence = false
    private(set) var marqueeRevision: UInt64 = 0
    var onSummaryPointer: ((NSPoint?) -> Void)?
    private var summaryTracking: NSTrackingArea?

    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        BrowserPointerSelection.isControlCopyDrag(NSEvent.modifierFlags, controlAliases: behavior.controlAliasesEnabled)
            || super.ignoreModifierKeys(for: session)
    }

    override func mouseDown(with event: NSEvent) {
        nameClick.begin(event, table: self, revision: marqueeRevision, currentRevision: { [weak self] in self?.marqueeRevision ?? 0 },
            enabled: nameClickRenameEnabled?() == true, action: { [weak self] in
                guard let self, commandValidation?(#selector(BrowserViewController.renameSelection(_:))) != false else { return }; onRename?()
            })
        let adapted = pointerSelection.begin(event, in: self, behavior: behavior, isEditingText: currentEditor() != nil)
        marqueeOwnsMouseSequence = marquee?.begin(with: adapted) == true
        if !marqueeOwnsMouseSequence { super.mouseDown(with: adapted) }
    }
    override func mouseDragged(with event: NSEvent) {
        nameClick.cancel()
        let adapted = pointerSelection.continuing(event, in: self)
        if marqueeOwnsMouseSequence { marquee?.drag(with: adapted) } else { super.mouseDragged(with: adapted) }
    }
    override func mouseUp(with event: NSEvent) {
        let adapted = pointerSelection.continuing(event, in: self)
        if marqueeOwnsMouseSequence { marqueeOwnsMouseSequence = false; marquee?.end(with: adapted) } else { super.mouseUp(with: adapted) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let summaryTracking { removeTrackingArea(summaryTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); summaryTracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onSummaryPointer?(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onSummaryPointer?(nil) }
    override func reloadData() {
        nameClick.cancel(); pointerSelection.cancel(); marquee?.cancel(restore: false); marqueeRevision &+= 1
        onSummaryPointer?(nil); super.reloadData()
    }
    override func noteNumberOfRowsChanged() {
        nameClick.cancel(); pointerSelection.cancel(); marquee?.cancel(restore: false); marqueeRevision &+= 1; super.noteNumberOfRowsChanged()
    }
    override func layout() { super.layout(); columnSizing.fit(self); marquee?.layout() }
    override func viewDidMoveToWindow() { pointerSelection.cancel(); super.viewDidMoveToWindow(); marquee?.bindWindow() }

    var onShortcut: ((NSEvent) -> Bool)?
    var onDragVisibleRowsChanged: (() -> Void)?
    var onFileDragExited: (() -> Void)?
    var behavior = BrowserBehaviorPreferences.explorer {
        didSet { if behavior != oldValue { pointerSelection.cancel(); marquee?.cancel(restore: false) } }
    }
    override func resignFirstResponder() -> Bool { pointerSelection.cancel(); return super.resignFirstResponder() }
    var explorerKeysEnabled: Bool {
        get { behavior == .explorer }
        set { behavior = newValue ? .explorer : .mac }
    }
    var onOpen: (() -> Void)?
    var onBack: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onUndo: (() -> Void)?
    weak var quickLookController: BrowserQuickLookController?
    var commandValidation: ((Selector?) -> Bool)?
    var contextMenuProvider: (() -> NSMenu?)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onDragVisibleRowsChanged?()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onFileDragExited?()
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        nameClick.cancel()
        if let onShortcut {
            if onShortcut(event) { return }
            super.keyDown(with: event); return
        }
        if let action = behavior.fileAction(for: event) {
            switch action {
            case .open: onOpen?()
            case .rename: onRename?()
            case .back: onBack?()
            case .trash: onTrash?()
            case .quickLook: onQuickLook?()
            }
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
    @objc func undo(_ sender: Any?) { onUndo?() }
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLookController?.acceptsControl == true }
    }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookController?.beginControl(panel) }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookController?.endControl(panel) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { commandValidation?(item.action) ?? true }

    override func menu(for event: NSEvent) -> NSMenu? {
        // NSWindow can ask for a Control-primary menu before mouseDown. The
        // Explorer alias must reach native selection without context mutation.
        if BrowserPointerSelection.isSelectionAlias(event, in: self, behavior: behavior,
            isEditingText: currentEditor() != nil) { return nil }
        // Right-clicks can arrive while another window/app is key. An explicit
        // file context request must target this visible browser before native
        // command validation; hidden verification views stay hidden.
        if let window, window.isVisible {
            if !NSApplication.shared.isActive { NSApplication.shared.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(self)
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked < 0 {
            deselectAll(nil)
        } else if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return contextMenuProvider?() ?? super.menu(for: event)
    }
}

@MainActor
class ActionButton: NSButton {
    var actionHandler: (() -> Void)?

    convenience init(title: String, image: NSImage? = nil, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        self.imagePosition = image == nil ? .noImage : .imageLeading
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(invoke(_:))
        self.actionHandler = action
    }

    @objc private func invoke(_ sender: Any?) { actionHandler?() }
}

/// Native path truncation and keyboard accessibility, with Explorer's familiar
/// click-on-unused-address-space to edit. No URL/icon filesystem resolution.
@MainActor
final class ExplorerPathControl: CollapsingPathControl {
    var onEdit: (() -> Void)?
    override var trailingEditFraction: CGFloat { 0.10 }
    private var firstClickWasCurrentComponent = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pathCell = cell as? NSPathCell else { super.mouseDown(with: event); return }
        let component = pathCell.pathComponentCell(at: point, withFrame: bounds, in: self)
        let isCurrent = component != nil && component === pathCell.pathComponentCells.last
        if event.clickCount == 1 { firstClickWasCurrentComponent = isCurrent }
        if component == nil || (event.clickCount == 2 && firstClickWasCurrentComponent && isCurrent) {
            onEdit?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class AddressSurfaceView: NSView {
    var onEdit: (() -> Void)?
    let editPathButton = NSButton()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editPathButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit folder path")
        editPathButton.isBordered = false
        editPathButton.bezelStyle = .recessed
        editPathButton.toolTip = "Edit folder path (⌘L)"
        editPathButton.setAccessibilityLabel("Edit folder path")
        editPathButton.target = self
        editPathButton.action = #selector(editPath(_:))
        editPathButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editPathButton)
        NSLayoutConstraint.activate([
            editPathButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            editPathButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            editPathButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            editPathButton.widthAnchor.constraint(equalToConstant: 22).interfaceScaled
        ])
    }
    required init?(coder: NSCoder) { nil }
    func setEditing(_ editing: Bool) {
        editPathButton.setAccessibilityLabel(editing ? "Show folder breadcrumbs" : "Edit folder path")
        editPathButton.toolTip = editing ? "Show folder breadcrumbs (Escape)" : "Edit folder path (⌘L)"
    }
    func installAddressControl(_ control: NSView) {
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control, positioned: .below, relativeTo: editPathButton)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            control.trailingAnchor.constraint(equalTo: editPathButton.leadingAnchor, constant: -2),
            control.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }
    @objc private func editPath(_ sender: Any?) { onEdit?() }
    var isGlassEnabled = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        let translucent = BrowserMaterialPolicy.glassEnabled(style: .glass, enabled: isGlassEnabled,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        (translucent ? NSColor.textBackgroundColor.withAlphaComponent(0.22) : .textBackgroundColor).setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

/// Use native font line metrics for the same rectangle in display, editing and
/// selection. The field's visual height can change without a baseline offset.
@MainActor
final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: NSFont.systemFontSize))
        let height = min(result.height, ceil(lineHeight))
        result.origin.y += (result.height - height) / 2
        result.size.height = height
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: drawingRect(forBounds: cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}

@MainActor
final class BrowserAddressRow: NSView {
    var drawsSolidBackground = true { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if drawsSolidBackground {
            NSColor.controlBackgroundColor.setFill()
            bounds.intersection(dirtyRect).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

@MainActor
final class SidebarNode: NSObject {
    let acceptsFolderPins: Bool
    let title: String
    let location: BrowserLocation?
    let icon: String
    let group: Bool
    let connectionTarget: BrowserConnectionIdentity?
    let serverBookmark: WorkspaceConnectionBookmark?
    var detail: String?
    let remotePin: UUID?
    var children: [SidebarNode]?
    var loading = false
    var task: Task<Void, Never>?

    init(_ title: String, location: BrowserLocation? = nil, icon: String = "folder",
         group: Bool = false, acceptsFolderPins: Bool = false, children: [SidebarNode]? = nil,
         connectionTarget: BrowserConnectionIdentity? = nil, detail: String? = nil, remotePin: UUID? = nil,
         serverBookmark: WorkspaceConnectionBookmark? = nil) {
        self.title = title
        self.location = location
        self.icon = icon
        self.group = group
        self.connectionTarget = connectionTarget; self.detail = detail
        self.serverBookmark = serverBookmark
        self.remotePin = remotePin
        self.acceptsFolderPins = acceptsFolderPins
        self.children = children
    }
}

struct OrderedRows: Sendable {
    var entries: [FileEntry]
    var rowsByURL: [URL: Int]
}

actor RowOrdering {
    func order(_ entries: [FileEntry], sort: DirectorySort, filter: String) throws -> OrderedRows {
        try Task.checkCancellation()
        let ordered = try orderedEntries(entries, sort: sort, filter: filter,
                                         checkCancellation: { try Task.checkCancellation() })
        try Task.checkCancellation()
        var lookup: [URL: Int] = [:]
        lookup.reserveCapacity(ordered.count)
        for (index, entry) in ordered.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            lookup[entry.url] = index
        }
        try Task.checkCancellation()
        return OrderedRows(entries: ordered, rowsByURL: lookup)
    }
}

@MainActor
extension BrowserBehaviorPreferences {
    func fileAction(for event: NSEvent) -> FileAction? {
        let key: FileKey
        switch event.keyCode {
        case 36, 76: key = .returnKey
        case 51: key = .backspace
        case 120: key = .function2
        case 117: key = .forwardDelete
        case 49: key = .space
        default: return nil
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return action(for: key, modifiers: modifiers)
    }
}
