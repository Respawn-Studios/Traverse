import AppKit
import Combine

@MainActor
extension BrowserViewController {
    func installPrivateNamesAttention() {
        privateNamesAttentionButton.target = self; privateNamesAttentionButton.action = #selector(showPrivateNames(_:))
        privateNamesAttentionButton.bezelStyle = .recessed
        privateNamesAttentionButton.image = symbol("tag", "Saved names need attention")
        privateNamesAttentionButton.imagePosition = .imageLeading
        privateNamesAttentionButton.setAccessibilityLabel("Saved names need attention. Open Remembered Items")
        privateNamesAttentionButton.toolTip = "Review saved names without changing file-operation results."
        privateNamesAttentionObservation = privateNames.$moveAttention.removeDuplicates().sink { [weak self] visible in
            self?.privateNamesAttentionButton.isHidden = !visible
        }
    }
    @objc func editPrivateNames(_ sender: Any?) {
        guard orderedSelectedURLs.count == 1, !showsComputerVolumes, let source = orderedSelectedURLs.first,
              !isBrowserSuspended, !isReadOnlyFileSession, let window = view.window else { return }
        privateNames.configure(self)
        if let sheet = privateNamesSheet, sheet.window?.sheetParent != nil { sheet.window?.makeKeyAndOrderFront(nil); return }
        let sheet = PrivateNamesSheet(owner: privateNames, browser: self, source: source)
        privateNamesSheet = sheet; sheet.show(in: window)
    }
    @objc func showPrivateNames(_ sender: Any?) { privateNames.showLibrary(browser: self) }
}
