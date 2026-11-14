import AppKit
import Combine
import ExplorerCore

/// One shared instance is injected into every pane in a workspace. Pins retain
/// paths only after explicit Add, and never manufacture a security access grant.
@MainActor
final class BrowserPinsController: ObservableObject {
    enum Availability: Sendable { case notChecked, opened, unavailable }
    @Published private(set) var collection = BrowserPinCollection()
    @Published private(set) var availability: [UUID: Availability] = [:]
    @Published private(set) var status = ""
    private(set) var isReady = false
    private var started = false
    private var blocked = false
    private let worker: BrowserPinsWorker
    let remote: RemoteConnectionPinsController

    init(stateDirectory: URL?) { worker = BrowserPinsWorker(directory: stateDirectory); remote = RemoteConnectionPinsRegistry.controller(directory: stateDirectory) }

    func restoreIfNeeded() async {
        guard !started else { return }
        started = true
        switch await worker.load() {
        case .success(let value): collection = value ?? BrowserPinCollection()
        case .failure:
            blocked = true
            status = "Saved pins could not be safely restored. Their data was preserved."
        }
        isReady = true
    }

    var canEdit: Bool { isReady && !blocked }

    func edit(_ mutation: (inout BrowserPinCollection) throws -> Void) {
        guard canEdit else { return }
        do {
            var next = collection
            try mutation(&next)
            guard next != collection else { return }
            let data = try next.encoded()
            status = ""
            collection = next
            availability = availability.filter { key, _ in next.pins.contains { $0.id == key } }
            worker.save(data)
        } catch {
            status = "The pin could not be changed. Use a short, nonempty label; at most 64 folders can be pinned."
        }
    }

    /// Called only after the explicit ordinary navigation result, never while
    /// rendering/restoring the sidebar. A saved path is not an identity claim.
    func recordNavigation(to url: URL, successful: Bool) {
        for pin in collection.pins where BrowserLocation.directory(pin.url) == .directory(url) {
            let value: Availability = successful ? .opened : .unavailable
            if availability[pin.id] != value { availability[pin.id] = value }
        }
    }

    func flush() async -> String? {
        let remoteIssue = await remote.flush()
        if await worker.flush() {
            status = "Pin changes are available for this session, but could not be saved safely."
            return status
        }
        return remoteIssue
    }
}

@MainActor
final class BrowserPinnedSidebar {
    private var ids: [ObjectIdentifier: UUID] = [:]
    func group(controller: BrowserPinsController) -> SidebarNode {
        ids = [:]
        let nodes = controller.collection.pins.map { pin in
            let unavailable = controller.availability[pin.id] == .unavailable
            let node = SidebarNode(pin.label, location: .directory(pin.url),
                                   icon: unavailable ? "exclamationmark.circle" : "pin", children: [])
            ids[ObjectIdentifier(node)] = pin.id
            return node
        }
        return SidebarNode("Pinned Folders", group: true, acceptsFolderPins: true, children: nodes)
    }
    func id(for node: SidebarNode) -> UUID? { ids[ObjectIdentifier(node)] }
}

@MainActor
extension BrowserViewController {
    func isPinned(_ url: URL) -> Bool {
        pinsController.collection.pins.contains { BrowserLocation.directory($0.url) == .directory(url) }
    }
    func toggleFolderPin(_ url: URL) {
        guard pinsController.canEdit else { return }
        let existing = pinsController.collection.pins.first { BrowserLocation.directory($0.url) == .directory(url) }
        pinsController.edit { pins in
            if let existing { try pins.remove(id: existing.id) }
            else { _ = try pins.add(url: url, label: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent) }
        }
        reportPinPersistence()
    }
    @objc func toggleSelectedFolderPin(_ sender: Any?) {
        guard let url = selectedFolderURL else { return }
        toggleFolderPin(url)
    }
    func connectPins() {
        remotePins.$collection.sink { [weak self] _ in Task { @MainActor [weak self] in self?.rebuildSidebar(coalescingLocalLayoutPublication: true) } }.store(in: &subscriptions)
        remotePins.$status.sink { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, !isBrowserSuspended, !value.isEmpty else { return }; status.stringValue = value
            }
        }.store(in: &subscriptions)
        pinsController.$collection.combineLatest(pinsController.$availability).sink { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.rebuildSidebar(coalescingLocalLayoutPublication: true) }
        }.store(in: &subscriptions)
        Task { [weak self] in
            guard let self else { return }
            await pinsController.restoreIfNeeded()
            await remotePins.restoreIfNeeded()
            rebuildSidebar()
            if !pinsController.status.isEmpty { status.stringValue = pinsController.status }
        }
    }

    var canPinCurrentFolder: Bool { isRemoteLocation ? hasLiveRemoteNavigation && remotePins.canEdit : location.directoryURL != nil && pinsController.canEdit }
    var selectedPin: BrowserPin? {
        if let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
           let id = pinnedSidebar.id(for: node) {
            return pinsController.collection.pins.first { $0.id == id }
        }
        return pinsController.collection.pins.first { BrowserLocation.directory($0.url) == location }
    }
    var canManageSelectedPin: Bool { selectedRemotePin != nil ? remotePins.canEdit : pinsController.canEdit && selectedPin != nil }
    var canMoveSelectedPinUp: Bool {
        if let pin = selectedRemotePin, let index = remotePins.collection.pins.firstIndex(where: { $0.id == pin.id }) { return remotePins.canEdit && index > 0 }
        guard let pin = selectedPin, let index = pinsController.collection.pins.firstIndex(where: { $0.id == pin.id }) else { return false }
        return pinsController.canEdit && index > 0
    }
    var canMoveSelectedPinDown: Bool {
        if let pin = selectedRemotePin, let index = remotePins.collection.pins.firstIndex(where: { $0.id == pin.id }) { return remotePins.canEdit && index + 1 < remotePins.collection.pins.count }
        guard let pin = selectedPin, let index = pinsController.collection.pins.firstIndex(where: { $0.id == pin.id }) else { return false }
        return pinsController.canEdit && index + 1 < pinsController.collection.pins.count
    }

    @objc func pinCurrentFolder(_ sender: Any?) {
        if isRemoteLocation { pinCurrentConnectionFolder(sender); return }
        guard canPinCurrentFolder, let url = location.directoryURL else { return }
        pinsController.edit { _ = try $0.add(url: url, label: location.displayName) }
        reportPinPersistence()
    }
    @objc func removeSelectedPin(_ sender: Any?) {
        if selectedRemotePin != nil { removeRemotePin(sender); return }
        guard canManageSelectedPin, let pin = selectedPin else { return }
        pinsController.edit { try $0.remove(id: pin.id) }
        reportPinPersistence()
    }
    @objc func renameSelectedPin(_ sender: Any?) {
        if selectedRemotePin != nil { renameRemotePin(sender); return }
        guard canManageSelectedPin, let pin = selectedPin, let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Pin Label"
        alert.informativeText = "This changes this app's shortcut label. The folder name and access permissions stay the same."
        let field = NSTextField(string: pin.label)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Label")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn, let self else { return }
            // The captured ID cannot silently become a different current pin.
            self.pinsController.edit { try $0.relabel(id: pin.id, label: field.stringValue) }
            self.reportPinPersistence()
        }
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
    }
    @objc func moveSelectedPinUp(_ sender: Any?) { moveSelectedPin(offset: -1) }
    @objc func moveSelectedPinDown(_ sender: Any?) { moveSelectedPin(offset: 1) }
    private func moveSelectedPin(offset: Int) {
        if let pin = selectedRemotePin, let index = remotePins.collection.pins.firstIndex(where: { $0.id == pin.id }), remotePins.collection.pins.indices.contains(index + offset) {
            remotePins.edit { try $0.move(id: pin.id, to: index + offset) }; return
        }
        guard canManageSelectedPin, let pin = selectedPin,
              let index = pinsController.collection.pins.firstIndex(where: { $0.id == pin.id }),
              pinsController.collection.pins.indices.contains(index + offset) else { return }
        pinsController.edit { try $0.move(id: pin.id, to: index + offset) }
        reportPinPersistence()
    }
    private func reportPinPersistence() {
        Task { [weak self] in
            guard let self else { return }
            if let failure = await pinsController.flush() { status.stringValue = failure }
            else if !pinsController.status.isEmpty { status.stringValue = pinsController.status }
        }
    }
}

private final class BrowserPinsWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.Pins", qos: .utility)
    private let store: BrowserPinStore?
    private var failed = false
    init(directory: URL?) { store = directory.map(BrowserPinStore.init) }
    func load() async -> Result<BrowserPinCollection?, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: Result { try store?.load() }) }
        }
    }
    func save(_ data: Data) {
        queue.async { [self] in
            do { try store?.save(data) }
            catch { failed = true }
        }
    }
    func flush() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: failed) }
        }
    }
}

private struct BrowserPinStore: Sendable {
    let directory: URL
    init(_ directory: URL) { self.directory = directory }
    private var file: BrowserSnapshotFile {
        BrowserSnapshotFile(directory: directory, name: "browser-pins-v1.json", maximumBytes: BrowserPinCollection.maximumEncodedBytes)
    }
    func load() throws -> BrowserPinCollection? {
        guard let data = try file.read() else { return nil }
        return try BrowserPinCollection.decode(data)
    }
    func save(_ data: Data) throws {
        try file.write(data) { _ = try BrowserPinCollection.decode($0) }
    }
}
