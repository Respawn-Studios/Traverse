import AppKit

@MainActor enum BrowserSelectionFocus {
    static func isEmphasized(in view: NSView) -> Bool {
        guard let window = view.window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }
}

@MainActor extension NSCollectionViewItem {
    /// Native marquee tracking proposes changes before committing selection.
    /// Drawing follows that proposal; commands and accessibility use isSelected.
    var displaysSelection: Bool {
        switch highlightState {
        case .forSelection: true
        case .forDeselection: false
        case .none, .asDropTarget: isSelected
        @unknown default: isSelected
        }
    }
}
