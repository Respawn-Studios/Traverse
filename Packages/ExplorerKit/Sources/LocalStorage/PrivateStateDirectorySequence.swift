import ExplorerCore
import Foundation

/// Explicit finite OS-base -> app-namespace preparation. Initialization is
/// inert. Existing permissions are never repaired; partial/failure evidence is
/// retained. One serial owner pins each established directory identity.
public final class PrivateStateDirectorySequence: Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.PrivateStorageRoots", qos: .utility)
    private let directories: [PrivateStateDirectory]
    public init(directories: [URL], activity: FileActivityGate? = nil) throws {
        guard (1...3).contains(directories.count),
            directories.allSatisfy({
                let decoded = URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
                    .removingPercentEncoding
                return decoded?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) == false
                    && $0.isFileURL && $0.path.hasPrefix("/") && $0.path != "/"
                    && $0.standardizedFileURL.path == $0.path
                    && !$0.path.utf8.contains(0) && $0.user == nil && $0.password == nil && $0.query == nil
                    && $0.fragment == nil
            }), zip(directories, directories.dropFirst()).allSatisfy({ $1.deletingLastPathComponent().path == $0.path })
        else {
            throw StateDirectoryPreparationError.invalidLocation
        }
        self.directories = directories.map { PrivateStateDirectory(directory: $0, activity: activity) }
    }
    public func prepare() async throws {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    let result = Result { try prepareOnQueue(cancellation) }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }
    public func prepareFromBackgroundThread() throws {
        guard !Thread.isMainThread else { throw StateDirectoryPreparationError.requiresBackgroundWorker }
        try queue.sync { try prepareOnQueue(Cancellation()) }
    }
    private func prepareOnQueue(_ cancellation: Cancellation) throws {
        for directory in directories {
            try cancellation.check()
            try directory.prepareFromBackgroundThread()
        }
        try cancellation.check()
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    }
}
