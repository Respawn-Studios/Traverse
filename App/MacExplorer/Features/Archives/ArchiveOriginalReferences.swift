import Darwin
import Foundation

/// App-owned saved names are separate from the file-operation journal. An archive
/// replacement must not silently move one of their bound objects into recovery.
@MainActor enum ArchiveOriginalReferences {
    enum Failure: Error {
        case savedNames, unavailable
        var message: String {
            switch self {
            case .savedNames: "This archive version has saved names. Save an archive copy or review its saved names before changing it."
            case .unavailable: "Saved names could not be checked for this archive. Save an archive copy or review saved names before changing it."
            }
        }
    }

    static func requireUnreferenced(_ roots: [URL], names: ApplicationPrivateNames,
                                    retaining access: FileAccessLifetimes?) async throws {
        guard (1...3).contains(roots.count), roots.allSatisfy(\.isFileURL) else { throw Failure.unavailable }
        defer { withExtendedLifetime(access) {} }
        // Recovery can be between the two renames. Definite absence is not a
        // reference proof for another root: inspect every present exact object.
        for root in Set(roots) {
            try Task.checkCancellation()
            let present = try await Task.detached(priority: .userInitiated) {
                var value = stat()
                if lstat(root.path, &value) == 0 {
                    guard value.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
                    return true
                }
                guard errno == ENOENT else { throw Failure.unavailable }
                return false
            }.value
            guard present else { continue }
            do {
                if try await names.hasCurrentBoundReference(at: root, retaining: access) { throw Failure.savedNames }
            } catch let failure as Failure { throw failure }
            catch is CancellationError { throw CancellationError() }
            catch { throw Failure.unavailable }
        }
    }

    static func refresh(_ original: URL, in coordinator: ApplicationOperationCoordinator) {
        for browser in coordinator.liveBrowsers where !browser.isBrowserSuspended {
            for archive in browser.archiveTabs.values where archive.source == original && !archive.isClosed {
                archive.refresh()
            }
        }
        if let standalone = ApplicationZIPBrowser.shared.controller,
           standalone.window?.isVisible == true, standalone.model.source == original {
            standalone.model.refresh()
        }
        if let standalone = ApplicationTARBrowser.shared.controller,
           standalone.window?.isVisible == true, standalone.model.source == original {
            standalone.model.refresh()
        }
    }
}
