import FileOperations
import Foundation

/// No catalog I/O, volume discovery or implicit enablement. A portable checkout
/// stays closed unless this build has the reviewed local qualification set.
enum DevelopmentCopyPreviewQualification {
    static var scope: QualifiedCopyPreviewScope? {
        guard Bundle.main.object(forInfoDictionaryKey: "MacExplorerCopyPreviewQualified") as? String == "YES" else { return nil }
        func identifier(_ key: String) -> UUID? {
            guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !text.contains("$(") else { return nil }
            return UUID(uuidString: text)
        }
        guard let internalVolume = identifier("MacExplorerCopyPreviewInternalVolume"),
              let workspaceVolume = identifier("MacExplorerCopyPreviewWorkspaceVolume"),
              let historyVolume = identifier("MacExplorerCopyPreviewHistoryVolume") else { return nil }
        return QualifiedCopyPreviewScope(volumes: [internalVolume, workspaceVolume], historyVolume: historyVolume)
    }
}
