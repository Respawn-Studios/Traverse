import AppKit
import ExplorerCore
import QuickLookUI

/// A recycled presentation of already supplied shallow observations. This view
/// never queries file metadata, requests thumbnails, or reads file bodies.
@MainActor
final class FileIconBrowserView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collectionView = FileIconCollectionView()
    let scrollView = NSScrollView()
    private let clipView = FileIconClipView()
    private let flow = FileIconFlowLayout()
    private var entries: [FileEntry] = []
    private var indexes: [URL: Int] = [:]
    private var cut = Set<URL>()
    private var showsExtensions = true
    var showsFullPathsInTooltips = false
    var openingAppearanceForEntry: ((FileEntry) -> FileOpeningAppearance)?
    var showsFolderSummaries = true {
        didSet { for item in visibleItems { if let entry = item.entry { configure(item, entry: entry) } } }
    }
    func summaryEntry(at point: NSPoint) -> FileEntry? {
        guard let path = collectionView.indexPathForItem(at: point), entries.indices.contains(path.item) else { return nil }
        return entries[path.item]
    }
    private var updatingSelection = false
    private var dropTarget: URL?
    private var boundsObservation: BrowserNotificationObservation?
    private var focusObservations: [BrowserNotificationObservation] = []
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("FileIconItem")
    #if DEBUG
    private(set) var snapshotReplacementCount = 0
    private(set) var fullSelectionOrderCount = 0
    #endif

    var onSelectionChange: (() -> Void)?
    var onAccessibleActivation: (() -> Bool)?
    var onVisibleEntriesChanged: (() -> Void)?
    var onPasteboardWriter: ((URL) -> (any NSPasteboardWriting)?)?
    var onDragWillBegin: ((NSDraggingSession, [URL]) -> Void)?
    var onDragEnded: ((NSDraggingSession) -> Void)?
    var onValidateDrop: ((NSDraggingInfo, URL?) -> NSDragOperation)?
    var onAcceptDrop: ((NSDraggingInfo, URL?) -> Bool)?
    var onDragExited: (() -> Void)?
    var contentBackgroundIsTransparent = false {
        didSet {
            collectionView.backgroundColors = contentBackgroundIsTransparent ? [.clear] : [.controlBackgroundColor]
            scrollView.drawsBackground = !contentBackgroundIsTransparent
            scrollView.contentView.drawsBackground = !contentBackgroundIsTransparent
            needsDisplay = true
        }
    }

    var orderedSelectedURLs: [URL] {
        #if DEBUG
        fullSelectionOrderCount += 1
        #endif
        return collectionView.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap {
            entries.indices.contains($0.item) ? entries[$0.item].url : nil
        }
    }
    var selectedCount: Int { collectionView.selectionIndexPaths.count }
    var selectedURLs: Set<URL> {
        Set(collectionView.selectionIndexPaths.compactMap {
            entries.indices.contains($0.item) ? entries[$0.item].url : nil
        })
    }

    /// Quick Look needs only the first bounded subset in display order. A
    /// bounded max-heap avoids sorting/materializing a whole Select All set.
    func orderedSelectedURLs(upTo limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        let paths = collectionView.selectionIndexPaths
        if paths.count <= limit { return orderedSelectedURLs }
        var heap: [Int] = []
        heap.reserveCapacity(limit)
        for path in paths where path.section == 0 && entries.indices.contains(path.item) {
            let index = path.item
            if heap.count < limit {
                heap.append(index)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard heap[child] > heap[parent] else { break }
                    heap.swapAt(child, parent); child = parent
                }
            } else if index < heap[0] {
                heap[0] = index
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count && heap[child + 1] > heap[child] { child += 1 }
                    guard heap[child] > heap[parent] else { break }
                    heap.swapAt(child, parent); parent = child
                }
            }
        }
        return heap.sorted().map { entries[$0].url }
    }
    var visibleEntries: [FileEntry] {
        collectionView.indexPathsForVisibleItems().sorted { $0.item < $1.item }.compactMap {
            entries.indices.contains($0.item) ? entries[$0.item] : nil
        }
    }
    var visibleItems: [FileIconItem] { collectionView.visibleItems().compactMap { $0 as? FileIconItem } }
    var itemCount: Int { entries.count }
    var scrollOffset: Double {
        get { max(0, scrollView.contentView.bounds.origin.y + scrollView.contentView.contentInsets.top) }
        set {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, newValue) - scrollView.contentView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        flow.itemSize = NSSize(width: 136, height: 120)
        flow.minimumInteritemSpacing = 8
        flow.minimumLineSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self; collectionView.delegate = self
        collectionView.isSelectable = true; collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(FileIconItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.setAccessibilityLabel("Files in the current folder, Icons view")
        collectionView.autoresizingMask = [.width]
        collectionView.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        collectionView.registerForDraggedTypes([.fileURL, ArchiveMemberDragSource.pasteboardType,
            RemoteDownloadDrag.pasteboardType])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.onSelectionAppearanceChanged = { [weak self] in self?.refreshVisibleItems() }
        collectionView.onContextSelection = { [weak self] event in self?.selectContextItem(event) }
        collectionView.onValidateFileDrop = { [weak self] info in self?.validateDrop(info) ?? [] }
        collectionView.onAcceptFileDrop = { [weak self] info in self?.acceptDrop(info) ?? false }
        collectionView.onFileDragExited = { [weak self] in self?.setDropTarget(nil); self?.onDragExited?() }
        scrollView.contentView = clipView
        clipView.onWillResize = { [weak self] width in self?.flow.prepareForClipWidth(width) }
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true; scrollView.backgroundColor = .controlBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObservation = BrowserNotificationObservation(name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView) { [weak self] _ in
                MainActor.assumeIsolated { self?.onVisibleEntriesChanged?() }
            }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservations.append(BrowserNotificationObservation(name: name) { [weak self] _ in
                // The observation wrapper delivers on OperationQueue.main.
                // Recompute from our own window; do not send Notification's Any
                // payload across an actor boundary.
                MainActor.assumeIsolated { self?.refreshVisibleItems() }
            })
        }
        pin(scrollView, inside: self)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = max(1, scrollView.contentView.bounds.width)
        if abs(collectionView.frame.width - width) > 0.5 {
            collectionView.setFrameSize(NSSize(width: width, height: collectionView.frame.height))
            flow.invalidateLayout()
        }
        onVisibleEntriesChanged?()
    }

    /// The ordering actor already builds this paired entry/index snapshot. Reuse
    /// its copy-on-write values; do not rebuild a second full index on the UI actor.
    func update(_ rows: OrderedRows, selected: Set<URL>, cut: Set<URL>, showsExtensions: Bool) {
        entries = rows.entries
        indexes = rows.rowsByURL
        self.cut = cut; self.showsExtensions = showsExtensions
        dropTarget = nil
        #if DEBUG
        snapshotReplacementCount += 1
        #endif
        updatingSelection = true
        collectionView.reloadData()
        setSelection(selected)
        updatingSelection = false
        onVisibleEntriesChanged?()
    }

    /// Cut/extension/selection changes affect visible tiles only. Offscreen
    /// items receive the current appearance when AppKit presents them again.
    func updateAppearance(selected: Set<URL>, cut: Set<URL>, showsExtensions: Bool) {
        self.cut = cut; self.showsExtensions = showsExtensions
        setSelection(selected)
        for item in visibleItems {
            guard let entry = item.entry else { continue }
            configure(item, entry: entry)
        }
    }

    func setSelection(_ urls: Set<URL>) {
        let wasUpdating = updatingSelection; updatingSelection = true
        collectionView.selectionIndexPaths = Set(urls.compactMap { indexes[$0].map { IndexPath(item: $0, section: 0) } })
        updatingSelection = wasUpdating
        refreshVisibleItems()
    }

    func focus() { window?.makeFirstResponder(collectionView) }
    func reveal(_ url: URL) {
        guard let index = indexes[url] else { return }
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
        collectionView.layoutSubtreeIfNeeded()
    }

    /// Resolve after asynchronous validation. Geometry belongs to the actual
    /// filename in the visible collection view, never a hidden table row.
    func selectionAnchor(for urls: [URL]) -> NSRect? {
        guard !urls.isEmpty, urls.allSatisfy({ indexes[$0] != nil }) else { return nil }
        if !visibleItems.contains(where: { item in item.entry.map { urls.contains($0.url) } == true }), let first = urls.first {
            reveal(first)
        }
        collectionView.layoutSubtreeIfNeeded()
        func visibleAnchor() -> NSRect? {
            guard let item = visibleItems.first(where: { item in item.entry.map { urls.contains($0.url) } == true }) else { return nil }
            let rect = collectionView.convert(item.filenameLabel.bounds, from: item.filenameLabel).intersection(collectionView.visibleRect)
            return rect.isEmpty ? nil : rect
        }
        if let rect = visibleAnchor() { return rect }
        // A tile can intersect the viewport while its filename is clipped.
        // Bring the selected filename into view before exposing native geometry.
        guard let first = urls.first else { return nil }
        reveal(first)
        return visibleAnchor()
    }

    func inlineFilenameAnchor(for url: URL) -> (rect: NSRect, label: NSTextField)? {
        guard let rect = selectionAnchor(for: [url]),
              let item = visibleItems.first(where: { $0.entry?.url == url }) else { return nil }
        return (rect, item.filenameLabel)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        if let cell = item as? FileIconItem, entries.indices.contains(indexPath.item) {
            let entry = entries[indexPath.item]
            configure(cell, entry: entry)
            cell.onAccessibleOpen = { [weak self] url in
                guard let self, self.indexes[url] != nil, self.collectionView.isSelectable, self.collectionView.onOpen != nil,
                      NativeAccessibleAction.canInvoke(self), NativeAccessibleAction.activateWindow(self),
                      self.onAccessibleActivation?() != false else { return false }
                guard self.indexes[url] != nil, self.collectionView.isSelectable, NativeAccessibleAction.canInvoke(self) else { return false }
                self.window?.makeFirstResponder(self.collectionView)
                self.setSelection([url]); self.onSelectionChange?(); self.collectionView.onOpen?(); return true
            }
        }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let item = item as? FileIconItem, entries.indices.contains(indexPath.item) else { return }
        configure(item, entry: entries[indexPath.item])
    }
    private func configure(_ item: FileIconItem, entry: FileEntry) {
        let opening = openingAppearanceForEntry?(entry) ?? .ordinary
        item.configure(entry, showsExtensions: showsExtensions, cut: cut.contains(entry.url), emphasized: selectionIsEmphasized,
                       openingAppearance: opening)
        if showsFullPathsInTooltips {
            item.view.toolTip = entry.url.path + (cut.contains(entry.url) ? " — Cut: ready to move when pasted" : "")
            if let explanation = opening.explanation { item.view.toolTip = (item.view.toolTip ?? entry.url.path) + "\n" + explanation }
            item.view.setAccessibilityLabel(entry.name + ", in " + entry.url.deletingLastPathComponent().path
                + (opening.explanation.map { ", " + $0 } ?? ""))
        }
        if showsFolderSummaries, entry.kind == .directory, !showsFullPathsInTooltips { item.view.toolTip = nil }
        item.isDropTarget = entry.url == dropTarget
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    private func selectionChanged() {
        guard !updatingSelection else { return }
        refreshVisibleItems(); onSelectionChange?()
    }
    private var selectionIsEmphasized: Bool { BrowserSelectionFocus.isEmphasized(in: collectionView) }
    private func refreshVisibleItems() { for item in visibleItems { item.emphasized = selectionIsEmphasized } }

    private func selectContextItem(_ event: NSEvent) {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        if let path = collectionView.indexPathForItem(at: point) {
            if !collectionView.selectionIndexPaths.contains(path) { collectionView.selectionIndexPaths = [path] }
        } else { collectionView.selectionIndexPaths = [] }
        refreshVisibleItems(); onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard entries.indices.contains(indexPath.item) else { return nil }
        return onPasteboardWriter?(entries[indexPath.item].url)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        let urls = indexPaths.sorted { $0.item < $1.item }.compactMap { entries.indices.contains($0.item) ? entries[$0.item].url : nil }
        guard urls.count == indexPaths.count else { return }
        onDragWillBegin?(session, urls)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { onDragEnded?(session) }

    private func destination(_ info: NSDraggingInfo) -> (valid: Bool, url: URL?) {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        guard collectionView.visibleRect.contains(point) else { return (false, nil) }
        guard let path = collectionView.indexPathForItem(at: point) else { return (true, nil) }
        guard entries.indices.contains(path.item), entries[path.item].kind == .directory else { return (false, nil) }
        return (true, entries[path.item].url)
    }
    private func validateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let target = destination(info)
        guard target.valid else { setDropTarget(nil); return [] }
        let operation = onValidateDrop?(info, target.url) ?? []
        setDropTarget(operation.isEmpty ? nil : target.url)
        return operation
    }
    private func acceptDrop(_ info: NSDraggingInfo) -> Bool {
        defer { setDropTarget(nil); onDragExited?() }
        let target = destination(info)
        guard target.valid else { return false }
        return onAcceptDrop?(info, target.url) ?? false
    }
    private func setDropTarget(_ url: URL?) {
        guard dropTarget != url else { return }
        dropTarget = url
        for item in visibleItems { item.isDropTarget = url != nil && item.entry?.url == url }
    }
}

@MainActor
private final class FileIconClipView: NSClipView {
    var onWillResize: ((CGFloat) -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width { onWillResize?(newSize.width) }
        super.setFrameSize(newSize)
    }
}

/// A collection can be resized by NSScrollView before its parent's layout
/// callback. Admit flow preparation from the actual clip allocation, keeping
/// supplied data/selection intact while a hidden or newly born pane is narrow.
@MainActor
private final class FileIconFlowLayout: NSCollectionViewFlowLayout {
    private var viewportWidth: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
    }
    private var availableWidth: CGFloat {
        var width = min(viewportWidth, collectionView?.bounds.width ?? 0)
        if let scroll = collectionView?.enclosingScrollView, scroll.hasVerticalScroller,
           scroll.scrollerStyle == .legacy {
            // The first admitted rows can reveal a legacy scroller during
            // native preparation. Size for that allocation before asking the
            // superclass for any attributes, rather than correcting it later.
            let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            width = min(width, scroll.bounds.width - scroller)
        }
        return width
    }
    private var canPrepareItems: Bool {
        let minimum = 16 + sectionInset.left + sectionInset.right
        return availableWidth.isFinite && availableWidth >= minimum
    }
    /// Run before NSClipView posts its frame change. NSCollectionView handles
    /// that notification by preparing immediately, before the parent's layout.
    func prepareForClipWidth(_ proposed: CGFloat) {
        var width = proposed
        if let scroll = collectionView?.enclosingScrollView, scroll.hasVerticalScroller,
           scroll.scrollerStyle == .legacy {
            width = min(width, scroll.bounds.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        }
        if width >= 16 + sectionInset.left + sectionInset.right {
            itemSize.width = min(InterfaceMetrics.points(136), max(16, width - sectionInset.left - sectionInset.right))
        }
        let context = NSCollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutDelegateMetrics = true
        context.invalidateFlowLayoutAttributes = true
        invalidateLayout(with: context)
    }
    private func admitItems() -> Bool {
        guard canPrepareItems else { return false }
        let width = min(InterfaceMetrics.points(136), max(16, availableWidth - sectionInset.left - sectionInset.right))
        if itemSize.width != width || itemSize.height != InterfaceMetrics.points(120) {
            itemSize.width = width
            itemSize.height = InterfaceMetrics.points(120)
            // A deferred section may still cache its previous per-item size.
            // Invalidate metrics as well as attributes before native prepare
            // resumes, rather than correcting the public itemSize alone.
            let context = NSCollectionViewFlowLayoutInvalidationContext()
            context.invalidateFlowLayoutDelegateMetrics = true
            context.invalidateFlowLayoutAttributes = true
            invalidateLayout(with: context)
        }
        return true
    }
    override func prepare() {
        guard admitItems() else { return }
        super.prepare()
    }
    override var collectionViewContentSize: NSSize {
        admitItems() ? super.collectionViewContentSize : NSSize(width: max(0, viewportWidth), height: 0)
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        admitItems() ? super.layoutAttributesForItem(at: indexPath) : nil
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        admitItems() ? super.layoutAttributesForElements(in: rect) : []
    }
}

@MainActor
final class FileIconCollectionView: NSCollectionView, NSMenuItemValidation {
    var onSummaryPointer: ((NSPoint?) -> Void)?
    private var summaryTracking: NSTrackingArea?
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        BrowserPointerSelection.isControlCopyDrag(NSEvent.modifierFlags, controlAliases: behavior.controlAliasesEnabled)
            || super.ignoreModifierKeys(for: session)
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
    override func reloadData() { nameClick.cancel(); onSummaryPointer?(nil); super.reloadData() }

    var onShortcut: ((NSEvent) -> Bool)?
    private let nameClick = SelectedNameClickRename()
    var nameClickRenameEnabled: (() -> Bool)?
    private let pointerSelection = BrowserPointerSelection()
    var behavior = BrowserBehaviorPreferences.explorer { didSet { if behavior != oldValue { pointerSelection.cancel() } } }
    override func mouseDown(with event: NSEvent) {
        nameClick.begin(event, collection: self, enabled: nameClickRenameEnabled?() == true, action: { [weak self] in
            guard let self, commandValidation?(#selector(BrowserViewController.renameSelection(_:))) != false else { return }; onRename?()
        })
        super.mouseDown(with: pointerSelection.begin(event, in: self, behavior: behavior,
            isEditingText: BrowserPointerSelection.isEditingText(in: self)))
    }
    override func mouseDragged(with event: NSEvent) { nameClick.cancel(); super.mouseDragged(with: pointerSelection.continuing(event, in: self)) }
    override func mouseUp(with event: NSEvent) { super.mouseUp(with: pointerSelection.continuing(event, in: self)) }
    override func viewDidMoveToWindow() { pointerSelection.cancel(); super.viewDidMoveToWindow() }
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
    var onContextSelection: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onSelectionAppearanceChanged: (() -> Void)?
    var commandValidation: ((Selector?) -> Bool)?
    weak var quickLookController: BrowserQuickLookController?
    var onValidateFileDrop: ((NSDraggingInfo) -> NSDragOperation)?
    var onAcceptFileDrop: ((NSDraggingInfo) -> Bool)?
    var onFileDragExited: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onSelectionAppearanceChanged?()
            DispatchQueue.main.async { [weak self] in self?.onSelectionAppearanceChanged?() }
        }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        pointerSelection.cancel()
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onSelectionAppearanceChanged?() } }
        return accepted
    }
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
    override func menu(for event: NSEvent) -> NSMenu? {
        if BrowserPointerSelection.isSelectionAlias(event, in: self, behavior: behavior,
            isEditingText: BrowserPointerSelection.isEditingText(in: self)) { return nil }
        if let window, window.isVisible {
            if !NSApplication.shared.isActive { NSApplication.shared.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(self)
        onContextSelection?(event)
        return onContextMenu?(event) ?? super.menu(for: event)
    }
    @objc func copy(_ sender: Any?) { if commandValidation?(#selector(copy(_:))) != false { onCopy?() } }
    @objc func cut(_ sender: Any?) { if commandValidation?(#selector(cut(_:))) != false { onCut?() } }
    @objc func paste(_ sender: Any?) { if commandValidation?(#selector(paste(_:))) != false { onPaste?() } }
    @objc func undo(_ sender: Any?) { if commandValidation?(#selector(undo(_:))) != false { onUndo?() } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { commandValidation?(item.action) ?? true }
    // QuickLookUI's responder declarations lack UI actor annotations. AppKit
    // invokes these on the UI thread; assert that boundary synchronously.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLookController?.acceptsControl == true }
    }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookController?.beginControl(panel) }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLookController?.endControl(panel) }
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onValidateFileDrop?(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onValidateFileDrop?(sender) ?? [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !(onValidateFileDrop?(sender) ?? []).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onAcceptFileDrop?(sender) ?? false }
    override func draggingExited(_ sender: NSDraggingInfo?) { onFileDragExited?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onFileDragExited?() }
}

@MainActor
final class FileIconItem: NSCollectionViewItem, NSGestureRecognizerDelegate {
    private(set) var entry: FileEntry?
    let filenameLabel = label("", size: 12)
    let fileImage = NSImageView()
    let cutBadge = NSImageView()
    var onAccessibleOpen: ((URL) -> Bool)?
    var emphasized = false { didSet { refreshAppearance() } }
    var isDropTarget = false { didSet { refreshAppearance() } }
    private var isCut = false
    private var openingAppearance = FileOpeningAppearance.ordinary
    override var isSelected: Bool { didSet { refreshAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet {
        refreshAppearance()
        #if DEBUG
        SelectionGestureEvidence.observe(kind: "file", state: highlightState, committed: isSelected)
        #endif
    } }

    override func loadView() {
        let background = FileIconBackground()
        view = background
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(openFromDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.buttonMask = 1
        doubleClick.delaysPrimaryMouseButtonEvents = false
        doubleClick.delegate = self
        background.addGestureRecognizer(doubleClick)
        filenameLabel.alignment = .center
        filenameLabel.maximumNumberOfLines = 2
        filenameLabel.cell?.wraps = true
        filenameLabel.cell?.usesSingleLineMode = false
        filenameLabel.lineBreakMode = .byWordWrapping
        filenameLabel.cell?.truncatesLastVisibleLine = true
        fileImage.imageScaling = .scaleProportionallyUpOrDown
        cutBadge.image = symbol("scissors", "Cut: ready to move")
        cutBadge.contentTintColor = .secondaryLabelColor
        for child in [fileImage, filenameLabel, cutBadge] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.setAccessibilityElement(false); background.addSubview(child)
        }
        NSLayoutConstraint.activate([
            fileImage.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            fileImage.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            fileImage.widthAnchor.constraint(equalToConstant: 48).interfaceScaled, fileImage.heightAnchor.constraint(equalToConstant: 48).interfaceScaled,
            filenameLabel.topAnchor.constraint(equalTo: fileImage.bottomAnchor, constant: 8),
            filenameLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            filenameLabel.heightAnchor.constraint(equalToConstant: 36).interfaceScaled,
            cutBadge.leadingAnchor.constraint(equalTo: fileImage.trailingAnchor, constant: -4),
            cutBadge.topAnchor.constraint(equalTo: fileImage.topAnchor, constant: -4),
            cutBadge.widthAnchor.constraint(equalToConstant: 15).interfaceScaled, cutBadge.heightAnchor.constraint(equalToConstant: 15).interfaceScaled
        ])
        background.setAccessibilityElement(true); background.setAccessibilityRole(.cell)
        background.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open", target: self, selector: #selector(accessibleOpen(_:)))
        ])
    }
    func configure(_ entry: FileEntry, showsExtensions: Bool, cut: Bool, emphasized: Bool,
                   openingAppearance: FileOpeningAppearance = .ordinary) {
        _ = view
        self.entry = entry; self.isCut = cut; self.openingAppearance = openingAppearance; self.emphasized = emphasized
        let name = showsExtensions || entry.kind == .directory ? entry.name : (entry.name as NSString).deletingPathExtension
        filenameLabel.stringValue = name
        let icon = FileIconRole.classify(name: entry.name, kind: entry.kind.rawValue)
        fileImage.image = FileOpeningSymbol.image(role: icon, appearance: openingAppearance)
        cutBadge.isHidden = !cut
        view.toolTip = entry.name + (cut ? " — Cut: ready to move when pasted" : "")
        if let explanation = openingAppearance.explanation { view.toolTip = (view.toolTip ?? entry.name) + "\n" + explanation }
        view.setAccessibilityHelp(openingAppearance.explanation ?? (entry.kind.rawValue + ". Open performs the shared browser command."))
        view.setAccessibilityLabel(entry.name + (cut ? ", cut, ready to move" : "")
            + (openingAppearance.explanation.map { ", " + $0 } ?? ""))
        refreshAppearance()
    }
    private func refreshAppearance() {
        guard isViewLoaded, let background = view as? FileIconBackground else { return }
        let selected = displaysSelection
        background.selected = selected; background.emphasized = emphasized; background.dropTarget = isDropTarget
        background.setAccessibilitySelected(isSelected)
        let text: NSColor = selected ? (emphasized ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) : .labelColor
        filenameLabel.textColor = text
        fileImage.contentTintColor = selected ? text : FileOpeningSymbol.tint(openingAppearance, directory: entry?.kind == .directory)
        fileImage.alphaValue = isCut ? 0.5 : 1
        filenameLabel.alphaValue = isCut ? 0.65 : 1
        background.needsDisplay = true
    }
    @objc func accessibleOpen(_ action: NSAccessibilityCustomAction) -> Bool {
        guard let entry, isViewLoaded, NativeAccessibleAction.canInvoke(view) else { return false }
        return onAccessibleOpen?(entry.url) ?? false
    }
    @objc private func openFromDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended, let entry else { return }
        _ = onAccessibleOpen?(entry.url)
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
}

@MainActor
private final class FileIconBackground: NSView {
    var selected = false
    var emphasized = false
    var dropTarget = false
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if selected {
            (emphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill(); path.fill()
        }
        if dropTarget { NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke() }
    }
}
