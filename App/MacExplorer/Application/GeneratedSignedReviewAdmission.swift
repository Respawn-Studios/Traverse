import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Filesystem mechanics shared by the two exact, nonshipping Release roles.
/// Each caller still validates its own phase, fixture and mutation ceilings.
enum GeneratedSignedReviewAdmission {
    static func ownedDirectory(_ url: URL, privateMode: Bool = false) -> Bool {
        var facts = stat()
        return lstat(url.path, &facts) == 0 && facts.st_mode & S_IFMT == S_IFDIR
            && facts.st_uid == geteuid() && (!privateMode || facts.st_mode & 0o077 == 0)
    }

    static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), String(integer) == number.stringValue else { return nil }
        return integer
    }

    private static func lowerHexDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func privateJSON(_ url: URL) -> ([String: Any], stat, Data)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o600,
              before.st_size >= 0, before.st_size <= 4096 else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4097)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0, data.count + count <= 4096 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (fields, after, data)
    }

    /// Read an exact role's bounded scope before its one-use consumption. The
    /// caller must bind these selected fields to that same consumed scope.
    static func privateFields(_ url: URL) -> [String: Any]? { privateJSON(url)?.0 }

    /// The host issues one attempt after sealing a signed artifact and exact
    /// scope. A failed launch consumes that attempt before AppKit is created.
    static func consume(caseID: String, bundleID: String, caseRoot: URL, phase: String,
                        prefix: String, packet: String,
                        scopeValid: ([String: Any]) -> Bool) -> Bool {
        let evidence = caseRoot.appendingPathComponent("evidence", isDirectory: true)
        guard ownedDirectory(evidence, privateMode: true) else { return false }
        let pending = evidence.appendingPathComponent(prefix + phase + "-permit.json")
        let consumed = evidence.appendingPathComponent(prefix + phase + "-consumed.json")
        guard let (fields, before, _) = privateJSON(pending),
              Set(fields.keys) == Set(["packet", "case", "phase", "bundleIdentifier", "caseRoot",
                                       "artifactTreeSHA256", "scopeSHA256", "expiresUTC", "attempt"]),
              fields["packet"] as? String == packet,
              fields["case"] as? String == caseID,
              fields["phase"] as? String == phase,
              fields["bundleIdentifier"] as? String == bundleID,
              fields["caseRoot"] as? String == caseRoot.path,
              exactInteger(fields["attempt"]) == 1,
              let artifactHash = fields["artifactTreeSHA256"] as? String,
              let scopeHash = fields["scopeSHA256"] as? String,
              lowerHexDigest(artifactHash), lowerHexDigest(scopeHash),
              let expires = fields["expiresUTC"] as? String,
              let deadline = ISO8601DateFormatter().date(from: expires), Date() <= deadline else { return false }
        let scopePath = evidence.appendingPathComponent("runtime-scope.json")
        guard let (scope, _, scopeData) = privateJSON(scopePath),
              SHA256.hash(data: scopeData).map({ String(format: "%02x", $0) }).joined() == scopeHash,
              scope["case"] as? String == caseID,
              scope["bundleIdentifier"] as? String == bundleID,
              scope["caseRoot"] as? String == caseRoot.path,
              scope["artifactTreeSHA256"] as? String == artifactHash,
              scope["expiresUTC"] as? String == expires,
              scopeValid(scope),
              link(pending.path, consumed.path) == 0 else { return false }
        var linked = stat()
        guard lstat(consumed.path, &linked) == 0,
              linked.st_dev == before.st_dev, linked.st_ino == before.st_ino,
              linked.st_nlink == 2, unlink(pending.path) == 0 else { return false }
        var final = stat()
        let directory = open(evidence.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if directory >= 0 { close(directory) } }
        return directory >= 0 && fsync(directory) == 0
            && lstat(consumed.path, &final) == 0
            && final.st_dev == before.st_dev && final.st_ino == before.st_ino
            && final.st_nlink == 1
    }
}
