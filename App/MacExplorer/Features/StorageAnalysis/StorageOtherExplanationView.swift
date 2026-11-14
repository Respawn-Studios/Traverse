import StorageAnalysis
import SwiftUI

/// Alternative views of one subtotal, never an additive accounting claim.
/// Fixed-size stored metadata only; drawing and hover perform no source I/O.
struct StorageOtherExplanationView: View {
    let value: StoredAnalysisOtherExplanation
    let metric: AnalysisByteMetric
    private enum Group: String, CaseIterable, Identifiable {
        case layouts = "Layouts", roles = "Roles", names = "Names"
        var id: Self { self }
    }
    @State private var group = Group.layouts
    private struct Row: Identifiable {
        let id: Int
        let title: String
        let value: StoredAnalysisValue
    }
    private func rows(_ values: [StoredAnalysisValue], titles: [String]) -> [Row] {
        zip(values, titles).enumerated().compactMap { index, pair in
            pair.0.counts.regularFiles > 0 ? Row(id: index, title: pair.1, value: pair.0) : nil
        }.sorted {
            let a = $0.value.bytes[metric].knownBytes ?? 0, b = $1.value.bytes[metric].knownBytes ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
    }
    private var selectedGroup: Group { value.applicationLayouts == nil && group == .layouts ? .roles : group }
    private var title: String {
        switch selectedGroup {
        case .layouts: "Application layouts within Other"
        case .roles: "Storage roles within Other"
        case .names: "Filename patterns"
        }
    }
    private var selectedRows: [Row] {
        switch selectedGroup {
        case .layouts: rows(value.applicationLayouts ?? [], titles: AnalysisApplicationLayout.allCases.map(\.title))
        case .roles: rows(value.storageRoles, titles: AnalysisCategory.allCases.map(\.title))
        case .names: rows(value.namePatterns, titles: AnalysisOtherNamePattern.allCases.map(\.title))
        }
    }
    private func fraction(_ row: Row) -> Double {
        guard let all = value.value.bytes[metric].knownBytes, all > 0,
              let bytes = row.value.bytes[metric].knownBytes else { return 0 }
        return min(1, Double(bytes) / Double(all))
    }
    private func files(_ count: UInt64) -> String { "\(count.formatted()) " + (count == 1 ? "file" : "files") }
    private func row(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).lineLimit(2)
                Spacer(minLength: 8)
                Text(storageMetricText(row.value.bytes[metric], files: row.value.counts.regularFiles))
                    .monospacedDigit().multilineTextAlignment(.trailing)
            }.interfaceFont(.caption)
            GeometryReader { geometry in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: geometry.size.width * fraction(row))
                    }
            }.frame(height: 3).accessibilityHidden(true)
            Text(files(row.value.counts.regularFiles))
                .interfaceFont(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.vertical, 4)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Why these files are Other", systemImage: "info.circle").interfaceFont(.callout.weight(.medium))
            Text("Their names do not identify a supported file type. Explore different explanations of these same files.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(storageMetricText(value.value.bytes[metric], files: value.value.counts.regularFiles)
                 + " · " + files(value.value.counts.regularFiles))
                .interfaceFont(.callout.weight(.medium)).monospacedDigit()
            Picker("Explanation", selection: $group) {
                ForEach(Group.allCases.filter { $0 != .layouts || value.applicationLayouts != nil }) { group in
                    Text(group.rawValue).tag(group)
                }
            }.pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("storage-other-explanation-group")
            Text(title).interfaceFont(.caption.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(selectedRows) { row($0) }
                }
            }.frame(height: min(232, CGFloat(max(1, selectedRows.count)) * 61))
                .accessibilityIdentifier("storage-other-explanation-rows")
            Text("These lists are alternative views of the same subtotal. Layouts and suffixes are hints; file contents were not read, and labels do not establish cleanup safety.")
                .interfaceFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .onAppear { if value.applicationLayouts == nil { group = .roles } }
    }
}
