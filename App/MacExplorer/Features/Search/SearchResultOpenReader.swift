import Darwin
import ExplorerCore
@_spi(ApplicationOwnership) import FileOperations
import Foundation

enum SearchOpenValidation: Sendable, Equatable {
    case ready, changed, missing, denied, unavailable, unsupported, cancelled

    var userMessage: String {
        switch self {
        case .ready: ""
        case .changed: "This result changed. Search again before opening it."
        case .missing: "This result is no longer available at its observed location."
        case .denied: "Access to this result was denied."
        case .unavailable: "This result could not be checked. Reconnect or refresh its folder."
        case .unsupported: "This result cannot be opened here: links, aliases, special files and cloud placeholders need explicit handling."
        case .cancelled: ""
        }
    }
}

struct SearchOpenObservation: Sendable {
    let validation: SearchOpenValidation
    var textSelection: LocalTextOpenSelection? = nil
}

/// Validate current kind, size and modification time without reading a body.
/// The in-app editor can also recheck the same parent and file observations.
final class SearchResultOpenReader: @unchecked Sendable {
    private let queue: OperationQueue
    private let lock = NSLock()
    private var pending: Work?
    private var scheduled = false
    private struct Work: Sendable {
        let entry: FileEntry
        let cancellation: Cancellation
        let continuation: CheckedContinuation<SearchOpenObservation, Never>
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.withLock { value = true } }
        var cancelled: Bool { lock.withLock { value } }
    }

    init() {
        queue = OperationQueue()
        queue.name = "MacExplorer.Search.OpenValidation"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }
    func validate(_ entry: FileEntry) async -> SearchOpenValidation {
        await observe(entry).validation
    }
    func observe(_ entry: FileEntry) async -> SearchOpenObservation {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let replaced = lock.withLock {
                    let replaced = pending
                    pending = Work(entry: entry, cancellation: cancellation, continuation: continuation)
                    if !scheduled {
                        scheduled = true
                        queue.addOperation { [self] in drain() }
                    }
                    return replaced
                }
                replaced?.continuation.resume(returning: .init(validation: .cancelled))
            }
        } onCancel: { cancellation.cancel() }
    }
    private func drain() {
        while let work = lock.withLock({ () -> Work? in
            let work = pending
            pending = nil
            if work == nil { scheduled = false }
            return work
        }) {
            var selection: LocalTextOpenSelection?
            let result: SearchOpenValidation
            do {
                let activity = try ApplicationFileActivity.gate.begin()
                defer { withExtendedLifetime(activity) {} }
                result = work.cancellation.cancelled ? .cancelled :
                    Self.verify(work.entry, cancellation: work.cancellation, selection: &selection)
            } catch { result = .unavailable }
            work.continuation.resume(returning: .init(validation: result, textSelection: selection))
        }
    }
    private static func verify(_ entry: FileEntry, cancellation: Cancellation,
                               selection: inout LocalTextOpenSelection?) -> SearchOpenValidation {
        let url = entry.url
        guard url.isFileURL, url.path.hasPrefix("/"), url.path == url.standardizedFileURL.path,
              (url.host == nil || url.host == "" || url.host == "localhost"),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              !url.path.utf8.contains(0), url.absoluteString.utf8.count <= 8_192,
              [.file, .directory, .package].contains(entry.kind) else { return .unsupported }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return failure(errno) }
        for component in entry.url.deletingLastPathComponent().pathComponents.dropFirst() {
            if cancellation.cancelled { close(descriptor); return .cancelled }
            var observed = stat()
            guard fstatat(descriptor, component, &observed, AT_SYMLINK_NOFOLLOW) == 0 else {
                let result = failure(errno); close(descriptor); return result
            }
            guard observed.st_mode & S_IFMT == S_IFDIR, observed.st_flags & UInt32(SF_DATALESS) == 0 else {
                close(descriptor); return .unsupported
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            close(descriptor)
            guard next >= 0 else { return failure(error) }
            var opened = stat()
            guard fstat(next, &opened) == 0, same(observed, opened) else { close(next); return .changed }
            descriptor = next
        }
        defer { close(descriptor) }
        guard !cancellation.cancelled else { return .cancelled }
        var observed = stat()
        guard fstatat(descriptor, entry.url.lastPathComponent, &observed, AT_SYMLINK_NOFOLLOW) == 0 else { return failure(errno) }
        let type = observed.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR, observed.st_flags & UInt32(SF_DATALESS) == 0 else { return .unsupported }
        do {
            let values = try entry.url.resourceValues(forKeys: [.isAliasFileKey, .isPackageKey, .isUbiquitousItemKey])
            guard values.isAliasFile != true, values.isUbiquitousItem != true else { return .unsupported }
            let kind: FileKind = type == S_IFDIR ? (values.isPackage == true ? .package : .directory) : .file
            let size: Int64? = kind == .file ? Int64(observed.st_size) : nil
            let time = observed.st_mtimespec
            let modified = Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
            guard kind == entry.kind, size == entry.byteCount, modified == entry.modifiedAt else { return .changed }
        } catch {
            let native = error as NSError
            return native.code == NSFileReadNoPermissionError ? .denied : .unavailable
        }
        guard !cancellation.cancelled else { return .cancelled }
        var rechecked = stat()
        guard fstatat(descriptor, entry.url.lastPathComponent, &rechecked, AT_SYMLINK_NOFOLLOW) == 0,
              same(observed, rechecked), observed.st_size == rechecked.st_size,
              observed.st_mtimespec.tv_sec == rechecked.st_mtimespec.tv_sec,
              observed.st_mtimespec.tv_nsec == rechecked.st_mtimespec.tv_nsec else { return .changed }
        // A parent rename must not redirect the later native path handoff.
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { return .unavailable }
        let currentPath = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard currentPath == entry.url.deletingLastPathComponent().path else { return .changed }
        if entry.kind == .file {
            var parent = stat()
            guard fstat(descriptor, &parent) == 0 else { return failure(errno) }
            selection = LocalTextOpenSelection(observedURL: url, parent: parent, file: rechecked)
        }
        return .ready
    }
    private static func same(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode & S_IFMT == right.st_mode & S_IFMT
    }
    private static func failure(_ code: Int32) -> SearchOpenValidation {
        switch code {
        case ENOENT: .missing
        case EACCES, EPERM: .denied
        case ELOOP, ENOTDIR: .unsupported
        default: .unavailable
        }
    }
}
