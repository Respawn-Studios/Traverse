import CryptoKit
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// One explicitly read, complete regular ZIP member. The source witness and
/// decoded digest are private; display values never grant file access.
public struct ZIPTextEditDocument: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let contents: TextDocumentValue
    public var archiveURL: URL { selection.binding.source }
    public var archivePath: String { selection.path }
    public var displayName: String { selection.displayName }
    public var description: String { "<checked ZIP text member>" }
    public var debugDescription: String { description }

    internal let selection: ZIPTextPreviewSelection
    internal let sourceDigest: Data

    internal init(selection: ZIPTextPreviewSelection, bytes: Data) throws {
        _ = try ZIPTextPreviewReader.validatedText(bytes)
        contents = try TextDocumentValue.original(bytes)
        self.selection = selection
        sourceDigest = Data(SHA256.hash(data: bytes))
    }
}

extension RecoverableFileOperations {
    public func prepareZIPMemberTextReplacementOriginal(_ document: ZIPTextEditDocument,
        contents: TextDocumentValue, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberTextReplacementOriginal(document, contents: contents,
            observing: source, hooks: .init())
    }

    internal func prepareZIPMemberTextReplacementOriginal(_ document: ZIPTextEditDocument,
        contents: TextDocumentValue, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [document.archiveURL],
            original: document.archiveURL, observing: source) { check in
            try PreparedZIPCopyEdit(.replace(document, contents), check: check,
                hooks: hooks, updateOriginal: true)
        }
    }

    public func prepareZIPMemberTextReplacementCopy(_ document: ZIPTextEditDocument,
        contents: TextDocumentValue, outputName: String,
        observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberTextReplacementCopy(document, contents: contents,
            outputName: outputName, observing: source, hooks: .init())
    }

    internal func prepareZIPMemberTextReplacementCopy(_ document: ZIPTextEditDocument,
        contents: TextDocumentValue, outputName: String,
        observing source: FileOperationSelection, hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRenameFailure.invalidName
        }
        return try await prepareArchiveCreation(sources: [document.archiveURL],
            parent: document.archiveURL.deletingLastPathComponent(), name: outputName,
            observing: source) { check in
            try PreparedZIPCopyEdit(.replace(document, contents), check: check, hooks: hooks)
        }
    }
}
