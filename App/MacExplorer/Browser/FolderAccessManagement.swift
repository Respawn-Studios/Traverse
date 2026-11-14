import AppKit
import ExplorerCore
import LocalStorage
import SwiftUI

@MainActor final class FolderAccessManagementModel: ObservableObject {
    @Published var remember = true
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    let access: FolderAccessController
    weak var window: NSWindow?
    private var task: Task<Void, Never>?
    private let changed: @MainActor () async -> Void
    init(access: FolderAccessController, changed: @escaping @MainActor () async -> Void = {}) {
        self.access = access; self.changed = changed
    }
    func refresh() async { _ = await access.resolveRememberedFolders() }
    func choose(replacing location: FolderAccessLocation? = nil, initial: URL? = nil) {
        guard task == nil, let window else { return }
        busy = true; message = ""
        let remember = location != nil || remember
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            guard let choice = await self.access.chooseFolder(in: window, initialDirectory: initial ?? location?.url ?? BrowsingHome.url,
                remember: remember, replacingReference: location?.isRemembered == true ? location?.id : nil, purpose: .setup),
                !Task.isCancelled else { self.message = "No location was added or changed."; return }
            switch choice.remembering {
            case .saved: self.message = "Remembered on this Mac for next time."
            case .notRequested:
                self.message = self.access.locations.contains { $0.id == choice.selection.id && $0.isRemembered }
                    ? "This location is already remembered. Use Forget to remove that saved choice."
                    : "Added for this session."
            case .failed: self.message = "Added for this session, but remembering failed. Choose it again next time."
            }
            await self.changed()
        }
    }
    func forget(_ location: FolderAccessLocation) {
        guard task == nil else { return }
        busy = true; message = ""
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil }
            if let issue = await self.access.forget(id: location.id) {
                self.message = "Forget incomplete. " + issue.message
            } else {
                self.message = location.isRemembered ? "Saved location forgotten. Your files and macOS permissions are unchanged."
                    : "Location removed from this session."
                await self.changed()
            }
        }
    }
    func close() {
        task?.cancel()
        if busy { access.invalidatePendingRequests() }
    }
}

struct FolderAccessLocationsView: View {
    @ObservedObject var access: FolderAccessController
    var actions: ((FolderAccessLocation, Bool) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if access.locations.isEmpty {
                Text("No locations selected here yet. You can finish setup and choose one when needed.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
            }
            ForEach(access.locations) { location in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: location.isRemembered ? "folder.badge.person.crop" : "folder")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location.title).lineLimit(1).truncationMode(.middle)
                        Text(location.status).interfaceFont(.caption).foregroundStyle(.secondary)
                        if let url = location.url {
                            Text(url.path).interfaceFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let actions {
                        Button(location.isRemembered ? "Reselect…" : "Remember…") { actions(location, false) }
                            .accessibilityLabel("\(location.isRemembered ? "Reselect" : "Remember") \(location.title)")
                        Button(location.isRemembered ? "Forget" : "Remove") { actions(location, true) }
                            .accessibilityLabel("\(location.isRemembered ? "Forget saved access to" : "Remove this session’s access to") \(location.title)")
                    }
                }.accessibilityElement(children: .contain)
            }
            if let issue = access.storageIssue {
                Text(issue).interfaceFont(.callout).foregroundStyle(.secondary).accessibilityIdentifier("access-storage-issue")
            }
        }.accessibilityIdentifier("selected-folder-access-list")
    }
}

/// The same explicit per-drive choices in setup and Settings. A selected root
/// is evidence of user selection, not proof every descendant is readable.
struct FolderAccessDriveChoicesView: View {
    @ObservedObject var access: FolderAccessController
    let drives: [VolumeInfo]
    var choose: (URL) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(drives.enumerated()), id: \.offset) { index, drive in
                HStack(alignment: .top) {
                    Image(systemName: drive.kind == .internalDisk ? "internaldrive" : "externaldrive")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(drive.name).lineLimit(1)
                        // A remembered '/' or parent spelling must not claim
                        // that another mounted drive was individually selected.
                        Text(access.selectedRootCovering(drive.url)?.standardizedFileURL == drive.url.standardizedFileURL ? "Drive selected" : "Not selected")
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { choose(drive.url) }
                        .accessibilityLabel("Choose access for \(drive.name)")
                        .accessibilityIdentifier("drive-access-choice-\(index)")
                }
            }
            Text("Choose each drive you want to use. A selected drive includes its folders where macOS allows access; read-only drives cannot be changed. You can add newly connected drives later.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("drive-access-choices")
    }
}

struct FolderAccessManagementView: View {
    @StateObject private var model: FolderAccessManagementModel
    @ObservedObject private var access: FolderAccessController
    private let drives: [VolumeInfo]
    init(access: FolderAccessController, drives: [VolumeInfo] = [], changed: @escaping @MainActor () async -> Void = {}) {
        self.access = access; self.drives = drives
        _model = StateObject(wrappedValue: FolderAccessManagementModel(access: access, changed: changed))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TraverseAccessPolicy.requiresFolderSelection
                ? "Choose a folder or drive to use it and its subfolders. Remember your choice to open it again next time."
                : "Remember locations to open them again next time. Some protected folders may need extra permission from macOS.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            Toggle("Remember my next selection on this Mac", isOn: $model.remember)
                .disabled(!model.access.canRememberFolders)
            Button("Choose a Folder or Drive…") { model.choose() }
                .accessibilityIdentifier("settings-add-folder-access")
            FolderAccessLocationsView(access: model.access) { location, forget in
                if forget { model.forget(location) } else { model.choose(replacing: location) }
            }
            if !drives.isEmpty {
                Divider()
                Text("Drive selections").interfaceFont(.headline)
                FolderAccessDriveChoicesView(access: access, drives: drives) { model.choose(initial: $0) }
            }
            if !model.message.isEmpty { Text(model.message).interfaceFont(.callout).foregroundStyle(.secondary) }
            Text("Reselect lets you choose a saved location again. Forget removes the saved choice without changing your files or stopping work already in progress.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
            .background(FolderAccessWindowReader { model.window = $0 }.frame(width: 0, height: 0))
            .task { await model.refresh() }.onDisappear { model.close() }
    }
}

/// Feature-oriented checklist. Status describes only evidence available through
/// public interfaces; opening settings never turns a row into a granted badge.
struct TraversePermissionChecklist: View {
    let access: FolderAccessController
    var showConnections: (() -> Void)? = nil
    var motion = BrowserMotionPreferences()
    @State private var settingsNotice = ""
    @StateObject private var network = LocalNetworkPermissionRequest()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Full Disk Access", icon: "lock.shield", status: "Optional · managed in System Settings",
                purpose: "For fuller analysis of protected folders. macOS requires you to enable this in System Settings; it has no in-app Allow prompt. Choose your folders or drives above as well. Reopen Traverse if macOS asks.",
                action: "Open Full Disk Access…") {
                    if !access.openFullDiskAccessSettings() {
                        settingsNotice = "Open System Settings → Privacy & Security → Full Disk Access. Use + to add Traverse, then enable it. macOS may ask you to quit and reopen the app."
                    } else {
                        settingsNotice = "Enable Traverse if it’s listed. Otherwise, use Show Traverse in Finder and drag the app into Full Disk Access. Reopen Traverse if macOS asks."
                    }
                }
            HStack(alignment: .center, spacing: 12) {
                TraverseApplicationAccessDrag(motion: motion) {
                    if !access.openFullDiskAccessSettings() {
                        settingsNotice = "Open System Settings → Privacy & Security → Full Disk Access, then drag Traverse into the list."
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Drag Traverse into Full Disk Access").interfaceFont(.callout.weight(.medium))
                    Text("Start dragging the icon to open its system settings. Drop it into the list, then enable it.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Button("Show Traverse in Finder…") { access.revealApplication() }
                        .accessibilityIdentifier("show-traverse-for-permissions")
                }
            }
            if !settingsNotice.isEmpty { Text(settingsNotice).interfaceFont(.caption).foregroundStyle(.secondary) }
            row("Local network", icon: "network", status: "For nearby SMB and SFTP servers",
                purpose: "Ask macOS for access before connecting. A system alert appears only when needed; requesting does not connect to a server or search nearby devices.",
                action: network.requesting ? "Requesting…" : "Request Local Network Access…", perform: { network.request() })
                .disabled(network.requesting)
            if !network.notice.isEmpty { Text(network.notice).interfaceFont(.caption).foregroundStyle(.secondary) }
            HStack {
                if let showConnections { Button("Connect to Server…", action: showConnections) }
                Button("Open Privacy & Security…") {
                    if !access.openPrivacySettings() { settingsNotice = "Open System Settings → Privacy & Security → Local Network." }
                }
            }
            Text("Password saving is optional. macOS asks for Keychain access when a saved password needs it. Filename search and your saved names don’t need a separate permission.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            Text("Choose only the access you need. You can return to these options in Settings.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("traverse-permission-checklist").onDisappear { network.cancel() }
    }
    private func row(_ title: String, icon: String, status: String, purpose: String,
                     action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).interfaceFont(.title3).foregroundStyle(Color(red: 0.55, green: 0.59, blue: 0.76))
                .frame(width: 25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).interfaceFont(.headline)
                Text(status).interfaceFont(.caption).foregroundStyle(.secondary)
                Text(purpose).interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action { Button(action, action: perform) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
    }
}

/// Established DaisyDisk/Commander One assistance: share only the running app's
/// URL, open the system destination, and leave the actual grant to the person.
private struct TraverseApplicationAccessDrag: View {
    let motion: BrowserMotionPreferences
    let openSettings: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable().scaledToFit().frame(width: 48, height: 48)
            .padding(9).background(Color.accentColor.opacity(hovered ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 12))
            .onHover { hovered = $0 }
            .animation(reduceMotion || !motion.allows(.pages) ? nil
                : .easeOut(duration: motion.mode == .reduced ? 0.08 : 0.12), value: hovered)
            .onDrag {
                openSettings()
                return NSItemProvider(object: Bundle.main.bundleURL as NSURL)
            }
            .help("Drag this Traverse icon into the Full Disk Access list in System Settings.")
            .accessibilityLabel("Traverse app; drag to add to Full Disk Access")
            .accessibilityIdentifier("permission-application-drag")
    }
}

private struct FolderAccessWindowReader: NSViewRepresentable {
    let changed: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(changed: changed) }
    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }
    final class Reader: NSView {
        var changed: @MainActor (NSWindow?) -> Void
        init(changed: @escaping @MainActor (NSWindow?) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed(window) }
    }
}
