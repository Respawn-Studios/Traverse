import AppKit
import ExplorerCore

/// One transient native menu over the existing local layout library. Loading
/// and fresh selection validation remain owned through actual store completion.
@MainActor final class QuickLaunchProfiles: NSObject {
    private weak var workspace: BrowserWorkspaceController?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var menu: NSMenu?
    private var offered: Set<UUID> = []
    private var chosen: UUID?
    private var manageChosen = false
    private var savedChosen = false
    private var toggleChosen: UUID?
    private(set) var lastNotice = ""
    #if DEBUG
        var presentForVerification: (@MainActor (NSMenu) async -> Void)?
    #endif
    init(workspace: BrowserWorkspaceController) { self.workspace = workspace }

    func open() {
        guard let workspace, workspace.canOpenLaunchProfile else {
            notice("Finish current work and disconnect live connections before opening a layout profile.")
            return
        }
        guard work == nil else {
            notice("The previous profile request is still finishing.")
            return
        }
        let token = UUID()
        generation = token
        lastNotice = ""
        work = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            defer {
                self.work = nil
                self.menu = nil
                self.offered = []
                self.chosen = nil
                self.manageChosen = false
                self.savedChosen = false; self.toggleChosen = nil
            }
            do {
                let before = try workspace.captureSessionSnapshot(syncViewState: false)
                let store = workspace.launchProfileStore
                let saved = try await store.load()
                let memory = try? await workspace.profileWorkspaces.refresh()
                var resumable = Set<UUID>(), changedTemplates = Set<UUID>()
                for profile in saved.library.profiles {
                    if let record = memory?.memory.record(for: profile.id) {
                        if try await workspace.profileWorkspaceStore.key(for: profile) == record.templateKey { resumable.insert(profile.id) }
                        else { changedTemplates.insert(profile.id) }
                    }
                }
                guard self.generation == token, !Task.isCancelled, workspace.canOpenLaunchProfile,
                    workspace.launchProfileStore === store,
                    try workspace.captureSessionSnapshot(syncViewState: false) == before
                else { throw WorkspaceLaunchProfiles.Failure.stale }
                let menu = NSMenu(title: "Switch Layout Profile")
                menu.autoenablesItems = false
                let header = menu.addItem(withTitle: "Resume a workspace or open a layout", action: nil, keyEquivalent: "")
                header.isEnabled = false
                if memory == nil { menu.addItem(withTitle: "Remembered workspaces unavailable · saved layouts only", action: nil, keyEquivalent: "").isEnabled = false }
                for profile in saved.library.profiles {
                    let item = menu.addItem(
                        withTitle: profile.name, action: #selector(self.choose(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = profile.id
                    let snapshot = resumable.contains(profile.id) ? memory?.memory.record(for: profile.id)?.snapshot ?? profile.snapshot : profile.snapshot
                    let tabs = snapshot.panes.reduce(0) { $0 + $1.tabs.tabs.count }
                    item.toolTip =
                        "\(resumable.contains(profile.id) ? "Resume workspace" : "Open saved layout") · \(snapshot.panes.count) panes · \(tabs) tabs · replaces this window’s tabs/panes"
                    item.image = symbol(resumable.contains(profile.id) ? "clock.arrow.circlepath" : "square.stack", "Profile")
                    item.state = workspace.profileWorkspaces.currentProfile?.id == profile.id ? .on : .off
                    if changedTemplates.contains(profile.id) { item.isEnabled = false; item.toolTip = "The saved layout changed. Open its saved layout below, or forget the older remembered workspace." }
                }
                if saved.library.profiles.isEmpty {
                    menu.addItem(withTitle: "No profiles saved", action: nil, keyEquivalent: "").isEnabled = false
                }
                menu.addItem(.separator())
                if !saved.library.profiles.isEmpty {
                    let templates = NSMenu(title: "Open Saved Layout")
                    for profile in saved.library.profiles {
                        let item = templates.addItem(withTitle: profile.name, action: #selector(self.chooseSaved(_:)), keyEquivalent: "")
                        item.target = self; item.representedObject = profile.id
                    }
                    let entry = menu.addItem(withTitle: "Open Saved Layout", action: nil, keyEquivalent: ""); entry.submenu = templates
                    if let id = workspace.profileWorkspaces.currentProfile?.id, saved.library.profiles.contains(where: { $0.id == id }) {
                        let item = menu.addItem(withTitle: "Remember Where I Leave Off", action: #selector(self.toggleRemembering(_:)), keyEquivalent: "")
                        item.target = self; item.representedObject = id; item.isEnabled = memory != nil
                        item.state = memory?.memory.record(for: id) != nil ? .on : .off
                        item.toolTip = "Store this profile’s tabs/panes. Saved servers reopen disconnected. Turning this off forgets its working workspace, keeping the saved layout."
                    }
                    menu.addItem(.separator())
                }
                menu.addItem(
                    withTitle: "Manage Launch Profiles…", action: #selector(self.manage(_:)), keyEquivalent: ""
                ).target = self
                self.menu = menu
                self.offered = Set(saved.library.profiles.map(\.id))
                #if DEBUG
                    if let presentForVerification = self.presentForVerification {
                        await presentForVerification(menu)
                    } else {
                        self.present(menu, in: workspace)
                    }
                #else
                    self.present(menu, in: workspace)
                #endif
                guard self.generation == token, !Task.isCancelled else { return }
                if self.manageChosen {
                    workspace.showLaunchProfiles()
                    return
                }
                guard let chosen = self.chosen else { return }  // Cancel changes nothing.
                let latest = try await store.load()
                guard self.generation == token, !Task.isCancelled, workspace.canOpenLaunchProfile,
                    workspace.launchProfileStore === store, latest.revision == saved.revision,
                    try workspace.captureSessionSnapshot(syncViewState: false) == before,
                    let profile = latest.library.profiles.first(where: { $0.id == chosen })
                else {
                    throw WorkspaceLaunchProfiles.Failure.stale
                }
                if let toggled = self.toggleChosen {
                    let current = try await workspace.profileWorkspaces.refresh()
                    guard current.memory.record(for: toggled)?.consent == memory?.memory.record(for: toggled)?.consent else { throw WorkspaceLaunchProfiles.Failure.stale }
                    try await workspace.profileWorkspaces.setRemembering(current.memory.record(for: toggled) == nil, for: profile)
                } else {
                    try await workspace.profileWorkspaces.open(profile, resuming: !self.savedChosen && resumable.contains(chosen))
                }
                workspace.view.window?.makeKeyAndOrderFront(nil)
            } catch {
                self.notice(ProfileWorkspaceController.message(error))
            }
        }
    }
    @objc private func chooseSaved(_ item: NSMenuItem) {
        guard item.menu?.supermenu === menu, let id = item.representedObject as? UUID, offered.contains(id) else { return }
        chosen = id; savedChosen = true
    }
    @objc private func toggleRemembering(_ item: NSMenuItem) {
        guard menu?.items.contains(where: { $0 === item }) == true,
              let id = item.representedObject as? UUID, offered.contains(id) else { return }
        chosen = id; toggleChosen = id
    }
    private func present(_ menu: NSMenu, in workspace: BrowserWorkspaceController) {
        let strip = workspace.activeBrowser.tabStrip
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: strip.bounds.maxY - 4), in: strip)
    }
    @objc private func choose(_ item: NSMenuItem) {
        guard menu?.items.contains(where: { $0 === item }) == true,
            let id = item.representedObject as? UUID, offered.contains(id)
        else { return }
        chosen = id
    }
    @objc private func manage(_ item: NSMenuItem) {
        guard menu?.items.contains(where: { $0 === item }) == true else { return }
        manageChosen = true
    }
    private func notice(_ message: String) {
        lastNotice = message
        workspace?.activeBrowser.status.stringValue = message
    }
    func close() {
        generation = UUID()
        menu?.cancelTracking()
        work?.cancel()
    }
    func drain() async { while let work { await work.value } }
}

@MainActor extension BrowserWorkspaceController {
    var canOpenLaunchProfile: Bool {
        sessionReady && canChangePaneLayout && !activeBrowser.hasPendingFileOperation
            && browsers.values.allSatisfy {
                $0.smbTabs.isEmpty && $0.sftpTabs.isEmpty && !$0.inlineRename.isEditing && !$0.privateNames.isSaving
            }
    }
    var quickProfiles: QuickLaunchProfiles {
        if let quickProfileSwitcher { return quickProfileSwitcher }
        let value = QuickLaunchProfiles(workspace: self)
        quickProfileSwitcher = value
        return value
    }
}

@MainActor extension BrowserViewController {
    @objc func switchLaunchProfile(_ sender: Any?) { workspace?.quickProfiles.open() }
}
