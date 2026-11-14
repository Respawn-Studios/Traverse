import Foundation
@_spi(ArchiveProduction) import FileOperations

/// A folder in one live ZIP catalog. The visible path cannot be substituted
/// for the sealed archive identity, or used as a local filesystem location.
public struct ZIPMemberAdditionSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var archiveURL: URL { binding.source }
    /// Empty means the archive root; otherwise catalog spelling without /.
    public let virtualFolder: String
    internal let binding: ZIPSourceBinding
    public var description: String { "Selected ZIP destination" }
    public var debugDescription: String { description }
}

/// Replacement applies only to regular-file roots with the exact decoded
/// catalog path (no case/normalization folding). New records use the local
/// files' contents and portable metadata; existing folders never merge.
public enum ZIPMemberAdditionCollisionPolicy: Sendable, Hashable { case refuse, keepBoth, replaceFiles }

public enum ZIPMemberAdditionFailure: Error, Equatable, Sendable {
    case invalidSelection, invalidOutputName, nameConflict, unsupportedArchive, unsupportedSource
    case sourceChanged, contentMismatch, limitReached

    public var userMessage: String {
        switch self {
        case .invalidSelection: "Choose files or folders to add to the open ZIP."
        case .invalidOutputName: "Choose a different name for the new ZIP copy."
        case .nameConflict: "An added name already exists in this ZIP folder or conflicts with another selected item. Rename the local item or choose another ZIP folder. Nothing was replaced."
        case .unsupportedArchive: "This ZIP has a format or metadata this copy cannot preserve. The original is unchanged."
        case .unsupportedSource: "Choose local files and folders without links, cloud-only data or unsupported security metadata."
        case .sourceChanged: "The ZIP or an added item changed while preparing its copy. The originals are unchanged."
        case .contentMismatch: "The ZIP contents did not verify. No copy was published."
        case .limitReached: "This selection exceeds the ZIP copy limits or includes a location Traverse keeps private. Choose fewer items or a different location."
        }
    }

    internal static func project(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? ZIPMemberRenameFailure {
            switch failure {
            case .invalidMember: return Self.invalidSelection
            case .invalidName: return Self.invalidOutputName
            case .ambiguousName: return Self.nameConflict
            case .unsupportedArchive, .unsupportedSecurity: return Self.unsupportedArchive
            case .sourceChanged: return Self.sourceChanged
            case .contentMismatch: return Self.contentMismatch
            case .limitReached: return Self.limitReached
            }
        }
        if let failure = error as? ZIPCreationFailure {
            switch failure {
            case .sourceChanged: return Self.sourceChanged
            case .contentMismatch: return Self.contentMismatch
            case .limitOrPrivacy: return Self.limitReached
            case .unsupportedSource, .resourceFork, .codecUnavailable: return Self.unsupportedSource
            }
        }
        if let failure = error as? ZIPArchiveFailure {
            switch failure {
            case .ambiguousNames: return Self.nameConflict
            case .limited: return Self.limitReached
            default: return Self.unsupportedArchive
            }
        }
        return error
    }
}

public enum ZIPMemberNewEntryFailure: Error, Equatable, Sendable {
    case invalidSelection, invalidName, invalidOutputName, nameConflict, unsupportedArchive, unsupportedSecurity
    case sourceChanged, contentMismatch, limitReached

    public var userMessage: String {
        switch self {
        case .invalidSelection: "Choose a folder in the open ZIP and review it again."
        case .invalidName: "Choose a different file or folder name without folder separators."
        case .invalidOutputName: "Choose a different name for the new ZIP copy."
        case .nameConflict: "A file or folder already uses that name in this ZIP. Nothing was changed."
        case .unsupportedArchive: "This ZIP has a format or metadata Traverse cannot preserve. The original is unchanged."
        case .unsupportedSecurity: "This ZIP has file security metadata Traverse cannot safely carry. The original is unchanged."
        case .sourceChanged: "The ZIP changed. Reopen it and choose the folder again."
        case .contentMismatch: "The ZIP contents did not verify. No new item was published."
        case .limitReached: "This ZIP exceeds the current edit limits. The original is unchanged."
        }
    }

    internal static func project(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? ZIPMemberRenameFailure {
            switch failure {
            case .invalidMember: return Self.invalidSelection
            case .invalidName: return Self.invalidName
            case .ambiguousName: return Self.nameConflict
            case .unsupportedArchive: return Self.unsupportedArchive
            case .unsupportedSecurity: return Self.unsupportedSecurity
            case .sourceChanged: return Self.sourceChanged
            case .contentMismatch: return Self.contentMismatch
            case .limitReached: return Self.limitReached
            }
        }
        if let failure = error as? ZIPMemberAdditionFailure {
            switch failure {
            case .invalidSelection: return Self.invalidSelection
            case .invalidOutputName: return Self.invalidOutputName
            case .nameConflict: return Self.nameConflict
            case .unsupportedArchive, .unsupportedSource: return Self.unsupportedArchive
            case .sourceChanged: return Self.sourceChanged
            case .contentMismatch: return Self.contentMismatch
            case .limitReached: return Self.limitReached
            }
        }
        if let failure = error as? ZIPArchiveFailure {
            switch failure {
            case .ambiguousNames: return Self.nameConflict
            case .limited: return Self.limitReached
            default: return Self.unsupportedArchive
            }
        }
        return error
    }
}

/// Existing folder callers retain their error type while files and folders use
/// the same checked creation path.
public typealias ZIPMemberNewFolderFailure = ZIPMemberNewEntryFailure
public typealias ZIPMemberNewFileFailure = ZIPMemberNewEntryFailure

extension RecoverableFileOperations {
    public func prepareZIPMemberNewFolderOriginal(_ selection: ZIPMemberAdditionSelection,
        name: String, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberNewFolderOriginal(selection, name: name, observing: source, hooks: .init())
    }

    internal func prepareZIPMemberNewFolderOriginal(_ selection: ZIPMemberAdditionSelection,
        name: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberNewEntryOriginal(selection, name: name, kind: .directory,
                                                   observing: source, hooks: hooks)
    }

    public func prepareZIPMemberNewFileOriginal(_ selection: ZIPMemberAdditionSelection,
        name: String, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberNewEntryOriginal(selection, name: name, kind: .file,
                                                   observing: source, hooks: .init())
    }

    private func prepareZIPMemberNewEntryOriginal(_ selection: ZIPMemberAdditionSelection,
        name: String, kind: ZIPNewMemberKind, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveUpdatePlan {
        let modifiedSeconds = Int(Date().timeIntervalSince1970)
        do {
            return try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL],
                original: selection.archiveURL, observing: source) { check in
                try PreparedZIPCopyEdit(.newMember(selection, name, kind, modifiedSeconds), check: check,
                                        hooks: hooks, updateOriginal: true)
            }
        } catch { throw ZIPMemberNewEntryFailure.project(error) }
    }

    public func prepareZIPMemberNewFolderCopy(_ selection: ZIPMemberAdditionSelection,
        name: String, outputName: String, observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberNewFolderCopy(selection, name: name, outputName: outputName,
                                                observing: source, hooks: .init())
    }

    internal func prepareZIPMemberNewFolderCopy(_ selection: ZIPMemberAdditionSelection,
        name: String, outputName: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberNewEntryCopy(selection, name: name, kind: .directory,
            outputName: outputName, observing: source, hooks: hooks)
    }

    public func prepareZIPMemberNewFileCopy(_ selection: ZIPMemberAdditionSelection,
        name: String, outputName: String, observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberNewEntryCopy(selection, name: name, kind: .file,
            outputName: outputName, observing: source, hooks: .init())
    }

    private func prepareZIPMemberNewEntryCopy(_ selection: ZIPMemberAdditionSelection,
        name: String, kind: ZIPNewMemberKind, outputName: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberNewEntryFailure.invalidOutputName
        }
        let modifiedSeconds = Int(Date().timeIntervalSince1970)
        do {
            return try await prepareArchiveCreation(sources: [selection.archiveURL],
                parent: selection.archiveURL.deletingLastPathComponent(), name: outputName,
                observing: source) { check in
                try PreparedZIPCopyEdit(.newMember(selection, name, kind, modifiedSeconds),
                                        check: check, hooks: hooks)
            }
        } catch { throw ZIPMemberNewEntryFailure.project(error) }
    }

    public func prepareZIPMemberAdditionOriginal(_ selection: ZIPMemberAdditionSelection,
        sources: [URL], compression: ZIPCompression = .balanced,
        collisions: ZIPMemberAdditionCollisionPolicy = .refuse,
        observing observation: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberAdditionOriginal(selection, sources: sources,
            compression: compression, collisions: collisions, observing: observation, hooks: .init())
    }

    internal func prepareZIPMemberAdditionOriginal(_ selection: ZIPMemberAdditionSelection,
        sources: [URL], compression: ZIPCompression = .balanced,
        collisions: ZIPMemberAdditionCollisionPolicy = .refuse,
        observing observation: FileOperationSelection, hooks: ZIPCreationHooks) async throws -> ArchiveUpdatePlan {
        guard !sources.isEmpty, sources.count <= 511, !sources.contains(selection.archiveURL),
              Set(sources).count == sources.count else { throw ZIPMemberAdditionFailure.invalidSelection }
        do {
            return try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL] + sources,
                original: selection.archiveURL, observing: observation) { check in
                try PreparedZIPCopyEdit(.add(selection, sources, compression, collisions), check: check,
                                        hooks: hooks, updateOriginal: true)
            }
        } catch { throw ZIPMemberAdditionFailure.project(error) }
    }

    /// Adds roots from any explicitly observed local parents into a fresh,
    /// absent sibling ZIP. Existing records and local originals are retained.
    public func prepareZIPMemberAdditionCopy(_ selection: ZIPMemberAdditionSelection,
        sources: [URL], outputName: String, compression: ZIPCompression = .balanced,
        collisions: ZIPMemberAdditionCollisionPolicy = .refuse,
        observing observation: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberAdditionCopy(selection, sources: sources, outputName: outputName,
            compression: compression, collisions: collisions, observing: observation, hooks: .init())
    }

    internal func prepareZIPMemberAdditionCopy(_ selection: ZIPMemberAdditionSelection,
        sources: [URL], outputName: String, compression: ZIPCompression = .balanced,
        collisions: ZIPMemberAdditionCollisionPolicy = .refuse,
        observing observation: FileOperationSelection, hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberAdditionFailure.invalidOutputName
        }
        guard !sources.isEmpty, sources.count <= 511, !sources.contains(selection.archiveURL),
              Set(sources).count == sources.count else { throw ZIPMemberAdditionFailure.invalidSelection }
        do {
            return try await prepareArchiveCreation(sources: [selection.archiveURL] + sources,
                parent: selection.archiveURL.deletingLastPathComponent(), name: outputName,
                observing: observation) { check in
                try PreparedZIPCopyEdit(.add(selection, sources, compression, collisions), check: check, hooks: hooks)
            }
        } catch { throw ZIPMemberAdditionFailure.project(error) }
    }
}
