import Foundation

public struct SelectionGroupHistoryUpgradeResult: Sendable {
    public let status: FileOperationStatus
    public let backupLocation: URL?
    public let catalogVersion: Int?
}

extension RecoverableFileOperations {
    /// The composition protects the application state directory. This public
    /// action never accepts a user-selected backup location or creates on inspect.
    public func upgradeSelectionGroupHistory() async -> SelectionGroupHistoryUpgradeResult {
        let backup = directory.deletingLastPathComponent().appendingPathComponent("operation-history-backup-" + UUID().uuidString)
        do {
            try await worker { cancellation in
                let parent = try DirectoryAnchor(self.directory.deletingLastPathComponent(), resolve: false)
                var protected = false
                for root in self.protectedLocations {
                    let policy = try HistoryProtection(root, cancellation: cancellation)
                    if try policy.protects(parent: parent, name: self.directory.lastPathComponent),
                       try policy.protects(parent: parent, name: backup.lastPathComponent) { protected = true; break }
                }
                guard protected else { throw FileOperationFailure.protectedLocation }
            }
            try await upgradeSelectionGroupHistory(backup: backup)
            return SelectionGroupHistoryUpgradeResult(status: .succeeded, backupLocation: backup, catalogVersion: 7)
        } catch {
            let version = try? await worker(ignoringCancellation: true) { cancellation -> Int? in
                let result = try OperationHistoryInspector.inspect(self.directory, cancellation: cancellation)
                if case .available(let version) = result.readiness { return version }; return nil
            }
            // A failed action may have produced partial custody or committed an
            // upgrade whose acknowledgement was lost. Never auto-restore either.
            let retained = try? await worker(ignoringCancellation: true) { _ -> URL? in
                let parent = try DirectoryAnchor(backup.deletingLastPathComponent(), resolve: false)
                return try NativeRenameEntry.optional(parent: parent, name: backup.lastPathComponent) == nil ? nil : backup
            }
            return SelectionGroupHistoryUpgradeResult(status: operationStatus(error), backupLocation: retained ?? nil, catalogVersion: version ?? nil)
        }
    }
}
