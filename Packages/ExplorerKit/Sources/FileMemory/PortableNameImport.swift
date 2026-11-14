import Darwin
import ExplorerCore
import Foundation
import LocalStorage

public enum NameImportFailure: Error, Sendable, Equatable {
    case invalidDocument, unsupportedVersion, tooLarge, quota, stalePreview, cancelled
    case inaccessibleFile, changedFile, unsupportedFile, storageUnavailable
}
internal enum NameImportBoundary: String, Sendable {
    case readOpened, readComplete, parsed, rows, beforeCommit, commitAdmitted, committed, acknowledged
}
internal typealias NameImportProbe = @Sendable (NameImportBoundary) throws -> Void
internal struct NameImportPayload: Sendable {
    let names: [AuthoredNames]
    let sourceIDs: [UUID]
    let encodedBytes: Int
    let locationCount: Int
    var repeatedDescriptions = 0
    var matchingDescriptions = 0
    var matchingSourceIDs = 0
}

/// Only this deliberately selected metadata document is read. None of its path
/// strings enter a native reader, bookmark API or filesystem operation.
internal enum PortableNameInput {
    static let maximumBytes = PreparedNameExport.maximumBytes
    static func read(_ url: URL, cancellation: RememberedNameCancellation,
                     current: @escaping () throws -> Void, probe: NameImportProbe?) throws -> NameImportPayload {
        try current(); try check(cancellation)
        guard url.isFileURL, url.path == url.standardizedFileURL.path, !url.path.utf8.contains(0),
              url.pathExtension.lowercased() == "json", !AutomaticMetadataPolicy.excludes(url),
              !url.pathComponents.contains(where: { ["CloudStorage", "Mobile Documents", "FileProvider", ".Trash", ".Trashes"].contains($0)
                  || $0.hasSuffix(".icloud") || $0.lowercased().hasPrefix(".mac-explorer-recovery-") }) else { throw NameImportFailure.unsupportedFile }
        let metadata = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard metadata.isUbiquitousItem != true else { throw NameImportFailure.unsupportedFile }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw NameImportFailure.inaccessibleFile }; defer { close(fd) }
        var before = stat(), fs = statfs()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NameImportFailure.unsupportedFile }
        let kind = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        guard kind == "apfs" else { throw NameImportFailure.unsupportedFile }
        guard (2...maximumBytes).contains(Int(before.st_size)) else { throw NameImportFailure.tooLarge }
        try probe?(.readOpened)
        var data = Data(); data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try current(); try check(cancellation)
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes - data.count + 1))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw NameImportFailure.inaccessibleFile }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw NameImportFailure.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        try probe?(.readComplete)
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              stamp(before) == stamp(after), stamp(named) == stamp(after), data.count == before.st_size else { throw NameImportFailure.changedFile }
        let fresh = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fresh >= 0 else { throw NameImportFailure.changedFile }; defer { close(fresh) }
        var reopened = stat()
        guard fstat(fresh, &reopened) == 0, stamp(reopened) == stamp(before) else { throw NameImportFailure.changedFile }
        let value = try decode(data, cancellation: cancellation, current: current)
        try current(); try check(cancellation); try probe?(.parsed); return value
    }
    private static func stamp(_ s: stat) -> [Int64] {
        [Int64(s.st_dev), Int64(bitPattern: s.st_ino), Int64(s.st_gen), s.st_size,
         Int64(s.st_mode), Int64(s.st_nlink), Int64(s.st_mtimespec.tv_sec), Int64(s.st_mtimespec.tv_nsec),
         Int64(s.st_ctimespec.tv_sec), Int64(s.st_ctimespec.tv_nsec), Int64(s.st_birthtimespec.tv_sec), Int64(s.st_birthtimespec.tv_nsec)]
    }
    static func check(_ cancellation: RememberedNameCancellation) throws {
        guard !cancellation.isCancelled else { throw NameImportFailure.cancelled }
    }
    static func decode(_ data: Data, cancellation: RememberedNameCancellation = .init(), current: @escaping () throws -> Void = {}) throws -> NameImportPayload {
        guard data.count <= maximumBytes else { throw NameImportFailure.tooLarge }
        do {
            var syntax = StrictNameJSON(bytes: Array(data), cancellation: cancellation, current: current)
            try syntax.validate()
            let document = try JSONDecoder().decode(ImportDocument.self, from: data)
            guard document.format == "MacExplorer.PrivateNames", document.version == 1 else { throw NameImportFailure.unsupportedVersion }
            guard (1...NameStoreFormat.maximumRecords).contains(document.records.count) else { throw NameImportFailure.quota }
            var seen = Set<UUID>(), names: [AuthoredNames] = [], ids: [UUID] = [], locations = 0, keys = 0
            names.reserveCapacity(document.records.count); ids.reserveCapacity(document.records.count)
            for row in document.records {
                try check(cancellation); try current()
                guard let id = UUID(uuidString: row.id), id.uuidString == row.id, seen.insert(id).inserted else { throw NameImportFailure.invalidDocument }
                if row.hasLocation {
                    guard document.includesLocations else { throw NameImportFailure.invalidDocument }
                    if let path = row.lastKnownLocation {
                        guard path.hasPrefix("/"), path.utf8.count <= 8_192, !path.utf8.contains(0),
                              URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw NameImportFailure.invalidDocument }
                        locations += 1
                    }
                }
                let value = try AuthoredNames(nickname: row.nickname, alternateNames: row.alternateNames, labels: row.labels)
                guard value.nickname == row.nickname, value.alternateNames == row.alternateNames, value.labels == row.labels else { throw NameImportFailure.invalidDocument }
                for field in try NameProjection.fields(value) { keys += 4 + 2 * (field.literalWords.count + field.tolerantWords.count) }
                guard keys <= 4_000_000 else { throw NameImportFailure.quota }
                names.append(value); ids.append(id)
            }
            return NameImportPayload(names: names, sourceIDs: ids, encodedBytes: data.count, locationCount: locations)
        } catch let failure as NameImportFailure { throw failure }
        catch { throw NameImportFailure.invalidDocument }
    }
}

private struct ImportKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
private struct ImportDocument: Decodable {
    let format: String, version: Int, includesLocations: Bool, records: [ImportRecord]
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ImportKey.self)
        guard Set(c.allKeys.map(\.stringValue)) == ["format", "version", "includesLocations", "records"] else { throw NameImportFailure.invalidDocument }
        format = try c.decode(String.self, forKey: .init("format")); version = try c.decode(Int.self, forKey: .init("version"))
        includesLocations = try c.decode(Bool.self, forKey: .init("includesLocations")); records = try c.decode([ImportRecord].self, forKey: .init("records"))
    }
}
private struct ImportRecord: Decodable {
    let id: String, nickname: String?, alternateNames: [String], labels: [String], lastKnownLocation: String?
    let hasLocation: Bool
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: ImportKey.self), keys = Set(c.allKeys.map(\.stringValue))
        guard keys.isSubset(of: ["id", "nickname", "alternateNames", "labels", "lastKnownLocation"]),
              Set(["id", "alternateNames", "labels"]).isSubset(of: keys) else { throw NameImportFailure.invalidDocument }
        id = try c.decode(String.self, forKey: .init("id")); nickname = try c.decodeIfPresent(String.self, forKey: .init("nickname"))
        alternateNames = try c.decode([String].self, forKey: .init("alternateNames")); labels = try c.decode([String].self, forKey: .init("labels"))
        hasLocation = keys.contains("lastKnownLocation"); lastKnownLocation = try c.decodeIfPresent(String.self, forKey: .init("lastKnownLocation"))
    }
}

/// Bounded syntax/duplicate-key guard. Portable field names are literal ASCII;
/// escaped field-name spellings are refused rather than allowed to alias keys.
/// Foundation still validates Unicode escapes, numbers and decoded value types.
private struct StrictNameJSON {
    let bytes: [UInt8], cancellation: RememberedNameCancellation, current: () throws -> Void
    var i = 0, nodes = 0
    mutating func validate() throws { try value(depth: 0); whitespace(); guard i == bytes.count else { throw NameImportFailure.invalidDocument } }
    mutating func whitespace() { while i < bytes.count, [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
    mutating func value(depth: Int) throws {
        nodes += 1
        guard nodes <= 4_000_000, depth <= 8 else { throw NameImportFailure.quota }
        if nodes % 128 == 0 { try current(); try PortableNameInput.check(cancellation) }
        whitespace(); guard i < bytes.count else { throw NameImportFailure.invalidDocument }
        switch bytes[i] {
        case 123:
            i += 1; whitespace(); var keys = Set<String>()
            if take(125) { return }
            while true {
                whitespace(); let key = try string(key: true)
                guard keys.insert(key).inserted, keys.count <= 8 else { throw NameImportFailure.invalidDocument }
                whitespace(); guard take(58) else { throw NameImportFailure.invalidDocument }
                if depth == 0, key == "version" { whitespace(); guard i < bytes.count, bytes[i] == 49,
                    i + 1 == bytes.count || [9, 10, 13, 32, 44, 125].contains(bytes[i + 1]) else { throw NameImportFailure.unsupportedVersion } }
                try value(depth: depth + 1); whitespace()
                if take(125) { return }; guard take(44) else { throw NameImportFailure.invalidDocument }
            }
        case 91:
            i += 1; whitespace(); if take(93) { return }
            while true { try value(depth: depth + 1); whitespace(); if take(93) { return }; guard take(44) else { throw NameImportFailure.invalidDocument } }
        case 34: _ = try string(key: false)
        default:
            let start = i
            while i < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 }
            guard (1...32).contains(i - start) else { throw NameImportFailure.invalidDocument }
        }
    }
    mutating func take(_ byte: UInt8) -> Bool { if i < bytes.count, bytes[i] == byte { i += 1; return true }; return false }
    mutating func string(key: Bool) throws -> String {
        guard take(34) else { throw NameImportFailure.invalidDocument }; let start = i
        while i < bytes.count {
            let b = bytes[i]
            if b == 34 {
                let end = i; i += 1
                if key { guard end - start <= 32 else { throw NameImportFailure.invalidDocument }; return String(decoding: bytes[start..<end], as: UTF8.self) }
                return ""
            }
            guard b >= 32, !key || b < 128 && b != 92 else { throw NameImportFailure.invalidDocument }
            if b == 92 {
                i += 1; guard i < bytes.count else { throw NameImportFailure.invalidDocument }
                if bytes[i] == 117 { guard i + 4 < bytes.count else { throw NameImportFailure.invalidDocument }; i += 4 }
            }
            i += 1
            guard i - start <= 65_536 else { throw NameImportFailure.tooLarge }
        }
        throw NameImportFailure.invalidDocument
    }
}
