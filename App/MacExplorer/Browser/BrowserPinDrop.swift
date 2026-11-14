import AppKit
import Darwin
import ExplorerCore

/// Serial shallow observations only. Pins are lexical shortcuts, never access
/// grants or observed identities reused by file operations.
private actor PinFolderReader {
    static let shared = PinFolderReader()
    func validate(_ urls: [URL]) throws {
        let activity = try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        for url in urls {
            try Task.checkCancellation()
            var value = stat()
            guard url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &value) } ?? -1 }) == 0,
                  value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PinDropFailure.notDirectory }
        }
    }
}
private enum PinDropFailure: Error { case notDirectory }

@MainActor
final class BrowserPinDrop {
    private weak var browser: BrowserViewController?
    private(set) var task: Task<Void, Never>?
    private var revision = UUID()
    init(browser: BrowserViewController) { self.browser = browser }
    func cancel() { revision = UUID(); task?.cancel(); task = nil }
    private func urls(_ board: NSPasteboard) -> [URL]? {
        let count = board.changeCount
        guard let items = board.pasteboardItems, (1...64).contains(items.count),
              items.allSatisfy({ $0.types.contains(.fileURL) }),
              let objects = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
              objects.count == items.count else { return nil }
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        guard BrowserDragDropController.validURLs(urls), board.changeCount == count else { return nil }
        return urls
    }
    func validate(_ info: NSDraggingInfo, target: Any?) -> NSDragOperation {
        guard let browser, let target = target as? SidebarNode, target.acceptsFolderPins,
              !browser.isBrowserSuspended, browser.pinsController.canEdit, task == nil,
              !ApplicationFileActivity.gate.isClosed, info.draggingSourceOperationMask.contains(.copy),
              urls(info.draggingPasteboard) != nil else { return [] }
        return .copy // never authorizes the source app to remove an original
    }
    func accept(_ info: NSDraggingInfo, target: Any?) -> Bool {
        guard !validate(info, target: target).isEmpty, let urls = urls(info.draggingPasteboard) else { return false }
        return prepare(urls)
    }
    @discardableResult
    func prepare(_ urls: [URL]) -> Bool {
        guard let browser, !browser.isBrowserSuspended, browser.pinsController.canEdit, task == nil,
              (1...64).contains(urls.count), BrowserDragDropController.validURLs(urls) else { return false }
        let token = UUID(), visit = browser.sessionID, tab = browser.activeID
        revision = token
        browser.status.stringValue = "Checking folders to pin…"
        task = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            defer { if self.revision == token { self.task = nil } }
            do {
                let access = await browser.accessLifetime(for: urls)
                defer { withExtendedLifetime(access) {} }
                try Task.checkCancellation()
                try await PinFolderReader.shared.validate(urls)
                try Task.checkCancellation()
                guard self.revision == token, !browser.isBrowserSuspended, browser.sessionID == visit,
                      browser.activeID == tab, browser.pinsController.canEdit else { return }
                // One edit validates the complete collection before publishing;
                // capacity errors cannot leave only some of this drop pinned.
                browser.pinsController.edit { pins in
                    for url in urls { _ = try pins.add(url: url, label: url.lastPathComponent) }
                }
                if let failure = await browser.pinsController.flush() {
                    guard self.revision == token, !browser.isBrowserSuspended else { return }
                    browser.status.stringValue = failure; return
                }
                guard self.revision == token, !browser.isBrowserSuspended, browser.sessionID == visit else { return }
                browser.status.stringValue = browser.pinsController.status.isEmpty
                    ? "Pinned \(urls.count) folder\(urls.count == 1 ? "" : "s") · originals stay in place"
                    : browser.pinsController.status
            } catch is CancellationError { }
            catch {
                guard self.revision == token, !browser.isBrowserSuspended, browser.sessionID == visit else { return }
                browser.status.stringValue = "Only accessible folders can be pinned. Nothing was moved or copied."
            }
        }
        return true
    }
}
