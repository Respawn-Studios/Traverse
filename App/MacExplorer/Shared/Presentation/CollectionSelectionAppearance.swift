import AppKit

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
