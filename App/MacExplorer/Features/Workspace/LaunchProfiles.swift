import AppKit
import Combine
import ExplorerCore
import SwiftUI

@MainActor final class LaunchProfilesModel: ObservableObject {
    @Published private(set) var profiles: [WorkspaceLaunchProfile] = []
    @Published var selected: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var notice = ""
    @Published private(set) var templateKeys: [UUID: String] = [:]
    private(set) var lastFailure: String?
    let settings: BrowserSettings
    private let store: LaunchProfileStore
    private var revision: UUID?
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var closed = true
    private var reloadRequested = false
    private var memoryObservation: AnyCancellable?
    let workspaces: ProfileWorkspaceController
    var busy: Bool { isBusy || workspaces.isBusy }
    private enum EditFailure: Error { case forgetUnconfirmed, templateRetained }
    weak var workspace: BrowserWorkspaceController?
    weak var window: NSWindow?
    var selection: WorkspaceLaunchProfile? { profiles.first { $0.id == selected } }
    init(workspace: BrowserWorkspaceController, store: LaunchProfileStore) {
        self.workspace = workspace; self.store = store; settings = workspace.primaryBrowser.settings
        workspaces = workspace.profileWorkspaces
        memoryObservation = workspaces.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    func start() { closed = false; generation = UUID(); reload() }
    func close() {
        closed = true; generation = UUID(); profiles = []; selected = nil
        // A submitted Save/rename/delete remains owned until actual completion.
        // Closing a tool window is not cancellation of an acknowledged intent.
    }
    func drain() async {
        // Reopening during a submitted edit can schedule one fresh reload in
        // that edit's defer. Include the replacement owner, not just the task
        // that happened to be current when draining began.
        while let work { await work.value }
        await store.drain()
    }
    func reload() {
        guard !closed else { return }
        guard work == nil else { reloadRequested = true; return }
        perform { [self] in
            let value = try await store.load()
            do { _ = try await workspaces.refresh() }
            catch { return (value, "Remembered workspaces are unavailable. Saved layouts can still be opened.") }
            if settings.startupMode == .profile, !value.library.profiles.contains(where: { $0.id == settings.startupProfileID }) {
                return (value, "The selected launch profile is missing. Choose another profile or This Mac in General settings.")
            }
            return (value, lastFailure ?? "")
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> (LaunchProfileStore.Snapshot, String)) {
        guard !closed, work == nil, !workspaces.isBusy else { return }
        let token = generation; isBusy = true
        work = Task { [self] in
            defer {
                work = nil; isBusy = false
                if reloadRequested, !closed { reloadRequested = false; reload() }
            }
            do {
                let (value, message) = try await action()
                lastFailure = nil
                guard !closed, token == generation else { return }
                var keys: [UUID: String] = [:]
                if let workspace {
                    for profile in value.library.profiles where workspaces.records[profile.id] != nil {
                        keys[profile.id] = try? await workspace.profileWorkspaceStore.key(for: profile)
                    }
                }
                guard !closed, token == generation else { return }
                templateKeys = keys
                revision = value.revision; profiles = value.library.profiles; notice = message
                workspaces.noteLibrary(profiles)
                if !profiles.contains(where: { $0.id == selected }) { selected = profiles.first?.id }
            } catch {
                let message = Self.message(error); lastFailure = message
                guard !closed, token == generation else { return }
                notice = message
            }
        }
    }
    func saveCurrent(name: String, includeFilters: Bool, atLaunch: Bool, replacing id: UUID? = nil) {
        guard !closed, work == nil, let workspace else { return }
        do {
            let snapshot = try workspace.captureLaunchProfile(includeFilters: includeFilters)
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines), expected = revision
            if id == nil { try WorkspaceLaunchProfiles.validateName(title) }
            perform { [self] in
                if let id { try await workspaces.stopFollowing(id, forget: false) }
                let value = try await store.edit(expected: expected) { library in
                    if let id { try library.update(id, snapshot: snapshot, includeFilters: includeFilters) }
                    else { try library.add(name: title, snapshot: snapshot, includeFilters: includeFilters) }
                }
                let saved = id ?? value.library.profiles.last!.id
                if atLaunch {
                    do { try await settings.chooseStartup(.profile, profile: saved) }
                    catch { return (value, "Profile saved. Its startup choice could not be confirmed; review General settings.") }
                }
                return (value, atLaunch ? "Profile saved and selected for launch." : "Profile saved. Browsing will not change it.")
            }
        } catch { notice = Self.message(error) }
    }
    func useAtLaunch() {
        guard let selected, !closed, work == nil else { return }
        perform { [self] in
            let latest = try await store.load()
            guard latest.library.profiles.contains(where: { $0.id == selected }) else { throw WorkspaceLaunchProfiles.Failure.stale }
            try await settings.chooseStartup(.profile, profile: selected)
            return (latest, "Selected for future launches. The current window stays as it is.")
        }
    }
    func rename(to name: String) {
        guard let selected, !closed, work == nil else { return }
        let expected = revision, title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { [self] in
            let value = try await store.edit(expected: expected) { try $0.rename(selected, to: title) }
            return (value, "Profile renamed.")
        }
    }
    func removeSelected() {
        guard let selected, !closed, work == nil else { return }
        let expected = revision
        perform { [self] in
            do { try await workspaces.stopFollowing(selected, forget: true) }
            catch { throw EditFailure.forgetUnconfirmed }
            let value: LaunchProfileStore.Snapshot
            do { value = try await store.edit(expected: expected) { try $0.remove(selected) } }
            catch { throw EditFailure.templateRetained }
            workspaces.profileWasRemoved(selected)
            if settings.startupProfileID == selected {
                do {
                    if settings.startupMode == .profile { try await settings.chooseStartup(.computer) }
                    settings.startupProfileID = nil
                } catch { return (value, "Profile deleted. The startup choice could not be confirmed; review General settings.") }
            }
            return (value, "Profile deleted from this app. Earlier backups may retain its locations.")
        }
    }
    func openSelected(resuming: Bool = false) {
        guard let profile = selection, let workspace, let window, !busy else { return }
        let alert = NSAlert(); alert.messageText = resuming ? "Resume \(profile.name)?" : "Open \(profile.name)?"
        alert.informativeText = resuming
            ? "Replace this window’s tabs and panes with this profile’s remembered workspace. Future layout changes will be remembered. Saved servers reopen disconnected; file operations do not resume."
            : "Replace this window’s tabs and panes with the saved layout. Its remembered workspace stays as it was. The launch default is unchanged."
        alert.addButton(withTitle: resuming ? "Resume Workspace" : "Open Profile"); alert.addButton(withTitle: "Cancel")
        let token = generation
        Task { [weak self, weak workspace] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn, let self, let workspace,
                  !self.closed, !self.busy else { return }
            self.perform { [self] in
                let before = try workspace.captureSessionSnapshot(syncViewState: false)
                let latest = try await store.load()
                guard !closed, generation == token,
                      try workspace.captureSessionSnapshot(syncViewState: false) == before,
                      latest.revision == revision, let chosen = latest.library.profiles.first(where: { $0.id == profile.id }) else {
                    throw WorkspaceLaunchProfiles.Failure.stale
                }
                try await workspaces.open(chosen, resuming: resuming)
                window.close(); workspace.view.window?.makeKeyAndOrderFront(nil)
                return (latest, workspaces.notice)
            }
        }
    }
    func setRemembering(_ enabled: Bool) {
        guard let profile = selection, !busy else { return }
        perform { [self] in
            try await workspaces.setRemembering(enabled, for: profile)
            return (try await store.load(), workspaces.notice)
        }
    }
    static func message(_ error: Error) -> String {
        switch error {
        case EditFailure.forgetUnconfirmed: "Forgetting the remembered workspace could not be confirmed. The saved layout was kept; refresh to review."
        case EditFailure.templateRetained: "The remembered workspace was cleared. Removing the saved layout could not be confirmed. Refresh to review."
        case WorkspaceLaunchProfiles.Failure.invalidName: "Choose a shorter, nonempty name without line breaks."
        case WorkspaceLaunchProfiles.Failure.duplicateName: "A profile already has that name. Choose another name."
        case WorkspaceLaunchProfiles.Failure.limitReached: "Save up to 20 profiles and 32 tabs per pane. Remove an old profile or reduce the tabs first."
        case WorkspaceLaunchProfiles.Failure.stale: "Profiles changed. Refresh before editing; existing data was preserved."
        case WorkspaceLaunchProfiles.Failure.missingProfile: "That profile is no longer available. Refresh the list."
        case WorkspaceSession.ValidationFailure.invalidLocation: "Remember each network server in Connect to Server before saving its tab in a layout. No connection or password is saved in the layout."
        default: ProfileWorkspaceController.message(error)
        }
    }
}

private struct LaunchProfilesView: View {
    @ObservedObject var model: LaunchProfilesModel
    @ObservedObject var settings: BrowserSettings
    @State private var name = ""
    @State private var includeFilters = false
    @State private var atLaunch = false
    @State private var renaming = false
    @State private var rename = ""
    @State private var deleting = false
    @State private var updating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Launch Profiles").interfaceFont(.title2.weight(.semibold))
                    Text("Your layouts, ready when you need them.").interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(); if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { model.reload() }.disabled(model.busy)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                List(selection: $model.selected) {
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(profile.name).lineLimit(1)
                                Spacer()
                                if model.workspaces.records[profile.id] != nil {
                                    Image(systemName: "clock.arrow.circlepath").help("Remembered workspace available")
                                }
                                if settings.startupMode == .profile, settings.startupProfileID == profile.id {
                                    Image(systemName: "power").help("Selected for launch")
                                }
                            }
                            Text(Self.summary(profile.snapshot))
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(profile.id)
                    }
                }.frame(minWidth: 220, idealWidth: 250, maxWidth: 280).scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.2))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let profile = model.selection {
                        Text(profile.name).interfaceFont(.headline)
                        Text(profile.includesFilters ? "Folder filters included" : "Folder filters cleared at launch")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                        Toggle("Remember where I leave off", isOn: Binding(
                            get: { model.workspaces.records[profile.id] != nil }, set: { model.setRemembering($0) }))
                            .disabled(!model.workspaces.available)
                        Text("Save this profile’s tabs and panes. Resume picks up that workspace; launch opens the saved layout. Saved servers reopen disconnected.")
                            .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let record = model.workspaces.records[profile.id] {
                            Label("Remembered · " + Self.summary(record.snapshot), systemImage: "clock.arrow.circlepath")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                            if model.templateKeys[profile.id] != record.templateKey {
                                Text("The saved layout changed. Turn remembering off to forget its older workspace, then enable it for this layout.")
                                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(profile.snapshot.panes, id: \.id) { pane in
                                    Text("\(pane.viewMode) · \(pane.tabs.tabs.count) \(pane.tabs.tabs.count == 1 ? "tab" : "tabs")").interfaceFont(.caption.weight(.semibold))
                                    ForEach(Array(pane.tabs.tabs.enumerated()), id: \.offset) { index, tab in
                                        Label(tab.location.url?.path ?? "This Mac", systemImage: index == pane.tabs.activeTab ? "folder.fill" : "folder")
                                            .interfaceFont(.caption).lineLimit(2).textSelection(.enabled)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            if model.workspaces.records[profile.id] != nil {
                                Button("Resume…") { model.openSelected(resuming: true) }
                                    .disabled(!model.workspaces.available || model.templateKeys[profile.id] != model.workspaces.records[profile.id]?.templateKey)
                            }
                            Button("Open Saved Layout…") { model.openSelected() }
                            Button("Use at Launch") { model.useAtLaunch() }
                        }
                        HStack {
                            Button("Rename…") { rename = profile.name; renaming = true }
                            Button("Update from Window…") { updating = true }
                            Button("Delete…", role: .destructive) { deleting = true }
                        }.controlSize(.small)
                    } else {
                        Text(model.profiles.isEmpty ? "Save a layout to get started." : "Choose a profile.").foregroundStyle(.secondary)
                        Spacer()
                    }
                }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .disabled(model.busy).toolPageEntrance(model.selected, enabled: settings.motion.allows(.pages), mode: settings.motion.mode)
            }.frame(minHeight: 240)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Save Current Window").interfaceFont(.headline)
                HStack {
                    TextField("Profile name", text: $name).onSubmit { save() }
                    Button("Save Layout", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                HStack { Toggle("Include folder filters", isOn: $includeFilters); Toggle("Use at launch", isOn: $atLaunch); Spacer() }
                Text("Locations stay on this Mac and grant no access. Selection, scroll, history, search results, operations and previews are not saved.")
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.notice.isEmpty { Text(model.notice).interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(18).disabled(model.busy)
        }.frame(minWidth: 800, minHeight: 580)
            .alert("Rename Profile", isPresented: $renaming) {
                TextField("Name", text: $rename)
                Button("Rename") { model.rename(to: rename) }; Button("Cancel", role: .cancel) {}
            }
            .alert("Delete this profile?", isPresented: $deleting) {
                Button("Delete Profile", role: .destructive) { model.removeSelected() }; Button("Cancel", role: .cancel) {}
            } message: { Text("The saved layout and its remembered workspace are removed. Files stay in place; earlier backups may retain locations. If used at launch, the startup choice returns to This Mac.") }
            .alert("Update the selected profile?", isPresented: $updating) {
                Button("Update Layout") { if let id = model.selected { model.saveCurrent(name: "", includeFilters: includeFilters, atLaunch: false, replacing: id) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Replace its saved tabs and panes with the current window. The Include folder filters choice below applies; the name and launch selection stay the same.") }
    }
    private func save() { model.saveCurrent(name: name, includeFilters: includeFilters, atLaunch: atLaunch) }
    private static func summary(_ snapshot: PaneWorkspaceSnapshot) -> String {
        let panes = snapshot.panes.count, tabs = snapshot.panes.reduce(0) { $0 + $1.tabs.tabs.count }
        return "\(panes) \(panes == 1 ? "pane" : "panes") · \(tabs) \(tabs == 1 ? "tab" : "tabs")"
    }
}

@MainActor final class LaunchProfilesWindowController: NSWindowController, NSWindowDelegate {
    let model: LaunchProfilesModel
    var onClose: (() -> Void)?
    init(model: LaunchProfilesModel) {
        self.model = model
        let window = ToolWindowChrome.makeWindow(title: "Launch Profiles", size: .init(width: 900, height: 640),
            minimumSize: .init(width: 800, height: 580),
            content: InterfaceHostingController(rootView: LaunchProfilesView(model: model, settings: model.settings)))
        super.init(window: window); window.delegate = self; model.window = window
        ToolWindowChrome.install(in: window, settings: model.settings)
    }
    required init?(coder: NSCoder) { nil }
    func show(relativeTo owner: NSWindow? = nil) {
        model.start()
        if let window, !window.isVisible { ToolWindowChrome.position(window, relativeTo: owner) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model.close(); onClose?() }
}

@MainActor extension BrowserWorkspaceController {
    func showLaunchProfiles() {
        guard !isClosing else { return }
        if let launchProfilesWindow { launchProfilesWindow.showWindow(nil); launchProfilesWindow.window?.makeKeyAndOrderFront(nil); return }
        let controller = LaunchProfilesWindowController(model: launchProfiles)
        controller.onClose = { [weak self] in self?.launchProfilesWindow = nil }
        launchProfilesWindow = controller; controller.show(relativeTo: view.window)
    }
    func captureLaunchProfile(includeFilters: Bool = false) throws -> PaneWorkspaceSnapshot {
        guard !isClosing, !restoringSession, sessionReady else { throw WorkspaceLaunchProfiles.Failure.stale }
        guard browsers.values.allSatisfy({ $0.tabs.count <= WorkspaceSession.maximumTabs }) else { throw WorkspaceLaunchProfiles.Failure.limitReached }
        let panes = try layout.paneIDs.compactMap { id -> PaneWorkspaceSnapshot.Pane? in
            guard let browser = browsers[id] else { return nil }
            browser.captureArchiveViewState()
            return .init(id: id, tabs: try .captureLaunchTemplate(browser.tabs, activeID: browser.activeID, includeFilters: includeFilters),
                viewMode: (browser.isArchiveLocation ? browser.paneViewMode : browser.effectiveViewMode).rawValue)
        }
        let snapshot = PaneWorkspaceSnapshot(layout: layout, activePane: activePaneID, panes: panes)
        try snapshot.validate(); return snapshot
    }
    func openLaunchProfile(_ profile: WorkspaceLaunchProfile) throws {
        guard profileWorkspaceController?.isFollowing != true else { throw WorkspaceLaunchProfiles.Failure.stale }
        try applyLaunchProfileSnapshot(profile.snapshot)
    }
    func applyLaunchProfileSnapshot(_ snapshot: PaneWorkspaceSnapshot) throws {
        guard canOpenLaunchProfile else { throw WorkspaceLaunchProfiles.Failure.stale }
        let coordinator = primaryBrowser.operationCoordinator, token = UUID()
        guard coordinator.beginPreparation(owner: token) else { throw WorkspaceLaunchProfiles.Failure.stale }
        defer { coordinator.finishPreparation(owner: token) }
        restoringSession = true
        do { try applyRestoredSnapshot(snapshot) }
        catch { restoringSession = false; throw error }
        restoringSession = false
        for browser in browsers.values { startBrowser(browser) }
        recordSession()
    }
}

@MainActor extension BrowserViewController {
    @objc func showLaunchProfiles(_ sender: Any?) { workspace?.showLaunchProfiles() }
}
