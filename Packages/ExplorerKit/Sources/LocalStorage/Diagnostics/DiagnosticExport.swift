import Darwin
import ExplorerCore
import Foundation

public enum DiagnosticExportFailure: Error, Sendable, Equatable {
    case empty, alreadyExists, invalidDestination, changed, accessDenied, cancelled, capacity, io
}
public enum DiagnosticExportOutcome: Sendable, Equatable {
    case saved(records: Int, bytes: Int, incomplete: Bool)
    case notCreated(DiagnosticExportFailure)
    case createdButIncomplete(DiagnosticExportFailure)
}

/// Describes the exporting process, not every historical session in the file.
/// Reuses the closed runtime vocabulary; no machine, account or network names.
public struct DiagnosticExportMetadata: Codable, Sendable, Equatable {
    public let build: DiagnosticBuild?
    public let runtime: DiagnosticRuntime
    public init(build: DiagnosticBuild?, runtime: DiagnosticRuntime) {
        self.build = build; self.runtime = runtime
    }
}

public final class DiagnosticExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

/// New-file publication only. A failed/partial export is retained and reported;
/// neither an existing file nor an earlier export is silently replaced/deleted.
enum DiagnosticExport {
    static func write(to url: URL, protected: URL, maximumBytes: Int, cancellation: DiagnosticExportCancellation,
                      scope: DiagnosticLogScope = .all,
                      metadata: DiagnosticExportMetadata? = nil,
                      page: (DiagnosticHistoryCursor?) throws -> DiagnosticHistoryPage) -> DiagnosticExportOutcome {
        var created = false
        do {
            guard url.isFileURL, url.path == url.standardizedFileURL.path,
                  !url.path.utf8.contains(0), !url.lastPathComponent.isEmpty, url.lastPathComponent.utf8.count <= 255,
                  url != protected, !url.path.hasPrefix(protected.path + "/"),
                  !AutomaticMetadataPolicy.excludes(url),
                  !url.pathComponents.contains(where: { ["CloudStorage","Mobile Documents","FileProvider",".Trash",".Trashes"].contains($0)
                      || $0.lowercased().hasPrefix(".mac-explorer-recovery-") }) else { throw DiagnosticExportFailure.invalidDestination }
            try cancellation.check()
            // Codable can construct values without DiagnosticBuild's input
            // initializer. Revalidate before any metadata reaches the export.
            guard metadata?.build?.isValid != false else { throw DiagnosticHistoryFailure.invalidInput }
            var first = try page(nil)
            if first.events.isEmpty && first.next == nil { throw DiagnosticExportFailure.empty }
            let parentURL = url.deletingLastPathComponent()
            let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
            guard parent >= 0 else { throw code(errno) }; defer { close(parent) }
            var before = stat(), fs = statfs()
            guard fstat(parent, &before) == 0, fstatfs(parent, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else {
                throw DiagnosticExportFailure.invalidDestination
            }
            try cancellation.check()
            try checkParent(parentURL, original: before)
            let fd = openat(parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw code(errno) }; created = true; defer { close(fd) }
            var initial = stat(); guard fstat(fd, &initial) == 0 else { throw DiagnosticExportFailure.changed }
            var bytes = 0, count = 0, incomplete = false
            func append(_ data: Data) throws {
                guard data.count <= maximumBytes - bytes else { throw DiagnosticExportFailure.capacity }
                try data.withUnsafeBytes { value in
                    var offset = 0
                    while offset < value.count {
                        try cancellation.check()
                        let done = Darwin.write(fd, value.baseAddress!.advanced(by: offset), min(65536, value.count-offset))
                        if done < 0 && errno == EINTR { continue }
                        guard done > 0 else { throw code(errno) }; offset += done
                    }
                }
                bytes += data.count
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let scopeHeader: String
            switch scope {
            case .all: scopeHeader = ""
            case .operation(let trace): scopeHeader = ",\"scope\":\"operation\",\"rootTrace\":\"" + trace.uuidString + "\""
            }
            try append(Data(("{\"format\":\"Traverse.Diagnostics\",\"schema\":1" + scopeHeader).utf8))
            if let metadata {
                try append(Data(",\"exporter\":".utf8))
                try append(encoder.encode(metadata))
            }
            try append(Data(",\"events\":[".utf8))
            for _ in 0..<2048 {
                incomplete = incomplete || first.incomplete
                for event in first.events {
                    if count > 0 { try append(Data([44])) }
                    // Re-encode the typed projection; never copy raw log bytes or unknown fields.
                    try append(encoder.encode(event)); count += 1
                }
                guard let next = first.next else {
                    try append(Data("],\"incomplete\":\(incomplete ? "true" : "false")}".utf8))
                    guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw DiagnosticExportFailure.io }
                    var a = stat(), b = stat()
                    guard fstat(fd, &a) == 0, fstatat(parent, url.lastPathComponent, &b, AT_SYMLINK_NOFOLLOW) == 0,
                          a.st_dev == initial.st_dev, a.st_ino == initial.st_ino,
                          b.st_dev == initial.st_dev, b.st_ino == initial.st_ino,
                          a.st_mode & S_IFMT == S_IFREG, a.st_nlink == 1, a.st_size == bytes else {
                        throw DiagnosticExportFailure.changed
                    }
                    try checkParent(parentURL, original: before)
                    guard fsync(parent) == 0 else { throw DiagnosticExportFailure.io }
                    return .saved(records: count, bytes: bytes, incomplete: incomplete)
                }
                first = try page(next)
            }
            throw DiagnosticExportFailure.capacity
        } catch {
            let reason: DiagnosticExportFailure
            switch error {
            case is CancellationError: reason = .cancelled
            case DiagnosticHistoryFailure.capacity: reason = .capacity
            case DiagnosticHistoryFailure.changed: reason = .changed
            default: reason = error as? DiagnosticExportFailure ?? .io
            }
            return created ? .createdButIncomplete(reason) : .notCreated(reason)
        }
    }
    private static func checkParent(_ url: URL, original: stat) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw DiagnosticExportFailure.changed }; defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_dev == original.st_dev, value.st_ino == original.st_ino else {
            throw DiagnosticExportFailure.changed
        }
    }
    private static func code(_ value: Int32) -> DiagnosticExportFailure {
        switch value { case EEXIST: .alreadyExists; case EACCES, EPERM: .accessDenied; default: .io }
    }
}
