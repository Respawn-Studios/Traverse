import CryptoKit
import Foundation
import SQLite3

internal enum NameImportDuplicates {
    static func digest(_ names: AuthoredNames) -> Data {
        var data = Data()
        func append(_ value: String) {
            var count = UInt32(value.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(contentsOf: value.utf8)
        }
        data.append(names.nickname == nil ? 0 : 1); if let nickname = names.nickname { append(nickname) }
        data.append(UInt8(names.alternateNames.count)); names.alternateNames.forEach(append)
        data.append(UInt8(names.labels.count)); names.labels.forEach(append)
        return Data(SHA256.hash(data: data))
    }
    static func within(_ payload: inout NameImportPayload, cancellation: RememberedNameCancellation) throws {
        var seen: [Data: [Int]] = [:]
        for (index, names) in payload.names.enumerated() {
            try PortableNameInput.check(cancellation)
            let digest = digest(names)
            if seen[digest, default: []].contains(where: { payload.names[$0] == names }) { payload.repeatedDescriptions += 1 }
            else { seen[digest, default: []].append(index) }
        }
    }
}
extension NameIndexDatabase {
    func importPresence(nonce: UUID) throws -> Int {
        let row = try prepare("SELECT count(*) FROM records WHERE nonce=? AND revision=1 AND hidden=0")
        defer { sqlite3_finalize(row) }; try bind(nonce.uuidString, to: row, at: 1)
        guard try step(row) else { throw NameStoreFailure.unsafe }; return try integer(row, column: 0)
    }
    func importDuplicates(_ payload: inout NameImportPayload, cancellation: RememberedNameCancellation,
                          current: () throws -> Void) throws {
        try NameImportDuplicates.within(&payload, cancellation: cancellation)
        var candidates: [Data: [RememberedItemID]] = [:]
        let rows = try prepare("SELECT id FROM records WHERE hidden=0 ORDER BY record")
        defer { sqlite3_finalize(rows) }; var observed = 0
        while try step(rows) {
            try current(); try PortableNameInput.check(cancellation); observed += 1
            guard observed <= NameStoreFormat.maximumRecords, let uuid = UUID(uuidString: try text(rows, column: 0)) else { throw NameStoreFailure.unsafe }
            let id = RememberedItemID(uuid), names = try snapshot(id).names
            candidates[NameImportDuplicates.digest(names), default: []].append(id)
        }
        var comparisons = 0
        for (index, names) in payload.names.enumerated() {
            try current(); try PortableNameInput.check(cancellation)
            if try revision(RememberedItemID(payload.sourceIDs[index])) != nil { payload.matchingSourceIDs += 1 }
            for id in candidates[NameImportDuplicates.digest(names), default: []] {
                comparisons += 1; guard comparisons <= 1_000_000 else { throw NameImportFailure.quota }
                if try snapshot(id).names == names { payload.matchingDescriptions += 1; break }
            }
        }
    }
}
