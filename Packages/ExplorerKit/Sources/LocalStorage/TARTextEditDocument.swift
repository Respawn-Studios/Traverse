import CryptoKit
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Complete bytes from one explicitly chosen member. A catalog URL or display
/// path alone cannot create an edit document or authorize a later replacement.
public struct TARTextEditDocument: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let contents: TextDocumentValue
    public var archiveURL: URL { selection.binding.source }
    public var archivePath: String { selection.record.path }
    public var displayName: String { selection.displayName }
    public var isCompressed: Bool { selection.binding.compressed != nil }
    public var description: String { "<checked TAR text member>" }
    public var debugDescription: String { description }
    internal let selection: TARTextPreviewSelection
    internal let sourceDigest: Data

    internal init(selection: TARTextPreviewSelection, bytes: Data) throws {
        _ = try TARTextPreview.decode(bytes, check: {})
        contents = try TextDocumentValue.original(bytes)
        self.selection = selection
        sourceDigest = Data(SHA256.hash(data: bytes))
    }
}

public enum TARMemberEditFailure: Error, Equatable, Sendable {
    case compressedArchive, unsupportedArchive, invalidName, invalidMemberName, conflict, invalidDestination
    case sourceChanged, contentMismatch, limitReached
    public var userMessage: String {
        switch self {
        case .compressedArchive: "This compressed TAR does not support editing. Its files can still be browsed and extracted."
        case .unsupportedArchive: "This TAR contains metadata or member types that Traverse cannot safely rewrite. The original is unchanged."
        case .invalidName: "Keep this archive’s .tar, .tar.gz or .tgz extension. Existing files will be kept."
        case .invalidMemberName: "Use a single file or folder name without slashes, backslashes or control characters."
        case .conflict: "That name is already in the archive. Nothing was replaced."
        case .invalidDestination: "Choose another folder in this same archive. A folder cannot be moved inside itself."
        case .sourceChanged: "The TAR changed. Reload it, or save the visible text as a separate file."
        case .contentMismatch: "The edited TAR did not verify. It was not published; the original is unchanged."
        case .limitReached: "This TAR edit exceeds the supported size or time limit. The original is unchanged."
        }
    }
    internal static func operationError(_ error: Error) -> Error {
        if let value = error as? TAROutputStream.Failure {
            return value == .limit ? FileOperationFailure.unsupported : FileOperationFailure.copyContentMismatch
        }
        if let value = error as? ZIPCreationFailure {
            return switch value {
            case .sourceChanged: FileOperationFailure.sourceChanged
            case .contentMismatch: FileOperationFailure.copyContentMismatch
            default: FileOperationFailure.unsupported
            }
        }
        guard let value = error as? Self else { return error }
        return switch value {
        case .sourceChanged: FileOperationFailure.sourceChanged
        case .contentMismatch: FileOperationFailure.copyContentMismatch
        case .invalidName, .invalidMemberName, .invalidDestination: FileOperationFailure.invalidRequest
        case .conflict: FileOperationFailure.conflict
        case .compressedArchive, .unsupportedArchive, .limitReached: FileOperationFailure.unsupported
        }
    }
}

extension RecoverableFileOperations {
    public func prepareTARMemberTextReplacementOriginal(_ document: TARTextEditDocument,
        contents: TextDocumentValue, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [document.archiveURL], original: document.archiveURL,
            observing: source, authoredFormat: document.selection.binding.authoredFormat) { check in
            try PreparedTARMemberMutation(document, contents: contents, check: check, updatesOriginal: true)
        }
    }
    public func prepareTARMemberTextReplacementCopy(_ document: TARTextEditDocument,
        contents: TextDocumentValue, outputName: String,
        observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareTARMemberTextReplacementCopy(document, contents: contents,
            outputName: outputName, observing: source, hooks: .init())
    }

    internal func prepareTARMemberTextReplacementCopy(_ document: TARTextEditDocument,
        contents: TextDocumentValue, outputName: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard document.selection.binding.authoredFormat.acceptsFilename(outputName) else {
            throw TARMemberEditFailure.invalidName
        }
        return try await prepareArchiveCreation(sources: [document.archiveURL],
            parent: document.archiveURL.deletingLastPathComponent(), name: outputName,
            observing: source, authoredFormat: document.selection.binding.authoredFormat) { check in
            try PreparedTARMemberMutation(document, contents: contents, check: check, hooks: hooks)
        }
    }
}
