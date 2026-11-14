import CoreServices
import Darwin
import Foundation

enum DownloadQuarantineFailure: Error, Equatable { case unsafe, changed, unavailable }

/// New empty private APFS output only. Never remove or replace an existing
/// mark. No source address/account/path is supplied to quarantine.
enum DownloadedFileQuarantine {
    /// This generated signed-sandbox v7 probe requires the observed native
    /// execution-protecting mark before any publication attempt. No caller
    /// receives the mark bytes or an authority to rewrite them.
    static func hasExpectedV7NativeMark(_ descriptor: Int32) throws -> Bool {
        guard let bytes = try raw(descriptor) else { throw DownloadQuarantineFailure.changed }
        return bytes.starts(with: Data("0086;".utf8))
    }

    struct Witness: Sendable {
        fileprivate let device: dev_t, inode: ino_t, birth: timespec, bytes: Data
        func validate(_ descriptor: Int32) throws {
            var facts = stat()
            guard fstat(descriptor, &facts) == 0, facts.st_dev == device, facts.st_ino == inode,
                  facts.st_birthtimespec.tv_sec == birth.tv_sec, facts.st_birthtimespec.tv_nsec == birth.tv_nsec,
                  facts.st_mode & S_IFMT == S_IFREG, facts.st_nlink == 1, facts.st_uid == geteuid(),
                  try DownloadedFileQuarantine.raw(descriptor) == bytes else { throw DownloadQuarantineFailure.changed }
        }
    }
    static func markEmptyFile(_ descriptor: Int32, at url: URL) throws -> Witness {
        let facts = try inspectEmptyFile(descriptor, at: url)
        try requireLinked(descriptor, url: url)
        guard try raw(descriptor) == nil,
              try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties == nil else {
            throw DownloadQuarantineFailure.unsafe
        }
        var properties = URLResourceValues()
        properties.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Mac Explorer",
            kLSQuarantineAgentBundleIdentifierKey as String: "local.macexplorer.development",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date()
        ]
        var destination = URL(fileURLWithPath: url.path)
        do { try destination.setResourceValues(properties) } catch { throw DownloadQuarantineFailure.unavailable }
        try requireLinked(descriptor, url: url)
        guard let bytes = try raw(descriptor), !bytes.isEmpty,
              let observed = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties,
              observed[kLSQuarantineAgentNameKey as String] as? String == "Mac Explorer",
              observed[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeOtherDownload as String,
              observed[kLSQuarantineTimeStampKey as String] is Date else { throw DownloadQuarantineFailure.unavailable }
        let witness = Witness(device: facts.st_dev, inode: facts.st_ino, birth: facts.st_birthtimespec, bytes: bytes)
        try witness.validate(descriptor); return witness
    }
    /// Only the spool constructor calls this immediately after exclusive
    /// creation. A sandbox may already have marked that new empty file; accept
    /// only the exact observed native profile without rewriting its bytes.
    static func markFreshSpoolFile(_ descriptor: Int32, at url: URL) throws -> Witness {
        let facts = try inspectEmptyFile(descriptor, at: url)
        try requireLinked(descriptor, url: url)
        let before = try raw(descriptor)
        let properties = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        guard let before else {
            guard properties == nil else { throw DownloadQuarantineFailure.unsafe }
            return try markEmptyFile(descriptor, at: url)
        }
        guard let properties, isOwnedNativeSandboxMark(properties) else { throw DownloadQuarantineFailure.unsafe }
        try requireLinked(descriptor, url: url)
        let current = try inspectEmptyFile(descriptor, at: url)
        guard current.st_dev == facts.st_dev, current.st_ino == facts.st_ino,
              current.st_birthtimespec.tv_sec == facts.st_birthtimespec.tv_sec,
              current.st_birthtimespec.tv_nsec == facts.st_birthtimespec.tv_nsec,
              try raw(descriptor) == before else { throw DownloadQuarantineFailure.changed }
        let witness = Witness(device: facts.st_dev, inode: facts.st_ino, birth: facts.st_birthtimespec, bytes: before)
        try witness.validate(descriptor); return witness
    }
    private static func isOwnedNativeSandboxMark(_ properties: [String: Any]) -> Bool {
        isOwnedNativeSandboxMark(properties, creatorName: creatorName(), executableName: executableName())
    }
    static func isOwnedNativeSandboxMark(_ properties: [String: Any], creatorName: String?, executableName: String?) -> Bool {
        let agent = kLSQuarantineAgentNameKey as String
        let bundle = kLSQuarantineAgentBundleIdentifierKey as String
        let timestamp = kLSQuarantineTimeStampKey as String
        let type = kLSQuarantineTypeKey as String
        let ownership = "LSQuarantineIsOwnedByCurrentUser"
        let required: Set<String> = [agent, timestamp, type, ownership]
        let keys = Set(properties.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union([bundle])),
              let expectedName = creatorName, let observedName = properties[agent] as? String,
              observedName == expectedName || executableName.map({ $0 == observedName }) == true,
              properties[ownership] as? Bool == true,
              let date = properties[timestamp] as? Date, date.timeIntervalSinceReferenceDate.isFinite,
              properties[type] as? String == "LSQuarantineTypeSandboxed" else { return false }
        if let suppliedBundle = properties[bundle] {
            guard let expectedBundle = Bundle.main.bundleIdentifier,
                  suppliedBundle as? String == expectedBundle else { return false }
        }
        return true
    }
    private static func executableName() -> String? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !name.isEmpty, name.utf8.count <= 128, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    private static func creatorName() -> String? {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.processName
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    private static func inspectEmptyFile(_ descriptor: Int32, at url: URL) throws -> stat {
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
              url == url.standardizedFileURL else { throw DownloadQuarantineFailure.unsafe }
        var facts = stat(), volume = statfs()
        guard fstat(descriptor, &facts) == 0, facts.st_uid == geteuid(), facts.st_nlink == 1, facts.st_size == 0,
              facts.st_mode & S_IFMT == S_IFREG, facts.st_mode & 0o7777 == 0o600, fstatfs(descriptor, &volume) == 0,
              volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw DownloadQuarantineFailure.unsafe }
        let filesystem = withUnsafePointer(to: &volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard filesystem == "apfs" else { throw DownloadQuarantineFailure.unsafe }
        return facts
    }
    private static func requireLinked(_ descriptor: Int32, url: URL) throws {
        let current = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard current >= 0 else { throw DownloadQuarantineFailure.changed }; defer { Darwin.close(current) }
        var pinned = stat(), named = stat()
        guard fstat(descriptor, &pinned) == 0, fstat(current, &named) == 0, named.st_nlink == 1,
              named.st_uid == geteuid(), pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino,
              pinned.st_birthtimespec.tv_sec == named.st_birthtimespec.tv_sec,
              pinned.st_birthtimespec.tv_nsec == named.st_birthtimespec.tv_nsec else { throw DownloadQuarantineFailure.changed }
    }
    private static func raw(_ descriptor: Int32) throws -> Data? {
        let count = fgetxattr(descriptor, "com.apple.quarantine", nil, 0, 0, 0)
        if count < 0, errno == ENOATTR { return nil }
        guard count > 0, count <= 4096 else { throw DownloadQuarantineFailure.unavailable }
        var data = Data(count: count)
        guard data.withUnsafeMutableBytes({ fgetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, count, 0, 0) }) == count else {
            throw DownloadQuarantineFailure.unavailable
        }
        return data
    }
}
