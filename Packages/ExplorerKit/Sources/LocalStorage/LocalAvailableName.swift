import Darwin
import Foundation

/// A metadata-only local naming hint, never a reservation or permission to replace.
/// The publication plan must independently validate its destination exclusively.
public enum LocalAvailableName {
    public enum Failure: Error, Equatable, Sendable {
        case invalidName, exhausted
        case fileSystem(Int32)
    }

    private static let queue = DispatchQueue(label: "MacExplorer.LocalAvailableName", qos: .userInitiated)

    /// `preferredName` includes the final extension. Passing `extension: "zip"`
    /// numbers `notes.txt.zip` as `notes.txt 2.zip`; `"tar.gz"` keeps the
    /// compound suffix together. Nil numbers the whole name.
    /// Checks at most 1,024 candidates using the filesystem's own name lookup.
    public static func available(in directory: URL, preferredName: String,
                                 `extension` filenameExtension: String? = nil) async throws -> String {
        try Task.checkCancellation()
        let cancellation = LocalNameCancellation()
        let result: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try find(in: directory, preferredName: preferredName,
                                 filenameExtension: filenameExtension, check: cancellation.check)
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return result
    }

    private static func find(in directory: URL, preferredName: String, filenameExtension: String?,
                             check: () throws -> Void) throws -> String {
        try check()
        guard directory.isFileURL, valid(preferredName) else { throw Failure.invalidName }
        let suffix: String
        if let filenameExtension {
            guard !filenameExtension.isEmpty, valid(filenameExtension),
                  filenameExtension.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
                  preferredName.lowercased().hasSuffix("." + filenameExtension.lowercased()),
                  preferredName.count > filenameExtension.count + 1 else { throw Failure.invalidName }
            suffix = String(preferredName.suffix(filenameExtension.count + 1))
        } else { suffix = "" }
        let base = String(preferredName.dropLast(suffix.count))
        let descriptor = directory.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure.fileSystem(errno) }
        defer { close(descriptor) }
        for number in 1...1_024 {
            try check()
            let candidate = number == 1 ? preferredName : base + " \(number)" + suffix
            guard valid(candidate) else { throw Failure.invalidName }
            var facts = stat()
            if fstatat(descriptor, candidate, &facts, AT_SYMLINK_NOFOLLOW) == 0 { continue }
            let code = errno
            guard code == ENOENT else { throw Failure.fileSystem(code) }
            try check()
            return candidate
        }
        throw Failure.exhausted
    }

    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains(":")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// The flag is shared only across the caller's cancellation handler and the
/// serial metadata worker; every access is protected by this lock.
private final class LocalNameCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}
