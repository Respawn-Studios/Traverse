import Darwin
import FileOperations
import Foundation
import LocalStorage

/// One ordered writer owns the acknowledged preview fields. Ordinary snapshots
/// cannot overwrite them with a value captured before an awaited activation.
final class CopyPreviewPreferencePersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.Preferences")
    private let file: URL
    private var receipt: CopyPreviewActivationReceipt?
    private var disclosed: Bool
    private let preparation: PrivateStateDirectorySequence?
    #if DEBUG
    private let beforeWrite: (@Sendable (Bool) throws -> Void)?
    private let afterWrite: (@Sendable (Bool) throws -> Void)?
    #endif

    init(file: URL, receipt: CopyPreviewActivationReceipt?, disclosed: Bool) {
        self.file = file; self.receipt = receipt; self.disclosed = disclosed
        preparation = AppStorageLocations.isPortable && file.deletingLastPathComponent().path == AppStorageLocations.stateDirectory?.path
            ? try? AppStoragePreparation.owner(for: file.deletingLastPathComponent()) : nil
        #if DEBUG
        beforeWrite = nil
        afterWrite = nil
        #endif
    }
    #if DEBUG
    func drainForVerification() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    init(file: URL, receipt: CopyPreviewActivationReceipt?, disclosed: Bool,
         beforeWrite: @escaping @Sendable (Bool) throws -> Void,
         afterWrite: (@Sendable (Bool) throws -> Void)? = nil) {
        self.file = file; self.receipt = receipt; self.disclosed = disclosed; self.beforeWrite = beforeWrite; self.afterWrite = afterWrite
        preparation = nil
    }
    #endif

    func saveOrdinary(_ snapshot: Data) {
        queue.async { [self] in
            // Existing session preferences remain usable if ordinary saving fails.
            try? write(snapshot, receipt: receipt, disclosed: disclosed, durable: false)
        }
    }

    func prepareDirectory() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try prepareOnWriter()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func commit(_ snapshot: Data, receipt next: CopyPreviewActivationReceipt?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let accepted = disclosed || next != nil
                    try write(snapshot, receipt: next, disclosed: accepted, durable: true)
                    receipt = next; disclosed = accepted
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func write(_ snapshot: Data, receipt: CopyPreviewActivationReceipt?, disclosed: Bool, durable: Bool) throws {
        let activity = preparation == nil ? nil : try ApplicationFileActivity.gate.begin()
        defer { withExtendedLifetime(activity) {} }
        guard snapshot.count <= 131_072,
              var values = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else { throw FileOperationFailure.invalidRequest }
        values["groupedCopyPreview"] = receipt != nil
        values["copyPreviewDisclosureAccepted"] = disclosed
        if let receipt {
            values["copyPreviewActivationReceipt"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
        } else { values.removeValue(forKey: "copyPreviewActivationReceipt") }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard data.count <= 131_072 else { throw FileOperationFailure.unsupported }
        #if DEBUG
        try beforeWrite?(durable)
        #endif
        try prepareOnWriter()
        try data.write(to: file, options: .atomic)
        try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if durable {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FileOperationFailure.unavailable }; defer { close(fd) }
            let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw FileOperationFailure.unavailable }; defer { close(parent) }
            guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0, fsync(parent) == 0 else { throw FileOperationFailure.ioFailure }
            guard try Data(contentsOf: file) == data else { throw FileOperationFailure.sourceChanged }
        }
        #if DEBUG
        try afterWrite?(durable)
        #endif
    }

    private func prepareOnWriter() throws {
        if AppStorageLocations.isPortable && file.deletingLastPathComponent().path == AppStorageLocations.stateDirectory?.path {
            guard let preparation else { throw StateDirectoryPreparationError.unavailable }
            try preparation.prepareFromBackgroundThread()
        } else {
            try FileManager().createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        }
    }
}
