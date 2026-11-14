import SwiftUI

/// Shared presentation for the two concrete download stores. The store owns
/// discard authority; this row only reflects its read-only metadata summary.
struct RetainedDownloadRow: View {
    let isFolder: Bool
    let observedBytes: UInt64
    let active: Bool
    let publicationProtected: Bool
    let discard: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(isFolder ? "Folder copy" : "File copy") · \(ByteCountFormatter.string(fromByteCount: Int64(observedBytes), countStyle: .file))")
                Text(active ? "Transfer in progress" : publicationProtected ? "Publication needs review" : "Retained on this Mac")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !active && !publicationProtected {
                Button("Discard…", action: discard)
            } else if publicationProtected {
                Image(systemName: "lock.doc")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Protected by a file operation")
                    .help("This download is linked to a file operation. Review Results before changing its retained copies.")
            }
        }
    }
}
