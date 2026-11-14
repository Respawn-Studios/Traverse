import Darwin
import Foundation

/// Account metadata only. Foundation's current-home API intentionally points
/// inside a sandbox container; it must still be used for private app storage.
/// This lookup supplies a browsing location, never access to that location.
public enum UserAccountHome {
    public enum Failure: Error, Sendable { case unavailable, invalidPath }
    private static let queue: OperationQueue = {
        let value = OperationQueue(); value.name = "Traverse.AccountHome"
        value.maxConcurrentOperationCount = 1; value.qualityOfService = .userInitiated
        return value
    }()
    public static func resolve() async throws -> URL {
        try Task.checkCancellation()
        let value: URL = try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do { continuation.resume(returning: try read()) }
                catch { continuation.resume(throwing: error) }
            }
        }
        // A cancelled caller still waits for the actual native lookup to end.
        // No cancelled result is published or converted into a filesystem read.
        try Task.checkCancellation()
        return value
    }
    private static func read() throws -> URL {
        var capacity = 1024
        while capacity <= 256 * 1024 {
            var storage = [CChar](repeating: 0, count: capacity)
            var record = passwd(), result: UnsafeMutablePointer<passwd>?
            let found: String? = try storage.withUnsafeMutableBufferPointer { bytes in
                let status = getpwuid_r(getuid(), &record, bytes.baseAddress!, capacity, &result)
                if status == ERANGE { return nil }
                guard status == 0, result != nil, let directory = record.pw_dir else { throw Failure.unavailable }
                let count = strnlen(directory, 4097)
                guard count > 0, count <= 4096 else { throw Failure.invalidPath }
                return String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(directory).assumingMemoryBound(to: UInt8.self), count: count), encoding: .utf8)
            }
            if let found { return try validated(path: found) }
            capacity *= 2
        }
        throw Failure.unavailable
    }
    static func validated(path: String) throws -> URL {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidPath }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.standardizedFileURL.path == path else { throw Failure.invalidPath }
        return url
    }
}
