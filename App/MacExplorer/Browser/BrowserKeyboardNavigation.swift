import AppKit

@MainActor extension BrowserViewController {
    @objc func openTerminalHere(_ sender: Any?) { openAndShare.openTerminal() }
    @objc func openSelectedFolderInTerminal(_ sender: Any?) { openAndShare.openTerminal(selectedFolder: true) }
    @objc func compareSelectedFiles(_ sender: Any?) { openAndShare.compareSelection() }

    var keyboardContextTarget: NSView? {
        guard hasFileCommandFocus, let responder = view.window?.firstResponder as? NSView else { return nil }
        if responder === outline { return outline.selectedRow >= 0 ? outline : nil }
        let content = showsComputerVolumes ? volumeBrowser.collectionView : activeFileView
        if showsComputerVolumes, volumeBrowser.selectedCount == 0 { return nil }
        return responder === content ? content : nil
    }

    func keyboardContextMenuRequest() -> KeyboardContextMenu.Request? {
        guard !isBrowserSuspended, let target = keyboardContextTarget else { return nil }
        let menu: NSMenu?
        if target === outline { menu = outline.selectedContextMenu() }
        else if showsComputerVolumes { menu = volumeBrowser.selectedContextMenu() }
        else if let table = target as? RemoteFileTableView { menu = table.contextMenuProvider?() }
        else if let table = target as? FileTableView { menu = table.contextMenuProvider?() }
        else if target === iconBrowser.collectionView { menu = BrowserMenus.fileContextMenu(target: self) }
        else { menu = nil }
        return menu.flatMap { KeyboardContextMenu.prepare(in: target, menu: $0) }
    }

    @objc func showKeyboardContextMenu(_ sender: Any?) {
        keyboardContextMenuRequest()?.present()
    }
}
