import SwiftUI

/// Filesystem observations are kept separate from namespace/classification
/// sums. No subtraction from a file scan, cleanup estimate or source I/O here.
struct StorageVolumeAccountingView: View {
    let value: PropertyVolumeCapacity
    private func text(_ bytes: UInt64) -> String {
        Int64(exactly: bytes).map(FileSizeText.string) ?? "\(bytes) bytes"
    }
    private var slices: [StorageRingItem] {
        var result: [StorageRingItem] = [
            .init(title: value.capacityMinusFree == nil ? "Unavailable to ordinary apps" : "Capacity minus free",
                  amount: text(value.capacityMinusFree ?? value.capacity - value.available),
                  bytes: value.capacityMinusFree ?? value.capacity - value.available, canOpen: false, color: .blue),
            .init(title: "Available to apps", amount: text(value.available), bytes: value.available, canOpen: false, color: .mint)
        ]
        if let unavailable = value.freeUnavailableToApps, unavailable > 0 {
            result.append(.init(title: "Free unavailable to ordinary apps", amount: text(unavailable), bytes: unavailable, canOpen: false, color: .orange))
        }
        return result
    }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            StorageRingChart(items: slices).frame(width: 96, height: 96)
                .accessibilityLabel("Filesystem capacity; \(value.available) bytes available of \(value.capacity) bytes")
            VStack(alignment: .leading, spacing: 5) {
                Text("Filesystem space").interfaceFont(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow { Text("Capacity"); Text(text(value.capacity)).monospacedDigit() }
                    GridRow {
                        Text("Selected mount · filesystem used")
                        Text(value.used.map(text) ?? "Unavailable").monospacedDigit()
                    }
                    if let free = value.free { GridRow { Text("Free"); Text(text(free)).monospacedDigit() } }
                    GridRow { Text("Available to apps"); Text(text(value.available)).monospacedDigit() }
                    if let unavailable = value.freeUnavailableToApps, unavailable > 0 {
                        GridRow { Text("Free unavailable to ordinary apps"); Text(text(unavailable)).monospacedDigit() }
                    }
                }.interfaceFont(.caption)
                Text("Observed " + value.observedAt.formatted(date: .omitted, time: .shortened) + ". The ring shows capacity, free space and ordinary-app availability. APFS volumes share space, so volume-used can differ from capacity minus free. File totals are separate; they do not predict space freed by deletion.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }.textSelection(.enabled)
    }
}
