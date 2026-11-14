import Darwin
import Foundation

/// Only nondestructive defaults can be applied without a job-specific choice.
public enum TransferConflictDefault: String, CaseIterable, Codable, Sendable, Identifiable {
    case ask, skip, keepBoth
    public var id: Self { self }
    public var title: String {
        switch self { case .ask: "Ask"; case .skip: "Skip"; case .keepBoth: "Keep Both" }
    }
}

public enum TransferConflictKind: Sendable { case regularFiles, folders, other }

extension TransferConflictKind {
    static func observe(source: URL, destination: URL, sourceIdentity: EntrySnapshot, destinationIdentity: EntrySnapshot) throws -> Self {
        if sourceIdentity.type == S_IFREG && destinationIdentity.type == S_IFREG { return .regularFiles }
        if sourceIdentity.isDirectory && destinationIdentity.isDirectory,
           try !(source.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false),
           try !(destination.resourceValues(forKeys: [.isPackageKey]).isPackage ?? false) { return .folders }
        return .other
    }
}

/// A value captured at admission. Changing Settings cannot alter a waiting job.
public struct TransferConflictPreferences: Codable, Equatable, Sendable {
    public var files: TransferConflictDefault
    public var folders: TransferConflictDefault
    public init(files: TransferConflictDefault = .ask, folders: TransferConflictDefault = .ask) {
        self.files = files; self.folders = folders
    }

    public func choices(for conflicts: [TransferConflict]) -> (automatic: [UUID: TransferConflictResolution], asking: [TransferConflict]) {
        var automatic: [UUID: TransferConflictResolution] = [:]
        var asking: [TransferConflict] = []
        for conflict in conflicts {
            let preference: TransferConflictDefault
            switch conflict.kind {
            case .regularFiles: preference = files
            case .folders: preference = folders
            case .other: preference = .ask
            }
            switch preference {
            case .ask: asking.append(conflict)
            case .skip: automatic[conflict.id] = .skip
            case .keepBoth: automatic[conflict.id] = .keepBoth
            }
        }
        return (automatic, asking)
    }
}
