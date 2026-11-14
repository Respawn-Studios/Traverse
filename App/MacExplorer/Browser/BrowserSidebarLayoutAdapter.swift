import AppKit
import ExplorerCore
import LocalStorage

/// These identities are UI metadata. URL fallback values stay in this view's
/// memory; they are never encoded into preferences or the drag pasteboard.
enum BrowserSidebarLayoutRowID: Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    case stored(SidebarLayoutItemKey)
    case folderPin(UUID), connectionPin(UUID), server(BrowserConnectionIdentity)
    case sessionVolume(URL), sessionGrant(UUID), savedServer(WorkspaceConnectionBookmark)
    var description: String { "<sidebar row>" }
    var debugDescription: String { description }
}

@MainActor
final class BrowserSidebarLayoutAdapter {
    enum Subject: Equatable {
        case category(SidebarLayoutSection)
        case row(SidebarLayoutSection, BrowserSidebarLayoutRowID)
    }
    enum Target: Equatable {
        case category(SidebarLayoutSection?)
        case row(SidebarLayoutSection, BrowserSidebarLayoutRowID?)
    }
    enum Mode { case persisted, folderPins, connectionPins, session }
    struct Row { let node: SidebarNode; let id: BrowserSidebarLayoutRowID }

    /// Captures current cached observations and collection orders, independently
    /// of the asynchronous outline-rebuild notifications. No I/O occurs here.
    struct Fence: Equatable {
        let viewEpoch: UUID, layoutRevision: UInt64
        let roots: [SidebarLayoutSection]
        let folderPins: [UUID], connectionPins: [UUID]
        let folderPinValues: [BrowserPin], connectionPinValues: [RemoteConnectionPin]
        let pinAvailability: [Int]
        let volumes: [VolumeInfo], managedVolumes: [ManagedVolume]
        let references: [UUID], rememberedIDs: Set<UUID>
        let referencePresentations: [ReferencePresentation]
        let connections: [BrowserConnectionIdentity]
        let connectionValues: [BrowserConnectedLocation]
        let savedServerValues: [WorkspaceConnectionBookmark]
    }
    struct ReferencePresentation: Equatable { let id: UUID; let url: URL?; let state: Int }

    private weak var browser: BrowserViewController?
    let owner: BrowserSidebarLayoutController
    private(set) var epoch = UUID()
    private var roots: [SidebarLayoutSection: SidebarNode] = [:]
    private var rootIDs: [ObjectIdentifier: SidebarLayoutSection] = [:]
    private var rows: [SidebarLayoutSection: [Row]] = [:]
    private var rowIDs: [ObjectIdentifier: (SidebarLayoutSection, BrowserSidebarLayoutRowID)] = [:]
    private var sessionOrders: [SidebarLayoutSection: [BrowserSidebarLayoutRowID]] = [:]
    private var matchingLocalMove: (fence: Fence, nodes: [ObjectIdentifier])?
    private struct ParkedRowFocus {
        let binding: RowFocus
        let selection: Set<ObjectIdentifier>
    }
    private var pendingLocalMove: (generation: UUID, fence: Fence, nodes: [ObjectIdentifier], focus: ParkedRowFocus?)?
    #if DEBUG
    var didReconcileNativeMoveForQualification: ((UUID) -> Void)?
    var didFinishNativeMoveForQualification: ((UUID, Bool) -> Void)?
    var pendingNativeMoveGenerationForQualification: UUID? { pendingLocalMove?.generation }
    #endif
    private(set) var applyingExpansion = false
    lazy var drag = BrowserSidebarLayoutDragCoordinator(adapter: self)

    init(browser: BrowserViewController, owner: BrowserSidebarLayoutController) {
        self.browser = browser; self.owner = owner
    }
    var outline: NSOutlineView? { browser?.outline }
    var isActive: Bool {
        guard let browser else { return false }
        return !browser.isBrowserSuspended && browser.outline.window?.isKeyWindow == true
            && browser.outline.window === browser.view.window && browser.view.window?.attachedSheet == nil
    }

    func beginRebuild() {
        matchingLocalMove = nil
        revokeDrag()
        roots = [:]; rootIDs = [:]; rows = [:]; rowIDs = [:]
    }
    func revokeDrag() {
        epoch = UUID(); pendingLocalMove = nil; matchingLocalMove = nil
        drag.invalidate()
    }
    func invalidate() { revokeDrag(); roots = [:]; rootIDs = [:]; rows = [:]; rowIDs = [:]; sessionOrders = [:] }

    @discardableResult
    func bindRoot(_ node: SidebarNode, to section: SidebarLayoutSection) -> SidebarNode {
        if let previous = roots[section] { rootIDs.removeValue(forKey: ObjectIdentifier(previous)) }
        roots[section] = node; rootIDs[ObjectIdentifier(node)] = section
        return node
    }
    func removeRoot(_ section: SidebarLayoutSection) {
        revokeDrag()
        if let previous = roots.removeValue(forKey: section) { rootIDs.removeValue(forKey: ObjectIdentifier(previous)) }
        removeRows(section)
        sessionOrders.removeValue(forKey: section)
    }
    private func removeRows(_ section: SidebarLayoutSection) {
        for row in rows[section] ?? [] { rowIDs.removeValue(forKey: ObjectIdentifier(row.node)) }
        rows.removeValue(forKey: section)
    }

    /// Call only at the existing immediate-child construction sites. Nested
    /// directory listings are deliberately never registered as reorderable rows.
    func bindRows(_ observed: [Row], in section: SidebarLayoutSection) throws -> [SidebarNode] {
        guard observed.count <= SidebarLayoutPreferences.maximumObservedRows,
              Set(observed.map(\.id)).count == observed.count else { throw SidebarLayoutFailure.invalid }
        for row in observed {
            switch row.id {
            case .stored(let key): _ = try owner.preferences.orderedItems([key], in: section)
            case .folderPin: guard section == .pinnedFolders else { throw SidebarLayoutFailure.invalid }
            case .connectionPin: guard section == .pinnedConnections else { throw SidebarLayoutFailure.invalid }
            case .server, .savedServer: guard section == .servers else { throw SidebarLayoutFailure.invalid }
            case .sessionVolume: guard section == .locations else { throw SidebarLayoutFailure.invalid }
            case .sessionGrant: guard section == .rememberedFolders else { throw SidebarLayoutFailure.invalid }
            }
        }
        let order: [BrowserSidebarLayoutRowID]
        switch mode(for: section, observed: observed) {
        case .persisted:
            sessionOrders.removeValue(forKey: section)
            let keys = observed.compactMap { if case .stored(let key) = $0.id { return key }; return nil }
            order = try owner.preferences.orderedItems(keys, in: section).map(BrowserSidebarLayoutRowID.stored)
        case .folderPins, .connectionPins:
            // Sole order owner remains BrowserPinCollection / RemoteConnectionPinCollection.
            order = observed.map(\.id)
        case .session:
            let present = Set(observed.map(\.id)), previous = sessionOrders[section] ?? []
            let kept = previous.filter { present.contains($0) }, known = Set(kept)
            let template = kept + observed.map(\.id).filter { !known.contains($0) }
            // Reconcile only stable slots with saved order. Ephemeral positions
            // remain session-local, and never displace the stable subsequence.
            let stable = observed.compactMap { if case .stored(let key) = $0.id { return key }; return nil }
            let stableOrder = section.hasStoredRowOrder
                ? try owner.preferences.orderedItems(stable, in: section).map(BrowserSidebarLayoutRowID.stored) : []
            var stableIndex = 0
            order = template.map { id in
                guard case .stored = id else { return id }
                defer { stableIndex += 1 }
                return stableOrder[stableIndex]
            }
            sessionOrders[section] = order // retain current rows only, bounded by 512
        }
        let byID = Dictionary(uniqueKeysWithValues: observed.map { ($0.id, $0) })
        let ordered = order.compactMap { byID[$0] }
        revokeDrag(); removeRows(section); rows[section] = ordered
        for row in ordered { rowIDs[ObjectIdentifier(row.node)] = (section, row.id) }
        return ordered.map(\.node)
    }

    func orderedRoots(_ nodes: [SidebarNode]) throws -> [SidebarNode] {
        let sections = try nodes.map { node -> SidebarLayoutSection in
            guard let section = rootIDs[ObjectIdentifier(node)] else { throw SidebarLayoutFailure.invalid }
            return section
        }
        let present = Set(sections)
        sessionOrders = sessionOrders.filter { present.contains($0.key) }
        return try owner.preferences.orderedSections(sections).compactMap { roots[$0] }
    }
    func insertionIndex(for section: SidebarLayoutSection, among nodes: [SidebarNode]) throws -> Int {
        let observed = nodes.compactMap { rootIDs[ObjectIdentifier($0)] }
        guard observed.count == nodes.count, !observed.contains(section),
              let index = try owner.preferences.orderedSections(observed + [section]).firstIndex(of: section) else {
            throw SidebarLayoutFailure.invalid
        }
        return index
    }
    func root(for section: SidebarLayoutSection) -> SidebarNode? { roots[section] }
    func section(for node: SidebarNode) -> SidebarLayoutSection? { rootIDs[ObjectIdentifier(node)] }
    func subject(for node: SidebarNode) -> Subject? {
        if let section = section(for: node) { return .category(section) }
        return rowIDs[ObjectIdentifier(node)].map { .row($0.0, $0.1) }
    }
    func rowOrder(in section: SidebarLayoutSection) -> [BrowserSidebarLayoutRowID] { rows[section]?.map(\.id) ?? [] }
    var visibleSections: [SidebarLayoutSection] {
        browser?.sidebarRoots.compactMap { rootIDs[ObjectIdentifier($0)] } ?? []
    }

    func fence() -> Fence? {
        guard let browser,
              browser.volumes.count <= SidebarLayoutPreferences.maximumObservedRows,
              browser.operationCoordinator.drives.volumes.count <= SidebarLayoutPreferences.maximumObservedRows,
              browser.rememberedFolders.count <= SidebarLayoutPreferences.maximumObservedRows,
              browser.connectedLocationSnapshot.count <= SidebarLayoutPreferences.maximumObservedRows else { return nil }
        return .init(viewEpoch: epoch, layoutRevision: owner.preferences.revision, roots: visibleSections,
            folderPins: browser.pinsController.collection.pins.map(\.id),
            connectionPins: browser.remotePins.collection.pins.map(\.id),
            folderPinValues: browser.pinsController.collection.pins,
            connectionPinValues: browser.remotePins.collection.pins,
            pinAvailability: browser.pinsController.collection.pins.map { pin in
                switch browser.pinsController.availability[pin.id] ?? .notChecked {
                case .notChecked: 0
                case .opened: 1
                case .unavailable: 2
                }
            }, volumes: browser.volumes,
            managedVolumes: browser.operationCoordinator.drives.volumes,
            references: browser.rememberedFolders.map(\.id),
            rememberedIDs: Set(browser.folderAccess.locations.filter(\.isRemembered).map(\.id)),
            referencePresentations: browser.rememberedFolders.map { reference in
                let state: Int
                switch reference.state { case .resolvedUnverified: state = 0; case .needsRenewal: state = 1; case .unavailable: state = 2 }
                return .init(id: reference.id, url: reference.url, state: state)
            }, connections: browser.connectedLocationSnapshot.map(\.id), connectionValues: browser.connectedLocationSnapshot,
            savedServerValues: browser.disconnectedServerSnapshot)
    }

    func canMove(_ subject: Subject, to target: Target, captured: Fence) -> Bool {
        guard isActive, fence() == captured else { return false }
        do {
            switch (subject, target) {
            case let (.category(item), .category(before)):
                guard owner.canEdit else { return false }
                let visible = try SidebarLayoutPreferences.moved(item, before: before, in: captured.roots)
                if visible == captured.roots { return true }
                var preview = owner.preferences
                try preview.moveSection(item, before: before, expectedRevision: captured.layoutRevision)
            case let (.row(section, item), .row(targetSection, before)) where section == targetSection:
                let order = rowOrder(in: section)
                _ = try SidebarLayoutPreferences.moved(item, before: before, in: order)
                switch mode(for: section, observed: rows[section] ?? []) {
                case .persisted:
                    guard owner.canEdit, case .stored(let key) = item else { return false }
                    let keys = order.compactMap { if case .stored(let value) = $0 { return value }; return nil }
                    let targetKey: SidebarLayoutItemKey?
                    if let before { guard case .stored(let value) = before else { return false }; targetKey = value }
                    else { targetKey = nil }
                    var preview = owner.preferences
                    try preview.moveItem(key, before: targetKey, in: section, observed: keys,
                                         expectedRevision: captured.layoutRevision)
                case .folderPins:
                    guard browser?.pinsController.canEdit == true,
                          order == captured.folderPins.map(BrowserSidebarLayoutRowID.folderPin) else { return false }
                case .connectionPins:
                    guard browser?.remotePins.canEdit == true,
                          order == captured.connectionPins.map(BrowserSidebarLayoutRowID.connectionPin) else { return false }
                case .session:
                    let next = try SidebarLayoutPreferences.moved(item, before: before, in: order)
                    if let plan = mixedStableMove(item: item, old: order, next: next) {
                        guard owner.canEdit else { return false }
                        var preview = owner.preferences
                        try preview.moveItem(plan.item, before: plan.before, in: section, observed: plan.observed,
                                             expectedRevision: captured.layoutRevision)
                    }
                }
            default: return false
            }
            return true
        } catch { return false }
    }

    /// Synchronous UI metadata mutation only. Native acceptDrop and keyboard/AX
    /// alternatives share this path; validation, hover and cancel never call it.
    @discardableResult
    func move(_ subject: Subject, to target: Target, captured: Fence) -> Bool {
        guard canMove(subject, to: target, captured: captured), let browser else { return false }
        let window = browser.outline.window
        let originalResponder = window?.firstResponder
        let originalSelection = selectedNodeIDs(in: browser.outline)
        let parkedFocus: ParkedRowFocus?
        do { parkedFocus = try prepareMoveFocus() }
        catch { return false }
        var beganNativeMove = false
        defer {
            // A no-op or refused admission has not removed the original view.
            // Never return focus to a control detached by a fallback rebuild.
            if !beganNativeMove, let window, let original = originalResponder as? NSView,
               original !== browser.outline, original.window === window,
               window.firstResponder === browser.outline,
               selectedNodeIDs(in: browser.outline) == originalSelection {
                _ = window.makeFirstResponder(original)
            }
        }
        // Resigning a native responder can call delegates synchronously.
        guard canMove(subject, to: target, captured: captured) else { return false }
        do {
            let changed: Bool
            let nextOrder: [BrowserSidebarLayoutRowID]?
            switch (subject, target) {
            case let (.category(item), .category(before)):
                // Missing categories remain in the full persisted model. A
                // visually unchanged drop must not move across a hidden group.
                let next = try SidebarLayoutPreferences.moved(item, before: before, in: captured.roots)
                guard next != captured.roots else { return true }
                nextOrder = nil
                changed = owner.moveSection(item, before: before, expectedRevision: captured.layoutRevision)
            case let (.row(section, item), .row(_, before)):
                let order = rowOrder(in: section)
                let next = try SidebarLayoutPreferences.moved(item, before: before, in: order)
                guard next != order else { return true }
                nextOrder = next
                switch mode(for: section, observed: rows[section] ?? []) {
                case .persisted:
                    guard case .stored(let key) = item else { return false }
                    let keys = order.compactMap { if case .stored(let value) = $0 { return value }; return nil }
                    let targetKey: SidebarLayoutItemKey?
                    if let before { guard case .stored(let value) = before else { return false }; targetKey = value }
                    else { targetKey = nil }
                    changed = owner.moveItem(key, before: targetKey, in: section, observed: keys,
                                             expectedRevision: captured.layoutRevision)
                case .folderPins:
                    guard case .folderPin(let id) = item, let position = next.firstIndex(of: item) else { return false }
                    browser.pinsController.edit { try $0.move(id: id, to: position) }
                    changed = browser.pinsController.collection.pins.map { BrowserSidebarLayoutRowID.folderPin($0.id) } == next
                case .connectionPins:
                    guard case .connectionPin(let id) = item, let position = next.firstIndex(of: item) else { return false }
                    browser.remotePins.edit { try $0.move(id: id, to: position) }
                    changed = browser.remotePins.collection.pins.map { BrowserSidebarLayoutRowID.connectionPin($0.id) } == next
                case .session:
                    if let plan = mixedStableMove(item: item, old: order, next: next) {
                        guard owner.moveItem(plan.item, before: plan.before, in: section, observed: plan.observed,
                                             expectedRevision: captured.layoutRevision) else { return false }
                    }
                    sessionOrders[section] = next; changed = true
                    browser.status.stringValue = section == .servers
                        ? "Saved server order is remembered. Temporary connections keep their positions for this session."
                        : "Positions for locations without a saved identity apply to this session. Known saved order is preserved."
                }
            default: return false
            }
            guard changed else { return false }
            beganNativeMove = applyNativeMove(subject, to: target, nextRows: nextOrder, parkedFocus: parkedFocus)
            guard beganNativeMove else {
                // Only a genuine unexpected local projection change rebuilds.
                revokeDrag(); browser.rebuildSidebar(); return true
            }
            return true
        } catch { return false }
    }

    private struct MixedMove { let item: SidebarLayoutItemKey; let before: SidebarLayoutItemKey?; let observed: [SidebarLayoutItemKey] }
    private func mixedStableMove(item: BrowserSidebarLayoutRowID, old: [BrowserSidebarLayoutRowID],
                                 next: [BrowserSidebarLayoutRowID]) -> MixedMove? {
        guard case .stored(let key) = item else { return nil }
        let before = old.compactMap { if case .stored(let value) = $0 { return value }; return nil }
        let after = next.compactMap { if case .stored(let value) = $0 { return value }; return nil }
        guard before != after, let index = after.firstIndex(of: key) else { return nil }
        return .init(item: key, before: index + 1 < after.count ? after[index + 1] : nil, observed: before)
    }

    /// Called at rebuildSidebar's entry. Never hide a dynamic source change:
    /// labels, availability, volume metadata and connection presentation are in
    /// the fence as well as IDs/order. Matching duplicate notifications may be
    /// deferred while their actual native completion is pending. Once reconciled,
    /// consume at most one duplicate; model agreement never licenses an unlimited
    /// sequence of notifications without another presentation reconciliation.
    func canSkipMatchingLocalProjectionNotification() -> Bool {
        if let pendingLocalMove, fence() == pendingLocalMove.fence,
           nodeSignature() == pendingLocalMove.nodes { return true }
        guard let matchingLocalMove else { return false }
        self.matchingLocalMove = nil
        return fence() == matchingLocalMove.fence && nodeSignature() == matchingLocalMove.nodes
    }
    private func nodeSignature() -> [ObjectIdentifier] {
        guard let browser else { return [] }
        return browser.sidebarRoots.flatMap { [ObjectIdentifier($0)] + ($0.children ?? []).map(ObjectIdentifier.init) }
    }
    private func applyNativeMove(_ subject: Subject, to target: Target,
                                 nextRows: [BrowserSidebarLayoutRowID]?, parkedFocus: ParkedRowFocus?) -> Bool {
        guard let browser, let window = browser.outline.window else { return false }
        let outline = browser.outline
        let parent: SidebarNode?, movingNode: SidebarNode, oldIndex: Int, newIndex: Int
        let update: () -> Void
        switch (subject, target) {
        case let (.category(item), .category(before)):
            let old = visibleSections
            guard let next = try? SidebarLayoutPreferences.moved(item, before: before, in: old),
                  let from = old.firstIndex(of: item), let to = next.firstIndex(of: item),
                  next.count == browser.sidebarRoots.count, let node = roots[item],
                  browser.sidebarRoots[from] === node else { return false }
            parent = nil; movingNode = node; oldIndex = from; newIndex = to
            update = { browser.sidebarRoots = next.compactMap { self.roots[$0] } }
        case let (.row(section, item), .row(targetSection, _)) where section == targetSection:
            guard let node = roots[section], let existing = rows[section], let nextRows,
                  let from = existing.firstIndex(where: { $0.id == item }), let to = nextRows.firstIndex(of: item),
                  existing.count == nextRows.count, node.children?.count == existing.count else { return false }
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let ordered = nextRows.compactMap { byID[$0] }
            guard ordered.count == existing.count else { return false }
            guard node.children?[from] === existing[from].node else { return false }
            parent = node; movingNode = existing[from].node; oldIndex = from; newIndex = to
            update = { node.children = ordered.map(\.node); self.rows[section] = ordered }
        default: return false
        }
        let count = parent?.children?.count ?? browser.sidebarRoots.count
        guard oldIndex >= 0, newIndex >= 0, oldIndex < count, newIndex < count,
              outline.numberOfChildren(ofItem: parent) == count else { return false }
        let nativeRow = outline.row(forItem: movingNode)
        guard nativeRow >= 0, (outline.item(atRow: nativeRow) as? SidebarNode) === movingNode,
              (outline.parent(forItem: movingNode) as? SidebarNode) === parent else { return false }
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarNode }
        let expansion = visibleExpansion(in: outline)
        let previousUpdating = browser.updatingSidebarSelection
        browser.updatingSidebarSelection = true; applyingExpansion = true
        defer { browser.updatingSidebarSelection = previousUpdating; applyingExpansion = false }
        update() // update the existing data source arrays before native animation
        revokeDrag()
        guard let current = fence() else { return false }
        let generation = UUID()
        pendingLocalMove = (generation, current, nodeSignature(), parkedFocus)
        let motion = browser.settings.motion
        let duration = animatesReordering ? 0.20 * motion.mode.durationScale : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration; context.allowsImplicitAnimation = duration > 0
            outline.beginUpdates()
            outline.moveItem(at: oldIndex, inParent: parent, to: newIndex, inParent: parent)
            outline.endUpdates()
        } completionHandler: { [weak self, weak outline, weak window] in
            // AppKit completion, including the zero-duration case, is the only
            // settling boundary. Hop to MainActor without retaining the window.
            Task { @MainActor [weak self, weak outline, weak window] in
                self?.reconcileNativeMove(generation, outline: outline, window: window)
            }
        }
        for (node, wasExpanded) in expansion where outline.isItemExpanded(node) != wasExpanded {
            if wasExpanded { outline.expandItem(node) } else { outline.collapseItem(node) }
        }
        let selection = IndexSet(selected.compactMap { node in
            let index = outline.row(forItem: node); return index >= 0 ? index : nil
        })
        outline.selectRowIndexes(selection, byExtendingSelection: false)
        // Completion reads user choices anew; it must not restore this earlier
        // selection or expansion snapshot after another event has changed them.
        return true
    }

    var animatesReordering: Bool {
        browser?.settings.motion.allows(.pages) == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func visibleExpansion(in outline: NSOutlineView) -> [(SidebarNode, Bool)] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SidebarNode,
                  outline.isExpandable(node) else { return nil }
            return (node, outline.isItemExpanded(node))
        }
    }

    private typealias RowFocus = (node: SidebarNode, column: Int, path: [Int], kind: ObjectIdentifier)
    private func selectedNodeIDs(in outline: NSOutlineView) -> Set<ObjectIdentifier> {
        var selected = Set<ObjectIdentifier>()
        for index in outline.selectedRowIndexes {
            if let node = outline.item(atRow: index) as? SidebarNode { selected.insert(ObjectIdentifier(node)) }
        }
        return selected
    }
    private func prepareMoveFocus() throws -> ParkedRowFocus? {
        guard let browser, let outline = outline, let window = outline.window else { return nil }
        let selected = selectedNodeIDs(in: outline)
        if window.firstResponder === outline, let pending = pendingLocalMove?.focus,
           pending.selection == selected {
            return pending
        }
        guard let view = window.firstResponder as? NSView, let binding = rowFocus(view, in: outline) else { return nil }
        let previousUpdating = browser.updatingSidebarSelection
        browser.updatingSidebarSelection = true
        defer { browser.updatingSidebarSelection = previousUpdating }
        // Release AppKit's first-responder row before it enters the animated
        // off-list. Another selection can then change safely during the move.
        guard window.makeFirstResponder(outline), window.firstResponder === outline else {
            throw SidebarLayoutFailure.invalid
        }
        return .init(binding: binding, selection: selected)
    }
    private func rowFocus(_ view: NSView, in outline: NSOutlineView) -> RowFocus? {
        let row = outline.row(for: view), column = max(0, outline.column(for: view))
        guard row >= 0, column < outline.tableColumns.count,
              let node = outline.item(atRow: row) as? SidebarNode,
              let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) else { return nil }
        var child = view, path: [Int] = []
        while child !== cell {
            guard let parent = child.superview,
                  let index = parent.subviews.firstIndex(where: { $0 === child }) else { return nil }
            path.insert(index, at: 0); child = parent
        }
        return (node, column, path, ObjectIdentifier(type(of: view)))
    }
    private func replacementFocus(_ binding: RowFocus, in outline: NSOutlineView) -> NSView? {
        let row = outline.row(forItem: binding.node)
        guard row >= 0, let cell = outline.view(atColumn: binding.column, row: row, makeIfNecessary: true) else { return nil }
        var view = cell
        for index in binding.path {
            guard view.subviews.indices.contains(index) else { return nil }
            view = view.subviews[index]
        }
        return ObjectIdentifier(type(of: view)) == binding.kind ? view : nil
    }

    private func reconcileNativeMove(_ generation: UUID, outline: NSOutlineView?, window: NSWindow?) {
        #if DEBUG
        var reconciledForQualification = false
        defer { didFinishNativeMoveForQualification?(generation, reconciledForQualification) }
        #endif
        guard let pending = pendingLocalMove, pending.generation == generation else { return }
        pendingLocalMove = nil
        guard let outline, let window, let browser, browser.outline === outline, !browser.isBrowserSuspended,
              outline.window === window, browser.view.window === window,
              fence() == pending.fence, nodeSignature() == pending.nodes else { return }
        // Capture now, not when the drag began: selection, disclosure, scrolling
        // or focus may have changed during the animation. No await/event gap is
        // allowed between this snapshot and restoration.
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? SidebarNode }
        let expansion = visibleExpansion(in: outline)
        let clip = outline.enclosingScrollView?.contentView, bounds = clip?.bounds
        let responder = window.firstResponder
        let focus: RowFocus?
        if responder === outline, let parked = pending.focus,
           parked.selection == selectedNodeIDs(in: outline) {
            focus = parked.binding
        } else if let view = responder as? NSView { focus = rowFocus(view, in: outline) }
        else { focus = nil }
        let previousUpdating = browser.updatingSidebarSelection, previousExpansion = applyingExpansion
        browser.updatingSidebarSelection = true; applyingExpansion = true
        defer { browser.updatingSidebarSelection = previousUpdating; applyingExpansion = previousExpansion }
        // A user may have focused a different row since admission. Release
        // that native row before rebuilding, then bind its replacement view.
        if focus != nil, window.firstResponder !== outline {
            guard window.makeFirstResponder(outline), window.firstResponder === outline else { return }
        }
        guard fence() == pending.fence, nodeSignature() == pending.nodes, !browser.isBrowserSuspended else { return }
        // Re-request mounted cells/row styles from the existing node graph.
        // This does not enter rebuildSidebar, replace nodes, or cancel child tasks.
        outline.reloadData()
        for (node, expanded) in expansion where outline.isItemExpanded(node) != expanded {
            if expanded { outline.expandItem(node) } else { outline.collapseItem(node) }
        }
        outline.selectRowIndexes(IndexSet(selected.compactMap { node in
            let row = outline.row(forItem: node); return row >= 0 ? row : nil
        }), byExtendingSelection: false)
        outline.layoutSubtreeIfNeeded()
        var focusRestored = true
        if let focus {
            if let replacement = replacementFocus(focus, in: outline), replacement.window === window {
                focusRestored = window.firstResponder === replacement || window.makeFirstResponder(replacement)
            } else {
                // A changed cell structure must not leave an orphan responder or
                // authorize notification coalescing. Keep keyboard access local.
                _ = window.makeFirstResponder(outline); focusRestored = false
            }
        } else if let responder, window.firstResponder !== responder {
            if let view = responder as? NSView, view.window !== window { focusRestored = false }
            else { focusRestored = window.makeFirstResponder(responder) }
        }
        if let clip, let bounds {
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            outline.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        outline.layoutSubtreeIfNeeded()
        guard focusRestored, fence() == pending.fence, nodeSignature() == pending.nodes else { return }
        matchingLocalMove = (pending.fence, pending.nodes)
        #if DEBUG
        reconciledForQualification = true
        didReconcileNativeMoveForQualification?(generation)
        #endif
    }

    @discardableResult
    func reset(captured: Fence) -> Bool {
        guard isActive, fence() == captured,
              owner.reset(expectedRevision: captured.layoutRevision) else { return false }
        matchingLocalMove = nil
        // The shared preferences publication reconciles every pane once.
        // Rebuilding here too would discard row identities and child tasks twice.
        return true
    }

    func restoreExpansion() {
        guard let browser, !browser.outline.isFileDragActive else { return }
        applyingExpansion = true
        defer { applyingExpansion = false }
        for node in browser.sidebarRoots where node.group {
            guard let section = section(for: node) else { continue }
            if owner.preferences.collapsed.contains(section) { browser.outline.collapseItem(node) }
            else { browser.outline.expandItem(node) }
        }
    }
    func disclosureChanged(_ node: SidebarNode, expanded: Bool) {
        guard !applyingExpansion, let section = section(for: node), section.canCollapse else { return }
        if !owner.setCollapsed(!expanded, for: section, expectedRevision: owner.preferences.revision) {
            restoreExpansion()
        }
    }
    func toggleDisclosure(_ section: SidebarLayoutSection, captured: Fence) -> Bool {
        guard isActive, fence() == captured, section.canCollapse else { return false }
        let changed = owner.setCollapsed(!owner.preferences.collapsed.contains(section), for: section,
                                         expectedRevision: captured.layoutRevision)
        if changed { restoreExpansion() }
        return changed
    }

    private func mode(for section: SidebarLayoutSection, observed: [Row]) -> Mode {
        if section == .pinnedFolders { return .folderPins }
        if section == .pinnedConnections { return .connectionPins }
        if section.hasStoredRowOrder && observed.allSatisfy({ if case .stored = $0.id { return true }; return false }) { return .persisted }
        // Pins retain their separate order owner. Mixed stable/temporary rows
        // keep temporary slots here and persist only the stable subsequence.
        return .session
    }

    static func serverRowIDs(live: [BrowserConnectedLocation], saved: [WorkspaceConnectionBookmark]) -> [BrowserSidebarLayoutRowID] {
        func key(_ value: WorkspaceConnectionBookmark) -> SidebarLayoutItemKey {
            .server(value.kind, id: value.serverID)
        }
        let candidates = live.compactMap(\.savedTarget).map(key) + saved.map(key)
        let counts = Dictionary(grouping: candidates, by: { $0 }).mapValues(\.count)
        // Two open tabs can use the same saved profile. Keep their identities
        // distinct and session-local instead of inventing a stable owner.
        return live.map { value in
            if let saved = value.savedTarget, counts[key(saved)] == 1 { return .stored(key(saved)) }
            return .server(value.id)
        } + saved.map { value in
            counts[key(value)] == 1 ? .stored(key(value)) : .savedServer(value)
        }
    }

    static func volumeID(_ volume: VolumeInfo, cached: [ManagedVolume]) -> BrowserSidebarLayoutRowID {
        let candidates = cached.filter { $0.url?.standardizedFileURL == volume.url.standardizedFileURL }
        if candidates.count == 1, let id = candidates[0].volumeUUID,
           cached.filter({ $0.volumeUUID == id }).count == 1 { return .stored(.volume(id)) }
        return .sessionVolume(volume.url.standardizedFileURL)
    }
    static func referenceID(_ reference: FolderAccessRestoreResult, rememberedIDs: Set<UUID>) -> BrowserSidebarLayoutRowID {
        // The synthetic store-error row is absent from this cached remembered
        // set. Never persist resolveRememberedFolders()'s fresh diagnostic UUID.
        rememberedIDs.contains(reference.id) ? .stored(.rememberedFolder(reference.id)) : .sessionGrant(reference.id)
    }
}
