import AppKit
import Combine
import ExplorerCore
import LocalStorage
import SwiftUI

@MainActor
final class DriveStatusControl: NSHostingView<InterfaceRoot<DriveStatusView>> {
    private let presentation = DrivePopoverPresentation()
    private var visibility: AnyCancellable?
    init(browser: BrowserViewController) {
        super.init(rootView: InterfaceRoot(content: DriveStatusView(drives: browser.operationCoordinator.drives,
            settings: browser.settings, inspectQueue: { [weak browser] in browser?.showTransferQueue(nil) }, presentation: presentation,
            inspectVolume: { [weak browser] in browser?.openDrives(.health, volume: $0) })))
        InterfacePresentation.markHosting(self)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel("Drives and pending requests")
        visibility = Publishers.CombineLatest3(browser.settings.$showsDriveStatus,
            browser.operationCoordinator.drives.$pending, browser.operationCoordinator.drives.$isPreparing)
            .sink { [weak self] enabled, pending, preparing in
                self?.isHidden = !enabled && pending == nil && !preparing
            }
    }
    @available(*, unavailable) required init(rootView: InterfaceRoot<DriveStatusView>) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show() { presentation.show() }
}

@MainActor
final class DrivePopoverPresentation: ObservableObject {
    @Published var visible = false
    var pinned = false
    var buttonHovered = false
    var cardHovered = false
    private var delay: Task<Void, Never>?
    func show() { delay?.cancel(); pinned = true; visible = true }
    func hover(button: Bool? = nil, card: Bool? = nil) {
        if let button { buttonHovered = button }; if let card { cardHovered = card }
        delay?.cancel()
        delay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            if self.buttonHovered || self.cardHovered { self.visible = true }
            else if !self.pinned { self.visible = false }
        }
    }
}

struct DriveStatusView: View {
    @ObservedObject var drives: ApplicationVolumeCoordinator
    @ObservedObject var settings: BrowserSettings
    var inspectQueue: () -> Void
    @ObservedObject var presentation: DrivePopoverPresentation
    var inspectVolume: ((ManagedVolume) -> Void)?
    var body: some View {
        Button { drives.loadNativeDriveJobIfNeeded(); presentation.show() } label: {
            Label(drives.pending == nil ? "Drives" : drives.pendingActionTitle + " pending", systemImage: "eject")
                .interfaceFont(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .onHover { presentation.hover(button: $0) }
        .popover(isPresented: $presentation.visible, arrowEdge: .bottom) {
            DriveControlsView(drives: drives, settings: settings, inspectQueue: inspectQueue, inspectVolume: inspectVolume)
                .onHover { presentation.hover(card: $0) }
        }
        .onChange(of: presentation.visible) { _, visible in if !visible { presentation.pinned = false } }
        .help(drives.message.isEmpty ? "Mount, unmount or eject drives. Hover for details; click to keep them open." : drives.message)
    }
}

struct DriveControlsView: View {
    @Environment(\.colorScheme) private var inheritedColorScheme
    @ObservedObject var drives: ApplicationVolumeCoordinator
    @ObservedObject var settings: BrowserSettings
    var inspectQueue: () -> Void
    var embedded = false
    var inspectVolume: ((ManagedVolume) -> Void)? = nil
    var mediaIDs: Set<UInt64>? = nil
    private var displayedVolumes: [ManagedVolume] {
        drives.volumes.filter { volume in mediaIDs.map { ids in volume.mediaID.map(ids.contains) == true } ?? true }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drives").interfaceFont(.headline)
            if !drives.protectionIssue.isEmpty {
                Label(drives.protectionIssue, systemImage: "exclamationmark.shield").interfaceFont(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !drives.nativeDriveJobIssue.isEmpty {
                Label(drives.nativeDriveJobIssue, systemImage: "exclamationmark.triangle")
                    .interfaceFont(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !drives.protectionReady || !drives.protectionIssue.isEmpty {
                Button(drives.isEditingProtection ? "Checking Protection…" : "Reload Protection", action: drives.reloadProtection)
                    .disabled(drives.isBusy)
            }
            if !drives.message.isEmpty { Text(drives.message).interfaceFont(.callout).fixedSize(horizontal: false, vertical: true) }
            if drives.isPreparing {
                Button(drives.isStoppingPreparation ? "Stopping Check…" : "Cancel Check", action: drives.cancel)
                    .disabled(!drives.canCancel)
            }
            if let pending = drives.pending {
                Text("\(pending.plan.target.name) · \(phase(pending.intent.phase))").interfaceFont(.subheadline.bold())
                if !drives.jobs.isEmpty {
                    ForEach(drives.jobs.prefix(5)) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).interfaceFont(.caption.bold())
                            Text(job.detail).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if drives.jobs.count > 5 { Text("\(drives.jobs.count - 5) more tasks").interfaceFont(.caption) }
                }
                HStack {
                    if !drives.jobs.isEmpty || pending.intent.phase == .needsAttention { Button("Inspect Queue", action: inspectQueue) }
                    if pending.intent.phase == .needsAttention { Button("Resume " + drives.pendingActionTitle, action: drives.resumeAfterReview) }
                    if drives.canCancel { Button("Cancel " + drives.pendingActionTitle, action: drives.cancel) }
                }
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if displayedVolumes.isEmpty {
                        Text("No available volumes are reported for this device.").foregroundStyle(.secondary)
                    }
                    ForEach(displayedVolumes) { volume in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(volume.name, systemImage: volume.isInternal == true ? "internaldrive" : "externaldrive")
                                .interfaceFont(.subheadline.bold())
                            Text(volume.url?.path ?? "Not mounted").interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if DriveDetailsFeature.ordinaryEnabled {
                                Button("Drive Details…") {
                                    if let inspectVolume { inspectVolume(volume) }
                                    else { ApplicationDriveDetails.shared.show(volume, settings: settings) }
                                }
                                    .interfaceFont(.caption)
                            }
                            if volume.deviceKind == .diskImage { Text("Disk image").interfaceFont(.caption).foregroundStyle(.secondary) }
                            if [.externalDisk, .diskImage].contains(volume.deviceKind) {
                                Picker("Protection", selection: Binding(get: { drives.protectionLevel(for: volume) },
                                    set: { drives.setProtection($0, for: volume) })) {
                                    Text("No extra protection").tag(VolumeProtectionLevel.none)
                                    Text("Prevent Eject").tag(VolumeProtectionLevel.preventEject)
                                    Text("Keep Mounted").tag(VolumeProtectionLevel.keepMounted)
                                }.interfaceFont(.caption).disabled(drives.isBusy || !drives.protectionReady)
                                if volume.canEject && drives.protectionReady && drives.protectionLevel(for: volume) == .none
                                    && !drives.permitsRemoval(volume, action: .eject) {
                                    Label("A sibling volume is protected, or this device's protection scope cannot be verified.", systemImage: "lock.shield")
                                        .interfaceFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                if !drives.savesProtection(for: volume) {
                                    Text("New protection is session-only: no unique volume identifier is available.").interfaceFont(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if volume.canMount || volume.canUnmount || volume.canEject {
                                HStack {
                                    if volume.canMount { action("Mount", volume, .mount) }
                                    if volume.canUnmount && drives.permitsRemoval(volume, action: .unmount) { action("Unmount", volume, .unmount) }
                                    if volume.canEject && drives.permitsRemoval(volume, action: .eject) { action("Eject when ready", volume, .eject) }
                                }.disabled(drives.isBusy)
                            } else { Text("System or unsupported volume").interfaceFont(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: embedded ? 200 : nil, maxHeight: embedded ? .infinity : min(300, max(90, CGFloat(displayedVolumes.count) * 95)))
            if !drives.savedProtections.isEmpty {
                DisclosureGroup("Saved protections (\(drives.savedProtections.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(drives.savedProtections) { rule in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(rule.name).lineLimit(1)
                                        Text(rule.level.title).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Remove Rule") { drives.forgetSavedProtection(rule.id) }
                                        .disabled(drives.isBusy || !drives.protectionReady)
                                }.interfaceFont(.caption)
                            }
                        }
                    }.frame(maxHeight: 140)
                }
            }
            Text("Protection applies only in Traverse. Keep Mounted also prevents Eject. Finder, Disk Utility and physical unplugging are unaffected.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Normal macOS requests only. A busy drive stays connected. Eject requests are not restored after quitting.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: embedded ? nil : 400)
            .environment(\.colorScheme, settings.appearance == .system ? inheritedColorScheme : settings.appearance == .dark ? .dark : .light)
    }
    private func action(_ title: String, _ volume: ManagedVolume, _ action: VolumeAction) -> some View {
        Button(title) { drives.request(volume, action: action, policy: settings.ejectNewWorkPolicy) }
    }
    private func phase(_ value: DeferredEject.Phase) -> String {
        switch value {
        case .waiting: "Waiting for transfers"
        case .needsAttention: "Needs attention"
        case .draining: "Closing background work"
        case .submitted: "Waiting for macOS"
        case .finished: "Finished"
        case .cancelled: "Cancelled"
        }
    }
}

@MainActor
extension BrowserViewController {
    @objc func showDriveControls(_ sender: Any?) { openDrives(.volumes) }

    func driveMenu(for url: URL) -> NSMenu? {
        let drives = operationCoordinator.drives
        guard let volume = drives.volumes.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        if DriveDetailsFeature.ordinaryEnabled || isControlledVerification {
            let details = NSMenuItem(title: "Drive Details…", action: #selector(showContextDriveDetails(_:)), keyEquivalent: "")
            details.target = self; details.representedObject = DriveDetailsMenuTarget(volume: volume); menu.addItem(details)
        }
        for (title, action, available) in [("Unmount", VolumeAction.unmount, volume.canUnmount),
                                          ("Eject when ready", .eject, volume.canEject)] where available && drives.permitsRemoval(volume, action: action) {
            let item = NSMenuItem(title: title, action: #selector(requestContextDriveAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = DriveMenuCommand(volume: volume, action: action)
            item.isEnabled = !drives.isBusy
            menu.addItem(item)
        }
        if [.externalDisk, .diskImage].contains(volume.deviceKind) {
            let protection = NSMenuItem(title: "Drive Protection", action: nil, keyEquivalent: "")
            let choices = NSMenu(); choices.autoenablesItems = false
            for level in VolumeProtectionLevel.allCases {
                let item = NSMenuItem(title: level.title, action: #selector(setContextDriveProtection(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = DriveProtectionMenuCommand(volume: volume, level: level)
                item.state = drives.protectionLevel(for: volume) == level ? .on : .off
                item.isEnabled = !drives.isBusy && drives.protectionReady; choices.addItem(item)
            }
            let detail = NSMenuItem(title: drives.savesProtection(for: volume) ? "Saved on this Mac · Explorer only" : "Until quit · Explorer only", action: nil, keyEquivalent: "")
            detail.isEnabled = false; choices.addItem(.separator()); choices.addItem(detail)
            protection.submenu = choices; menu.addItem(protection)
        }
        if settings.showsSidebarEject && (volume.deviceKind == .externalDisk || volume.deviceKind == .diskImage) {
            let hidden = settings.hiddenEjectSessions.contains(volume.id) || volume.volumeUUID.map { settings.hiddenEjectVolumes.contains($0) } == true
            let item = NSMenuItem(title: hidden ? "Show Sidebar Eject Button" : "Hide Sidebar Eject Button",
                                  action: #selector(toggleSidebarEject(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = DriveMenuCommand(volume: volume, action: .eject)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let inspect = NSMenuItem(title: "Drives…", action: #selector(showDriveControls(_:)), keyEquivalent: "")
        inspect.target = self; menu.addItem(inspect)
        return menu
    }
    @objc private func requestContextDriveAction(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? DriveMenuCommand else { return }
        operationCoordinator.drives.request(request.volume, action: request.action, policy: settings.ejectNewWorkPolicy)
        driveStatus.show()
    }
    @objc private func showContextDriveDetails(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? DriveDetailsMenuTarget else { return }
        if isControlledVerification { ApplicationDriveDetails.shared.show(target.volume, settings: settings, offscreen: true) }
        else { openDrives(.health, volume: target.volume) }
    }
    func isSidebarEjectHidden(for volume: ManagedVolume) -> Bool {
        !operationCoordinator.drives.permitsRemoval(volume, action: .eject) || settings.hiddenEjectSessions.contains(volume.id)
            || volume.volumeUUID.map { settings.hiddenEjectVolumes.contains($0) } == true
    }
    @objc private func setContextDriveProtection(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DriveProtectionMenuCommand else { return }
        operationCoordinator.drives.setProtection(command.level, for: command.volume)
        driveStatus.show()
    }
    @objc private func toggleSidebarEject(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DriveMenuCommand else { return }
        setSidebarEjectHidden(!isSidebarEjectHidden(for: command.volume), for: command.volume)
    }
    func setSidebarEjectHidden(_ hidden: Bool, for volume: ManagedVolume) {
        if let uuid = volume.volumeUUID {
            var hiddenVolumes = settings.hiddenEjectVolumes.filter { $0 != uuid }
            if hidden && hiddenVolumes.count < 256 { hiddenVolumes.append(uuid) }
            else if hidden { settings.hiddenEjectSessions.insert(volume.id) }
            settings.hiddenEjectVolumes = hiddenVolumes
        } else if hidden { settings.hiddenEjectSessions.insert(volume.id) }
        if !hidden { settings.hiddenEjectSessions.remove(volume.id) }
    }
}

/// A menu captures the observation it displayed. It cannot manufacture authority
/// from a path, selection change or BSD device name; prepare revalidates it.
private final class DriveMenuCommand: NSObject {
    let volume: ManagedVolume
    let action: VolumeAction
    init(volume: ManagedVolume, action: VolumeAction) { self.volume = volume; self.action = action }
}

private final class DriveProtectionMenuCommand: NSObject {
    let volume: ManagedVolume
    let level: VolumeProtectionLevel
    init(volume: ManagedVolume, level: VolumeProtectionLevel) { self.volume = volume; self.level = level }
}

private final class DriveDetailsMenuTarget: NSObject {
    let volume: ManagedVolume
    init(volume: ManagedVolume) { self.volume = volume }
}

extension VolumeProtectionLevel {
    var title: String {
        switch self { case .none: "No Extra Protection"; case .preventEject: "Prevent Eject"; case .keepMounted: "Keep Mounted" }
    }
}

/// Explicit clicked targets prevent a sidebar menu from inheriting the current
/// file selection or a subsequently selected sidebar row. Mutation authority is
/// still obtained by the ordinary guarded operation boundary.
@MainActor
private final class LocationMenuCommand: NSObject {
    let location: BrowserLocation
    let pane: UUID
    let tab: UUID
    let visit: UUID
    init(location: BrowserLocation, browser: BrowserViewController) {
        self.location = location; pane = browser.paneID; tab = browser.activeID; visit = browser.sessionID
    }
}

@MainActor
extension BrowserViewController {
    func locationMenu(for location: BrowserLocation) -> NSMenu {
        if let connection = connectedLocationSnapshot.first(where: { $0.location == location }) { return connectedLocationMenu(connection) }
        let menu = NSMenu(); menu.autoenablesItems = false
        let command = LocationMenuCommand(location: location, browser: self)
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = command
            item.isEnabled = enabled && !isBrowserSuspended
            menu.addItem(item)
        }
        add("Open", #selector(openContextLocation(_:)))
        if location.isRemote {
            add("Open in New Tab · use a new connection", #selector(openContextLocationInTab(_:)), enabled: false)
            let explanation = NSMenuItem(title: "Remote metadata only · local file and drive actions are unavailable", action: nil, keyEquivalent: "")
            explanation.isEnabled = false; menu.addItem(explanation); return menu
        }
        add("Open in New Tab", #selector(openContextLocationInTab(_:)), enabled: canOpenBrowserTab)
        if let url = location.directoryURL {
            menu.addItem(.separator())
            add("Copy", #selector(copyContextLocation(_:)))
            add("Copy Path", #selector(copyContextLocationPath(_:)))
            add("Paste Items Here", #selector(pasteContextLocation(_:)), enabled: canAdmitTransfer
                && transferPasteboard.availableType(from: [.fileURL]) != nil)
            add("Reveal in Finder", #selector(revealContextLocation(_:)))
            add(isPinned(url) ? "Unpin Folder" : "Pin Folder", #selector(toggleContextLocationPin(_:)), enabled: pinsController.canEdit)
            add("Properties…", #selector(propertiesContextLocation(_:)))
            if let actions = driveMenu(for: url) {
                menu.addItem(.separator())
                let item = NSMenuItem(title: "Drive", action: nil, keyEquivalent: "")
                item.submenu = actions; menu.addItem(item)
            }
        } else {
            menu.addItem(.separator())
            add("Refresh This Mac", #selector(refreshContextComputer(_:)))
            add("Drives…", #selector(showDriveControls(_:)))
        }
        return menu
    }
    private func contextLocation(_ sender: NSMenuItem) -> BrowserLocation? {
        guard let command = sender.representedObject as? LocationMenuCommand,
              command.pane == paneID, command.tab == activeID, command.visit == sessionID,
              !isBrowserSuspended, isActiveCommandPane, view.window?.attachedSheet == nil else { return nil }
        return command.location
    }
    @objc private func toggleContextLocationPin(_ sender: NSMenuItem) {
        guard let url = contextLocation(sender)?.directoryURL else { return }
        toggleFolderPin(url)
    }
    @objc private func openContextLocation(_ sender: NSMenuItem) {
        guard let location = contextLocation(sender) else { return }
        navigate(to: location)
    }
    @objc private func openContextLocationInTab(_ sender: NSMenuItem) {
        guard let location = contextLocation(sender), canOpenBrowserTab else { return }
        saveViewState()
        let tab = BrowserTab(location: location)
        tabs.append(tab); activeID = tab.id; loadLocation()
    }
    @objc private func copyContextLocation(_ sender: NSMenuItem) {
        guard let url = contextLocation(sender)?.directoryURL else { return }
        clearCutSelection()
        let revision = clipboardRevision
        let publication = clipboardWriter(nil, [url])
        showTransferFeedback(.copy, urls: [url], publication: publication, revision: revision)
    }
    @objc private func copyContextLocationPath(_ sender: NSMenuItem) {
        guard let url = contextLocation(sender)?.directoryURL else { return }
        clearCutSelection(); _ = clipboardWriter(url.path, [])
    }
    @objc private func pasteContextLocation(_ sender: NSMenuItem) {
        guard let url = contextLocation(sender)?.directoryURL else { return }
        pasteFiles(into: url)
    }
    @objc private func revealContextLocation(_ sender: NSMenuItem) {
        guard let url = contextLocation(sender)?.directoryURL else { return }
        #if DEBUG
        if isVerificationSession { return }
        #endif
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func propertiesContextLocation(_ sender: NSMenuItem) {
        guard let url = contextLocation(sender)?.directoryURL else { return }
        propertiesController.show(urls: [url], relativeTo: view.window)
    }
    @objc private func refreshContextComputer(_ sender: NSMenuItem) {
        guard contextLocation(sender) == .computer else { return }
        if location == .computer { refresh(sender) } else { navigate(to: .computer) }
    }
}
