import Foundation

package extension URL {
    /// Foundation can add a trailing directory marker when a URL constructed
    /// before creation is standardized after creation. Accept only that
    /// spelling change. Callers still prove access and filesystem identity.
    var hasStandardizedFilePath: Bool {
        guard isFileURL else { return false }
        let normalized = standardizedFileURL
        if self == normalized { return true }
        guard baseURL == nil, normalized.baseURL == nil,
              hasDirectoryPath != normalized.hasDirectoryPath else { return false }
        let folder = hasDirectoryPath ? self : normalized
        let other = hasDirectoryPath ? normalized : self
        let encoded = folder.absoluteString.utf8
        return encoded.last == 47 && encoded.dropLast().elementsEqual(other.absoluteString.utf8)
    }
}
