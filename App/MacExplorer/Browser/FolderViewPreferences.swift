import AppKit
import Combine
import ExplorerCore
import SwiftUI

@MainActor final class ApplicationFolderViews: NSObject, ObservableObject, NSWindowDelegate {
    static let shared: ApplicationFolderViews = {
        let directory = AppStorageLocations.stateDirectory?.appendingPathComponent("folder-views")
        return ApplicationFolderViews(store: FolderViewStore(directory: directory))
    }()
    @Published private(set) var library = FolderViewPresets()
    @Published private(set) var isBusy = false
    @Published private(set) var isUnavailable = false
    @Published private(set) var notice = ""
    @Published var selected: UUID?
    private let store: FolderViewStore
    private var snapshot: FolderViewStore.Snapshot?
    private var work: Task<Void, Never>?
    private var editEpoch = UUID()
    private var controller: NSWindowController?
    var window: NSWindow? { controller?.window }
    init(store: FolderViewStore) { self.store = store; super.init() }
    func readChoice(for path: String) async throws -> FolderViewChoice? {
        let epoch = editEpoch
        do {
            let value = try await store.load(); adopt(value)
            return value.library.record(for: path)?.choice
        } catch {
            if editEpoch == epoch { isUnavailable = true; notice = Self.message(error) }
            throw error
        }
    }
    private func adopt(_ value: FolderViewStore.Snapshot) {
        guard snapshot == nil || value.ordinal >= snapshot!.ordinal else { return }
        let changed = snapshot == nil || snapshot?.bytes != value.bytes
        snapshot = value
        if changed { library = value.library }
        if isUnavailable { notice = ""; isUnavailable = false }
        if let selected, !library.records.contains(where: { $0.id == selected }) { self.selected = nil }
    }
    func reload() {
        guard work == nil else { return }
        isBusy = true
        work = Task { [self] in
            defer { isBusy = false; work = nil }
            do { adopt(try await store.load()); notice = "" }
            catch { isUnavailable = true; notice = Self.message(error) }
        }
    }
    func save(path: String, choice: FolderViewChoice) {
        edit { try $0.save(path: path, choice: choice) }
    }
    func forget(_ id: UUID) { edit { try $0.forget(id) } }
    func forgetAll() { edit { $0.forgetAll() } }
    func selectAdjacent(_ offset: Int) {
        guard !library.records.isEmpty else { return }
        let current = selected.flatMap { id in library.records.firstIndex { $0.id == id } }
        let next = current.map { min(library.records.count - 1, max(0, $0 + offset)) }
            ?? (offset < 0 ? library.records.count - 1 : 0)
        selected = library.records[next].id
    }
    private func edit(_ change: @escaping @Sendable (inout FolderViewPresets) throws -> Void) {
        guard work == nil, !isUnavailable else { return }
        isBusy = true; editEpoch = UUID(); let expected = snapshot
        work = Task { [self] in
            defer { isBusy = false; work = nil }
            do { adopt(try await store.edit(expected: expected, change)); notice = "Saved folder views updated. Current visits keep their choices." }
            catch { isUnavailable = true; notice = Self.message(error) }
        }
    }
    func drain() async { while let work { await work.value }; await store.drain() }
    func show(from browser: BrowserViewController) {
        if let window = controller?.window, window.isVisible { window.makeKeyAndOrderFront(nil); reload(); return }
        let host = InterfaceHostingController(rootView: FolderViewsManagementView(model: self, settings: browser.settings))
        let size = NSSize(width: 700, height: 520), minimum = NSSize(width: 600, height: 400)
        let window = ToolWindowChrome.makeWindow(title: "Saved Folder Views", size: size,
            minimumSize: minimum, content: host)
        ToolWindowChrome.install(in: window, settings: browser.settings,
            initialContentSize: size, minimumContentSize: minimum)
        ToolWindowChrome.position(window, relativeTo: browser.view.window)
        if browser.isControlledVerification { window.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        controller = NSWindowController(window: window)
        window.delegate = self
        window.makeKeyAndOrderFront(nil); ToolContentMotion.reveal(window.contentView!, effect: .windows); reload()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controller?.window else { return }
        // Break the model -> controller -> hosting view -> model cycle. A
        // submitted save remains owned by its task until actual completion.
        controller = nil
    }
    func confirmForgetAll() {
        guard let window, !isBusy, !isUnavailable, !library.records.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Forget all saved folder views?"
        alert.informativeText = "This removes all \(library.records.count) saved locations and view preferences from this app. Current tabs and files stay unchanged. Earlier backups can retain copies."
        alert.addButton(withTitle: "Forget Views"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
        let revision = library.revision
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.library.revision == revision else { return }
            self.forgetAll()
        }
    }
    private static func message(_ error: Error) -> String {
        switch error {
        case FolderViewPresets.Failure.limit: "The 512-folder limit is reached. Forget an unused view before saving another."
        case FolderViewStore.Failure.stale: "Saved views changed elsewhere. Reload before editing them."
        case BrowserSnapshotFile.Failure.writerBusy: "Another Explorer instance is saving views. Wait briefly, then Reload."
        default: "Saved folder views could not be verified. Browsing can continue with the current view. The original preferences stay protected; restore valid state if needed, then Reload."
        }
    }
}

private struct FolderViewsManagementView: View {
    @ObservedObject var model: ApplicationFolderViews
    @ObservedObject var settings: BrowserSettings
    @Environment(\.colorScheme) private var inheritedColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Saved Folder Views").interfaceFont(.title2.bold()); Spacer(); Button("Reload", action: model.reload).disabled(model.isBusy) }
            Text("Local only. Explicitly saved folder locations, view modes and sorting; no files, contents or access grants. Nothing is collected automatically.")
                .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.notice.isEmpty { Text(model.notice).interfaceFont(.callout).fixedSize(horizontal: false, vertical: true) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.library.records) { record in
                            Button { model.selected = record.id } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.path == "/" ? "/" : URL(fileURLWithPath: record.path).lastPathComponent).interfaceFont(.headline).lineLimit(1)
                                    Text(record.path).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text("\(record.choice.mode.rawValue) · \(record.choice.sort.field.rawValue.capitalized) · \(record.choice.sort.ascending ? "Ascending" : "Descending") · \(record.choice.sort.foldersFirst ? "Folders first" : "Mixed items")")
                                        .interfaceFont(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(record.id == model.selected ? Color.accentColor.opacity(0.2) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(record.id)
                                .accessibilityAddTraits(record.id == model.selected ? .isSelected : [])
                        }
                    }.padding(3)
                }.focusable().onMoveCommand { direction in
                    if direction == .up { model.selectAdjacent(-1) }
                    else if direction == .down { model.selectAdjacent(1) }
                }.onChange(of: model.selected) { _, selected in
                    if let selected { proxy.scrollTo(selected) }
                }
            }
                .overlay {
                    if model.library.records.isEmpty {
                        Text(model.isBusy ? "Loading saved views…" : "No saved folder views")
                            .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            HStack {
                Button("Forget Selected") { if let id = model.selected { model.forget(id) } }
                    .disabled(model.selected == nil || model.isBusy || model.isUnavailable)
                Button("Forget All…", action: model.confirmForgetAll).disabled(model.library.records.isEmpty || model.isBusy || model.isUnavailable)
                Spacer(); if model.isBusy { ProgressView().controlSize(.small) }
                Text("\(model.library.records.count) of 512 locations").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Text("Save from View → Folder View. Saved choices apply on a fresh visit; Back, Forward, restored layouts and current overrides keep their choices. No .DS_Store files are written.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(minWidth: 560, minHeight: 340)
            .environment(\.colorScheme, settings.appearance == .system ? inheritedColorScheme : settings.appearance == .dark ? .dark : .light)
    }
}

@MainActor extension BrowserViewController {
    var folderViewPath: String? { metadataSearch.isShowingResults ? nil : location.directoryURL?.standardizedFileURL.path }
    var folderViewChoice: FolderViewChoice { .init(mode: effectiveViewMode, sort: tabs[activeIndex].sort) }
    func markFolderViewOverride(mode: DirectoryViewMode? = nil) {
        folderViewRevision = UUID(); tabs[activeIndex].resolveFolderView(mode: mode ?? effectiveViewMode, sort: tabs[activeIndex].sort)
    }
    func resolveSavedFolderView(for path: String, session: UUID, force: Bool = false) async {
        guard force || !tabs[activeIndex].folderViewResolved else { return }
        let revision = folderViewRevision
        let choice = try? await folderViews.readChoice(for: path)
        guard !Task.isCancelled, sessionID == session, folderViewRevision == revision, !isBrowserSuspended,
              location.directoryURL?.standardizedFileURL.path == path else { return }
        if let choice { tabs[activeIndex].resolveFolderView(mode: choice.mode, sort: choice.sort); applyDisplayPreferences(); syncSortIndicators() }
        else { tabs[activeIndex].resolveFolderView() }
    }
    @objc func saveFolderView(_ sender: Any?) {
        guard let path = folderViewPath, !folderViews.isBusy else { return }
        markFolderViewOverride(mode: effectiveViewMode)
        folderViews.save(path: path, choice: folderViewChoice)
    }
    @objc func applySavedFolderView(_ sender: Any?) {
        guard let path = folderViewPath, !folderViews.isBusy else { return }
        let token = sessionID
        Task { [weak self] in await self?.resolveSavedFolderView(for: path, session: token, force: true) }
    }
    @objc func forgetFolderView(_ sender: Any?) {
        guard let path = folderViewPath, let record = folderViews.library.record(for: path) else { return }
        folderViews.forget(record.id)
    }
    @objc func showFolderViews(_ sender: Any?) { folderViews.show(from: self) }
}
