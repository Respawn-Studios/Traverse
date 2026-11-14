import Darwin
import Foundation

/// A captured request, never authority to enable an unqualified execution path.
public enum CopyExecutionRequest: String, Sendable, Equatable {
    case standard
    case previewIfAvailable
}

public enum CopyPreviewAvailability: Sendable, Equatable {
    case qualificationPending
    case available
}

public enum StandardCopyReason: String, Sendable, Equatable {
    case previewOff, qualificationPending, move, unsupportedInput, destinationConflict, unqualifiedLocation, continuation
    case outsidePreviewLimits, historyUnavailable
}

/// The preparation result describes the entire job, not an eligible subset.
public enum TransferExecutionDecision: Sendable, Equatable {
    case standard(StandardCopyReason)
    case groupedCopy(maximumMembersPerGroup: Int)
}

internal enum CopyExecutionAuthorization: Sendable {
    case closed
    // Existing package/process fixtures keep their established hook semantics.
    case legacyQualification
    case generatedFixture
}

extension RecoverableFileOperations {
    /// Default engines stay closed. A reviewed qualification set exposes the
    /// explicit activation action; this getter never opens/upgrades a catalog.
    public var copyPreviewAvailability: CopyPreviewAvailability {
        switch copyExecutionAuthorization {
        case .closed: qualifiedCopyPreview == nil ? .qualificationPending : .available
        case .legacyQualification, .generatedFixture: .available
        }
    }

    internal func validateCopyExecutionSession(locations: [URL], directories: [URL] = []) throws {
        if case .generatedFixture = copyExecutionAuthorization {
            guard let qualification = hooks.groupedCopy.qualification else { throw FileOperationFailure.invalidRequest }
            try qualification.validate(locations: locations + [directory])
            for location in locations { _ = try DirectoryAnchor(location.deletingLastPathComponent(), resolve: false) }
            for directory in directories { _ = try DirectoryAnchor(directory, resolve: false) }
        }
    }

    #if DEBUG
    /// Development-only native queue qualification. No hook, group-count or
    /// general owner-location opt-in is exposed by this factory.
    public static func generatedCopyVerificationSession(in fixtureRoot: URL) async throws -> RecoverableFileOperations {
        let journal = fixtureRoot.appendingPathComponent("journal", isDirectory: true)
        let validator = RecoverableFileOperations(journalDirectory: journal)
        return try await validator.worker { cancellation in
            try cancellation.check()
            let qualification = try GeneratedCopyVerificationRoot.validate(fixtureRoot, cancellation: cancellation)
            var hooks = RecoveryHooks()
            hooks.groupedCopy.qualification = qualification
            return RecoverableFileOperations(journalDirectory: journal, hooks: hooks, copyExecutionAuthorization: .generatedFixture)
        }
    }
    #endif
}

#if DEBUG
private enum GeneratedCopyVerificationRoot {
    private static var repository: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    private static func directory(_ url: URL, privateMode: Bool = true) throws -> DirectoryAnchor {
        guard url.isFileURL, url.path == url.standardizedFileURL.path else { throw FileOperationFailure.invalidRequest }
        let anchor = try DirectoryAnchor(url, resolve: false)
        var info = stat()
        guard fstat(anchor.fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & (privateMode ? 0o077 : 0o022) == 0 else { throw FileOperationFailure.invalidRequest }
        return anchor
    }
    private static func read(_ name: String, in anchor: DirectoryAnchor, maximum: Int) throws -> Data {
        let fd = openat(anchor.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == geteuid(), before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o077 == 0, before.st_nlink == 1, before.st_size >= 0,
              before.st_size <= maximum else { throw FileOperationFailure.invalidRequest }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: min(maximum + 1, 16_385))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0, bytes.count + count <= maximum else { throw FileOperationFailure.invalidRequest }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), linked = stat()
        guard fstat(fd, &after) == 0, fstatat(anchor.fd, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid, after.st_nlink == 1,
              linked.st_dev == after.st_dev, linked.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw FileOperationFailure.invalidRequest }
        try anchor.validate(); return bytes
    }
    static func validate(_ root: URL, cancellation: OperationCancellation) throws -> GroupedCopyQualification {
        // Bind to the actual source repository, not any path containing .build.
        guard URL(fileURLWithPath: #filePath).path == repository.appendingPathComponent("Packages/ExplorerKit/Sources/FileOperations/CopyExecutionPreference.swift").path else {
            throw FileOperationFailure.invalidRequest
        }
        _ = try directory(repository, privateMode: false)
        _ = try directory(repository.appendingPathComponent(".build", isDirectory: true), privateMode: false)
        let base = repository.appendingPathComponent(".build/grouped-copy-production", isDirectory: true)
        _ = try directory(base)
        let fixtures = root.deletingLastPathComponent(), run = fixtures.deletingLastPathComponent()
        guard run.deletingLastPathComponent().path == base.path, UUID(uuidString: run.lastPathComponent) != nil,
              fixtures.lastPathComponent == "fixtures", root.lastPathComponent.hasPrefix("copy-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(5))) != nil else { throw FileOperationFailure.invalidRequest }
        let runAnchor = try directory(run)
        _ = try directory(fixtures)
        let fixture = try directory(root)
        guard try read(".qualification-owner", in: runAnchor, maximum: 128) == Data("MacExplorer grouped production qualification v1\n\(run.lastPathComponent)\n".utf8),
              try read(".owned-grouped-production-fixture", in: fixture, maximum: 128) == Data("MacExplorer generated grouped production fixture v1\n\(root.lastPathComponent)\n".utf8),
              try read(GroupedCopyQualification.markerName, in: fixture, maximum: 128) == GroupedCopyQualification.marker else {
            throw FileOperationFailure.invalidRequest
        }
        let allowed: Set<String> = ["source", "destination", "journal", "seed.json", ".owned-grouped-production-fixture", GroupedCopyQualification.markerName]
        let children = try GroupedCopyFilesystemEvidence.children(in: fixture, cancellation: cancellation, limit: allowed.count)
        guard Set(children).isSubset(of: allowed), Set(children).isSuperset(of: allowed.subtracting(["journal"])) else { throw FileOperationFailure.invalidRequest }
        let source = try directory(root.appendingPathComponent("source", isDirectory: true))
        _ = try directory(root.appendingPathComponent("destination", isDirectory: true))
        if children.contains("journal") { _ = try directory(root.appendingPathComponent("journal", isDirectory: true)) }
        let seed = try JSONDecoder().decode([String: String].self, from: read("seed.json", in: fixture, maximum: 16_384))
        guard Set(seed.keys) == ["count", "sourceFingerprint", "emptyDestinationFingerprint"],
              let count = seed["count"].flatMap(Int.init), [1, 16, 17, 31, 33].contains(count),
              seed["sourceFingerprint"].map(GroupedCopyRecord.isDigest) == true,
              seed["emptyDestinationFingerprint"].map(GroupedCopyRecord.isDigest) == true else { throw FileOperationFailure.invalidRequest }
        let names = try GroupedCopyFilesystemEvidence.children(in: source, cancellation: cancellation, limit: 33)
        let expected = Set((0..<count).map { $0 % 2 == 0 ? "Case-\($0).txt" : "caf\u{00E9}-\($0).txt" })
        guard Set(names) == expected else { throw FileOperationFailure.invalidRequest }
        var total: Int64 = 0
        for name in names {
            try cancellation.check()
            var info = stat()
            guard fstatat(source.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_nlink == 1,
                  info.st_size >= 0, info.st_size <= 16_777_216 else { throw FileOperationFailure.invalidRequest }
            total += info.st_size
            guard total <= 67_108_864 else { throw FileOperationFailure.unsupported }
        }
        try source.validate(); try fixture.validate(); try runAnchor.validate(); try cancellation.check()
        return try GroupedCopyQualification(root: root)
    }
}
#endif
