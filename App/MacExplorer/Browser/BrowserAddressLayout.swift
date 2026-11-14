import AppKit

/// Reparents the existing pane controls; no second editor, query owner or path
/// value. Bottom layout keeps each pane's address visible independently.
@MainActor
final class BrowserAddressLayout {
    static let bottomRowHeight: CGFloat = 34
    let tabRow = stack([], orientation: .horizontal, spacing: 4)
    let bottomSurface: NavigationGlassSurface
    private let bottomRow = stack([], orientation: .horizontal, spacing: 4)
    private weak var browser: BrowserViewController?
    private let addressRow: NSStackView
    private let pathArea: AddressSurfaceView
    private var bottom: Bool?

    init(browser: BrowserViewController, addressRow: NSStackView, pathArea: AddressSurfaceView) {
        self.browser = browser; self.addressRow = addressRow; self.pathArea = pathArea
        bottomSurface = NavigationGlassSurface(contentView: bottomRow)
        bottomRow.edgeInsets = .init(top: 3, left: 8, bottom: 3, right: 8)
        bottomRow.heightAnchor.constraint(equalToConstant: Self.bottomRowHeight).interfaceScaled.isActive = true
        tabRow.heightAnchor.constraint(equalToConstant: 36).interfaceScaled.isActive = true
        browser.tabStrip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browser.tabStrip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply()
    }

    private func detach(_ view: NSView) {
        (view.superview as? NSStackView)?.removeArrangedSubview(view)
        view.removeFromSuperview()
    }

    func apply() {
        guard let browser else { return }
        let next = browser.settings.showsPathBar
        guard bottom != next else { return }
        if bottom != nil { browser.cancelLocationEditing(restoringFocus: false); browser.folderFilter.contextWillChange() }
        bottom = next
        let controls = browser.navigationButtons.map(\.0)
        for view in controls + [browser.tabStrip, pathArea, browser.folderFilter.view, browser.navigationOperationButton] { detach(view) }
        tabRow.edgeInsets = .init(top: 0, left: next ? 8 : 0, bottom: 0, right: next ? 8 : 0)
        if next {
            // Keep Up/Refresh available in the path menu and shortcuts. Their
            // ordinary buttons can fit beside tabs at the wider allocations.
            for button in controls { tabRow.addArrangedSubview(button) }
            tabRow.addArrangedSubview(browser.tabStrip)
            tabRow.addArrangedSubview(browser.folderFilter.view)
            tabRow.addArrangedSubview(browser.navigationOperationButton)
            bottomRow.addArrangedSubview(pathArea)
            pathArea.widthAnchor.constraint(equalTo: bottomRow.widthAnchor, constant: -16).isActive = true
        } else {
            // Any former bottom-row constraint belongs to that parent only.
            for constraint in bottomRow.constraints where constraint.firstItem as? NSView === pathArea || constraint.secondItem as? NSView === pathArea {
                constraint.isActive = false
            }
            tabRow.addArrangedSubview(browser.tabStrip)
            for view in controls + [pathArea, browser.folderFilter.view, browser.navigationOperationButton] { addressRow.addArrangedSubview(view) }
        }
        browser.folderFilter.prefersCompact = next
        browser.pathContainer.isHidden = next
        bottomSurface.isHidden = !next
        bottomSurface.isGlassEnabled = browser.settings.navigationStyle == .glass && browser.settings.glassNavigation
        browser.viewIfLoaded?.needsLayout = true
    }
}
