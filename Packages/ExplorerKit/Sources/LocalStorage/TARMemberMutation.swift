import Foundation
@_spi(ArchiveProduction) import FileOperations

/// A source-bound set of member roots. Descendants covered by a selected
/// folder occur once; display paths never become local filesystem locations.
public struct TARMemberSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal let binding: TARSourceBinding
    internal let roots: [TARExtractionSelection.Root]
    public let coveredSelectionCount: Int
    public var archiveURL: URL { binding.source }
    public var archivePaths: [String] { roots.map(\.path) }
    public var folderPaths: [String] { roots.filter { $0.kind == .directory }.map(\.path) }
    public var description: String { "<checked TAR member set>" }
    public var debugDescription: String { description }
}

public struct TARMemberDestination: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal let binding: TARSourceBinding
    public let virtualFolder: String
    public var archiveURL: URL { binding.source }
    public var description: String { "<checked TAR destination>" }
    public var debugDescription: String { description }
}

/// Concrete TAR changes share one checked rewrite. Names and local additions
/// are captured at Review; mutation authority still belongs to FileOperations.
public enum TARMemberMutation: Sendable {
    case rename(TARMemberSelection, to: String)
    case remove(TARMemberSelection)
    case duplicate(TARMemberSelection, into: TARMemberDestination?)
    case move(TARMemberSelection, into: TARMemberDestination)
    case newFile(TARMemberDestination, name: String)
    case newFolder(TARMemberDestination, name: String)
    case add(TARMemberDestination, sources: [URL])
    case group(TARMemberSelection, name: String)
    case replace(TARTextEditDocument, contents: TextDocumentValue)

    internal var binding: TARSourceBinding {
        switch self {
        case .rename(let value, _), .remove(let value), .duplicate(let value, _), .move(let value, _), .group(let value, _): value.binding
        case .newFile(let value, _), .newFolder(let value, _), .add(let value, _): value.binding
        case .replace(let value, _): value.selection.binding
        }
    }
    public var archiveURL: URL { binding.source }
    internal var addedSources: [URL] { if case .add(_, let sources) = self { sources } else { [] } }
}

extension RecoverableFileOperations {
    public func prepareTARMemberMutationOriginal(_ mutation: TARMemberMutation,
        observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [mutation.archiveURL] + mutation.addedSources,
            original: mutation.archiveURL, observing: source, authoredFormat: .strictPortableTAR) { check in
            try PreparedTARMemberMutation(mutation, check: check, updatesOriginal: true)
        }
    }
    public func prepareTARMemberMutationCopy(_ mutation: TARMemberMutation, outputName: String,
        observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "tar" else { throw TARMemberEditFailure.invalidName }
        return try await prepareArchiveCreation(sources: [mutation.archiveURL] + mutation.addedSources,
            parent: mutation.archiveURL.deletingLastPathComponent(), name: outputName,
            observing: source, authoredFormat: .strictPortableTAR) { check in
            try PreparedTARMemberMutation(mutation, check: check)
        }
    }
}
