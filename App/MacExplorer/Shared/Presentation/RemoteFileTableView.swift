import AppKit
import ExplorerCore

/// Native input shared by SFTP and SMB listings. Concrete row controllers own
/// observations and command admission; this table owns only presentation/input.
@MainActor final class RemoteFileTableView: NSTableView, NSMenuItemValidation, FileColumnSizingTable {
    let columnSizing = FileColumnSizing()
    private let nameClick = SelectedNameClickRename()
    var nameClickRenameEnabled: (() -> Bool)?, onNameClickRename: (() -> Void)?
    private let pointerSelection = BrowserPointerSelection()
    var behavior = BrowserBehaviorPreferences.explorer {
        didSet { if behavior != oldValue { pointerSelection.cancel(); marquee?.cancel(restore: false) } }
    }
    var marquee: TableMarqueeSelection?
    private var marqueeOwnsMouse = false
    private(set) var marqueeRevision: UInt64 = 0
    var onOpen: (() -> Void)?, onBack: (() -> Void)?, onUp: (() -> Void)?
    var onShortcut: ((NSEvent) -> Bool)?, onFocus: (() -> Void)?
    var onPaste: (() -> Void)?, pasteAllowed: (() -> Bool)?
    var onCut: (() -> Void)?, cutAllowed: (() -> Bool)?
    var onCopy: (() -> Void)?, copyAllowed: (() -> Bool)?
    var contextMenuProvider: (() -> NSMenu?)?
    @objc func paste(_ sender: Any?) { if pasteAllowed?() == true { onPaste?() } }
    @objc func cut(_ sender: Any?) { if cutAllowed?() == true { onCut?() } }
    @objc func copy(_ sender: Any?) { if copyAllowed?() == true { onCopy?() } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)) { return onPaste != nil && pasteAllowed?() == true }
        if item.action == #selector(cut(_:)) { return onCut != nil && cutAllowed?() == true }
        if item.action == #selector(copy(_:)) { return onCopy != nil && copyAllowed?() == true }
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        nameClick.begin(event, table: self, revision: marqueeRevision, currentRevision: { [weak self] in self?.marqueeRevision ?? 0 },
            enabled: nameClickRenameEnabled?() == true, action: { [weak self] in self?.onNameClickRename?() })
        onFocus?()
        let adapted = pointerSelection.begin(event, in: self, behavior: behavior, isEditingText: currentEditor() != nil)
        marqueeOwnsMouse = marquee?.begin(with: adapted) == true
        if !marqueeOwnsMouse { super.mouseDown(with: adapted) }
    }
    override func mouseDragged(with event: NSEvent) {
        nameClick.cancel()
        let adapted = pointerSelection.continuing(event, in: self)
        if marqueeOwnsMouse { marquee?.drag(with: adapted) } else { super.mouseDragged(with: adapted) }
    }
    override func mouseUp(with event: NSEvent) {
        let adapted = pointerSelection.continuing(event, in: self)
        if marqueeOwnsMouse { marqueeOwnsMouse = false; marquee?.end(with: adapted) } else { super.mouseUp(with: adapted) }
    }
    override func reloadData() { nameClick.cancel(); pointerSelection.cancel(); marquee?.cancel(restore: false); marqueeRevision &+= 1; super.reloadData() }
    override func noteNumberOfRowsChanged() { nameClick.cancel(); pointerSelection.cancel(); marquee?.cancel(restore: false); marqueeRevision &+= 1; super.noteNumberOfRowsChanged() }
    override func layout() { super.layout(); columnSizing.fit(self); marquee?.layout() }
    override func viewDidMoveToWindow() { pointerSelection.cancel(); super.viewDidMoveToWindow(); marquee?.bindWindow() }
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { pointerSelection.cancel(); return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        nameClick.cancel()
        if onShortcut?(event) == true { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode), modifiers.intersection([.command, .control, .option]).isEmpty { onOpen?(); return }
        if event.keyCode == 125, modifiers.contains(.command) { onOpen?(); return }
        if event.keyCode == 126, modifiers.contains(.command) { onUp?(); return }
        if event.keyCode == 123, modifiers.contains(.option) { onBack?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if BrowserPointerSelection.isSelectionAlias(event, in: self, behavior: behavior,
            isEditingText: currentEditor() != nil) { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) } } else { deselectAll(nil) }
        return contextMenuProvider?() ?? super.menu(for: event)
    }
}
