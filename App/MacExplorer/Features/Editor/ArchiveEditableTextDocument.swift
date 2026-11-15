import Foundation
import FileOperations
import LocalStorage

/// The two concrete archive editors share one native document lifecycle. Each
/// format still owns its reader, sealed member witness and production checks.
enum ArchiveEditableTextDocument: Sendable {
    case zip(ZIPTextEditDocument, ZIPArchiveReader)
    case tar(TARTextEditDocument, TARArchiveReader)

    var contents: TextDocumentValue { switch self { case .zip(let d, _): d.contents; case .tar(let d, _): d.contents } }
    var archiveURL: URL { switch self { case .zip(let d, _): d.archiveURL; case .tar(let d, _): d.archiveURL } }
    var archivePath: String { switch self { case .zip(let d, _): d.archivePath; case .tar(let d, _): d.archivePath } }
    var displayName: String { switch self { case .zip(let d, _): d.displayName; case .tar(let d, _): d.displayName } }
    var formatName: String { switch self { case .zip: "ZIP"; case .tar(let document, _): document.isCompressed ? "TAR.gz" : "TAR" } }

    func prepareSave(contents: TextDocumentValue, copyName: String?, observing source: FileOperationSelection,
        using engine: RecoverableFileOperations) async throws -> ArchiveWritePlan {
        switch self {
        case .zip(let document, _):
            if let copyName {
                return .create(try await engine.prepareZIPMemberTextReplacementCopy(document,
                    contents: contents, outputName: copyName, observing: source))
            }
            return .update(try await engine.prepareZIPMemberTextReplacementOriginal(document,
                contents: contents, observing: source))
        case .tar(let document, _):
            if let copyName {
                return .create(try await engine.prepareTARMemberTextReplacementCopy(document,
                    contents: contents, outputName: copyName, observing: source))
            }
            return .update(try await engine.prepareTARMemberTextReplacementOriginal(document,
                contents: contents, observing: source))
        }
    }
    func reopen(at destination: URL? = nil, expecting contents: TextDocumentValue? = nil,
        retaining lifetime: any Sendable) async throws -> Self {
        switch self {
        case .zip(let document, let reader):
            .zip(try await reader.reopenTextForEdit(document, at: destination,
                expecting: contents, retaining: lifetime), reader)
        case .tar(let document, let reader):
            .tar(try await reader.reopenTextForEdit(document, at: destination,
                expecting: contents, retaining: lifetime), reader)
        }
    }
}

enum ArchiveTextEditorRequest: Sendable {
    case zip(ZIPTextPreviewSelection, ZIPArchiveReader)
    case tar(TARTextPreviewSelection, TARArchiveReader)
    @MainActor func isAllowed(from browser: BrowserViewController) -> Bool {
        switch self { case .zip: browser.canOpenZIPTextEditor; case .tar: browser.canOpenTARTextEditor }
    }
    func open(retaining access: any Sendable) async throws -> ArchiveEditableTextDocument {
        switch self {
        case .zip(let selection, let reader): .zip(try await reader.openTextForEdit(selection, retaining: access), reader)
        case .tar(let selection, let reader): .tar(try await reader.openTextForEdit(selection, retaining: access), reader)
        }
    }
}
