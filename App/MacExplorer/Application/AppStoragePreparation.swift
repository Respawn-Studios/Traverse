import ExplorerCore
import Foundation
import LocalStorage

/// Shared identity pins for the two concrete app roots. Injected generated
/// profiles retain their existing single-leaf contract. Construction is inert.
enum AppStoragePreparation {
    private static let state = AppStorageLocations.layout.flatMap {
        try? PrivateStateDirectorySequence(directories: $0.stateCreationChain, activity: ApplicationFileActivity.gate)
    }
    private static let cache = AppStorageLocations.layout.flatMap {
        try? PrivateStateDirectorySequence(directories: $0.cacheCreationChain, activity: ApplicationFileActivity.gate)
    }
    static func owner(for directory: URL) throws -> PrivateStateDirectorySequence {
        if directory.standardizedFileURL.path == AppStorageLocations.layout?.stateDirectory.standardizedFileURL.path {
            guard let state else { throw StateDirectoryPreparationError.unavailable }
            return state
        }
        if directory.standardizedFileURL.path == AppStorageLocations.layout?.cacheDirectory.standardizedFileURL.path {
            guard let cache else { throw StateDirectoryPreparationError.unavailable }
            return cache
        }
        return try .init(directories: [directory], activity: ApplicationFileActivity.gate)
    }
    static func preparePortableCache() async throws {
        guard AppStorageLocations.isPortable else { return }
        guard let cache else { throw StateDirectoryPreparationError.unavailable }
        try await cache.prepare()
    }
}
