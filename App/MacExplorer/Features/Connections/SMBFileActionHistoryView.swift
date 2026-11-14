import SwiftUI
@_spi(Qualification) import LocalStorage

struct SMBFileActionHistoryView: View {
    @ObservedObject var model: SMBConnectionStorageModel
    @State private var removing: UUID?
    @State private var recovering = false
    var body: some View {
        GroupBox("File actions") {
            VStack(alignment: .leading, spacing: 12) {
                if model.actionRecoveryRequired {
                    Button("Review last saved outcomes…") { recovering = true }
                } else if model.actionHistory?.records.isEmpty != false {
                    Text("No file-action records.").interfaceFont(.callout).foregroundStyle(.secondary)
                }
                ForEach((model.actionHistory?.records ?? []).reversed(), id: \.id) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: record.outcome == .confirmed ? "checkmark.circle" : record.outcome == .needsReview ? "exclamationmark.triangle" : "doc")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.source.displayName + (record.target.map { " → " + $0.displayName } ?? ""))
                                .textSelection(.enabled)
                            Text(record.server.host + " · " + outcome(record)).foregroundStyle(.secondary)
                            Text(([record.server.share.displayName] + record.directory.map(\.displayName)).joined(separator: " / "))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                            if let destination = record.destinationDirectory {
                                Text("To: " + ([record.server.share.displayName] + destination.map(\.displayName)).joined(separator: " / "))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if let temporaryCopyName = record.temporaryCopyName,
                               record.outcome == .finalCollision || record.outcome == .needsReview || record.outcome == .mutationRequested {
                                Text("Temporary copy, if present: " + temporaryCopyName)
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(record.createdAt, format: .dateTime.day().month().year().hour().minute().second())
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !record.active { Button("Remove Record…") { removing = record.id } }
                    }.interfaceFont(.callout)
                }
                Text("Recorded outcomes describe that action. Refresh the connection to inspect current server files. Removing a record never retries or reverses an action.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .confirmationDialog("Remove this local action record?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Local Record", role: .destructive) { if let id = removing { model.forgetAction(id) }; removing = nil }
        } message: { Text("The server is not changed. If this action needs review, removing its record also removes the details you may need to investigate it.") }
        .confirmationDialog("Review the last saved file-action outcomes?", isPresented: $recovering) {
            Button("Keep Last Saved Outcomes") { model.recoverActionHistory() }
        } message: { Text("Only the unfinished local record update is discarded. No server action is retried.") }
    }
    private func outcome(_ record: SMBActionRecordSummary) -> String {
        if record.active { return "Action in progress" }
        switch record.outcome {
        case .confirmed:
            switch record.operation {
            case .rename, .renameDirectory: return "Renamed"
            case .move, .moveDirectory: return "Moved"
            case .copy: return "Copied · original kept"
            case .delete: return "Deleted permanently"
            case .deleteEmptyDirectory: return "Empty folder deleted permanently"
            }
        case .collision: return "Name already exists · existing items kept"
        case .stageCollision: return "Temporary name already exists · existing items kept"
        case .finalCollision: return "Destination name became occupied · temporary copy retained"
        case .notEmpty: return "Folder is not empty · nothing deleted"
        case .notStarted, .prepared: return "Not started"
        case .mutationRequested, .needsReview: return "Outcome needs review"
        }
    }
}
