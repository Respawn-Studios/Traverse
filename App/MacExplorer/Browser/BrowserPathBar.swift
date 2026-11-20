import AppKit
import ExplorerCore
import Combine

/// Identity of a live browser visit, independent of native menu key-window handoff.
struct BreadcrumbNavigationContext: Equatable {
    let pane: UUID
    let tab: UUID
    let visit: UUID
    let window: ObjectIdentifier
}

/// Both native bars share the full lexical path and the displayed-to-original
/// mapping. No URL is installed on an AppKit path item and no disk work occurs.
@MainActor
class CollapsingPathControl: NSPathControl {
    private(set) var logicalItems: [NSPathControlItem] = []
    private(set) var locations: [BrowserLocation] = []
    private(set) var displayedLocations: [Int?] = []
    private(set) var hiddenAncestors: [Int] = []
    var onNavigate: ((BrowserLocation) -> Void)?
    var onCopyPath: ((URL) -> Void)?
    var onLocationMenu: ((BrowserLocation) -> NSMenu)?
    var navigationContext: (() -> BreadcrumbNavigationContext?)?
    private var presentation = UUID()
    private var rebuilding = false
    var trailingEditFraction: CGFloat { 0 }
    #if DEBUG
    var presentAncestorMenuForVerification: ((NSMenu) -> Void)?
    #endif

    private final class MenuChoice: NSObject {
        let generation: UUID
        let context: BreadcrumbNavigationContext
        let originalIndex: Int
        init(_ generation: UUID, _ context: BreadcrumbNavigationContext, _ originalIndex: Int) {
            self.generation = generation; self.context = context; self.originalIndex = originalIndex
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pathStyle = .standard
        isEditable = false
        target = self
        action = #selector(activateNativeItem(_:))
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = NSView.noIntrinsicMetric
        return size
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { rebuildPresentation() }
    }
    override func setBoundsSize(_ newSize: NSSize) {
        let changed = bounds.size != newSize
        super.setBoundsSize(newSize)
        if changed { rebuildPresentation() }
    }
    override var font: NSFont? { didSet { rebuildPresentation() } }
    override var controlSize: NSControl.ControlSize { didSet { rebuildPresentation() } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildPresentation()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildPresentation()
    }

    func setBreadcrumbs(items: [NSPathControlItem], locations: [BrowserLocation]) {
        precondition(items.count == locations.count)
        // Copy the lexical input; displayed shortening never changes full labels.
        logicalItems = items.map { item in
            let copy = NSPathControlItem(); copy.title = item.title; copy.image = item.image
            return copy
        }
        self.locations = locations
        rebuildPresentation()
    }

    func location(forDisplayedIndex index: Int) -> BrowserLocation? {
        guard displayedLocations.indices.contains(index), let original = displayedLocations[index],
              locations.indices.contains(original) else { return nil }
        return locations[original]
    }

    /// Native title/image metrics plus a conservative separator/inset budget
    /// allocate label text. Actual NSPathCell geometry, not this estimate,
    /// decides whether an item/root/parent may be omitted.
    private func width(_ title: String, image: NSImage? = nil) -> CGFloat {
        let cell = NSPathComponentCell(textCell: title)
        cell.font = font ?? .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        cell.controlSize = controlSize
        cell.image = image
        return ceil(cell.cellSize.width) + 12
    }
    private func shortened(_ title: String, image: NSImage?, to limit: CGFloat) -> String {
        if width(title, image: image) <= limit { return title }
        let characters = Array(title)
        // At most O(log n) native metric checks; never split a grapheme cluster.
        var low = 0, high = characters.count
        while low < high {
            let count = (low + high + 1) / 2
            let candidate = String(characters.prefix((count + 1) / 2)) + "…"
                + String(characters.suffix(count / 2))
            if width(candidate, image: image) <= limit { low = count } else { high = count - 1 }
        }
        if low == 0 { return image == nil ? "…" : "" }
        return String(characters.prefix((low + 1) / 2)) + "…" + String(characters.suffix(low / 2))
    }

    private func rebuildPresentation() {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        presentation = UUID() // resize, font, appearance and visit retire old menus
        guard !logicalItems.isEmpty else {
            pathItems = []; displayedLocations = []; hiddenAncestors = []
            return
        }
        // A hidden bottom bar or a newly inserted pane may not have a native
        // allocation yet. NSPathCell fitting at zero size can produce invalid
        // geometry; retain the lexical visit and rebuild on the next resize.
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            pathItems = []; displayedLocations = []; hiddenAncestors = []
            return
        }
        let last = logicalItems.count - 1
        let editSpace = floor(bounds.width * trailingEditFraction)
        let available = max(0, bounds.width - editSpace - 4)
        let natural = logicalItems.map { width($0.title, image: $0.image) }
        var mapping: [Int?] = logicalItems.indices.map { Optional($0) }
        let menuWidth = width("…")
        let currentMinimum = width("…", image: logicalItems[last].image)
        let rootMinimum = width("", image: logicalItems[0].image)
        let current = logicalItems[last]
        let protectedCurrent = min(natural[last], max(currentMinimum, available * 0.32))
        var nativeGap = CGFloat.zero
        func minimalItems(_ indices: [Int?]) -> [NSPathControlItem] {
            indices.map { index in
                let item = NSPathControlItem()
                guard let index else { item.title = "…"; return item }
                item.image = logicalItems[index].image
                item.title = index == last ? shortened(current.title, image: current.image, to: protectedCurrent)
                    : (index == 0 ? "" : logicalItems[index].title)
                return item
            }
        }
        func nativeFits(_ items: [NSPathControlItem], keepEditSpace: Bool = true) -> Bool {
            nativeGap = 0
            pathItems = items
            guard let cell = cell as? NSPathCell, cell.pathComponentCells.count == items.count else { return false }
            var left = bounds.maxX, right = bounds.minX
            let hitTargetsFit = cell.pathComponentCells.allSatisfy { component in
                let rect = cell.rect(of: component, withFrame: bounds, in: self).intersection(bounds)
                let point = NSPoint(x: rect.midX, y: rect.midY)
                guard !rect.isEmpty && !rect.isNull && point.x.isFinite && point.y.isFinite
                    && bounds.contains(point) && rect.width + 0.5 >= component.cellSize.width
                    && cell.pathComponentCell(at: point, withFrame: bounds, in: self) === component else { return false }
                left = min(left, rect.minX); right = max(right, rect.maxX)
                return true
            }
            guard hitTargetsFit else { return false }
            nativeGap = userInterfaceLayoutDirection == .rightToLeft ? left - bounds.minX : bounds.maxX - right
            return !keepEditSpace || editSpace == 0 || nativeGap + 0.5 >= editSpace
        }
        let fullFits = nativeFits(logicalItems)
        if !fullFits && last > 0 {
            let rootAndCurrent: [Int?] = last == 1 ? [0, last] : [0, nil, last]
            // Drive is omitted only after the real native minimum candidate
            // cannot fit, rather than from an estimated separator width.
            let minimum = minimalItems(rootAndCurrent)
            if !nativeFits(minimum) && !nativeFits(minimum, keepEditSpace: false) {
                mapping = [nil, last]
            } else {
                mapping = rootAndCurrent
                if nativeFits(minimalItems(logicalItems.indices.map { Optional($0) })) {
                    mapping = logicalItems.indices.map { Optional($0) }
                } else if last > 2 {
                    // Admit the most useful contiguous suffix. A previously
                    // fitting parent never yields its place to an older one.
                    var first = 2, end = last - 1
                    while first <= end {
                        let start = first + (end - first) / 2
                        let candidate: [Int?] = [0, nil] + (start...last).map { Optional($0) }
                        if nativeFits(minimalItems(candidate)) { mapping = candidate; end = start - 1 }
                        else { first = start + 1 }
                    }
                }
            }
        }
        let visible = Set(mapping.compactMap { $0 })
        hiddenAncestors = logicalItems.indices.filter { $0 != last && !visible.contains($0) }
        if hiddenAncestors.isEmpty { mapping.removeAll { $0 == nil } }
        let fixed = mapping.reduce(CGFloat(0)) { sum, index in
            guard let index else { return sum + menuWidth }
            return sum + ((index != 0 && index != last) ? natural[index] : 0)
        }
        let flexible = max(0, available - fixed)
        let rootBudget = mapping.contains(where: { $0 == 0 }) && last > 0
            ? min(natural[0], max(rootMinimum, flexible * 0.3)) : 0
        let currentBudget = last == 0 ? available : max(currentMinimum, flexible - rootBudget)
        let displayed = mapping.map { index -> NSPathControlItem in
            let item = NSPathControlItem()
            guard let index else { item.title = "…"; return item }
            let original = logicalItems[index]
            item.image = original.image
            let budget = index == last ? currentBudget : (index == 0 ? rootBudget : natural[index])
            item.title = fullFits ? original.title : shortened(original.title, image: original.image, to: budget)
            return item
        }
        // Estimated label budgets may differ across AppKit versions/fonts.
        // Fall back to the already checked minimum presentation, not hidden
        // middle cells. There is no drawing, filesystem work or timing wait.
        if !nativeFits(displayed) {
            let minimal = minimalItems(mapping)
            if !nativeFits(minimal) { _ = nativeFits(minimal, keepEditSpace: false) }
        }
        // A single long name should not hide an otherwise useful folder when
        // its shortened label fits alongside the existing path and edit area.
        if editSpace > 0, let nearest = hiddenAncestors.last, nearest != 0,
           let menu = mapping.firstIndex(where: { $0 == nil }) {
            let replacesMenu = hiddenAncestors.count == 1
            let original = logicalItems[nearest]
            let spare = nativeGap - editSpace - 4 + (replacesMenu ? menuWidth : 0)
            let title = shortened(original.title, image: original.image, to: spare)
            if title.count >= 5 {
                let previous = pathItems
                var candidate = previous
                let parent = NSPathControlItem()
                parent.title = title; parent.image = original.image
                let slot = replacesMenu ? menu : menu + 1
                if replacesMenu { candidate[slot] = parent }
                else { candidate.insert(parent, at: slot) }
                if nativeFits(candidate) {
                    if replacesMenu { mapping[slot] = nearest }
                    else { mapping.insert(nearest, at: slot) }
                    hiddenAncestors.removeLast()
                } else { pathItems = previous }
            }
        }
        displayedLocations = mapping
        if let pathCell = cell as? NSPathCell {
            for (index, cell) in pathCell.pathComponentCells.enumerated() where mapping.indices.contains(index) {
                if let original = mapping[index] {
                    cell.setAccessibilityLabel(logicalItems[original].title)
                    cell.setAccessibilityHelp(locations[original].directoryURL?.path)
                    cell.setAccessibilityCustomActions(nil)
                } else {
                    cell.setAccessibilityLabel("Show parent folders")
                    cell.setAccessibilityHelp("Opens the omitted folders in path order")
                    cell.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show parent folders",
                        target: self, selector: #selector(showAncestorsForAccessibility(_:)))])
                }
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // AppKit does not consistently send the standard path action for a
        // synthetic middle item. Track only our explicit menu target here;
        // real folders retain native selection, keyboard and drag behavior.
        let point = convert(event.locationInWindow, from: nil)
        if let pathCell = cell as? NSPathCell,
           let component = pathCell.pathComponentCell(at: point, withFrame: bounds, in: self),
           let index = pathCell.pathComponentCells.firstIndex(where: { $0 === component }),
           displayedLocations.indices.contains(index), displayedLocations[index] == nil {
            _ = showAncestors()
            return
        }
        super.mouseDown(with: event)
    }

    @objc private func activateNativeItem(_ sender: Any?) { activateClickedPathItem() }
    func activateClickedPathItem() {
        guard navigationContext?() != nil, let clicked = clickedPathItem,
              let index = pathItems.firstIndex(where: { $0 === clicked }), displayedLocations.indices.contains(index) else { return }
        if let destination = location(forDisplayedIndex: index) { onNavigate?(destination) }
        else { showAncestors() }
    }

    /// Uses a native NSMenu; arrows, Return, Escape and accessibility retain
    /// AppKit semantics. Each choice validates exact presentation + live visit.
    func ancestorMenu() -> NSMenu? {
        guard !hiddenAncestors.isEmpty, let context = navigationContext?() else { return nil }
        let menu = NSMenu(title: "Parent folders")
        menu.autoenablesItems = false
        for original in hiddenAncestors {
            let item = NSMenuItem(title: logicalItems[original].title,
                action: #selector(chooseAncestor(_:)), keyEquivalent: "")
            item.target = self
            item.image = logicalItems[original].image
            item.toolTip = locations[original].directoryURL?.path
            item.representedObject = MenuChoice(presentation, context, original)
            item.setAccessibilityLabel(logicalItems[original].title)
            menu.addItem(item)
        }
        return menu
    }
    @objc private func chooseAncestor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MenuChoice,
              choice.generation == presentation, choice.context == navigationContext?(),
              locations.indices.contains(choice.originalIndex) else { return }
        onNavigate?(locations[choice.originalIndex])
    }
    @objc private func showAncestorsForAccessibility(_ action: NSAccessibilityCustomAction) -> Bool { showAncestors() }
    @discardableResult
    private func showAncestors() -> Bool {
        guard let menu = ancestorMenu(), let index = displayedLocations.firstIndex(where: { $0 == nil }),
              let cell = cell as? NSPathCell, cell.pathComponentCells.indices.contains(index) else { return false }
        let rect = cell.rect(of: cell.pathComponentCells[index], withFrame: bounds, in: self).intersection(bounds)
        guard !rect.isEmpty, !rect.isNull, rect.minX.isFinite, rect.minY.isFinite else { return false }
        #if DEBUG
        if let presentAncestorMenuForVerification { presentAncestorMenuForVerification(menu); return true }
        #endif
        let anchor = NSPoint(x: userInterfaceLayoutDirection == .rightToLeft ? rect.maxX : rect.minX,
            y: isFlipped ? rect.maxY : rect.minY)
        _ = menu.popUp(positioning: nil, at: anchor, in: self)
        return true // opening succeeded even when native tracking is cancelled
    }

    /// Copy Path uses the same visit/presentation guards as menu navigation.
    func copyMenu(forDisplayedIndex index: Int, action: Selector) -> NSMenu? {
        guard let context = navigationContext?(), displayedLocations.indices.contains(index),
              let original = displayedLocations[index], locations[original].directoryURL != nil else { return nil }
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Path", action: action, keyEquivalent: "")
        copy.target = self; copy.representedObject = MenuChoice(presentation, context, original)
        menu.addItem(copy)
        return menu
    }
    func copiedURL(from item: NSMenuItem) -> URL? {
        guard let choice = item.representedObject as? MenuChoice,
              choice.generation == presentation, choice.context == navigationContext?(),
              locations.indices.contains(choice.originalIndex) else { return nil }
        return locations[choice.originalIndex].directoryURL
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell = cell as? NSPathCell,
              let component = cell.pathComponentCell(at: convert(event.locationInWindow, from: nil), withFrame: bounds, in: self),
              let index = cell.pathComponentCells.firstIndex(where: { $0 === component }),
              displayedLocations.indices.contains(index) else { return nil }
        if displayedLocations[index] == nil { return ancestorMenu() }
        guard navigationContext?() != nil else { return nil }
        if let location = location(forDisplayedIndex: index), let onLocationMenu { return onLocationMenu(location) }
        return copyMenu(forDisplayedIndex: index, action: #selector(copyComponent(_:)))
    }
    @objc private func copyComponent(_ sender: NSMenuItem) {
        guard let url = copiedURL(from: sender) else { return }
        onCopyPath?(url)
    }
}

/// Finder-style bottom path navigation/copying, using the same presentation.
@MainActor
final class BrowserPathBar: CollapsingPathControl {
    override init(frame: NSRect) {
        super.init(frame: frame)
        controlSize = .small
        setAccessibilityLabel("Bottom folder path bar")
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
extension BrowserViewController {
    /// Menus may hand key status to AppKit; require the same live pane/window,
    /// tab and visit rather than isKeyWindow or active-command-pane status.
    func configureBreadcrumbContext(_ control: CollapsingPathControl) {
        control.navigationContext = { [weak self, weak control] in
            guard let self, let control, !self.isBrowserSuspended,
                  let window = self.view.window, control.window === window,
                  !control.isHiddenOrHasHiddenAncestor else { return nil }
            if let workspace = self.workspace {
                guard !workspace.isClosing, workspace.browsers[self.paneID] === self else { return nil }
            }
            return BreadcrumbNavigationContext(pane: self.paneID, tab: self.activeID,
                visit: self.sessionID, window: ObjectIdentifier(window))
        }
    }
    func configureAddressLayoutPreference() {
        settings.$showsPathBar.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.addressLayout?.apply() }
        }.store(in: &subscriptions)
    }
    @objc func togglePathBar(_ sender: Any?) { settings.showsPathBar.toggle() }
}
