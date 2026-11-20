import FileOperations
import Foundation
import LocalStorage

/// Source selection happens before the diff starts. Git and disk reads use the
/// bounded reader, and the draft capture consults the existing document owner.
@MainActor struct GitLocalFileReview {
    enum Source: String, CaseIterable, Sendable {
        case draft = "Unsaved Buffer"
        case disk = "On Disk"
        case index = "Git Index"
    }

    let url: URL
    let hasDraft: () -> Bool
    let captureDraft: () -> EditorComparisonCapture.Side?

    func label(_ source: Source) -> String { source.rawValue + " · " + url.lastPathComponent }

    func read(_ source: Source, through access: GitReviewAccess) async throws -> EditorComparisonCapture.Side {
        switch source {
        case .draft:
            guard let draft = captureDraft() else {
                throw EditorComparisonLoadFailure.unavailable("The open file has no available unsaved buffer.")
            }
            return draft
        case .disk, .index:
            do {
                let value = try await (source == .disk ? access.workingText(for: url) : access.indexText(for: url))
                return .init(text: value.text, format: value.format,
                    language: TextSyntaxLanguage.inferred(extension: EditorOpeningSupport.key(forFilename: url.lastPathComponent) ?? ""))
            } catch is CancellationError { throw CancellationError() }
            catch {
                if source == .disk, error is FileOperationFailure || error is TextComparisonReadFailure {
                    throw EditorComparisonLoadFailure.unavailable("The on-disk file could not be read safely within this project.")
                }
                throw EditorComparisonLoadFailure.unavailable(GitReviewAccess.message(for: error))
            }
        }
    }
}
