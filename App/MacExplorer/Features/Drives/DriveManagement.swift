import AppKit
import Combine
import LocalStorage
import SwiftUI

enum DriveManagementFeature { static let ordinaryEnabled = true }

/// One actual snapshot reader and one latest refresh. Closing suppresses
/// publication while retaining the worker until its real native return.
@MainActor final class ApplicationDriveManagement: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ApplicationDriveManagement(reader: VolumeLifecycle.shared)
    @Published private(set) var page = DriveWorkspacePage.overview
    @Published private(set) var snapshot: DriveTopologySnapshot?
    @Published private(set) var selectedRootID: UInt64?
    @Published private(set) var selectedNodeID: UInt64?
    @Published private(set) var isReading = false
    @Published private(set) var notice = ""
    @Published var showsVolumeCreation = false
    private let reader: any DriveTopologyReading
    let health: ApplicationDriveDetails
    let benchmark: ApplicationDriveBenchmark
    let volumeCreation = ApplicationAPFSVolumeCreation()
    private let detailsHandler: @MainActor (ManagedVolume, BrowserSettings) -> Void
    private var controller: NSWindowController?
    private var generation = UUID(), pending = false
    private var work: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []
    private var drives: ApplicationVolumeCoordinator?
    private var protectedLocations: [URL] = []
    private var benchmarkHandler: ((ManagedVolume?) -> Void)?
    private weak var sourceBrowser: BrowserViewController?
    private weak var settings: BrowserSettings?
    private var requestedVolume: ManagedVolume?
    private var drainingEmbeddedBenchmark = false
    private(set) var refreshCount = 0
    private(set) var selectionCount = 0
    var window: NSWindow? { controller?.window }
    var selectedRoot: DriveTopologyNode? { selectedRootID.flatMap { snapshot?.node($0) } }
    var selectedNode: DriveTopologyNode? { selectedNodeID.flatMap { snapshot?.node($0) } }
    var deviceRoots: [DriveTopologyNode] {
        (snapshot?.roots ?? []).sorted { left, right in
            func priority(_ node: DriveTopologyNode) -> Int {
                node.volume.deviceKind == .internalDisk ? 0 : node.volume.deviceKind == .externalDisk ? 1 : 2
            }
            return priority(left) == priority(right)
                ? left.name.localizedStandardCompare(right.name) == .orderedAscending : priority(left) < priority(right)
        }
    }
    init(reader: any DriveTopologyReading,
         health: ApplicationDriveDetails = .shared, benchmark: ApplicationDriveBenchmark = .shared,
         details: @escaping @MainActor (ManagedVolume, BrowserSettings) -> Void = {
             ApplicationDriveDetails.shared.show($0, settings: $1)
         }) { self.reader = reader; self.health = health; self.benchmark = benchmark; detailsHandler = details; super.init() }

    func show(settings: BrowserSettings, drives: ApplicationVolumeCoordinator? = nil,
              protectedLocations: [URL] = [], offscreen: Bool = false,
              benchmark: ((ManagedVolume?) -> Void)? = nil, browser: BrowserViewController? = nil,
              initialPage: DriveWorkspacePage? = nil) {
        drives?.loadNativeDriveJobIfNeeded()
        self.drives = drives; self.protectedLocations = protectedLocations
        self.settings = settings
        benchmarkHandler = benchmark
        if let browser { sourceBrowser = browser }
        if let initialPage { page = initialPage }
        if controller == nil {
            let host = InterfaceHostingController(rootView: DriveWorkspaceView(model: self, settings: settings))
            let window = ToolWindowChrome.makeWindow(title: "Drives", size: .init(width: 1040, height: 760),
                minimumSize: .init(width: 840, height: 580), content: host)
            _ = ToolWindowChrome.install(in: window, settings: settings)
            if offscreen { window.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
            else { ToolWindowChrome.position(window, relativeTo: NSApp.mainWindow) }
            window.delegate = self; controller = NSWindowController(window: window)
            window.makeKeyAndOrderFront(nil); ToolContentMotion.reveal(window.contentView!, effect: .windows)
        } else if let window { ToolWindowCloseMotion.cancel(window); window.makeKeyAndOrderFront(nil) }
        subscriptions.removeAll()
        if let drives {
            // Share the app's broadcast publisher, never consume its single
            // AsyncStream a second time and steal discovery events.
            subscriptions.append(drives.$volumes.dropFirst().removeDuplicates().sink { [weak self] _ in self?.refresh() })
            subscriptions.append(drives.$protectionRevision.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        refresh(); prepareSelectedPage()
    }
    func refresh() {
        generation = UUID(); pending = true; notice = ""; refreshCount += 1; startNext()
    }
    private func startNext() {
        guard work == nil, pending, controller != nil else { return }
        pending = false; isReading = true; let ticket = generation
        work = Task { [self] in
            defer { isReading = false; work = nil; startNext() }
            do {
                let result = try await reader.readTopology()
                guard !Task.isCancelled, generation == ticket, controller != nil else { return }
                snapshot = result
                if !result.roots.contains(where: { $0.id == selectedRootID }) {
                    // Losing the test device must not silently put another
                    // drive's live health beside the still-draining workload.
                    let runningHere = window.map { benchmark.isEmbedded(in: $0) && benchmark.hasPendingWork } == true
                    selectedRootID = runningHere ? nil : deviceRoots.first?.id
                    selectedNodeID = selectedRootID
                }
                if selectedNodeID.flatMap({ result.node($0) }) == nil {
                    let runningHere = window.map { benchmark.isEmbedded(in: $0) && benchmark.hasPendingWork } == true
                    if runningHere {
                        selectedRootID = nil; selectedNodeID = nil
                        notice = "The selected volume is no longer available. The benchmark keeps its original folder until its work and cleanup finish."
                    } else { selectedNodeID = selectedRootID }
                }
                if let requestedVolume { selectVolume(requestedVolume) }
                prepareSelectedPage()
            } catch {
                guard !Task.isCancelled, generation == ticket, controller != nil else { return }
                notice = "The drive observations changed or are unavailable. Refresh to read their current state."
            }
        }
    }
    func selectRoot(_ id: UInt64) {
        guard snapshot?.roots.contains(where: { $0.id == id }) == true else { return }
        guard permitsSelectionChange else { return }
        selectedRootID = id; selectedNodeID = id; selectionCount += 1; prepareSelectedPage()
    }
    func selectVolume(_ volume: ManagedVolume) {
        guard permitsSelectionChange else { return }
        requestedVolume = volume
        guard let snapshot, let node = snapshot.nodes.first(where: {
            $0.volume.id == volume.id || volume.mediaID != nil && $0.volume.mediaID == volume.mediaID
        }),
              let root = snapshot.path(to: node.id).first else { return }
        requestedVolume = nil
        selectedRootID = root.id; selectedNodeID = node.id; selectionCount += 1; prepareSelectedPage()
    }
    func selectNode(_ id: UInt64) {
        guard let snapshot, let root = selectedRootID,
              snapshot.path(to: id).contains(where: { $0.id == root }) else { return }
        guard permitsSelectionChange else { return }
        selectedNodeID = id; selectionCount += 1; prepareSelectedPage()
    }
    private var permitsSelectionChange: Bool {
        guard !volumeCreation.isWorking else { notice = "Finish the volume check or creation before switching drives."; return false }
        guard let window, benchmark.isEmbedded(in: window),
              benchmark.hasPendingWork else { return true }
        notice = "Stop the current benchmark before switching drives."
        return false
    }
    var volumeCoordinator: ApplicationVolumeCoordinator? { drives }
    var selectedMediaIDs: Set<UInt64> {
        guard let snapshot, let root = selectedRootID else { return [] }
        return Set(snapshot.nodes.filter { snapshot.path(to: $0.id).contains { $0.id == root } }.map(\.id))
    }
    var selectedMountedVolume: ManagedVolume? {
        guard let snapshot, let selected = selectedNode ?? selectedRoot else { return nil }
        if selected.volume.url != nil { return selected.volume }
        let children = snapshot.nodes.filter { $0.volume.url != nil && snapshot.path(to: $0.id).contains { $0.id == selected.id } }
        return (children.first { $0.volume.url?.path == "/" }
            ?? children.first { $0.volume.url?.path.hasPrefix("/Volumes/") == true }
            ?? children.first)?.volume
    }
    var hasBrowser: Bool { sourceBrowser != nil }
    var operationCoordinator: ApplicationOperationCoordinator? { sourceBrowser?.operationCoordinator }
    func showVolumeCreation() {
        guard let target = volumeCreationTarget, !benchmark.hasPendingWork, !isReading, !volumeCreation.isWorking else { return }
        volumeCreation.configure(target: target, operations: operationCoordinator, changed: { [weak self] in self?.refresh() })
        showsVolumeCreation = true
    }
    /// A container/device selection can choose its sole observed APFS
    /// container. Multiple containers require an explicit volume selection.
    var volumeCreationTarget: ManagedVolume? {
        guard let snapshot, let selected = selectedNode else { return nil }
        if selected.kind == .volume { return selected.fields.fileSystem?.lowercased() == "apfs" ? selected.volume : nil }
        let candidates = snapshot.nodes.filter {
            $0.kind == .volume && $0.fields.fileSystem?.lowercased() == "apfs" && $0.volume.url != nil
                && snapshot.path(to: $0.id).contains(where: { $0.id == selected.id })
        }
        guard Set(candidates.compactMap(\.parentID)).count == 1 else { return nil }
        return candidates.first?.volume
    }
    func selectPage(_ selected: DriveWorkspacePage) { page = selected; prepareSelectedPage() }
    func prepareSelectedPage() {
        guard let window else { return }
        if let selected = selectedMountedVolume ?? selectedNode?.volume {
            if health.target != selected || health.window !== window {
                health.attach(selected, to: window, settings: settings)
            }
        } else { health.detach(from: window) }
        switch page {
        case .health:
            break
        case .benchmark:
            if let sourceBrowser { _ = benchmark.attach(from: sourceBrowser, to: window, target: selectedMountedVolume, health: health) }
        default: break
        }
    }
    func inspectQueue() { sourceBrowser?.showTransferQueue(nil) }
    func analyzeSelectedVolume() {
        guard let browser = sourceBrowser, let root = selectedMountedVolume?.url else { return }
        ApplicationStorageAnalysis.shared.show(from: browser, root: root)
    }
    func chooseAnalysisFolder() { if let sourceBrowser { ApplicationStorageAnalysis.shared.chooseFromDriveWorkspace(from: sourceBrowser) } }
    func showDetails(settings: BrowserSettings) {
        if sourceBrowser != nil { selectPage(.health) }
        else if let node = selectedNode { detailsHandler(node.volume, settings) }
    }
    var canBenchmarkSelection: Bool {
        // In the shared workspace this command only opens its existing page.
        // A device root has no mount path; that page uses the observed mounted
        // child and still requires a freshly verified folder before any work.
        if sourceBrowser != nil {
            return DriveBenchmarkFeature.available && selectedMountedVolume != nil
        }
        return benchmarkHandler != nil && selectedNode?.volume.url != nil
            && selectedNode?.volume.fileSystemID != nil && selectedNode?.volume.group != nil
    }
    func benchmarkSelection() {
        if sourceBrowser != nil { selectPage(.benchmark) }
        else if let node = selectedNode, node.volume.url != nil { benchmarkHandler?(node.volume) }
    }
    func protectionLabel(for node: DriveTopologyNode) -> String? {
        guard let snapshot else { return nil }
        if snapshot.containsSystemStorage(node.id) { return "System storage" }
        let members = snapshot.nodes.filter { snapshot.path(to: $0.id).contains { $0.id == node.id } }
        if members.contains(where: { member in
            guard let root = member.volume.url else { return false }
            return protectedLocations.contains { location in
                let base = root.pathComponents, path = location.pathComponents
                return path.starts(with: base)
            }
        }) { return "Contains Traverse data" }
        guard let drives else { return nil }
        guard drives.protectionReady else { return "Protection needs review" }
        let levels = members.map { drives.protectionLevel(for: $0.volume) }
        if levels.contains(.keepMounted) { return "Keep Mounted" }
        if levels.contains(.preventEject) { return "Prevent Eject" }
        return nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if benchmark.isEmbedded(in: sender) {
            guard benchmark.windowShouldClose(sender) else { return false }
        }
        return ToolWindowCloseMotion.shouldClose(sender)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === controller?.window else { return }
        health.detach(from: window)
        showsVolumeCreation = false
        volumeCreation.dismiss()
        drainingEmbeddedBenchmark = benchmark.isEmbedded(in: window) && benchmark.hasPendingWork
        benchmark.detach(from: window)
        generation = UUID(); pending = false; subscriptions.removeAll(); drives = nil; protectedLocations = []; sourceBrowser = nil
        settings = nil
        snapshot = nil; selectedRootID = nil; selectedNodeID = nil; requestedVolume = nil; work?.cancel(); benchmarkHandler = nil; controller = nil
    }
    func drain() async {
        while let work { await work.value }
        if drainingEmbeddedBenchmark { await benchmark.drain(); drainingEmbeddedBenchmark = false }
        await volumeCreation.drain()
    }
    func closeAndDrain() async { window?.close(); await drain() }
}

struct DriveOverviewContent: View {
    // Values belong to this rendered page. The shared native page host can
    // fade its outgoing tree without that tree switching to the new device.
    // Commands still go to the live owner and retain its current admission.
    private let model: ApplicationDriveManagement
    private let snapshot: DriveTopologySnapshot?
    private let root: DriveTopologyNode?
    private let selected: DriveTopologyNode?
    private let notice: String
    private let isReading: Bool
    private let protectionLabel: String?
    private let canBenchmark: Bool
    @ObservedObject var settings: BrowserSettings
    init(model: ApplicationDriveManagement, settings: BrowserSettings) {
        self.model = model; self.settings = settings
        snapshot = model.snapshot; root = model.selectedRoot; selected = model.selectedNode
        notice = model.notice; isReading = model.isReading
        protectionLabel = model.selectedRoot.flatMap { model.protectionLabel(for: $0) }
        canBenchmark = model.canBenchmarkSelection
    }
    var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            if !notice.isEmpty { Text(notice).interfaceFont(.callout).foregroundStyle(.secondary) }
            if let snapshot, let root {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(root)).interfaceFont(.system(size: 34)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(root.name).interfaceFont(.title2.bold()).textSelection(.enabled)
                        Text(bytes(root.capacity)).interfaceFont(.title3.monospacedDigit())
                        if let label = protectionLabel {
                            Label(label, systemImage: "lock.shield").interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                GroupBox("Storage relationships") {
                    DriveRelationshipBranch(node: root, snapshot: snapshot, selected: selected?.id,
                        motionEnabled: settings.motion.allows(.pages), motionMode: settings.motion.mode, select: model.selectNode).id(root.id).padding(10)
                }
                Text("This map shows observed relationships, not free-space measurements. APFS volumes share their container’s capacity.")
                    .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let selected {
                    HStack(spacing: 4) {
                        ForEach(snapshot.path(to: selected.id)) { ancestor in
                            if ancestor.id != root.id { Image(systemName: "chevron.right").interfaceFont(.caption2).foregroundStyle(.tertiary) }
                            Button(ancestor.name) { model.selectNode(ancestor.id) }.buttonStyle(.link).lineLimit(1)
                        }
                    }
                    GroupBox("Selected storage") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            fact("Name", selected.name)
                            fact("Type", kind(selected))
                            fact("Device identifier", selected.deviceName)
                            fact("Reported media size", bytes(selected.capacity))
                            fact("Filesystem", selected.fields.fileSystem?.uppercased())
                            fact("Mount point", selected.volume.url?.path ?? "Not mounted")
                            fact("Connection", selected.fields.transport)
                            fact("Model", selected.fields.model)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    HStack {
                        Button("Drive Details…") { model.showDetails(settings: settings) }
                        if DriveBenchmarkFeature.available {
                            Button("Benchmark…", action: model.benchmarkSelection).disabled(!canBenchmark)
                        }
                        Spacer()
                    }
                }
                if snapshot.hasUnresolvedRelationships {
                    Label("Some storage relationships are unavailable in this observation.", systemImage: "info.circle")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
            } else if !isReading {
                ContentUnavailableView("No drive observations", systemImage: "externaldrive",
                    description: Text("Refresh to read the devices currently reported by macOS."))
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func fact(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).frame(width: 138, alignment: .leading)
            Text(value ?? "Unavailable").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.interfaceFont(.callout)
    }
}

private struct DriveRelationshipBranch: View {
    let node: DriveTopologyNode
    let snapshot: DriveTopologySnapshot
    let selected: UInt64?
    let motionEnabled: Bool
    let motionMode: BrowserMotionMode
    let select: (UInt64) -> Void
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func toggle() {
        withAnimation(reduceMotion || !motionEnabled ? nil : .easeInOut(duration: 0.22 * motionMode.durationScale)) { expanded.toggle() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                let children = snapshot.children(of: node.id)
                if !children.isEmpty {
                    Button {
                        toggle()
                    } label: {
                        Image(systemName: "chevron.right").interfaceFont(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 32, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse \(node.name)" : "Expand \(node.name)")
                        .help(expanded ? "Collapse \(node.name)" : "Expand \(node.name)")
                } else { Color.clear.frame(width: 32, height: 36).accessibilityHidden(true) }
                Button {
                    select(node.id)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: icon(node)).foregroundStyle(nodeTint(node))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.name).interfaceFont(.callout.weight(.medium)).lineLimit(1)
                            Text(node.sharesContainerSpace ? "APFS · shared container capacity" : kind(node))
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if !node.sharesContainerSpace { Text(bytes(node.capacity)).interfaceFont(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == node.id ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected == node.id ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1))
                }.buttonStyle(.plain)
                    .accessibilityHint("Show drive details")
            }
            if expanded {
                ForEach(snapshot.children(of: node.id)) { child in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 1).padding(.leading, 12)
                        DriveRelationshipBranch(node: child, snapshot: snapshot, selected: selected,
                            motionEnabled: motionEnabled, motionMode: motionMode, select: select)
                    }.padding(.leading, 8)
                        .transition(.opacity)
                }
            }
        }
    }
}

private func bytes(_ value: UInt64?) -> String {
    guard let value, value <= UInt64(Int64.max) else { return "Capacity unavailable" }
    return FileSizeText.string(Int64(value))
}
private func kind(_ node: DriveTopologyNode) -> String {
    switch node.kind {
    case .device: node.volume.deviceKind == .diskImage ? "Disk image" : "Storage device"
    case .partition: "Partition"
    case .apfsContainer: "APFS container"
    case .volume: "Volume"
    case .unresolved: "Relationship unavailable"
    }
}
private func icon(_ node: DriveTopologyNode) -> String {
    switch node.kind {
    case .device: node.volume.deviceKind == .internalDisk ? "internaldrive" : "externaldrive"
    case .partition: "rectangle.split.2x1"
    case .apfsContainer: "square.stack.3d.up"
    case .volume: "externaldrive"
    case .unresolved: "externaldrive.badge.questionmark"
    }
}
private func nodeTint(_ node: DriveTopologyNode) -> Color {
    switch node.kind {
    case .device: .blue
    case .partition: .orange
    case .apfsContainer: .purple
    case .volume: .teal
    case .unresolved: .secondary
    }
}

extension BrowserViewController {
    @objc func showDriveManagement(_ sender: Any?) {
        openDrives(.overview)
    }
    func openDrives(_ page: DriveWorkspacePage, volume: ManagedVolume? = nil) {
        guard DriveManagementFeature.ordinaryEnabled else { return }
        ApplicationDriveManagement.shared.show(settings: settings, drives: operationCoordinator.drives,
            protectedLocations: operationCoordinator.protectedStorageLocations, benchmark: { [weak self] volume in
                guard let self, !self.isBrowserSuspended else { return }
                ApplicationDriveBenchmark.shared.show(from: self, target: volume)
            }, browser: self, initialPage: page)
        if let volume { ApplicationDriveManagement.shared.selectVolume(volume) }
    }
}
