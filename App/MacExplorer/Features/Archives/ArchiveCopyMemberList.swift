import SwiftUI

/// Review-only names from a sealed selection. Every chosen path stays
/// available without letting a long selection displace the action footer.
struct ArchiveCopyMemberList: View {
    let paths: [String]
    let folderPaths: [String]
    let coveredSelectionCount: Int
    var title: String? = nil
    var accessibilityID = "zip-copy-removed-members"
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title ?? (paths.count == 1 ? "1 item to leave out of the copy" : "\(paths.count.formatted()) items to leave out of the copy"))
                .interfaceFont(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                        Label(path, systemImage: folderPaths.contains(path) ? "folder" : "doc")
                            .lineLimit(1).truncationMode(.middle)
                            .help(path).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(10)
            }
            .frame(height: min(144, CGFloat(paths.count) * 24 + 20) * scale)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(title ?? "Items omitted from the new ZIP copy; selected folders include their contents")
            .accessibilityIdentifier(accessibilityID)
            if coveredSelectionCount > 0 {
                Text(coveredSelectionCount == 1
                    ? "1 selected item is already included inside these folders."
                    : "\(coveredSelectionCount.formatted()) selected items are already included inside these folders.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
