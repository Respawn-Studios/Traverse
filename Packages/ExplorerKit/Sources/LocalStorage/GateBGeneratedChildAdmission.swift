#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

// BEGIN GATEB_KNOWN_FOUNDATION_METADATA_VALIDATOR_V1
/// Pure key-set classification. This narrow compatibility result is only one
/// witness; it never bypasses case, image, root, parent, birth or deadline checks.
enum GateBKnownFoundationMetadataKeySet {
    enum Decision: Equatable {
        case exact, knownMetadata, missingRequired, invalidExtra
    }
    private static let metadataKey = "__CF_USER_TEXT_ENCODING"
    private static let prefix = "TRAVERSE_GATEB_CHILD_"
    static let required: Set<String> = Set([
        "CASE", "ROOT_DEVICE", "ROOT_INODE", "ROOT_UID",
        "PARENT_PID", "PARENT_BIRTH_SECONDS", "PARENT_BIRTH_MICROSECONDS",
        "IMAGE_SHA256", "DEADLINE_UPTIME_MICROS"
    ].map { prefix + $0 }).union(["LANG", "LC_ALL", "MAC_EXPLORER_TEST_ROOT"])

    private static func unsigned32(_ field: Substring) -> UInt32? {
        let bytes = Array(field.utf8)
        if bytes.count >= 3, bytes[0] == 48, bytes[1] == 120 {
            let digits = bytes.dropFirst(2)
            guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { return nil }
            return UInt32(String(decoding: digits, as: UTF8.self), radix: 16)
        }
        guard !bytes.isEmpty, bytes.count <= 10,
              bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt32(String(decoding: bytes, as: UTF8.self), radix: 10)
    }

    static func classify(_ environment: [String: String],
                         realUID: UInt32, effectiveUID: UInt32) -> Decision {
        let observed = Set(environment.keys)
        guard required.isSubset(of: observed) else { return .missingRequired }
        let extras = observed.subtracting(required)
        if extras.isEmpty { return .exact }
        guard extras.count == 1, extras.contains(metadataKey),
              let value = environment[metadataKey], value.utf8.count <= 64 else {
            return .invalidExtra
        }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let uid = unsigned32(fields[0]),
              unsigned32(fields[1]) != nil,
              unsigned32(fields[2]) != nil,
              uid == realUID, uid == effectiveUID else { return .invalidExtra }
        return .knownMetadata
    }
}
// END GATEB_KNOWN_FOUNDATION_METADATA_VALIDATOR_V1

/// Source-only contract. Main creates a private admission marker after it has
/// reviewed the exact signed image and case. Parent environment is a witness
/// to cross-check; it cannot itself grant a child permission to run a probe.
enum GateBGeneratedChildAdmission {
    private static let master = "887B77DA-8583-42B1-9055-32B91A60641F"
    private static let action = "gateb-application-runtime-v1"
    private static let schema = "traverse-gateb-child-admission-v1"
    private static let maxBytes: UInt64 = 64 << 20
    private static let maxEntries = 1024
    private static let envPrefix = "TRAVERSE_GATEB_CHILD_"
    struct ParentWitness: Sendable {
        let image: URL, sha256: String
        let environment: [String: String]
        let deadline: TimeInterval
    }
    private static let keys: Set<String> = [
        "format", "caseUUID", "runtimeApproved", "reviewedExecutablePath",
        "reviewedExecutableSHA256", "rootDevice", "rootInode", "rootUID",
        "rootMode", "maximumLogicalBytes", "maximumAllocatedBytes",
        "maximumEntries", "maximumSeconds", "maximumRSSMiB",
        "maximumPinChildSeconds", "maximumRemoveChildSeconds"
    ]
    private static func fail(_ stage: String) -> GateBGeneratedFailure {
        GateBGeneratedFailure(stage: stage)
    }
    private static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
            && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
            && a.st_size == b.st_size && a.st_blocks == b.st_blocks
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func number(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.int64Value >= 0,
              value.stringValue == String(value.uint64Value) else { return nil }
        return value.uint64Value
    }
    private static func read(_ parent: Int32, _ name: String) throws -> Data {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(),
              named.st_mode & 0o7777 == 0o600, named.st_nlink == 1,
              named.st_size > 0, named.st_size <= 16 << 10 else {
            throw fail("child-admission-marker-kind")
        }
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail("child-admission-marker-open") }
        defer { Darwin.close(fd) }
        var opened = stat(), after = stat(), current = stat()
        guard fstat(fd, &opened) == 0, stable(named, opened) else {
            throw fail("child-admission-marker-replaced")
        }
        var bytes = Data(count: Int(opened.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw fail("child-admission-marker-read") }
            offset += count
        }
        guard fstat(fd, &after) == 0,
              fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              stable(opened, after), stable(after, current) else {
            throw fail("child-admission-marker-changed")
        }
        return bytes
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw fail("child-admission-json")
        }
        return value
    }
    private static func digestImage(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw fail("child-image-open") }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 192 << 20,
              before.st_mode & 0o7777 == 0o755 else {
            throw fail("child-image-kind-or-bound")
        }
        var value = SHA256(), offset: off_t = 0
        while offset < before.st_size {
            var buffer = Data(count: min(1 << 20, Int(before.st_size - offset)))
            let count = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress, $0.count, offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw fail("child-image-read") }
            value.update(data: buffer.prefix(count))
            offset += off_t(count)
        }
        guard fstat(fd, &after) == 0, stable(before, after) else {
            throw fail("child-image-changed")
        }
        return value.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func boundedCase(_ root: Int32, _ device: dev_t) throws {
        var entries = 0, logical: UInt64 = 0, allocated: UInt64 = 0
        func visit(_ parent: Int32) throws {
            for name in try DownloadDisk.names(parent, maximum: maxEntries) {
                var named = stat()
                guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_uid == geteuid(), named.st_dev == device,
                      named.st_size >= 0, named.st_blocks >= 0,
                      named.st_mode & 0o022 == 0 else {
                    throw fail("child-case-entry-unsafe")
                }
                entries += 1
                let size = UInt64(named.st_size), blocks = UInt64(named.st_blocks) * 512
                guard entries <= maxEntries, size <= maxBytes, blocks <= maxBytes,
                      logical <= maxBytes - size, allocated <= maxBytes - blocks else {
                    throw fail("child-case-resource-limit")
                }
                logical += size; allocated += blocks
                if named.st_mode & S_IFMT == S_IFDIR {
                    guard named.st_mode & 0o7777 == 0o700 else {
                        throw fail("child-case-directory-mode")
                    }
                    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw fail("child-case-directory-open") }
                    defer { Darwin.close(fd) }
                    var opened = stat(), after = stat(), current = stat()
                    guard fstat(fd, &opened) == 0, stable(named, opened) else {
                        throw fail("child-case-directory-replaced")
                    }
                    try visit(fd)
                    guard fstat(fd, &after) == 0,
                          fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          stable(opened, after), stable(after, current) else {
                        throw fail("child-case-directory-changed")
                    }
                } else {
                    guard named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else {
                        throw fail("child-case-link-or-special")
                    }
                }
            }
        }
        try visit(root)
    }
    private static func caseRoot(_ caseID: UUID) throws -> (URL, stat, [String: Any]) {
        guard let base = LocalStorageGeneratedCheckoutOrigin.developmentCases else { throw fail("child-case-path") }
        let root = base.appendingPathComponent(caseID.uuidString, isDirectory: true)
        guard root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == base else { throw fail("child-case-path") }
        var named = stat(), opened = stat()
        guard lstat(root.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFDIR,
              named.st_uid == geteuid(), named.st_mode & 0o7777 == 0o700 else {
            throw fail("child-case-root-kind")
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw fail("child-case-root-open") }
        defer { Darwin.close(fd) }
        guard fstat(fd, &opened) == 0, stable(named, opened) else {
            throw fail("child-case-root-replaced")
        }
        let reservation = try object(read(fd, "reservation.json"))
        let marker = try object(read(fd, "gateb-admission.json"))
        guard reservation["packet"] as? String == "traverse-development-v1",
              reservation["action"] as? String == action,
              reservation["master"] as? String == master,
              Set(marker.keys) == keys,
              marker["format"] as? String == schema,
              marker["caseUUID"] as? String == caseID.uuidString,
              let approved = marker["runtimeApproved"] as? NSNumber,
              CFGetTypeID(approved) == CFBooleanGetTypeID(),
              approved.boolValue,
              number(marker["rootDevice"]) == UInt64(truncatingIfNeeded: opened.st_dev),
              number(marker["rootInode"]) == UInt64(opened.st_ino),
              number(marker["rootUID"]) == UInt64(geteuid()),
              number(marker["rootMode"]) == 0o700,
              number(marker["maximumLogicalBytes"]) == maxBytes,
              number(marker["maximumAllocatedBytes"]) == maxBytes,
              number(marker["maximumEntries"]) == UInt64(maxEntries),
              number(marker["maximumSeconds"]) == 120,
              number(marker["maximumRSSMiB"]) == 384,
              number(marker["maximumPinChildSeconds"]) == 5,
              number(marker["maximumRemoveChildSeconds"]) == 12 else {
            throw fail("child-case-admission-fields")
        }
        try boundedCase(fd, opened.st_dev)
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(root.path, &current) == 0,
              stable(opened, after), stable(after, current) else {
            throw fail("child-case-root-changed")
        }
        return (root, opened, marker)
    }
    static func parentEnvironment(root: URL, maximumSeconds: Int) throws -> ParentWitness {
        guard let base = LocalStorageGeneratedCheckoutOrigin.developmentCases else { throw fail("child-parent-image-or-case") }
        guard let id = UUID(uuidString: root.lastPathComponent),
              id.uuidString == root.lastPathComponent,
              [5, 12, 60].contains(maximumSeconds) else { throw fail("child-parent-input") }
        let (exact, facts, marker) = try caseRoot(id)
        guard exact == root, let reviewedExecutable = Bundle.main.executableURL,
              reviewedExecutable.isFileURL,
              let sha256 = marker["reviewedExecutableSHA256"] as? String,
              marker["reviewedExecutablePath"] as? String == reviewedExecutable.path,
              reviewedExecutable.path.hasPrefix(base.path + "/"),
              reviewedExecutable.resolvingSymlinksInPath() == reviewedExecutable,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              try digestImage(reviewedExecutable) == sha256,
              let owner = GateBObservedChild.current(getpid()),
              owner.uid == geteuid(), owner.executable == reviewedExecutable.path else {
            throw fail("child-parent-image-or-case")
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= 0, now < Double(UInt64.max / 1_000_000) - Double(maximumSeconds) else {
            throw fail("child-parent-clock")
        }
        let deadline = UInt64((now + Double(maximumSeconds)) * 1_000_000)
        let environment = ["LANG": "C", "LC_ALL": "C", "MAC_EXPLORER_TEST_ROOT": root.path,
                envPrefix + "CASE": id.uuidString,
                envPrefix + "ROOT_DEVICE": String(UInt64(truncatingIfNeeded: facts.st_dev)),
                envPrefix + "ROOT_INODE": String(UInt64(facts.st_ino)),
                envPrefix + "ROOT_UID": String(geteuid()),
                envPrefix + "PARENT_PID": String(owner.pid),
                envPrefix + "PARENT_BIRTH_SECONDS": String(owner.birthSeconds),
                envPrefix + "PARENT_BIRTH_MICROSECONDS": String(owner.birthMicroseconds),
                envPrefix + "IMAGE_SHA256": sha256,
                envPrefix + "DEADLINE_UPTIME_MICROS": String(deadline)]
        return ParentWitness(image: reviewedExecutable, sha256: sha256,
            environment: environment, deadline: Double(deadline) / 1_000_000)
    }
    /// An independent child waits before its private admission work so the
    /// parent can capture its exact PID/birth/path before releasing one byte.
    /// This is a bounded local pipe handshake, not a source of authority.
    static func awaitParentRelease() throws {
        let until = ProcessInfo.processInfo.systemUptime + 1.5
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw fail("child-parent-release-pipe")
        }
        while ProcessInfo.processInfo.systemUptime < until {
            var ready = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&ready, 1, 20)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw fail("child-parent-release-poll") }
            if result == 0 { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count == 1, byte == 0xA5 else { throw fail("child-parent-release-byte") }
            return
        }
        throw fail("child-parent-release-expired")
    }

    static func requireChild(caseID: UUID, maximumSeconds: Int) throws
        -> (root: URL, facts: stat, deadline: TimeInterval) {
        guard let base = LocalStorageGeneratedCheckoutOrigin.developmentCases else { throw fail("child-reviewed-image-root-or-parent") }
        let env = ProcessInfo.processInfo.environment
        // The same pure classifier is compiled by the generated controls.
        // Every non-key-set witness below remains a separate closed guard.
        switch GateBKnownFoundationMetadataKeySet.classify(env,
                realUID: UInt32(getuid()), effectiveUID: UInt32(geteuid())) {
        case .missingRequired: throw fail("child-parent-required-key-missing")
        case .invalidExtra: throw fail("child-parent-extra-key")
        case .exact, .knownMetadata: break
        }
        guard env["LANG"] == "C", env["LC_ALL"] == "C" else {
            throw fail("child-parent-locale")
        }
        guard env[envPrefix + "CASE"] == caseID.uuidString else {
            throw fail("child-parent-case")
        }
        guard let device = env[envPrefix + "ROOT_DEVICE"].flatMap(UInt64.init),
              let inode = env[envPrefix + "ROOT_INODE"].flatMap(UInt64.init),
              let uid = env[envPrefix + "ROOT_UID"].flatMap(UInt64.init),
              let parentPID = env[envPrefix + "PARENT_PID"].flatMap(Int32.init),
              let birthSeconds = env[envPrefix + "PARENT_BIRTH_SECONDS"].flatMap(UInt64.init),
              let birthMicroseconds = env[envPrefix + "PARENT_BIRTH_MICROSECONDS"].flatMap(UInt64.init),
              let imageHash = env[envPrefix + "IMAGE_SHA256"],
              let deadline = env[envPrefix + "DEADLINE_UPTIME_MICROS"].flatMap(UInt64.init) else {
            throw fail("child-parent-numeric-parse")
        }
        guard [5, 12, 60].contains(maximumSeconds) else { throw fail("child-parent-duration") }
        guard parentPID > 1, getppid() == parentPID,
              uid == UInt64(geteuid()) else { throw fail("child-parent-identity") }
        guard birthMicroseconds < 1_000_000 else { throw fail("child-parent-birth-range") }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= 0, now < Double(UInt64.max / 1_000_000),
              UInt64(now * 1_000_000) < deadline,
              deadline <= UInt64((now + Double(maximumSeconds)) * 1_000_000) else {
            throw fail("child-deadline-expired-or-extended")
        }
        let (root, facts, marker) = try caseRoot(caseID)
        guard env["MAC_EXPLORER_TEST_ROOT"] == root.path,
              device == UInt64(truncatingIfNeeded: facts.st_dev),
              inode == UInt64(facts.st_ino), uid == UInt64(facts.st_uid),
              let image = Bundle.main.executableURL, image.isFileURL,
              marker["reviewedExecutablePath"] as? String == image.path,
              marker["reviewedExecutableSHA256"] as? String == imageHash,
              image.path.hasPrefix(base.path + "/"),
              image.resolvingSymlinksInPath() == image,
              try digestImage(image) == imageHash,
              let selfImage = GateBObservedChild.current(getpid()),
              selfImage.uid == geteuid(), selfImage.executable == image.path,
              let parent = GateBObservedChild.current(parentPID),
              parent.uid == geteuid(), parent.executable == image.path,
              parent.birthSeconds == birthSeconds,
              parent.birthMicroseconds == birthMicroseconds else {
            throw fail("child-reviewed-image-root-or-parent")
        }
        guard ProcessInfo.processInfo.systemUptime * 1_000_000 < Double(deadline) else {
            throw fail("child-admission-work-expired")
        }
        return (root, facts, Double(deadline) / 1_000_000)
    }
}
#endif
