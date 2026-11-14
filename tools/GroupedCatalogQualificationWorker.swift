import Darwin
import Foundation

private enum CatalogInjectedFault: Error { case boundary }
private final class CatalogFault: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    let mechanism: String
    let boundary: String
    init(_ mechanism: String, _ boundary: String) { self.mechanism = mechanism; self.boundary = boundary }
    var didReach: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func fire() throws {
        lock.lock(); reached = true; lock.unlock()
        if mechanism == "process_crash" {
            try CatalogFixture.emit(["pid": getpid(), "mechanism": mechanism, "boundary": boundary,
                                     "boundaryReached": true, "termination": "_exit(86)"])
            _exit(86)
        }
        throw CatalogInjectedFault.boundary
    }
}

@main internal enum GroupedCatalogQualificationWorker {
    static func main() {
        var stage = "validate_arguments"
        do { try execute { stage = $0 } }
        catch {
            // Constant diagnostic stages only; never error bodies, owner paths or
            // fixture content. Fail normally so the runner retains useful evidence.
            try? CatalogFixture.emit(["pid": getpid(), "failed": true, "stage": stage,
                                      "failureKind": error is FileOperationFailure ? "file_operation_failure" : "other_error"])
            exit(1)
        }
    }
    static func execute(stage: (String) -> Void) throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw FileOperationFailure.invalidRequest }
        let root = try CatalogFixture.root(args[2])
        switch args[1] {
        case "inspect":
            stage("inspect")
            guard args.count == 4, let expected = Int(args[3]), [3, 4].contains(expected) else { throw FileOperationFailure.invalidRequest }
            try inspect(root, expected: expected)
        case "upgrade":
            stage("upgrade")
            guard args.count == 5 else { throw FileOperationFailure.invalidRequest }
            try upgrade(root, mechanism: args[3], boundary: args[4])
        case "grouped-seed":
            guard args.count == 3 else { throw FileOperationFailure.invalidRequest }
            try groupedSeed(root, stage: stage)
        case "grouped-inspect", "compact":
            stage(args[1] == "compact" ? "compact" : "grouped_inspect")
            guard args.count == 3 else { throw FileOperationFailure.invalidRequest }
            try groupedInspect(root, compact: args[1] == "compact")
        default: throw FileOperationFailure.invalidRequest
        }
    }
    static func checkLegacy(_ journal: OperationJournal, root: URL) throws -> Int {
        let seed = try CatalogFixture.manifest(root)
        var count = 0
        guard try CatalogFixture.legacyEvidence(root) == seed["legacyJSON"] else { throw FileOperationFailure.recoveryUncertain }
        for (text, hash) in seed where text != "legacyRows" && text != "legacyJSON" {
            guard let id = UUID(uuidString: text), let catalog = try journal.inspectCatalogRecord(id),
                  let record = catalog.legacy,
                  CatalogFixture.digest(try CatalogFixture.encode(record)) == hash else {
                throw FileOperationFailure.recoveryUncertain
            }
            switch catalog {
            case .treeV1: guard record.version == 1 else { throw FileOperationFailure.recoveryUncertain }
            case .nameRenameV2: guard record.version == 2 else { throw FileOperationFailure.recoveryUncertain }
            case .groupedCopyV1: throw FileOperationFailure.recoveryUncertain
            }
            count += 1
        }
        return count
    }
    static func inspect(_ root: URL, expected: Int) throws {
        // Open production storage first: a crash-before-COMMIT may leave a hot
        // SQLite rollback journal. The independent cold open must resolve it.
        let journal = try OperationJournal(root.appendingPathComponent("journal"))
        try journal.validateWritableCatalog()
        let count = try checkLegacy(journal, root: root)
        let schema = try CatalogFixture.schema(root)
        guard schema == expected, try CatalogFixture.legacyRows(root) == CatalogFixture.manifest(root)["legacyRows"] else {
            throw FileOperationFailure.recoveryUncertain
        }
        try CatalogFixture.emit(["pid": getpid(), "schema": schema, "legacyRecordCount": count,
                                 "legacyRecordsPreserved": true, "legacyRowBytesPreserved": true, "legacyJSONBytesPreserved": true,
                                 "ordinaryOpenDidNotUpgrade": expected == 3])
    }
    static func upgrade(_ root: URL, mechanism: String, boundary: String) throws {
        guard (mechanism == "none" && boundary == "none") ||
              (["injected_error", "process_crash"].contains(mechanism) && ["before_commit", "after_commit"].contains(boundary)) ||
              (mechanism == "lost_acknowledgement" && boundary == "after_commit_before_ack") else {
            throw FileOperationFailure.invalidRequest
        }
        let fault = CatalogFault(mechanism, boundary)
        var hooks = JournalStorageHooks()
        if boundary == "before_commit" { hooks.beforeCatalogUpgradeCommit = { try fault.fire() } }
        if boundary == "after_commit" { hooks.afterCatalogUpgradeCommit = { try fault.fire() } }
        if boundary == "after_commit_before_ack" { hooks.afterCommitBeforeAcknowledgement = { try fault.fire() } }
        var injected = false
        // Destroy this instance on every outcome; only a separate process decides
        // whether an ambiguous acknowledgement committed durable schema authority.
        do {
            let journal = try OperationJournal(root.appendingPathComponent("journal"), hooks: hooks)
            try journal.upgradeForGroupedCopy()
            guard mechanism == "none" else { throw FileOperationFailure.recoveryUncertain }
        } catch CatalogInjectedFault.boundary {
            guard mechanism != "none", mechanism != "process_crash", fault.didReach else { throw FileOperationFailure.recoveryUncertain }
            injected = true
        }
        try CatalogFixture.emit(["pid": getpid(), "mechanism": mechanism, "boundary": boundary,
                                 "boundaryReached": fault.didReach, "injectedErrorObserved": injected,
                                 "requiresIndependentColdRead": true])
    }
    static func groupedSeed(_ root: URL, stage: (String) -> Void) throws {
        stage("grouped_seed_create_inputs")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        for index in 0..<17 {
            try CatalogFixture.write(Data("generated grouped member \(index)".utf8), to: source.appendingPathComponent("member-\(index).txt"))
        }
        stage("grouped_seed_capture_namespace")
        let before = try [CatalogFixture.fingerprint(source), CatalogFixture.fingerprint(destination)]
        let sourceAnchor = try DirectoryAnchor(source, resolve: false), destinationAnchor = try DirectoryAnchor(destination, resolve: false)
        guard let sourceVolume = try NativeRenameVolume.qualified(in: sourceAnchor),
              let destinationVolume = try NativeRenameVolume.qualified(in: destinationAnchor) else { throw FileOperationFailure.unsupported }
        func manifests(_ prefix: String) throws -> [GroupedCopyManifestMember] {
            try (0..<17).map { index in
                let name = "member-\(index).txt"
                return GroupedCopyManifestMember(
                    source: GroupedCopySlot(parent: source, nameBytes: Data(name.utf8), parentIdentity: sourceAnchor.identity, volume: sourceVolume),
                    destination: GroupedCopySlot(parent: destination, nameBytes: Data("\(prefix)-\(name)".utf8), parentIdentity: destinationAnchor.identity, volume: destinationVolume),
                    sourceTree: try verifiedTree(source.appendingPathComponent(name), cancellation: OperationCancellation()))
            }
        }
        stage("grouped_seed_open_catalog")
        let journal = try OperationJournal(root.appendingPathComponent("journal"))
        try journal.validateWritableCatalog()
        stage("grouped_seed_terminal")
        let terminal = try journal.beginGroupedEdit(members: manifests("terminal"))
        try journal.save(terminal); try terminal.close(); try journal.save(terminal)
        stage("grouped_seed_review_prepare")
        let review = try journal.beginGroupedEdit(members: manifests("review"))
        try journal.save(review)
        stage("grouped_seed_review_declare")
        let group = destination.appendingPathComponent("generated-group-area", isDirectory: true)
        try review.declareGroup(areaURL: group, memberAreaURLs: (0..<16).map { group.appendingPathComponent("member-\($0)", isDirectory: true) })
        stage("grouped_seed_review_save")
        try review.markNeedsReview(); try journal.save(review)
        stage("grouped_seed_cold_prepare")
        let coldPlanned = try journal.beginGroupedEdit(members: manifests("cold"))
        try journal.save(coldPlanned)
        stage("grouped_seed_verify_namespace")
        guard before == (try [CatalogFixture.fingerprint(source), CatalogFixture.fingerprint(destination)]) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let manifest = ["terminal": terminal.id.uuidString, "review": review.id.uuidString, "coldPlanned": coldPlanned.id.uuidString,
                        "sourceFingerprint": before[0], "destinationFingerprint": before[1]]
        stage("grouped_seed_save_receipt")
        try CatalogFixture.write(CatalogFixture.encode(manifest), to: root.appendingPathComponent("grouped.json"))
        try CatalogFixture.emit(["pid": getpid(), "groupedJobs": 3, "membersPerJob": 17,
                                 "namespaceUnchanged": true, "groupedFileExecution": false])
    }
    static func groupedInspect(_ root: URL, compact: Bool) throws {
        let manifest = try JSONDecoder().decode([String: String].self,
            from: CatalogFixture.read(root.appendingPathComponent("grouped.json"), maximum: 16_384))
        guard let terminal = manifest["terminal"].flatMap(UUID.init(uuidString:)),
              let review = manifest["review"].flatMap(UUID.init(uuidString:)),
              let coldPlanned = manifest["coldPlanned"].flatMap(UUID.init(uuidString:)) else { throw FileOperationFailure.recoveryUncertain }
        let journal = try OperationJournal(root.appendingPathComponent("journal"))
        let legacyCount = try checkLegacy(journal, root: root)
        func records() throws -> [GroupedCopyRecord] {
            guard case .groupedCopyV1(let first)? = try journal.inspectCatalogRecord(terminal),
                  case .groupedCopyV1(let second)? = try journal.inspectCatalogRecord(review),
                  case .groupedCopyV1(let third)? = try journal.inspectCatalogRecord(coldPlanned),
                  first.head.state == .stoppedSettled, first.groups.isEmpty, first.members.count == 17,
                  first.members.allSatisfy({ $0.progress.phase == "notDeclared" }),
                  second.head.state == .needsReview, second.groups.count == 1, second.members.count == 17,
                  second.members.prefix(16).allSatisfy({ $0.progress.phase == "declared" }),
                  second.members[16].progress.phase == "notDeclared",
                  third.head.state == .preparing, third.groups.isEmpty, third.members.count == 17,
                  third.members.allSatisfy({ $0.progress.phase == "notDeclared" }) else { throw FileOperationFailure.recoveryUncertain }
            try first.validate(); try second.validate(); try third.validate()
            return [first, second, third]
        }
        let before = CatalogFixture.digest(try CatalogFixture.encode(records()))
        if compact { _ = try journal.compact() }
        guard before == CatalogFixture.digest(try CatalogFixture.encode(records())),
              try CatalogFixture.fingerprint(root.appendingPathComponent("source")) == manifest["sourceFingerprint"],
              try CatalogFixture.fingerprint(root.appendingPathComponent("destination")) == manifest["destinationFingerprint"] else {
            throw FileOperationFailure.recoveryUncertain
        }
        var cursor: UUID?, seen = Set<UUID>(), groupedCount = 0, pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= 8 else { throw FileOperationFailure.recoveryUncertain }
            let page = try journal.inspectSummaries(after: cursor, limit: 1)
            guard page.refused.isEmpty, page.records.count <= 1,
                  page.next == nil || (page.next != cursor && page.records.count == 1) else { throw FileOperationFailure.recoveryUncertain }
            for row in page.records {
                guard seen.insert(row.id).inserted else { throw FileOperationFailure.recoveryUncertain }
                if row.id == terminal || row.id == review || row.id == coldPlanned {
                    guard !row.canRecover, !row.canUndo else { throw FileOperationFailure.recoveryUncertain }
                    groupedCount += 1
                }
            }
            cursor = page.next
            guard seen.count <= 6 else { throw FileOperationFailure.recoveryUncertain }
        } while cursor != nil
        guard groupedCount == 3, seen.count == legacyCount + 3 else { throw FileOperationFailure.recoveryUncertain }
        let cold = try journal.openGroupedEdit(coldPlanned)
        guard let cold else { throw FileOperationFailure.recoveryUncertain }
        var rejected = false
        do { try cold.close() } catch { rejected = true }
        guard rejected else { throw FileOperationFailure.recoveryUncertain }
        try CatalogFixture.emit(["pid": getpid(), "schema": CatalogFixture.schema(root), "groupedJobs": groupedCount,
                                 "legacyRecordsPreserved": true, "groupedHash": before, "compact": compact,
                                 "pagedMixedDispatch": true, "coldForwardRejected": true,
                                 "executionActionsUnavailable": true, "namespaceUnchanged": true])
    }
}
