import AppKit
import Darwin
import ExplorerCore
import QuickLookUI

/// A single off-main executor bounds selected-item metadata checks. No preview
/// object or content read is created before an explicit Quick Look request.
actor QuickLookSelectionReader {
    static let maximumItems = 256

    func eligibleURLs(_ urls: [URL]) throws -> [URL] {
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        return try urls.prefix(Self.maximumItems).filter { url in
            try Task.checkCancellation()
            // Reject symbolic links in the lexical path, including ancestors.
            // QL receives URLs, so a later external replacement remains a race.
            var current = URL(fileURLWithPath: "/", isDirectory: true)
            for component in url.pathComponents.dropFirst() {
                current.appendPathComponent(component)
                var info = stat()
                let result = current.withUnsafeFileSystemRepresentation { path in
                    path.map { lstat($0, &info) } ?? -1
                }
                guard result == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
            }
            return true
        }
    }
}

@MainActor
// QuickLookUI's Objective-C protocols lack actor annotations. AppKit invokes
// this panel's data source/delegate on its UI thread; retain MainActor isolation
// and runtime checking instead of exposing mutable preview state off-thread.
final class BrowserQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    weak var browser: BrowserViewController?
    let reader = QuickLookSelectionReader()
    private var preparation: Task<Void, Never>?
    private var revision = UUID()
    private var requested = false
    private weak var controlledPanel: QLPreviewPanel?
    private var access: FileAccessLifetimes?
    private var lastSelection: [URL] = []
    private(set) var previewURLs: [URL] = []

    init(browser: BrowserViewController) { self.browser = browser }

    var isActive: Bool { requested }

    var acceptsControl: Bool {
        requested && !previewURLs.isEmpty && browser?.isBrowserSuspended == false
            && browser?.isMetadataAccessQualification == false
    }

    func toggle() {
        if requested { endSession(); return }
        guard let browser, browser.canQuickLook else { return }
        requested = true
        prepareSelection()
    }

    func selectionDidChange() {
        guard requested, browser?.quickLookSelection != lastSelection else { return }
        prepareSelection()
    }

    private func prepareSelection() {
        preparation?.cancel()
        revision = UUID()
        let token = revision
        guard let browser, !browser.isMetadataAccessQualification, !browser.isBrowserSuspended else { endSession(); return }
        let urls = browser.quickLookSelection
        lastSelection = urls
        let visit = browser.sessionID
        guard !urls.isEmpty else { endSession(); return }
        preparation = Task { [weak self, weak browser, reader] in
            guard let self, let browser else { return }
            let lifetime = await browser.accessLifetime(for: urls)
            guard !Task.isCancelled else { return }
            let eligible: [URL]
            do { eligible = try await reader.eligibleURLs(urls) } catch { return }
            guard !Task.isCancelled, self.requested, self.revision == token,
                  browser.sessionID == visit, !browser.isMetadataAccessQualification,
                  !browser.isBrowserSuspended, browser.quickLookSelection == urls else { return }
            self.preparation = nil
            guard !eligible.isEmpty else {
                browser.status.stringValue = "Quick Look is unavailable for symbolic links or inaccessible items."
                self.endSession()
                return
            }
            self.access = lifetime
            self.previewURLs = eligible
            if eligible.count != browser.selectedItemCount {
                browser.status.stringValue = "Quick Look includes up to 256 selected items; symbolic links and inaccessible items are excluded."
            }
            // The active file surface owns QL control. Changing its
            // data source outside begin/end control violates the native API.
            browser.focusBrowserContent()
            guard let panel = QLPreviewPanel.shared() else { self.endSession(); return }
            panel.updateController()
            panel.makeKeyAndOrderFront(nil)
            panel.updateController()
            if self.controlledPanel === panel { panel.reloadData() }
        }
    }

    func beginControl(_ panel: QLPreviewPanel) {
        controlledPanel = panel
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func endControl(_ panel: QLPreviewPanel) {
        guard controlledPanel === panel else { return }
        panel.dataSource = nil
        panel.delegate = nil
        controlledPanel = nil
    }

    func endSession() {
        requested = false
        revision = UUID()
        preparation?.cancel()
        preparation = nil
        previewURLs = []
        lastSelection = []
        access = nil
        if let panel = controlledPanel {
            // Release our providers before native orderOut starts its animated
            // dismissal or changes responders. Those transitions can call the
            // native end-control callback reentrantly.
            endControl(panel)
            panel.orderOut(nil)
            panel.updateController()
        }
    }

    #if DEBUG
    /// Lifecycle evidence contains types/booleans only, never selected paths.
    func cleanupState(of panel: QLPreviewPanel) -> [String: Any] {
        ["panelVisible": panel.isVisible,
         "sourceType": panel.dataSource.map { String(describing: type(of: $0)) } ?? "nil",
         "delegateType": panel.delegate.map { String(describing: type(of: $0)) } ?? "nil",
         "controllerType": panel.currentController.map { String(describing: type(of: $0)) } ?? "nil",
         "sourceIsBrowser": (panel.dataSource as AnyObject?) === self,
         "delegateIsBrowser": (panel.delegate as AnyObject?) === self,
         "ownsPanel": controlledPanel === panel,
         "requested": requested, "preparationRetained": preparation != nil,
         "accessRetained": access != nil, "previewCount": previewURLs.count]
    }

    var hasReleasedSession: Bool {
        !requested && preparation == nil && controlledPanel == nil && access == nil
            && previewURLs.isEmpty && lastSelection.isEmpty
    }
    #endif

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { acceptsControl ? previewURLs.count : 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard acceptsControl, previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty && (event.keyCode == 49 || event.keyCode == 53) {
            endSession()
            browser?.focusBrowserContent()
            return true
        }
        if flags.isEmpty && ([125, 126].contains(event.keyCode)
            || (browser?.usesFileIcons == true && [123, 124].contains(event.keyCode))) {
            browser?.activeFileView.keyDown(with: event)
            return true
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { endSession() }
}

@MainActor
extension BrowserViewController {
    var quickLookSelection: [URL] {
        guard !showsComputerVolumes else { return [] }
        return orderedSelectedURLs(upTo: QuickLookSelectionReader.maximumItems).filter { url in
            guard let row = rowsByURL[url], displayedEntries.indices.contains(row) else { return false }
            return displayedEntries[row].kind != .symbolicLink
        }
    }

    var canQuickLook: Bool {
        !isMetadataAccessQualification && !isBrowserSuspended && !isLoading
            && view.window?.attachedSheet == nil && !(view.window?.firstResponder is NSTextView)
            && !quickLookSelection.isEmpty && (hasFileCommandFocus || quickLook.isActive)
    }

    @objc func showQuickLook(_ sender: Any?) { quickLook.toggle() }
}
