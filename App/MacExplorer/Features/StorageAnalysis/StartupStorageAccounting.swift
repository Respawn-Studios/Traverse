import ExplorerCore
import LocalStorage
import StorageAnalysis
import SwiftUI

/// A compact interval observation of a qualified startup group. Capacities and
/// free space are container facts; the two used reports are never summed into
/// a physical-disk or reclaimable-space assertion.
struct StartupStorageAccounting: Sendable {
    let id = UUID()
    let capacity: UInt64?
    let available: UInt64?
    let system: NativeVolumeUsedSpace?
    let data: NativeVolumeUsedSpace?
    let dataVolume: PropertyVolumeCapacity?

    enum CapacityBasis: String { case sharedContainer, dataVolume, unavailable }
    var capacityBasis: CapacityBasis {
        if let capacity, let available, capacity > 0, available <= capacity { return .sharedContainer }
        if let dataVolume, dataVolume.capacity > 0, dataVolume.available <= dataVolume.capacity { return .dataVolume }
        return .unavailable
    }
    var chartCapacity: UInt64? {
        switch capacityBasis { case .sharedContainer: capacity; case .dataVolume: dataVolume?.capacity; case .unavailable: nil }
    }
    var chartAvailable: UInt64? {
        switch capacityBasis { case .sharedContainer: available; case .dataVolume: dataVolume?.available; case .unavailable: nil }
    }
    init(capacity: UInt64?, available: UInt64?, system: NativeVolumeUsedSpace?, data: NativeVolumeUsedSpace?,
         dataVolume: PropertyVolumeCapacity? = nil) {
        self.capacity = capacity; self.available = available; self.system = system; self.data = data; self.dataVolume = dataVolume
    }

    static func observe(_ plan: StartupStoragePlan, discovery: StartupVolumeDiscovery,
                        reader: any FilePropertiesReading) async throws -> Self {
        guard plan.isTopologyUnchanged else { throw StartupStorageFailure.changed }
        let roots = [plan.systemRoot, plan.dataRoot]
        let report = try await reader.read(roots)
        // A selected-root report does not establish APFS group membership.
        // Reuse the verified discovery's native topology fence after reading.
        try await discovery.revalidate(plan)
        return project(capacity: plan.containerCapacity, available: plan.containerAvailable,
                       systemRoot: plan.systemRoot, dataRoot: plan.dataRoot, report: report)
    }

    /// Pure projection after the caller's topology fence. A redacted container
    /// must not discard a separately observed, exactly matched Data volume.
    static func project(capacity: UInt64?, available: UInt64?, systemRoot: URL, dataRoot: URL,
                        report: FilePropertiesReport) -> Self {
        func used(_ root: URL) -> NativeVolumeUsedSpace? {
            report.observations.first { $0.url == root }?.volumeCapacity?.reportedUsed
        }
        return .init(capacity: capacity, available: available, system: used(systemRoot), data: used(dataRoot),
                     dataVolume: report.observations.first { $0.url == dataRoot }?.volumeCapacity)
    }
}

struct StartupStorageAccountingView: View {
    let value: StartupStorageAccounting
    private func text(_ bytes: UInt64) -> String {
        Int64(exactly: bytes).map(FileSizeText.string) ?? "\(bytes) bytes"
    }
    private var slices: [StorageRingItem] {
        guard let capacity = value.chartCapacity, let available = value.chartAvailable,
              capacity > 0, available <= capacity else { return [] }
        let complement = capacity - available
        return [.init(title: value.capacityBasis == .dataVolume ? "Data capacity minus available" : "Container capacity minus free",
                      amount: text(complement), bytes: complement, canOpen: false, color: Color(red: 0.64, green: 0.59, blue: 0.85)),
                .init(title: value.capacityBasis == .dataVolume ? "Available to apps on Data" : "Container free",
                      amount: text(available), bytes: available, canOpen: false, color: Color(red: 0.48, green: 0.67, blue: 0.65))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Startup System + Data", systemImage: "internaldrive").interfaceFont(.headline)
            HStack(alignment: .top, spacing: 14) {
                if slices.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "internaldrive").interfaceFont(.title2).foregroundStyle(.secondary)
                        Text("Capacity\nunavailable").interfaceFont(.caption2).multilineTextAlignment(.center)
                    }.frame(width: 88, height: 88)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("startup-capacity-unavailable")
                } else {
                    StorageRingChart(items: slices).frame(width: 88, height: 88)
                        .accessibilityLabel(value.capacityBasis == .dataVolume ? "Data volume capacity and space available to apps" : "Shared startup container capacity and free space")
                        .accessibilityIdentifier("startup-capacity-chart")
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow { Text(value.capacityBasis == .dataVolume ? "Data volume capacity" : "Shared container capacity"); Text(value.chartCapacity.map(text) ?? "Not reported by macOS").monospacedDigit() }
                    GridRow { Text(value.capacityBasis == .dataVolume ? "Available to apps on Data" : "Container free at discovery"); Text(value.chartAvailable.map(text) ?? "Not reported by macOS").monospacedDigit() }
                    GridRow { Text("System · filesystem-used report"); Text(value.system.map { text($0.bytes) } ?? "Unavailable").monospacedDigit() }
                    GridRow { Text("Data · filesystem-used report"); Text(value.data.map { text($0.bytes) } ?? "Unavailable").monospacedDigit() }
                }.interfaceFont(.caption)
            }
            Text(slices.isEmpty
                ? "macOS did not report shared-container capacity and free space. The file analysis below is separate and remains available. System and Data used reports cannot supply the missing capacity; they do not predict space freed by deletion."
                : value.capacityBasis == .dataVolume
                    ? "Shared-container capacity was not reported. This ring uses the separately observed Data volume capacity and space available to apps. APFS volumes can share storage; the complement is not exclusive used space. System and Data used reports remain separate. File totals below do not predict space freed by deletion."
                    : "The ring partitions shared container capacity and free space. System and Data are separate, independently sampled used reports. Other APFS volumes and snapshots can occupy the same container. File totals below describe observed names; they do not predict space freed by deletion.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
        }.textSelection(.enabled)
    }
}

#if DEBUG
@MainActor
extension StoragePrefixVerification {
    static func startupAccountingOnly() async throws -> [String: Any] {
        let gate = FileActivityGate(), discovery = StartupVolumeDiscovery(activityGate: gate)
        let began = ProcessInfo.processInfo.systemUptime
        let plan = try await discovery.discover()
        let report = try await StartupStorageAccounting.observe(plan, discovery: discovery, reader: FilePropertiesReader())
        let capacityIsSane = report.capacity.flatMap { capacity in report.available.map { $0 <= capacity } } ?? true
        try UIVerification.require(plan.isTopologyUnchanged && capacityIsSane
            && gate.activeCount == 0 && ApplicationFileActivity.gate.activeCount == 0,
            "Startup accounting lost its topology, arithmetic or actual-reader lifetime")
        return ["passed": true, "scope": "Two admitted startup mount metadata observations only; no descendant scan or store",
            "container_capacity": report.capacity as Any? ?? NSNull(), "container_available": report.available as Any? ?? NSNull(),
            "system_used": report.system?.bytes as Any? ?? NSNull(), "data_used": report.data?.bytes as Any? ?? NSNull(),
            "both_reports_available": report.system != nil && report.data != nil,
            "file_totals_subtracted": false, "volume_capacities_summed": false,
            "gate_active": gate.activeCount, "seconds": ProcessInfo.processInfo.systemUptime - began]
    }
}
#endif
