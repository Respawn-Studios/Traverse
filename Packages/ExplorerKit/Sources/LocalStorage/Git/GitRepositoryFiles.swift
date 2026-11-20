import Darwin
import FileOperations
import Foundation

public struct GitObjectID: Hashable, Sendable {
    public let hex: String
    public var short: String { String(hex.prefix(10)) }

    public init?(_ text: String) {
        guard (text.utf8.count == 40 || text.utf8.count == 64), Self.isHex(text.utf8) else { return nil }
        hex = text
    }

    init(digest: some Sequence<UInt8>) {
        let digits = Array("0123456789abcdef".utf8)
        hex = String(decoding: digest.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    static func isHex(_ value: some Collection<UInt8>) -> Bool {
        !value.isEmpty && value.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    var isNull: Bool { hex.utf8.allSatisfy { $0 == 48 } }
}

public struct GitRevisionReference: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case branch, remoteTracking, tag }

    public var id: Data { Data(qualifiedName.utf8) }
    public let name: String
    public let kind: Kind
    public let object: GitObjectID
    let qualifiedName: String

    static func shortName(_ reference: String) -> (name: String, kind: Kind)? {
        let prefixes: [(String, Kind)] = [
            ("refs/heads/", .branch), ("refs/remotes/", .remoteTracking), ("refs/tags/", .tag)
        ]
        guard let (prefix, kind) = prefixes.first(where: { reference.hasPrefix($0.0) }),
              reference.utf8.count <= 512, !reference.contains(".."), !reference.contains("@{"),
              !reference.hasSuffix("."),
              reference.utf8.allSatisfy({ byte in
                  byte > 32 && byte != 127 && ![42, 58, 63, 91, 92, 94, 126].contains(byte)
              }) else { return nil }
        let short = String(reference.dropFirst(prefix.count))
        guard short.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }) else { return nil }
        return (short, kind)
    }

    init?(reference: String, object: GitObjectID) {
        guard let referenceName = Self.shortName(reference) else { return nil }
        self.name = referenceName.name
        self.kind = referenceName.kind
        self.object = object
        self.qualifiedName = reference
    }
}

/// Snapshot the local references as data. The repository's configuration,
/// attributes, hooks, remotes and alternates never enter the private Git view.
struct GitRepositoryFiles {
    private static let referenceLimit = 4_096
    let anchors: GitRepositoryAnchors
    var root: DirectoryAnchor { anchors.root }
    var metadata: DirectoryAnchor { anchors.metadata }
    var common: DirectoryAnchor { anchors.common }
    let objects: DirectoryAnchor
    let head: GitObjectID?
    let headName: String?
    let headRecord: Data
    let references: [GitRevisionReference]
    let shallow: Data?
    let hashLength: Int

    init(location: GitRepositoryLocation, check: () throws -> Void) throws {
        let anchors = try location.openAnchors(check: check)
        self.anchors = anchors
        let metadata = anchors.metadata
        let common = anchors.common
        guard let headBytes = try metadata.gitReadOptional("HEAD", maximum: 1_024, check: check) else {
            throw GitInspectionFailure.changed
        }
        headRecord = headBytes
        let objects = try common.gitDirectory("objects")
        guard try common.gitEntry("commondir") == nil, try common.gitEntry("reftable") == nil else {
            throw GitInspectionFailure.unsupportedRepository
        }
        var refs: [Data: GitRevisionReference] = [:]
        if let packed = try common.gitReadOptional("packed-refs", maximum: 4 << 20, check: check) {
            for line in packed.split(separator: 10) {
                try check()
                if line.first == 35 || line.first == 94 { continue }
                let fields = line.split(separator: 32, maxSplits: 1)
                guard fields.count == 2, let id = GitObjectID(String(decoding: fields[0], as: UTF8.self)),
                      let name = String(bytes: fields[1], encoding: .utf8) else { throw GitInspectionFailure.invalidOutput }
                if let ref = GitRevisionReference(reference: name, object: id) {
                    refs[Data(fields[1])] = ref
                    guard refs.count <= Self.referenceLimit else { throw GitInspectionFailure.limitExceeded }
                }
            }
        }
        if try common.gitEntry("refs") != nil {
            let directory = try common.gitDirectory("refs")
            var budget = Self.referenceLimit
            for area in ["heads", "remotes", "tags"] where try directory.gitEntry(area) != nil {
                try Self.readLoose(try directory.gitDirectory(area), prefix: "refs/\(area)/",
                                   depth: 0, budget: &budget, into: &refs, check: check)
            }
        }
        guard let headText = String(data: headBytes, encoding: .utf8) else { throw GitInspectionFailure.invalidOutput }
        let pointer = headText.trimmingCharacters(in: .newlines)
        if pointer.hasPrefix("ref: ") {
            let reference = String(pointer.dropFirst(5))
            head = refs[Data(reference.utf8)]?.object
            headName = refs[Data(reference.utf8)]?.name
        } else {
            guard let id = GitObjectID(pointer) else { throw GitInspectionFailure.invalidOutput }
            head = id
            headName = nil
        }
        references = refs.values.sorted { $0.qualifiedName.utf8.lexicographicallyPrecedes($1.qualifiedName.utf8) }
        let hashLength = head?.hex.utf8.count ?? references.first?.object.hex.utf8.count ?? 40
        guard references.allSatisfy({ $0.object.hex.utf8.count == hashLength }) else {
            throw GitInspectionFailure.unsupportedRepository
        }
        self.hashLength = hashLength
        let shallow = try common.gitReadOptional("shallow", maximum: 512 << 10, check: check)
        if let shallow {
            guard shallow.split(separator: 10).allSatisfy({ $0.count == hashLength && GitObjectID.isHex($0) }) else {
                throw GitInspectionFailure.invalidOutput
            }
        }
        self.shallow = shallow
        guard try metadata.gitReadOptional("HEAD", maximum: 1_024, check: check) == headBytes else {
            throw GitInspectionFailure.changed
        }
        try anchors.validate(check: check)
        self.objects = objects
    }

    private static func readLoose(_ directory: DirectoryAnchor, prefix: String, depth: Int, budget: inout Int,
                                  into results: inout [Data: GitRevisionReference], check: () throws -> Void) throws {
        guard depth < 24 else { throw GitInspectionFailure.limitExceeded }
        try directory.gitNames(check: check) { name in
            guard budget > 0 else { throw GitInspectionFailure.limitExceeded }
            budget -= 1
            guard !name.hasSuffix(".lock"), let observation = try directory.gitEntry(name) else { return }
            let qualified = prefix + name
            switch observation.st_mode & S_IFMT {
            case S_IFDIR:
                try readLoose(directory.gitDirectory(name), prefix: qualified + "/", depth: depth + 1,
                              budget: &budget, into: &results, check: check)
            case S_IFREG:
                guard let data = try directory.gitReadOptional(name, maximum: 1_024, check: check),
                      let text = String(data: data, encoding: .utf8) else { return }
                let value = text.trimmingCharacters(in: .newlines)
                if value.hasPrefix("ref: ") { return }
                guard let id = GitObjectID(value), let ref = GitRevisionReference(reference: qualified, object: id) else {
                    throw GitInspectionFailure.invalidOutput
                }
                results[Data(qualified.utf8)] = ref
                guard results.count <= referenceLimit else { throw GitInspectionFailure.limitExceeded }
            default:
                throw GitInspectionFailure.unsupportedRepository
            }
        }
    }
}

extension DirectoryAnchor {
    func gitEntry(_ name: String) throws -> stat? { try statGitEntry(fd, name) }

    func gitDirectory(_ name: String) throws -> DirectoryAnchor {
        guard let item = try gitEntry(name), item.st_mode & S_IFMT == S_IFDIR,
              item.st_uid == geteuid(), item.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else {
            throw GitInspectionFailure.unsupportedRepository
        }
        let child = try DirectoryAnchor(url.appendingPathComponent(name, isDirectory: true), resolve: false)
        guard try GitDirectoryIdentity(child.fd) == GitDirectoryIdentity(item),
              try GitDirectoryIdentity(fd).device == item.st_dev else { throw GitInspectionFailure.changed }
        return child
    }

    func gitReadOptional(_ name: String, maximum: Int, check: () throws -> Void) throws -> Data? {
        try check()
        guard let item = try gitEntry(name) else { return nil }
        guard item.st_mode & S_IFMT == S_IFREG, item.st_uid == geteuid(),
              item.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 else {
            throw GitInspectionFailure.unsupportedRepository
        }
        guard item.st_size >= 0, item.st_size <= maximum else { throw GitInspectionFailure.limitExceeded }
        let opened = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw GitInspectionFailure.unavailable }
        defer { close(opened) }
        let before = EntrySnapshot(item)
        guard try EntrySnapshot(fd: opened) == before else { throw GitInspectionFailure.changed }
        let bytes = try boundedRegularFileBytes(opened, maximumBytes: maximum, checkCancellation: check)
        guard let after = try gitEntry(name), EntrySnapshot(after) == before else { throw GitInspectionFailure.changed }
        return bytes
    }

    func gitNames(check: () throws -> Void, _ consume: (String) throws -> Void) throws {
        try visitGitNames(check: check) { name in try consume(name); return true }
    }

    func gitContainsExactName(_ name: String, check: () throws -> Void) throws -> Bool {
        var found = false
        var scanned = 0
        try visitGitNames(check: check) { entry in
            scanned += 1
            guard scanned <= 32_768 else { throw GitInspectionFailure.repositoryTooLarge }
            found = entry.utf8.elementsEqual(name.utf8)
            return !found
        }
        return found
    }

    private func visitGitNames(check: () throws -> Void, _ keepScanning: (String) throws -> Bool) throws {
        let reader = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard reader >= 0 else { throw GitInspectionFailure.unavailable }
        guard let directory = fdopendir(reader) else { close(reader); throw GitInspectionFailure.unavailable }
        defer { closedir(directory) }
        while true {
            try check()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw GitInspectionFailure.unavailable }
                return
            }
            let label: String? = withUnsafeBytes(of: &entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let label, !label.isEmpty else { throw GitInspectionFailure.unsupportedRepository }
            if label != ".", label != "..", try !keepScanning(label) { return }
        }
    }
}
