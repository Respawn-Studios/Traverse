import CoreServices
import Darwin
import Foundation

/// Source-only candidate for fresh received files and extracted members. No
/// app route activates it. It does not inspect or rewrite private xattr
/// values; a public quarantine observation is not an execution-policy verdict.
internal enum OSManagedQuarantineCandidate {
    enum Failure: Error { case changed, unsupported, unmarked }

    struct Witness: Sendable {
        fileprivate let identity: Identity
        let markRequired: Bool

        func require(_ descriptor: Int32, at url: URL) throws {
            let current = try OSManagedQuarantineCandidate.observe(descriptor, at: url)
            guard current.identity == identity else { throw Failure.changed }
            if markRequired, current.properties == nil { throw Failure.unmarked }
        }
    }

    /// An archive contributes only a source presence fact. Binding the fact
    /// across preparation and production prevents a newly marked archive from
    /// silently producing an unmarked member.
    struct ExtractionSourceWitness: Sendable, Equatable {
        fileprivate let identity: Identity
        let marked: Bool

        func require(_ descriptor: Int32, at url: URL) throws {
            let current = try OSManagedQuarantineCandidate.observe(descriptor, at: url)
            guard current.identity == identity, (current.properties != nil) == marked else {
                throw Failure.changed
            }
        }
    }

    static func observeExtractionSource(_ descriptor: Int32, at url: URL) throws -> ExtractionSourceWitness {
        let current = try observe(descriptor, at: url)
        return .init(identity: current.identity, marked: current.properties != nil)
    }

    /// A Download is a newly received object, so its private stage is marked
    /// before any body bytes are written. An existing OS mark is left alone.
    static func prepareReceivedEmptyStage(_ descriptor: Int32, at url: URL) throws -> Witness {
        try requirePrivateEmptyStage(descriptor, at: url)
        let before = try observe(descriptor, at: url)
        if before.properties == nil {
            try setPublicDownloadMark(at: url)
        }
        let after = try observe(descriptor, at: url)
        guard after.identity == before.identity, after.properties != nil else { throw Failure.unmarked }
        return .init(identity: before.identity, markRequired: true)
    }

    /// The sealed spool remains owned by its existing lease. This witness
    /// checks only that its documented public mark remains recognizable.
    static func observeMarkedSource(_ descriptor: Int32, at url: URL) throws -> Witness {
        let current = try observe(descriptor, at: url)
        guard current.properties != nil else { throw Failure.unmarked }
        return .init(identity: current.identity, markRequired: true)
    }

    /// An archive is not the same object as a member. A fresh private member
    /// inherits the *fact* of quarantine when the archive is marked. If the OS
    /// already marked the member, keep that mark; if not, set documented public
    /// properties before publication. No raw attribute is copied from archive.
    static func prepareExtractedStage(_ descriptor: Int32, at url: URL,
                                      from archive: Int32, at archiveURL: URL) throws -> Witness {
        try requirePrivateEmptyStage(descriptor, at: url)
        let source = try observe(archive, at: archiveURL)
        let before = try observe(descriptor, at: url)
        if source.properties != nil, before.properties == nil {
            try setPublicDownloadMark(at: url)
        }
        let finalSource = try observe(archive, at: archiveURL)
        let after = try observe(descriptor, at: url)
        guard finalSource.identity == source.identity,
              (source.properties != nil) == (finalSource.properties != nil),
              after.identity == before.identity else { throw Failure.changed }
        if source.properties != nil, after.properties == nil { throw Failure.unmarked }
        return .init(identity: before.identity, markRequired: after.properties != nil)
    }

    /// Only the concrete v16 producers call these before writing a fresh node.
    /// The producer owns the private root and pinned parent chain; this helper
    /// binds the public property write to the exact new regular file/directory.
    static func prepareReceivedTreeNode(_ descriptor: Int32, at url: URL) throws -> Witness {
        try requireFreshTreeNode(descriptor, at: url)
        let before = try observe(descriptor, at: url)
        if before.properties == nil { try setPublicDownloadMark(at: url) }
        let after = try observe(descriptor, at: url)
        guard after.identity == before.identity, after.properties != nil else { throw Failure.unmarked }
        return .init(identity: before.identity, markRequired: true)
    }

    static func prepareExtractedTreeNode(_ descriptor: Int32, at url: URL,
                                         source: ExtractionSourceWitness,
                                         archive: Int32, at archiveURL: URL) throws -> Witness {
        try requireFreshTreeNode(descriptor, at: url)
        try source.require(archive, at: archiveURL)
        let before = try observe(descriptor, at: url)
        if source.marked, before.properties == nil { try setPublicDownloadMark(at: url) }
        try source.require(archive, at: archiveURL)
        let after = try observe(descriptor, at: url)
        guard after.identity == before.identity,
              !source.marked || after.properties != nil else { throw Failure.unmarked }
        return .init(identity: before.identity, markRequired: after.properties != nil)
    }

    /// Public xattr flags only answer whether an opaque attribute should be
    /// copied for a *same-object* copy intent. Download and extraction above
    /// create new objects, so neither invokes this as permission to transfer
    /// archive/spool xattrs or as proof of a destination security state.
    static func copyIntentAllowsAttribute(named name: String) -> Bool {
        name.withCString { xattr_preserve_for_intent($0, UInt32(XATTR_OPERATION_INTENT_COPY)) != 0 }
    }

    fileprivate struct Identity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
        let kind: mode_t

        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino
            birthSeconds = value.st_birthtimespec.tv_sec
            birthNanoseconds = value.st_birthtimespec.tv_nsec
            kind = value.st_mode & S_IFMT
        }
    }

    private struct Observation {
        let identity: Identity
        let properties: [String: Any]?
    }

    private static func observe(_ descriptor: Int32, at url: URL) throws -> Observation {
        let before = try boundIdentity(descriptor, at: url)
        let properties = try URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        guard try boundIdentity(descriptor, at: url) == before else { throw Failure.changed }
        return .init(identity: before, properties: properties?.isEmpty == false ? properties : nil)
    }

    private static func boundIdentity(_ descriptor: Int32, at url: URL) throws -> Identity {
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil,
              url.fragment == nil, url == url.standardizedFileURL else { throw Failure.unsupported }
        let opened = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw Failure.changed }
        defer { Darwin.close(opened) }
        var pinned = stat(), named = stat()
        guard fstat(descriptor, &pinned) == 0, fstat(opened, &named) == 0,
              pinned.st_uid == geteuid(), named.st_uid == geteuid(),
              [S_IFREG, S_IFDIR].contains(pinned.st_mode & S_IFMT),
              pinned.st_mode & S_IFMT == named.st_mode & S_IFMT,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino,
              pinned.st_birthtimespec.tv_sec == named.st_birthtimespec.tv_sec,
              pinned.st_birthtimespec.tv_nsec == named.st_birthtimespec.tv_nsec,
              pinned.st_mode & S_IFMT != S_IFREG || (pinned.st_nlink == 1 && named.st_nlink == 1)
        else { throw Failure.changed }
        return Identity(pinned)
    }

    private static func requirePrivateStage(_ descriptor: Int32, at url: URL) throws {
        _ = try boundIdentity(descriptor, at: url)
        let parent = Darwin.open(url.deletingLastPathComponent().path,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.unsupported }
        defer { Darwin.close(parent) }
        var facts = stat()
        guard fstat(parent, &facts) == 0, facts.st_uid == geteuid(),
              facts.st_mode & S_IFMT == S_IFDIR,
              facts.st_mode & 0o7777 == 0o700 else { throw Failure.unsupported }
    }

    private static func requirePrivateEmptyStage(_ descriptor: Int32, at url: URL) throws {
        try requirePrivateStage(descriptor, at: url)
        var facts = stat()
        guard fstat(descriptor, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG,
              facts.st_size == 0, facts.st_mode & 0o7777 == 0o600 else { throw Failure.unsupported }
    }

    private static func requireFreshTreeNode(_ descriptor: Int32, at url: URL) throws {
        _ = try boundIdentity(descriptor, at: url)
        var facts = stat()
        guard fstat(descriptor, &facts) == 0, facts.st_uid == geteuid() else { throw Failure.unsupported }
        if facts.st_mode & S_IFMT == S_IFREG {
            guard facts.st_nlink == 1, facts.st_size == 0,
                  facts.st_mode & 0o7777 == 0o600 else { throw Failure.unsupported }
        } else if facts.st_mode & S_IFMT == S_IFDIR {
            guard facts.st_mode & 0o7777 == 0o700 else { throw Failure.unsupported }
            let copy = dup(descriptor)
            guard copy >= 0 else { throw Failure.changed }
            guard let directory = fdopendir(copy) else { close(copy); throw Failure.changed }
            defer { closedir(directory) }
            rewinddir(directory)
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    guard errno == 0 else { throw Failure.changed }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard name == "." || name == ".." else { throw Failure.unsupported }
            }
        } else { throw Failure.unsupported }
    }

    private static func setPublicDownloadMark(at url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Traverse",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date()
        ]
        var target = URL(fileURLWithPath: url.path)
        try target.setResourceValues(values)
    }
}
