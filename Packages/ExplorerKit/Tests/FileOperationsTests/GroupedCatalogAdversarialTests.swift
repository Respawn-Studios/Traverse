import CryptoKit
import Darwin
import Foundation
import SQLite3
@testable import FileOperations
import Testing

/// Independent storage qualification. Every SQLite edit and removal stays in
/// this marked, generated root; no production transfer or app routing is used.
private struct GroupedAdversarialFixture {
    let root: URL
    let journal: URL
    let source: URL
    let destination: URL
    let owner: UUID
    private let marker: Data

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("grouped-adversarial-" + UUID().uuidString, isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        owner = UUID()
        marker = Data(("mac-explorer-grouped-adversarial-v1:" + owner.uuidString).utf8)
        for directory in [root, journal, source, destination] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try marker.write(to: root.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
        try OperationJournal.writeExclusive(Data(owner.uuidString.utf8), name: ".mac-explorer-journal-v1",
            anchor: DirectoryAnchor(journal, resolve: false))
    }

    func remove() {
        guard root.resolvingSymlinksInPath().path == root.path,
              (try? Data(contentsOf: root.appendingPathComponent(".fixture-owner"))) == marker else { return }
        try? FileManager().removeItem(at: root)
    }

    func file(_ name: String, body: String = "generated grouped catalog input") throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(body.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    enum Value {
        case text(String), integer(Int64), blob(Data), null
    }
    enum Cell: Equatable {
        case text(String), integer(Int64), blob(Data), null
    }

    func sql(_ sql: String, _ values: [Value] = []) throws -> [[Cell]] {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(journal.appendingPathComponent(SQLiteJournalStore.name).path,
            &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw FileOperationFailure.ioFailure
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FileOperationFailure.ioFailure
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text): status = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw FileOperationFailure.ioFailure }
        }
        var rows: [[Cell]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw FileOperationFailure.ioFailure }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                case SQLITE_NULL: return .null
                default: return .text(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
                }
            })
        }
    }

    func integer(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        guard case .integer(let value) = try self.sql(sql, values).first?.first else {
            throw FileOperationFailure.recoveryUncertain
        }
        return value
    }

    func blob(_ sql: String, _ values: [Value] = []) throws -> Data {
        guard case .blob(let value) = try self.sql(sql, values).first?.first else {
            throw FileOperationFailure.recoveryUncertain
        }
        return value
    }
}

private final class GroupedAdversarialSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    func enable() { lock.withLock { shouldFail = true } }
    func disable() { lock.withLock { shouldFail = false } }
    func check() throws {
        if lock.withLock({ shouldFail }) { throw FileOperationFailure.ioFailure }
    }
}

private func groupedAdversarialDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension GroupedAdversarialFixture {
    func manifests(_ count: Int = 33, prefix: String = UUID().uuidString) throws -> [GroupedCopyManifestMember] {
        let sourceParent = try DirectoryAnchor(source, resolve: false)
        let targetParent = try DirectoryAnchor(destination, resolve: false)
        let sourceVolume = try #require(try NativeRenameVolume.qualified(in: sourceParent))
        let targetVolume = try #require(try NativeRenameVolume.qualified(in: targetParent))
        return try (0..<count).map { ordinal in
            let name = "\(prefix)-\(ordinal).txt"
            let input = try file(name)
            return GroupedCopyManifestMember(
                source: GroupedCopySlot(parent: source, nameBytes: Data(name.utf8),
                    parentIdentity: sourceParent.identity, volume: sourceVolume),
                destination: GroupedCopySlot(parent: destination, nameBytes: Data(name.utf8),
                    parentIdentity: targetParent.identity, volume: targetVolume),
                sourceTree: try verifiedTree(input, cancellation: OperationCancellation()))
        }
    }

    func declare(_ session: GroupedCopyEditSession) throws {
        let ordinal = session.snapshot.groups.count
        let area = destination.appendingPathComponent("owned-group-\(session.id.uuidString)-\(ordinal)", isDirectory: true)
        let start = ordinal * session.snapshot.head.groupSize
        let end = min(start + session.snapshot.head.groupSize, session.snapshot.members.count)
        let slots = (start..<end).map { area.appendingPathComponent("owned-member-\($0)", isDirectory: true) }
        try session.declareGroup(areaURL: area, memberAreaURLs: slots)
    }

    /// Fixture directories supply real observed identities. No staging payload,
    /// source copy, publication, rename, Trash or app route is executed.
    func settleNeverStaged(_ session: GroupedCopyEditSession) throws {
        let group = try #require(session.snapshot.groups.last)
        try FileManager().createDirectory(at: group.areaURL, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try session.recordGroupIdentity(DirectoryAnchor(group.areaURL, resolve: false).identity, at: group.ordinal)
        for ordinal in group.members { try session.recordNeverStaged(member: ordinal) }
        try session.sealGroup(group.ordinal)
        try session.settleGroup(group.ordinal)
    }

    func grouped(_ record: OperationCatalogRecord?) throws -> GroupedCopyRecord {
        guard case .groupedCopyV1(let grouped) = record else { throw FileOperationFailure.recoveryUncertain }
        return grouped
    }

    func legacyNameRecord() throws -> JournalRecord {
        let input = try file("legacy-name.txt")
        let parent = try DirectoryAnchor(source, resolve: false)
        let volume = try #require(try NativeRenameVolume.qualified(in: parent))
        let entry = try NativeRenameEntry.observe(parent: parent, name: input.lastPathComponent)
        var record = JournalRecord(version: 2, owner: owner, id: UUID(), operation: "Rename")
        record.nameRename = JournalNameRename(protocolVersion: 1, parent: source, parentIdentity: parent.identity,
            volume: volume, entry: entry, oldName: entry.nameBytes, newName: Data("legacy-renamed.txt".utf8), phase: .prepared)
        return record
    }

    func mutatePayload(table: String, job: UUID, ordinal: Int, change: (inout [String: Any]) throws -> Void) throws {
        guard ["grouped_groups", "grouped_members"].contains(table) else { throw FileOperationFailure.invalidRequest }
        let values: [Value] = [.text(job.uuidString), .integer(Int64(ordinal))]
        let original = try blob("SELECT payload FROM \(table) WHERE job=? AND ordinal=?", values)
        var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        try change(&json)
        let changed = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        _ = try sql("UPDATE jobs SET bytes=bytes+? WHERE id=?", [.integer(Int64(changed.count - original.count)), .text(job.uuidString)])
        _ = try sql("UPDATE \(table) SET payload=?,checksum=? WHERE job=? AND ordinal=?",
            [.blob(changed), .text(groupedAdversarialDigest(changed))] + values)
    }

    func mutateHead(job: UUID, change: (inout [String: Any]) throws -> Void) throws {
        let original = try blob("SELECT head FROM jobs WHERE id=?", [.text(job.uuidString)])
        var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        try change(&json)
        let changed = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let checksum = groupedAdversarialDigest(changed)
        _ = try sql("UPDATE jobs SET head=?,checksum=?,bytes=bytes+? WHERE id=?",
            [.blob(changed), .text(checksum), .integer(Int64(changed.count - original.count)), .text(job.uuidString)])
        _ = try sql("UPDATE grouped_revision_heads SET head_checksum=? WHERE job=? AND revision=(SELECT revision FROM jobs WHERE id=?)",
            [.text(checksum), .text(job.uuidString), .text(job.uuidString)])
    }

    func rows() throws -> [[Cell]] {
        let statements = [
            "SELECT 'jobs',id,revision,state,hex(head),checksum,bytes FROM jobs ORDER BY id",
            "SELECT 'protocols',job,kind,version FROM job_protocols ORDER BY job",
            "SELECT 'groups',job,ordinal,phase,hex(payload),checksum FROM grouped_groups ORDER BY job,ordinal",
            "SELECT 'members',job,ordinal,group_ordinal,phase,hex(payload),checksum FROM grouped_members ORDER BY job,ordinal",
            "SELECT 'heads',job,revision,head_checksum FROM grouped_revision_heads ORDER BY job,revision",
            "SELECT 'events',job,revision,state FROM events ORDER BY job,revision",
            "SELECT 'steps',job,ordinal,hex(payload),checksum FROM steps ORDER BY job,ordinal",
            "SELECT 'areas',job,ordinal,hex(payload),checksum FROM areas ORDER BY job,ordinal",
            "SELECT 'locations',job,ordinal,hex(payload),checksum FROM locations ORDER BY job,ordinal",
            "SELECT 'trash',job,ordinal,hex(payload),checksum FROM trash_intents ORDER BY job,ordinal"
        ]
        return try statements.flatMap { try sql($0) }
    }
}

private func groupedAdversarialCanonical(_ record: GroupedCopyRecord) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    return try encoder.encode(record)
}

@Test(arguments: ["owner", "job", "ordinal", "group", "phase"])
func groupedCatalogAdversarialValidSHAMemberCrosslinksAreRefused(damage: String) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(17))
        id = edit.id
        try fixture.declare(edit); try journal.save(edit)
        try fixture.settleNeverStaged(edit); try journal.save(edit)
        try fixture.declare(edit); try journal.save(edit)
    }
    if damage == "phase" {
        _ = try fixture.sql("UPDATE grouped_members SET phase='declared' WHERE job=? AND ordinal=0", [.text(id.uuidString)])
    } else {
        try fixture.mutatePayload(table: "grouped_members", job: id, ordinal: 0) { row in
            switch damage {
            case "owner", "job": row[damage] = UUID().uuidString
            case "ordinal": row["ordinal"] = 1
            default:
                var progress = try #require(row["progress"] as? [String: Any])
                var payload = try #require(progress["neverStaged"] as? [String: Any])
                var declaration = try #require(payload["_0"] as? [String: Any])
                declaration["groupOrdinal"] = 1
                payload["_0"] = declaration; progress["neverStaged"] = payload; row["progress"] = progress
            }
        }
        if damage == "group" {
            _ = try fixture.sql("UPDATE grouped_members SET group_ordinal=1 WHERE job=? AND ordinal=0", [.text(id.uuidString)])
        }
    }
    let payload = try fixture.blob("SELECT payload FROM grouped_members WHERE job=? AND ordinal=0", [.text(id.uuidString)])
    #expect(try fixture.sql("SELECT checksum FROM grouped_members WHERE job=? AND ordinal=0", [.text(id.uuidString)]) == [[.text(groupedAdversarialDigest(payload))]])
    let cold = try OperationJournal(fixture.journal)
    #expect(throws: (any Error).self) { _ = try cold.inspectCatalogRecord(id) }
}

@Test(arguments: ["owner", "job", "ordinal", "members", "marker", "phase"])
func groupedCatalogAdversarialValidSHAGroupCrosslinksAreRefused(damage: String) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(17))
        id = edit.id
        try fixture.declare(edit); try journal.save(edit)
        try fixture.settleNeverStaged(edit); try journal.save(edit)
    }
    if damage == "phase" {
        _ = try fixture.sql("UPDATE grouped_groups SET phase='declared:none' WHERE job=? AND ordinal=0", [.text(id.uuidString)])
    } else {
        try fixture.mutatePayload(table: "grouped_groups", job: id, ordinal: 0) { row in
            switch damage {
            case "owner", "job": row[damage] = UUID().uuidString
            case "ordinal": row["ordinal"] = 1
            case "members": row["members"] = Array(1...16)
            default: row["marker"] = Data("foreign generated marker".utf8).base64EncodedString()
            }
        }
    }
    let payload = try fixture.blob("SELECT payload FROM grouped_groups WHERE job=? AND ordinal=0", [.text(id.uuidString)])
    #expect(try fixture.sql("SELECT checksum FROM grouped_groups WHERE job=? AND ordinal=0", [.text(id.uuidString)]) == [[.text(groupedAdversarialDigest(payload))]])
    #expect(throws: (any Error).self) { _ = try OperationJournal(fixture.journal).inspectCatalogRecord(id) }
}

@Test(arguments: ["member-count", "group-count", "future-protocol", "future-kind", "owner", "job"])
func groupedCatalogAdversarialRechecksChecksummedHeadDispatchAndBounds(damage: String) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(17))
        id = edit.id; try fixture.declare(edit); try journal.save(edit)
    }
    try fixture.mutateHead(job: id) { head in
        switch damage {
        case "member-count": head["admittedCount"] = 16
        case "group-count": head["groupCount"] = 2
        case "future-protocol": head["protocolVersion"] = 2
        case "future-kind": head["protocolKind"] = "futureGroupedCopy"
        case "owner": head["owner"] = UUID().uuidString
        default: head["id"] = UUID().uuidString
        }
    }
    let head = try fixture.blob("SELECT head FROM jobs WHERE id=?", [.text(id.uuidString)])
    #expect(try fixture.sql("SELECT checksum FROM jobs WHERE id=?", [.text(id.uuidString)]) == [[.text(groupedAdversarialDigest(head))]])
    #expect(try fixture.sql("SELECT head_checksum FROM grouped_revision_heads WHERE job=? ORDER BY revision DESC LIMIT 1", [.text(id.uuidString)]) == [[.text(groupedAdversarialDigest(head))]])
    #expect(throws: (any Error).self) { _ = try OperationJournal(fixture.journal).inspectCatalogRecord(id) }
}

@Test(arguments: [
    "DELETE FROM grouped_members WHERE ordinal=0",
    "UPDATE grouped_members SET ordinal=19 WHERE ordinal=0",
    "DELETE FROM grouped_groups WHERE ordinal=0",
    "UPDATE grouped_groups SET ordinal=2 WHERE ordinal=0",
    "UPDATE grouped_members SET group_ordinal=NULL WHERE ordinal=0",
    "DELETE FROM job_protocols",
    "UPDATE job_protocols SET version=2",
    "DELETE FROM grouped_revision_heads",
    "UPDATE grouped_revision_heads SET revision=revision+1",
    "UPDATE jobs SET bytes=bytes+1",
    "DELETE FROM events"
])
func groupedCatalogAdversarialColdReadsRejectMissingKeysAndIndexedColumnDisagreement(sql: String) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(17))
        id = edit.id; try fixture.declare(edit); try journal.save(edit)
    }
    _ = try fixture.sql(sql)
    #expect(throws: (any Error).self) { _ = try OperationJournal(fixture.journal).inspectCatalogRecord(id) }
}

@Test func groupedCatalogAdversarialExtraMemberAndLegacyChildCannotBecomeAuthority() throws {
    for damage in ["extra-member", "extra-group", "legacy-child"] {
        let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
        let id: UUID
        do {
            let journal = try OperationJournal(fixture.journal)
            try journal.upgradeForGroupedCopy()
            let edit = try journal.beginGroupedEdit(members: fixture.manifests(1))
            id = edit.id; try fixture.declare(edit); try journal.save(edit)
        }
        if damage == "extra-member" {
            _ = try fixture.sql("INSERT INTO grouped_members(job,ordinal,group_ordinal,phase,payload,checksum) SELECT job,1,group_ordinal,phase,payload,checksum FROM grouped_members WHERE job=? AND ordinal=0", [.text(id.uuidString)])
        } else if damage == "extra-group" {
            _ = try fixture.sql("INSERT INTO grouped_groups(job,ordinal,phase,payload,checksum) SELECT job,1,phase,payload,checksum FROM grouped_groups WHERE job=? AND ordinal=0", [.text(id.uuidString)])
        } else {
            let payload = try JSONEncoder().encode(fixture.root.appendingPathComponent("generated-legacy-location"))
            _ = try fixture.sql("INSERT INTO locations(job,ordinal,payload,checksum) VALUES(?,0,?,?)",
                [.text(id.uuidString), .blob(payload), .text(groupedAdversarialDigest(payload))])
        }
        #expect(throws: (any Error).self) { _ = try OperationJournal(fixture.journal).inspectCatalogRecord(id) }
    }
}

@Test func groupedCatalogAdversarialLegacyDispatchRejectsGroupedChildRows() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let legacyID: UUID, groupedID: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        var legacy = JournalRecord(version: 1, owner: fixture.owner, id: UUID(), operation: "Copy")
        try journal.saveSnapshot(&legacy); legacyID = legacy.id
        try journal.upgradeForGroupedCopy()
        let grouped = try journal.beginGroupedEdit(members: fixture.manifests(1))
        try journal.save(grouped); groupedID = grouped.id
    }
    _ = try fixture.sql("INSERT INTO grouped_members(job,ordinal,group_ordinal,phase,payload,checksum) SELECT ?,ordinal,group_ordinal,phase,payload,checksum FROM grouped_members WHERE job=?",
        [.text(legacyID.uuidString), .text(groupedID.uuidString)])
    #expect(throws: (any Error).self) { _ = try OperationJournal(fixture.journal).inspectCatalogRecord(legacyID) }
}

@Test func groupedCatalogAdversarialUpgradeRefusesChecksummedUnsafeLegacyLocationWithoutWriting() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        var legacy = JournalRecord(version: 1, owner: fixture.owner, id: UUID(), operation: "Copy")
        legacy.locations = [fixture.root.appendingPathComponent("owned-location")]
        try journal.saveSnapshot(&legacy); id = legacy.id
    }
    let original = try fixture.blob("SELECT payload FROM locations WHERE job=? AND ordinal=0", [.text(id.uuidString)])
    let malicious = try JSONEncoder().encode(URL(string: "https://generated.invalid/not-filesystem-authority")!)
    _ = try fixture.sql("UPDATE locations SET payload=?,checksum=? WHERE job=? AND ordinal=0",
        [.blob(malicious), .text(groupedAdversarialDigest(malicious)), .text(id.uuidString)])
    _ = try fixture.sql("UPDATE jobs SET bytes=bytes+? WHERE id=?",
        [.integer(Int64(malicious.count - original.count)), .text(id.uuidString)])
    let database = fixture.journal.appendingPathComponent(SQLiteJournalStore.name)
    let before = try Data(contentsOf: database)
    do {
        let journal = try OperationJournal(fixture.journal)
        #expect(throws: (any Error).self) { try journal.upgradeForGroupedCopy() }
    }
    #expect(try fixture.integer("PRAGMA user_version") == 3)
    #expect(try fixture.integer("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='version'") == 3)
    #expect(try fixture.integer("SELECT count(*) FROM sqlite_master WHERE name='grouped_members'") == 0)
    #expect(try Data(contentsOf: database) == before)
}

@Test(arguments: [17, 31, 33])
func groupedCatalogAdversarialExactPlannedTailMembershipSurvivesColdReads(count: Int) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    var expected: Data
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(count))
        id = edit.id; try journal.save(edit)
        let fullGroups = count / 16
        for ordinal in 0..<fullGroups {
            try fixture.declare(edit); try journal.save(edit)
            #expect(edit.snapshot.groups[ordinal].members == Array((ordinal * 16)..<(ordinal * 16 + 16)))
            try fixture.settleNeverStaged(edit); try journal.save(edit)
        }
        #expect(edit.snapshot.members.suffix(count % 16).allSatisfy { $0.progress.phase == "notDeclared" })
        #expect(try fixture.integer("SELECT count(*) FROM grouped_members WHERE job=? AND group_ordinal IS NULL", [.text(id.uuidString)]) == Int64(count % 16))
        try edit.close(); try journal.save(edit)
        #expect(edit.snapshot.head.state == .stoppedSettled)
        expected = try groupedAdversarialCanonical(edit.snapshot)
    }
    do {
        let cold = try OperationJournal(fixture.journal)
        let record = try fixture.grouped(cold.inspectCatalogRecord(id))
        #expect(try groupedAdversarialCanonical(record) == expected)
        #expect(record.members.count == count && record.groups.count == count / 16)
        #expect(record.members.suffix(count % 16).allSatisfy { $0.progress.phase == "notDeclared" })
        let edit = try #require(try cold.openGroupedEdit(id))
        #expect(throws: FileOperationFailure.recoveryUncertain) { try fixture.declare(edit) }
    }
}

@Test func groupedCatalogAdversarialFinalSingletonTailHasExactMembership() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let edit = try journal.beginGroupedEdit(members: fixture.manifests(33))
    try journal.save(edit)
    for ordinal in 0..<3 {
        try fixture.declare(edit); try journal.save(edit)
        let expected = Array((ordinal * 16)..<min(ordinal * 16 + 16, 33))
        #expect(edit.snapshot.groups[ordinal].members == expected)
        try fixture.settleNeverStaged(edit); try journal.save(edit)
    }
    try edit.close(); try journal.save(edit)
    let cold = try fixture.grouped(journal.inspectCatalogRecord(edit.id))
    #expect(cold.groups.map(\.members) == [Array(0..<16), Array(16..<32), [32]])
    #expect(cold.members.allSatisfy { $0.progress.phase == "neverStaged" })
    #expect(cold.head.state == .stoppedSettled)
}

@Test(arguments: [false, true])
func groupedCatalogAdversarialFailedAndUncertainSaveRetiresAuthorityUntilColdRead(committed: Bool) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let gate = GroupedAdversarialSaveGate()
    let hooks = committed
        ? JournalStorageHooks(afterCommitBeforeAcknowledgement: { try gate.check() })
        : JournalStorageHooks(beforeSaveCommit: { try gate.check() })
    let journal = try OperationJournal(fixture.journal, hooks: hooks)
    try journal.upgradeForGroupedCopy()
    let edit = try journal.beginGroupedEdit(members: fixture.manifests(17))
    try journal.save(edit); try fixture.declare(edit); try journal.save(edit)
    let before = edit.snapshot
    try edit.recordNeverStaged(member: 0)
    gate.enable()
    #expect(throws: FileOperationFailure.ioFailure) { try journal.save(edit) }
    #expect(!edit.valid && edit.revision == before.head.revision)
    #expect(throws: FileOperationFailure.recoveryUncertain) { try edit.recordNeverStaged(member: 1) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(edit) }
    gate.disable()
    let cold = try #require(try journal.openGroupedEdit(edit.id))
    #expect(cold.snapshot.members[0].progress.phase == (committed ? "neverStaged" : "declared"))
    #expect(cold.revision == before.head.revision + (committed ? 1 : 0))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordNeverStaged(member: 1) }
    try cold.markNeedsReview(); try journal.save(cold)
    #expect(try fixture.grouped(journal.inspectCatalogRecord(edit.id)).head.state == .needsReview)
}

@Test func groupedCatalogAdversarialColdDeclaredRecordCannotResumeForwardWork() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(17))
        id = edit.id; try fixture.declare(edit); try journal.save(edit)
    }
    let coldJournal = try OperationJournal(fixture.journal)
    let cold = try #require(try coldJournal.openGroupedEdit(id))
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordNeverStaged(member: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.close() }
    let area = try #require(cold.snapshot.groups.first?.areaURL)
    try FileManager().createDirectory(at: area, withIntermediateDirectories: false)
    let identity = try DirectoryAnchor(area, resolve: false).identity
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.recordGroupIdentity(identity, at: 0) }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.sealGroup(0) }
    #expect(try fixture.grouped(coldJournal.inspectCatalogRecord(id)).members.allSatisfy { $0.progress.phase == "declared" || $0.progress.phase == "notDeclared" })
}

@Test func groupedCatalogAdversarialSQLitePageQuotaRefusesBeforeEditingAndKeepsCatalog() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let legacyID: UUID
    do {
        let journal = try OperationJournal(fixture.journal)
        var legacy = JournalRecord(version: 1, owner: fixture.owner, id: UUID(), operation: "Copy")
        try journal.saveSnapshot(&legacy); legacyID = legacy.id
        try journal.upgradeForGroupedCopy()
    }
    let pages = try fixture.integer("PRAGMA page_count")
    let before = try fixture.rows()
    let members = try fixture.manifests(OperationJournal.maximumInputs)
    do {
        // The current reservation guard catches an exhausted SQLite page quota
        // before an edit is opened. Later write/rollback failures have their own
        // existing fault controls; this case must not pretend to reach a write.
        let limited = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(maximumPageCount: pages))
        #expect(throws: FileOperationFailure.unsupported) { try limited.beginGroupedEdit(members: members) }
        #expect(try fixture.rows() == before)
        #expect(try limited.inspectCatalogRecord(legacyID)?.legacy?.id == legacyID)
    }
    let unrestricted = try OperationJournal(fixture.journal)
    let retry = try unrestricted.beginGroupedEdit(members: members)
    try unrestricted.save(retry)
    #expect(retry.revision == 1)
    #expect(try fixture.grouped(unrestricted.inspectCatalogRecord(retry.id)).members.count == OperationJournal.maximumInputs)
}

@Test func groupedCatalogAdversarialMemberEditsMatchColdSnapshotsAndStayProportionalToChangedEvidence() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let metrics = JournalMetrics()
    let journal = try OperationJournal(fixture.journal, hooks: JournalStorageHooks(metrics: metrics))
    // Existing unrelated history must not be re-encoded for one member edit.
    for index in 0..<65 {
        var legacy = JournalRecord(version: 1, owner: fixture.owner, id: UUID(), operation: "Copy")
        legacy.createdAt = Date(timeIntervalSinceReferenceDate: Double(index))
        legacy.state = "committed"
        legacy.locations = [fixture.root.appendingPathComponent("history-\(index)")]
        try journal.saveSnapshot(&legacy)
    }
    try journal.upgradeForGroupedCopy()
    let edit = try journal.beginGroupedEdit(members: fixture.manifests(33))
    try journal.save(edit); try fixture.declare(edit); try journal.save(edit)
    let untouched = try fixture.sql("SELECT id,hex(head),checksum FROM jobs WHERE id<>? ORDER BY id", [.text(edit.id.uuidString)])
    let undeclaredTail = try fixture.sql("SELECT ordinal,hex(payload),checksum FROM grouped_members WHERE job=? AND ordinal>=16 ORDER BY ordinal", [.text(edit.id.uuidString)])
    for ordinal in 0..<16 {
        let before = metrics.snapshot.counters
        try edit.recordNeverStaged(member: ordinal); try journal.save(edit)
        let after = metrics.snapshot.counters
        #expect((after["validatedRows"] ?? 0) - (before["validatedRows"] ?? 0) == 1)
        #expect((after["comparedRows"] ?? 0) - (before["comparedRows"] ?? 0) == 1)
        #expect((after["encodedRows"] ?? 0) - (before["encodedRows"] ?? 0) == 2)
        #expect((after["writtenRows"] ?? 0) - (before["writtenRows"] ?? 0) == 1)
        #expect((after["rowScanCandidates"] ?? 0) - (before["rowScanCandidates"] ?? 0) == 1)
        let loaded = try fixture.grouped(journal.inspectCatalogRecord(edit.id))
        #expect(try groupedAdversarialCanonical(loaded) == groupedAdversarialCanonical(edit.snapshot))
        #expect(try fixture.sql("SELECT id,hex(head),checksum FROM jobs WHERE id<>? ORDER BY id", [.text(edit.id.uuidString)]) == untouched)
        #expect(try fixture.sql("SELECT ordinal,hex(payload),checksum FROM grouped_members WHERE job=? AND ordinal>=16 ORDER BY ordinal", [.text(edit.id.uuidString)]) == undeclaredTail)
    }
    let before = metrics.snapshot.counters
    try edit.markNeedsReview(); try journal.save(edit)
    let after = metrics.snapshot.counters
    #expect((after["validatedRows"] ?? 0) - (before["validatedRows"] ?? 0) == 0)
    #expect((after["encodedRows"] ?? 0) - (before["encodedRows"] ?? 0) == 1)
    #expect((after["writtenRows"] ?? 0) - (before["writtenRows"] ?? 0) == 0)
    #expect(try groupedAdversarialCanonical(fixture.grouped(journal.inspectCatalogRecord(edit.id))) == groupedAdversarialCanonical(edit.snapshot))
}

@Test func groupedCatalogAdversarialSchemaFourPaginationAndCompactionPreserveMixedCurrentEvidence() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    var expected = Set<UUID>()
    var expectedGrouped: [UUID: Data] = [:]
    do {
        let journal = try OperationJournal(fixture.journal)
        var name = try fixture.legacyNameRecord()
        try journal.saveSnapshot(&name); expected.insert(name.id)
        for index in 0..<65 {
            var legacy = JournalRecord(version: 1, owner: fixture.owner, id: UUID(), operation: "Copy")
            legacy.createdAt = Date(timeIntervalSinceReferenceDate: Double(index))
            legacy.state = "committed"
            legacy.locations = [fixture.root.appendingPathComponent("retained-history-\(index)")]
            try journal.saveSnapshot(&legacy); expected.insert(legacy.id)
        }
        try journal.upgradeForGroupedCopy()
        let manifests = try fixture.manifests(1)
        for _ in 0..<5 {
            let edit = try journal.beginGroupedEdit(members: manifests)
            try journal.save(edit); try fixture.declare(edit); try journal.save(edit)
            try fixture.settleNeverStaged(edit); try journal.save(edit)
            try edit.close(); try journal.save(edit)
            expected.insert(edit.id)
            expectedGrouped[edit.id] = try groupedAdversarialCanonical(edit.snapshot)
        }
        let payloads = try fixture.sql("SELECT job,ordinal,hex(payload),checksum FROM grouped_members ORDER BY job,ordinal")
        let groups = try fixture.sql("SELECT job,ordinal,phase,hex(payload),checksum FROM grouped_groups ORDER BY job,ordinal")
        let before = try journal.maintenance()
        let compacted = try journal.compact()
        #expect(compacted.eventCount < before.eventCount)
        #expect(try fixture.sql("SELECT job,ordinal,hex(payload),checksum FROM grouped_members ORDER BY job,ordinal") == payloads)
        #expect(try fixture.sql("SELECT job,ordinal,phase,hex(payload),checksum FROM grouped_groups ORDER BY job,ordinal") == groups)
        #expect(try fixture.integer("SELECT count(*) FROM grouped_revision_heads") == 5)
    }
    let cold = try OperationJournal(fixture.journal)
    var cursor: UUID?
    var actual: [UUID] = []
    repeat {
        let page = try cold.inspectSummaries(after: cursor, limit: 7)
        #expect(page.refused.isEmpty && page.records.count <= 7)
        actual += page.records.map(\.id)
        cursor = page.next
    } while cursor != nil
    #expect(actual.count == expected.count && Set(actual) == expected)
    let sqlOrder = try fixture.sql("SELECT id FROM jobs ORDER BY created_at DESC,id DESC")
    #expect(actual.map { [GroupedAdversarialFixture.Cell.text($0.uuidString)] } == sqlOrder)
    for (id, bytes) in expectedGrouped {
        #expect(try groupedAdversarialCanonical(fixture.grouped(cold.inspectCatalogRecord(id))) == bytes)
    }
    #expect(try cold.unfinishedCount() == 1) // The deliberately prepared legacy name-Rename.
    #expect(try fixture.integer("PRAGMA user_version") == 4)
}

@Test(arguments: [("Report.txt", "report.txt"), ("Café.txt", "Cafe\u{301}.txt")])
func groupedCatalogAdversarialAmbiguousPublicNamespaceIsRejectedBeforeRecording(names: (String, String)) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let original = try fixture.manifests(2)
    let renamed = zip(original, [names.0, names.1]).map { member, name in
        GroupedCopyManifestMember(source: member.source,
            destination: GroupedCopySlot(parent: member.destination.parent, nameBytes: Data(name.utf8),
                parentIdentity: member.destination.parentIdentity, volume: member.destination.volume),
            sourceTree: member.sourceTree)
    }
    #expect(throws: FileOperationFailure.recoveryUncertain) { _ = try journal.beginGroupedEdit(members: renamed) }
    #expect(try fixture.integer("SELECT count(*) FROM jobs") == 0)
}

@Test(arguments: ["public-area", "marker-slot", "ambiguous-private-slots"])
func groupedCatalogAdversarialPrivateDeclarationCannotAliasPublicOrMarkerNamespace(damage: String) throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let edit = try journal.beginGroupedEdit(members: fixture.manifests(damage == "ambiguous-private-slots" ? 2 : 1))
    try journal.save(edit)
    let area = damage == "public-area" ? edit.snapshot.members[0].manifest.destination.url
        : fixture.destination.appendingPathComponent("generated-owned-group", isDirectory: true)
    let slots: [URL]
    if damage == "marker-slot" { slots = [area.appendingPathComponent(GroupedCopyGroup.markerName)] }
    else if damage == "ambiguous-private-slots" { slots = [area.appendingPathComponent("MemberA"), area.appendingPathComponent("membera")] }
    else { slots = [area.appendingPathComponent("owned-member")] }
    #expect(throws: FileOperationFailure.recoveryUncertain) { try edit.declareGroup(areaURL: area, memberAreaURLs: slots) }
    #expect(edit.snapshot.groups.isEmpty && edit.snapshot.head.groupCount == 0)
    #expect(try fixture.integer("SELECT count(*) FROM grouped_groups") == 0)
}

@Test func groupedCatalogAdversarialCallerForgedSessionCannotBypassStoreOwnedBookkeeping() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    let genuine = try journal.beginGroupedEdit(members: fixture.manifests(1))
    try journal.save(genuine)
    var forgedRecord = genuine.snapshot
    forgedRecord.members[0] = GroupedCopyMember(owner: UUID(), job: genuine.id, ordinal: 0,
        manifest: forgedRecord.members[0].manifest, progress: .notDeclared)
    // A false "unchanged" session is not a capability, even inside the module.
    let forged = GroupedCopyEditSession(forgedRecord, new: false)
    #expect(forged.changedMembers.isEmpty)
    let before = try fixture.rows()
    #expect(throws: FileOperationFailure.recoveryUncertain) { try journal.save(forged) }
    #expect(!forged.valid)
    #expect(try fixture.rows() == before)
    #expect(try groupedAdversarialCanonical(fixture.grouped(journal.inspectCatalogRecord(genuine.id))) == groupedAdversarialCanonical(genuine.snapshot))
}

@Test func groupedCatalogAdversarialPersistedClosureIntentNeedsFreshExplicitReviewAfterColdOpen() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let id: UUID
    let interruptedIntent = UUID()
    do {
        let journal = try OperationJournal(fixture.journal)
        try journal.upgradeForGroupedCopy()
        let edit = try journal.beginGroupedEdit(members: fixture.manifests(1))
        id = edit.id
        try journal.save(edit); try fixture.declare(edit); try journal.save(edit)
        try fixture.settleNeverStaged(edit); try journal.save(edit)
        try edit.beginReview(GroupedCopyReviewIntent(id: interruptedIntent, kind: .closure,
            preparedRevision: edit.revision, members: [], inventoryDigest: String(repeating: "a", count: 64)))
        try journal.save(edit)
        #expect(edit.snapshot.head.state == .needsReview)
    }
    let journal = try OperationJournal(fixture.journal)
    let cold = try #require(try journal.openGroupedEdit(id))
    #expect(cold.snapshot.head.reviewIntent?.id == interruptedIntent)
    let durableBefore = try fixture.rows()
    #expect(throws: FileOperationFailure.recoveryUncertain) { try cold.finishReview(interruptedIntent) }
    #expect(cold.snapshot.head.state == .needsReview && cold.snapshot.head.reviewIntent?.id == interruptedIntent)
    #expect(try fixture.rows() == durableBefore)
    let freshIntent = UUID()
    try cold.beginReview(GroupedCopyReviewIntent(id: freshIntent, kind: .closure,
        preparedRevision: cold.revision, members: [], inventoryDigest: String(repeating: "a", count: 64)))
    try cold.finishReview(freshIntent)
    try journal.save(cold)
    let stored = try fixture.grouped(journal.inspectCatalogRecord(id))
    #expect(stored.head.state == .stoppedSettled && stored.head.reviewIntent == nil)
    #expect(stored.members[0].progress.phase == "neverStaged")
    #expect(stored.groups[0].cleanup.phase == "none")
    #expect(!FileManager().fileExists(atPath: stored.members[0].manifest.destination.url.path))
}

@Test func groupedCatalogAdversarialCrossMemberNormalizedSourceDestinationOverlapIsRefused() throws {
    let fixture = try GroupedAdversarialFixture(); defer { fixture.remove() }
    let first = try fixture.file("A.txt")
    let second = try fixture.file("B.txt")
    let parent = try DirectoryAnchor(fixture.source, resolve: false)
    let volume = try #require(try NativeRenameVolume.qualified(in: parent))
    let before = try [first, second].map { try verifiedTree($0, cancellation: OperationCancellation()) }
    let manifests = zip([first, second], ["b.txt", "a.txt"]).enumerated().map { ordinal, pair in
        GroupedCopyManifestMember(
            source: GroupedCopySlot(parent: parent.url, nameBytes: Data(pair.0.lastPathComponent.utf8),
                parentIdentity: parent.identity, volume: volume),
            destination: GroupedCopySlot(parent: parent.url, nameBytes: Data(pair.1.utf8),
                parentIdentity: parent.identity, volume: volume),
            sourceTree: before[ordinal])
    }
    let journal = try OperationJournal(fixture.journal)
    try journal.upgradeForGroupedCopy()
    // Literal slots and per-member keys are distinct, but each proposed public
    // name aliases the other selected source on qualified insensitive APFS.
    #expect(throws: FileOperationFailure.recoveryUncertain) { _ = try journal.beginGroupedEdit(members: manifests) }
    #expect(try fixture.integer("SELECT count(*) FROM jobs") == 0)
    for (ordinal, source) in [first, second].enumerated() {
        #expect(before[ordinal].matches(try verifiedTree(source, cancellation: OperationCancellation())))
    }
}
