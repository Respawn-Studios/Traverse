import AppKit
import Combine
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// One live writer per private profile across windows; weak entries retain no
/// closed UI or idle profile. The disk expected-version check still protects
/// against a different process or an external arrival.
@MainActor enum RemoteConnectionPinsRegistry {
    private final class Weak {
        weak var value: RemoteConnectionPinsController?
        init(_ value: RemoteConnectionPinsController) { self.value = value }
    }
    private static var values: [String: Weak] = [:]
    static func controller(directory: URL?) -> RemoteConnectionPinsController {
        guard let directory else { return .init(directory: nil) }
        values = values.filter { $0.value.value != nil }
        let key = directory.standardizedFileURL.path
        if let value = values[key]?.value { return value }
        let value = RemoteConnectionPinsController(directory: directory); values[key] = Weak(value); return value
    }
    static func flushAll() async {
        let active = values.values.compactMap(\.value)
        for controller in active { _ = await controller.flush() }
    }
}

@MainActor final class RemoteConnectionPinsController: ObservableObject {
    @Published private(set) var collection = RemoteConnectionPinCollection()
    @Published private(set) var status = ""
    @Published private(set) var isReady = false
    private var started = false, blocked = false
    private var work: Task<Void, Never>?
    private let worker: RemoteConnectionPinsWorker
    private let persistent: Bool
    init(directory: URL?) { persistent = directory != nil; worker = RemoteConnectionPinsWorker(directory: directory) }
    var canEdit: Bool { isReady && !blocked && work == nil }
    var isSaving: Bool { work != nil }
    #if DEBUG
    // Qualification only: blocks the generated load on its existing private queue.
    var beforeLoadForVerification: (@Sendable () throws -> Void)?
    #endif
    func restoreIfNeeded() async {
        guard !started else { return }; started = true
        #if DEBUG
        let loaded = await worker.load(beforeLoad: beforeLoadForVerification)
        #else
        let loaded = await worker.load()
        #endif
        switch loaded {
        case .success(let value): collection = value ?? .init()
        case .failure: blocked = true; status = "Saved connection pins need review. Their data was preserved; editing is disabled."
        }
        isReady = true
    }
    func edit(_ change: (inout RemoteConnectionPinCollection) throws -> Void) {
        guard canEdit else { return }
        do {
            var next = collection; try change(&next); guard next != collection else { return }
            let data = try next.encoded(); collection = next; status = "Saving connection pin…"
            work = Task { [self] in
                let saved = await worker.save(data)
                status = saved ? (persistent ? "Connection pin saved." : "Connection pin is available for this session.")
                    : "Pin changes remain in this session; saving could not be confirmed. Editing is paused to protect the saved state."
                if !saved { blocked = true }
                work = nil
            }
        } catch { status = "The pin exceeds the saved-pin limits. Use a short nonempty label, or remove some pins." }
    }
    func flush() async -> String? {
        await work?.value
        return status.contains("could not") || blocked ? status : nil
    }
}

private final class RemoteConnectionPinsWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.RemoteConnectionPins", qos: .utility)
    private let file: BrowserSnapshotFile?
    private var expected: BrowserSnapshotFile.ExpectedVersion?
    init(directory: URL?) {
        file = directory.map {
            var value = BrowserSnapshotFile(directory: $0, name: "remote-connection-pins-v1.json", maximumBytes: RemoteConnectionPinCollection.maximumEncodedBytes)
            value.requiresPrivateDurability = true; return value
        }
    }
    func load(beforeLoad: (@Sendable () throws -> Void)? = nil) async -> Result<RemoteConnectionPinCollection?, Error> {
        await withCheckedContinuation { continuation in queue.async { [self] in
            continuation.resume(returning: Result {
                try beforeLoad?()
                guard let file else { return nil }
                guard let data = try file.read() else { expected = .absent; return nil }
                let value = try RemoteConnectionPinCollection.decode(data); expected = .bytes(data); return value
            })
        } }
    }
    func save(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            do {
                if let file {
                    guard let expected else { throw BrowserSnapshotFile.Failure.invalidDocument }
                    try file.write(data, replacing: expected) { _ = try RemoteConnectionPinCollection.decode($0) }
                    self.expected = .bytes(data)
                }
                continuation.resume(returning: true)
            }
            catch { continuation.resume(returning: false) }
        } }
    }
}

@MainActor extension BrowserViewController {
    var remotePins: RemoteConnectionPinsController { pinsController.remote }
    func remotePinsGroup() -> SidebarNode {
        .init("Pinned Connections", group: true, children: remotePins.collection.pins.map {
            SidebarNode($0.label, icon: "pin", children: [], detail: "Saved remote folder. Uses an open matching connection or asks you to connect.", remotePin: $0.id)
        })
    }
    var currentRemoteBookmark: WorkspaceConnectionBookmark? {
        switch location {
        case .sftp(let value): return sftpTabs[activeID]?.bookmark(for: value)
        case .smb(let value): return smbTabs[activeID]?.bookmark(for: value)
        default: return nil
        }
    }
    @objc func pinCurrentConnectionFolder(_ sender: Any?) {
        guard !isBrowserSuspended, isActiveCommandPane, view.window?.isVisible == true, view.window?.attachedSheet == nil else { return }
        guard remotePins.canEdit else {
            status.stringValue = remotePins.status.isEmpty ? "Connection pins are loading or saving. Try again when that work finishes." : remotePins.status
            return
        }
        guard let target = currentRemoteBookmark else {
            showCurrentConnectionProperties(nil); status.stringValue = "Save Connection Details explicitly before pinning this remote folder."; return
        }
        remotePins.edit { _ = try $0.add(target: target, label: location.displayName) }
    }
    func openRemotePin(_ id: UUID) {
        guard !isBrowserSuspended, view.window?.isVisible == true, view.window?.attachedSheet == nil,
              let pin = remotePins.collection.pins.first(where: { $0.id == id }) else { return }
        let target = pin.target
        let browsers = workspace.map { workspace in workspace.layout.paneIDs.compactMap { workspace.browsers[$0] } }
        // Resolve saved target identity, never a display title or stale opaque
        // session UUID. The folder remains the explicit pin's captured path.
        for browser in browsers ?? [self] {
            for tab in browser.tabs {
                guard let saved = tab.connectionBookmark, saved.kind == target.kind,
                      saved.serverID == target.serverID, saved.binding == target.binding else { continue }
                do {
                    let value: BrowserLocation
                    if target.isSFTP, let owner = browser.sftpTabs[tab.id], !owner.isClosing {
                        value = .sftp(try owner.directoryLocation(components: WorkspaceConnectionBinding.sftpComponents(target), relativeToHome: target.relativeToHome))
                    } else if !target.isSFTP, let owner = browser.smbTabs[tab.id], !owner.isClosing {
                        value = .smb(try owner.directoryLocation(components: WorkspaceConnectionBinding.smbComponents(target)))
                    } else { continue }
                    workspace?.activate(browser, focus: false); browser.selectTab(tab.id)
                    if browser.location != value { browser.navigate(to: value) }; browser.focusBrowserContent(); return
                } catch { status.stringValue = "This pin's saved folder could not be resolved safely."; return }
            }
        }
        do {
            let tab = try target.disconnectedTab()
            saveViewState(); tabs.append(tab); activeID = tab.id; loadLocation(animatingTab: true); focusBrowserContent()
        } catch { status.stringValue = "This saved connection pin is invalid. Its data was preserved." }
    }
    var selectedRemotePin: RemoteConnectionPin? {
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode, let id = node.remotePin else { return nil }
        return remotePins.collection.pins.first { $0.id == id }
    }
    private func remotePin(for sender: Any?) -> RemoteConnectionPin? {
        if let id = ((sender as? NSMenuItem)?.representedObject as? RemotePinMenuTarget)?.id {
            return remotePins.collection.pins.first { $0.id == id }
        }
        return selectedRemotePin
    }
    func remotePinMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, action) in [("Open Connection Folder", #selector(openRemotePinMenu(_:))),
            ("Rename Pin Label…", #selector(renameRemotePin(_:))), ("Remove Pin", #selector(removeRemotePin(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = RemotePinMenuTarget(id)
            item.isEnabled = !isBrowserSuspended && (action == #selector(openRemotePinMenu(_:)) || remotePins.canEdit)
        }
        return menu
    }
    @objc private func openRemotePinMenu(_ sender: NSMenuItem) { if let pin = remotePin(for: sender) { openRemotePin(pin.id) } }
    @objc func removeRemotePin(_ sender: Any?) {
        guard let pin = remotePin(for: sender) else { return }; remotePins.edit { try $0.remove(id: pin.id) }
    }
    @objc func renameRemotePin(_ sender: Any?) {
        guard remotePins.canEdit, let pin = remotePin(for: sender), let window = view.window, window.attachedSheet == nil else { return }
        let captured = remotePins.collection
        let alert = NSAlert(); alert.messageText = "Rename Connection Pin"
        let field = NSTextField(string: pin.label); field.frame = .init(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save Label"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] reply in
            guard reply == .alertFirstButtonReturn, let self, remotePins.collection == captured else { return }
            remotePins.edit { try $0.relabel(id: pin.id, label: field.stringValue) }
        }
    }
}

@MainActor private final class RemotePinMenuTarget: NSObject {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}
