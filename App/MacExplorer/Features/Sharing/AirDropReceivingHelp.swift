import AppKit

@MainActor
extension BrowserViewController {
    @objc func showAirDropReceivingHelp(_ sender: Any?) {
        guard !isBrowserSuspended, let host = view.window, host.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Receive files with AirDrop"
        alert.informativeText = "Turn on AirDrop in Control Centre and choose who can send to you. Keep Wi-Fi and Bluetooth on, with both devices nearby.\n\nAccept the incoming request in macOS and follow any code request shown there. Depending on the item, macOS may save it in Downloads, open an app or offer a save location. You can browse the received files in Traverse."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Apple’s AirDrop Guide ↗")
        Task { @MainActor [weak host] in
            guard let host, host.isVisible else { return }
            if await alert.beginSheetModal(for: host) == .alertSecondButtonReturn,
               let url = URL(string: "https://support.apple.com/guide/mac-help/mh35868/mac") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
