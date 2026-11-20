import AppKit
import ExplorerCore
import LocalStorage
import SwiftUI

/// A single navigation shell over the existing drive owners. Selection
/// can monitor the selected drive when Live is enabled; it never starts a
/// benchmark, file scan or device action.
struct DriveWorkspaceView: View {
    private struct ContentID: Hashable {
        let page: DriveWorkspacePage
        let device: UInt64?
    }
    @ObservedObject var model: ApplicationDriveManagement
    @ObservedObject var settings: BrowserSettings
    @ObservedObject private var details: ApplicationDriveDetails
    @ObservedObject private var benchmark: ApplicationDriveBenchmark
    @ObservedObject private var volumeCreation: ApplicationAPFSVolumeCreation
    @ObservedObject private var volumeFormat: ApplicationAPFSVolumeFormat
    init(model: ApplicationDriveManagement, settings: BrowserSettings) {
        self.model = model; self.settings = settings; details = model.health; benchmark = model.benchmark
        volumeCreation = model.volumeCreation; volumeFormat = model.volumeFormat
    }
    private var pages: [DriveWorkspacePage] {
        DriveWorkspacePage.allCases.filter { $0 != .benchmark || DriveBenchmarkFeature.available }
    }
    var body: some View {
        HStack(spacing: 0) {
            ToolNavigationSidebar(scale: settings.interfaceSize.scale, baseWidth: 244) {
                Text("Drives").interfaceFont(.headline)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    NativeToolPageNavigation(selection: Binding(get: { model.page }, set: model.selectPage),
                        scale: settings.interfaceSize.scale,
                        items: pages.map { .init(id: $0, title: $0.navigationTitle, symbolName: $0.symbol) },
                        identifier: "drive-sections", accessibilityLabel: "Drive sections")
                        // Source-list style includes native top/bottom insets.
                        // Keep this short section list fully visible; devices
                        // have their own scrolling space below it.
                        .frame(height: CGFloat(pages.count) * ceil(34 * settings.interfaceSize.scale + 4) + 24)
                    Divider()
                    Text("Devices").interfaceFont(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    NativeToolPageNavigation(selection: Binding(get: { model.selectedRootID ?? 0 }, set: model.selectRoot),
                        scale: settings.interfaceSize.scale,
                        items: model.deviceRoots.map {
                            .init(id: $0.id, title: $0.name,
                                symbolName: $0.volume.deviceKind == .internalDisk ? "internaldrive" : "externaldrive",
                                subtitle: capacity($0.capacity))
                        }, identifier: "drive-devices", accessibilityLabel: "Storage devices",
                        allowsSelection: model.canSelectRoot)
                }
            } footer: {
                if let snapshot = model.snapshot {
                    Text("Updated " + snapshot.capturedAt.formatted(date: .omitted, time: .shortened))
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            NativeToolPageHost(page: ContentID(page: model.page, device: model.selectedRootID),
                content: AnyView(devicePage), motion: settings.motion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 840, minHeight: 580)
        .sheet(isPresented: $model.showsVolumeCreation) {
            APFSVolumeCreationView(model: volumeCreation, settings: settings)
        }
        .sheet(isPresented: $model.showsVolumeFormat) {
            APFSVolumeFormatView(model: volumeFormat, settings: settings)
        }
    }
    private var devicePage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(model.page.title, systemImage: model.page.symbol).interfaceFont(.title2.bold())
                Spacer()
                if (model.page == .overview || model.page == .volumes), model.volumeCreationTarget != nil {
                    Button("Add Volume…", action: model.showVolumeCreation).disabled(benchmark.hasPendingWork || model.isReading)
                }
                if (model.page == .overview || model.page == .volumes), model.volumeFormatTarget != nil {
                    Button("Format Volume…", action: model.showVolumeFormat)
                        .disabled(!NativeAPFSFormatFeature.ordinaryEnabled || benchmark.hasPendingWork || model.isReading)
                        .help(NativeAPFSFormatFeature.ordinaryEnabled
                            ? "Review formatting the selected APFS volume."
                            : "Open Disk Utility to format this volume.")
                }
                if model.isReading { ProgressView().controlSize(.small).accessibilityLabel("Updating drives") }
                Button("Refresh Devices", action: model.refresh).disabled(model.isReading)
            }.padding(20)
            selectedDeviceContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var selectedDeviceContent: some View {
        VStack(spacing: 0) {
            if model.page != .volumes && model.page != .analysis,
               DriveHealthFeature.available, details.window === model.window {
                DriveHealthSummary(model: details, settings: settings, copyReading: model.copyHealthReading)
                    .padding(.horizontal, 20).padding(.bottom, 14)
            }
            Divider()
            pageContent
        }
    }
    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .overview:
            DriveOverviewContent(model: model, settings: settings)
        case .volumes:
            if let drives = model.volumeCoordinator {
                DriveControlsView(drives: drives, settings: settings, inspectQueue: model.inspectQueue, embedded: true,
                    inspectVolume: { model.selectVolume($0); model.selectPage(.health) }, mediaIDs: model.selectedMediaIDs,
                    manualUtilityAllowed: !benchmark.hasPendingWork && !volumeCreation.isWorking
                        && !volumeFormat.isWorking && !model.isReading)
            } else {
                unavailable("Volume controls are unavailable", "Open Drives from an Explorer window to manage its connected volumes.")
            }
        case .health:
            if details.target != nil { DriveDetailsView(model: details, settings: settings, embedded: true) }
            else { unavailable("Choose a device", "Select a device on the left to see its details and available health readings.") }
        case .benchmark:
            if model.window.map({ benchmark.isEmbedded(in: $0) }) == true {
                DriveBenchmarkView(model: benchmark, settings: settings, health: details)
            } else {
                VStack(spacing: 12) {
                    unavailable("Benchmark", "Finish the existing benchmark, or open Drives from an Explorer window.")
                    if benchmark.hasPendingWork { Button("Show Running Benchmark", action: benchmark.reveal) }
                }
            }
        case .analysis:
            analysisPage
        }
    }
    private var analysisPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Find what uses your storage").interfaceFont(.title3.bold())
                Text("See large folders, file types and project data. Choose the location to scan; existing saved results remain available.")
                    .interfaceFont(.body).foregroundStyle(.secondary)
                if let volume = model.selectedMountedVolume {
                    Label(volume.name, systemImage: "externaldrive").interfaceFont(.headline)
                    HStack {
                        Button("Analyze This Volume", action: model.analyzeSelectedVolume).disabled(!model.hasBrowser)
                        Button("Choose Another Location…", action: model.chooseAnalysisFolder).disabled(!model.hasBrowser)
                    }
                } else {
                    Text("Select a mounted volume in Overview, or choose another location.").foregroundStyle(.secondary)
                    Button("Choose a Location…", action: model.chooseAnalysisFolder).disabled(!model.hasBrowser)
                }
                Text("Detailed results open in Storage Analysis, where you can keep reviewing them while using Drives.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                Divider()
                RecentAnalysesSection(inventory: model.recentAnalyses, enabled: model.hasBrowser,
                    onRefresh: model.refreshRecentAnalyses, onOpen: model.openRecentAnalysis)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: model.page.symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func capacity(_ bytes: UInt64?) -> String {
        guard let bytes, bytes <= UInt64(Int64.max) else { return "Capacity unavailable" }
        return FileSizeText.string(Int64(bytes))
    }
}

/// Display-only leaf. A row callback is a selection hint; the application
/// owner decides whether that exact catalog may be opened.
struct RecentAnalysesSection: View {
    let inventory: RecentAnalysisInventory
    let enabled: Bool
    let onRefresh: () -> Void
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Analyses").interfaceFont(.headline)
                Spacer()
                Button("Refresh", action: onRefresh)
                    .accessibilityLabel("Refresh recent analyses")
            }
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var content: some View {
        switch inventory {
        case .loading:
            ProgressView("Checking saved analyses…")
        case .ready(let rows) where rows.isEmpty:
            Text("No recent analyses are saved on this Mac.")
                .foregroundStyle(.secondary)
        case .ready(let rows):
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    RecentAnalysisRowView(row: row, enabled: enabled) { onOpen(row.id) }
                }
            }
            Text("Saved results show an earlier observation. Opening one may ask for folder access.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        case .disabled:
            Text("Keeping recent analyses is off in Settings.").foregroundStyle(.secondary)
        case .busy:
            Text("Saved analyses are busy. Refresh in a moment.").foregroundStyle(.secondary)
        case .unavailable:
            Text("Saved analyses are unavailable. Your files are untouched.").foregroundStyle(.secondary)
        case .needsAttention:
            Text("Saved analyses are in use or need attention. Refresh after closing Storage Analysis; check Settings if this persists.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecentAnalysisRowView: View {
    let row: RecentAnalysis
    let enabled: Bool
    let open: () -> Void
    private var name: String { row.root.lastPathComponent.isEmpty ? row.root.path : row.root.lastPathComponent }
    private var date: String { row.observedThrough.formatted(date: .abbreviated, time: .shortened) }
    private var state: String { row.result == .complete ? "Complete" : "Partial" }
    private var scope: String { row.policy == .standard ? "Standard" : "Application Data" }
    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "chart.pie")
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).interfaceFont(.body.weight(.semibold))
                    Text(row.root.path).interfaceFont(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(date) · \(state) · \(scope)")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .disabled(!enabled)
        .accessibilityLabel("Open saved analysis for \(row.root.path), \(state), \(scope), \(date)")
        .accessibilityHint("Opens this recorded result without starting a scan")
    }
}
