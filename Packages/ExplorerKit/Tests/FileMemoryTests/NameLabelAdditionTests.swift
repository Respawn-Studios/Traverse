import ExplorerCore
import Foundation
import Testing
@testable import FileMemory

private struct LabelFixture {
    let root: URL
    var catalog: URL { root.appendingPathComponent("catalog") }
    init() throws {
        guard let value = ProcessInfo.processInfo.environment["MAC_EXPLORER_LABEL_TEST_ROOT"] else { throw NameStoreFailure.unsafe }
        let source = URL(fileURLWithPath: value), owner = source.deletingLastPathComponent()
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard source.lastPathComponent == "source", owner.deletingLastPathComponent().path == repo.appendingPathComponent(".build/traverse-release").path,
              UUID(uuidString: owner.lastPathComponent)?.uuidString == owner.lastPathComponent,
              source.resolvingSymlinksInPath().path == source.path,
              let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: owner.appendingPathComponent("reservation.json"))) as? [String: Any],
              marker["action"] as? String == "traverse-private-labels" else { throw NameStoreFailure.unsafe }
        root = source.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func seeded(_ count: Int = 3, firstLabels: [String] = ["existing"]) async throws -> (PersistentNameStore, [RememberedItemID]) {
        let store = try await PersistentNameStore.create(directory: catalog,
            first: AuthoredNames(nickname: "Generated 0", alternateNames: ["Alias 0"], labels: firstLabels))
        var ids = [try await store.firstItemID()]
        for index in 1..<count {
            let edit = try await store.prepareNew(AuthoredNames(nickname: "Generated \(index)", alternateNames: ["Alias \(index)"], labels: ["existing"]))
            ids.append(try await store.apply(edit))
        }
        return (store, ids)
    }
}
private func captures(_ store: PersistentNameStore, _ ids: [RememberedItemID]) async throws -> [StoredNameSnapshot] {
    var result: [StoredNameSnapshot] = []
    for id in ids { result.append(try await store.snapshot(id)) }
    return result
}
private func names(_ store: PersistentNameStore, _ id: RememberedItemID) async throws -> RememberedNamesSnapshot {
    let captured = try await store.snapshot(id)
    var result: RememberedNamesSnapshot?
    guard captured.publish({ result = $0 }), let result else { throw NameIndexFailure.stalePage }
    return result
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_LABEL_TEST_ROOT"] != nil))
struct NameLabelAdditionTests {
    @Test func appendIsAtomicAndPreservesOtherFieldsAndDirectIndex() async throws {
        let (store, ids) = try await LabelFixture().seeded()
        let snapshots = try await captures(store, ids)
        let edit = try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: ["Café notes", "checked", "checked"])
        #expect(edit.itemIDs == ids && edit.changedCount == 3 && edit.labelCount == 2)
        let result = try await store.applyLabelAddition(edit)
        #expect(result.selectedItems == 3 && result.changedItems == 3 && result.unchangedItems == 0)
        for (index, id) in ids.enumerated() {
            let value = try await names(store, id)
            #expect(value.revision == snapshots[index].revision + 1 && value.names.nickname == "Generated \(index)")
            #expect(value.names.alternateNames == ["Alias \(index)"] && value.names.labels == ["existing", "Café notes", "checked"])
        }
        let page = try await store.query(RememberedNameQuery(text: "cafe notes"))
        var matches: [RememberedNameMatch] = []
        #expect(page.publish { matches = $0 })
        #expect(Set(matches.map { $0.item.id }) == Set(ids))
        #expect(matches.allSatisfy { $0.reasons.contains { $0.field == .label } })
        #expect(try await store.resolveLabelAddition(edit) == .saved)
        #expect(await store.qualificationLabelBatchCount() == 0)
        await store.close()
    }
    @Test func duplicateExistingLabelsAreNoopWithoutRevisionOrIndexInvalidation() async throws {
        let (store, ids) = try await LabelFixture().seeded()
        let snapshots = try await captures(store, ids), page = try await store.query(RememberedNameQuery(text: "existing"))
        let edit = try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: ["existing", "existing"])
        #expect(edit.changedCount == 0)
        let result = try await store.applyLabelAddition(edit)
        #expect(result.changedItems == 0 && result.unchangedItems == 3)
        #expect(page.publish { _ in })
        for (index,id) in ids.enumerated() { #expect(try await names(store,id).revision == snapshots[index].revision) }
        await #expect(throws: NameIndexFailure.staleEdit) { try await store.applyLabelAddition(edit) }
        await store.close()
    }
    @Test func oneOverflowOrInvalidLabelRefusesEveryItemBeforeSave() async throws {
        let (store, ids) = try await LabelFixture().seeded(firstLabels: (0..<16).map { "label \($0)" })
        let snapshots = try await captures(store, ids)
        await #expect(throws: NameIndexFailure.invalidInput) { try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: ["extra"]) }
        for labels in [[], [""], ["line\nbreak"], [String(repeating: "é",count:65)], (0..<17).map { "\($0)" }] {
            await #expect(throws: (any Error).self) { try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: labels) }
        }
        #expect(await store.qualificationLabelBatchCount() == 0)
        for (index,id) in ids.enumerated() { #expect(try await names(store,id).revision == snapshots[index].revision) }
        await store.close()
    }
    @Test func maximum64IsSupportedButEmptyDuplicateOr65SelectionsRefuse() async throws {
        let (store, ids) = try await LabelFixture().seeded(64)
        let snapshots = try await captures(store, ids)
        await #expect(throws: NameIndexFailure.invalidInput) { try await store.prepareLabelAdditionFromSnapshots([], labels: ["checked"]) }
        await #expect(throws: NameIndexFailure.invalidInput) { try await store.prepareLabelAdditionFromSnapshots([snapshots[0],snapshots[0]], labels: ["checked"]) }
        await #expect(throws: NameIndexFailure.invalidInput) { try await store.prepareLabelAdditionFromSnapshots(snapshots + [snapshots[0]], labels: ["checked"]) }
        _ = try await store.snapshot(ids[0])
        #expect(!snapshots[0].publish { _ in Issue.record("Display snapshot should have retired") })
        let edit = try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: [String(repeating: "é",count:64)])
        #expect(try await store.applyLabelAddition(edit).changedItems == 64)
        #expect(try await store.qualificationStatistics().records == 64)
        await store.close()
    }
    @Test func staleOneRecordRefusesWholeBatchIncludingUnchangedRows() async throws {
        let (store, ids) = try await LabelFixture().seeded(firstLabels: ["existing", "new"])
        let snapshots = try await captures(store, ids)
        let edit = try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: ["new"])
        #expect(edit.changedCount == 2) // The concurrently changed target was a reviewed no-op.
        let concurrent = try await store.prepareEdit(snapshots[0], names: AuthoredNames(nickname: "Changed", labels: ["existing"]))
        _ = try await store.apply(concurrent)
        await #expect(throws: NameIndexFailure.staleEdit) { try await store.applyLabelAddition(edit) }
        #expect(try await names(store, ids[0]).names.labels == ["existing"])
        #expect(try await names(store, ids[0]).names.nickname == "Changed")
        #expect(try await names(store, ids[2]).names.labels == ["existing"])
        #expect(await store.qualificationLabelBatchCount() == 0)
        await store.close()
    }
    @Test func pendingHandleIsOpaqueBoundedCancelledAndForeignOrClosedCannotApply() async throws {
        let (first, ids) = try await LabelFixture().seeded(), (second, otherIDs) = try await LabelFixture().seeded()
        let snapshots = try await captures(first, ids)
        let edit = try await first.prepareLabelAdditionFromSnapshots(snapshots, labels: ["new"])
        await #expect(throws: NameIndexFailure.pendingLimit) { try await first.prepareLabelAdditionFromSnapshots(snapshots, labels: ["other"]) }
        await #expect(throws: NameIndexFailure.staleEdit) { try await second.applyLabelAddition(edit) }
        await first.cancelLabelAddition(edit)
        await #expect(throws: NameIndexFailure.staleEdit) { try await first.applyLabelAddition(edit) }
        #expect(try await names(second,otherIDs[0]).names.labels == ["existing"])
        let closed = try await first.prepareLabelAdditionFromSnapshots(captures(first, ids), labels: ["closed"])
        await first.close()
        #expect(await first.qualificationLabelBatchCount() == 0)
        await #expect(throws: NameStoreFailure.closed) { try await first.applyLabelAddition(closed) }
        await second.close()
    }
    @Test func forgetDestroysPendingPayloadAndCannotResurrectAnItem() async throws {
        let (store, ids) = try await LabelFixture().seeded()
        let edit = try await store.prepareLabelAdditionFromSnapshots(captures(store, ids), labels: ["must not return"])
        let request = try store.prepareForget(ids[1])
        #expect(try await store.finishForget(request) == .forgotten)
        #expect(await store.qualificationLabelBatchCount() == 0)
        await #expect(throws: NameIndexFailure.staleEdit) { try await store.applyLabelAddition(edit) }
        #expect(try await names(store,ids[0]).names.labels == ["existing"])
        await #expect(throws: NameIndexFailure.missingRecord) { try await store.snapshot(ids[1]) }
        await store.close()
    }
    @Test func secondRowRollbackAndUncertainCommitKeepWholeBatchOutcomesDistinct() async throws {
        for boundary in [NameStoreBoundary.saveRows, .saveCommit] {
            let fixture = try LabelFixture(), (original, ids) = try await fixture.seeded()
            await original.close()
            let count = LabelBoundaryCounter()
            let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
                if $0 == boundary, boundary == .saveCommit || count.next() == 2 { throw NameStoreFailure.unavailable }
            }, vfs: nil)
            let edit = try await store.prepareLabelAdditionFromSnapshots(captures(store, ids), labels: ["atomic"])
            await #expect(throws: (any Error).self) { try await store.applyLabelAddition(edit) }
            #expect(await store.qualificationLabelBatchCount() == 0)
            if boundary == .saveRows {
                for id in ids { #expect(try await names(store,id).names.labels == ["existing"]) }
            } else {
                await #expect(throws: NameStoreFailure.recoveryRequired) { try await store.snapshot(ids[0]) }
            }
            await store.close()
            let recovered = try await PersistentNameStore.open(directory: fixture.catalog, action: .recover)
            for id in ids { #expect(try await names(recovered,id).names.labels == (boundary == .saveCommit ? ["existing","atomic"] : ["existing"])) }
            #expect(try await recovered.resolveLabelAddition(edit) == (boundary == .saveCommit ? .saved : .notCurrent))
            await recovered.close()
        }
    }
    @Test func forgetDuringActualWriteWaitsForUseAndDoesNotResurrectSavedNames() async throws {
        let fixture = try LabelFixture(), (original, ids) = try await fixture.seeded()
        await original.close()
        let hold = LabelWriteHold(); defer { hold.release() }
        let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
            if $0 == .saveRows { hold.pauseOnce() }
        }, vfs: nil)
        let snapshots = try await captures(store,ids)
        var use: RememberedNameUse? = try store.beginUse(snapshots[1])
        let edit = try await store.prepareLabelAdditionFromSnapshots(snapshots, labels: ["concurrent"])
        let writing = Task { try await store.applyLabelAddition(edit) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !hold.entered {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NameStoreFailure.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
        let request = try store.prepareForget(ids[1])
        #expect(!snapshots[1].publish { _ in Issue.record("Withdrawn text published") })
        hold.release(); #expect(try await writing.value.changedItems == 3)
        let completion = LabelCompletion()
        let forgetting = Task { let result = try await store.finishForget(request); completion.finish(); return result }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!completion.finished)
        withExtendedLifetime(use) {}; use = nil
        #expect(try await forgetting.value == .forgotten)
        #expect(await store.qualificationLabelBatchCount() == 0)
        await #expect(throws: NameIndexFailure.missingRecord) { try await store.snapshot(ids[1]) }
        #expect(try await names(store,ids[0]).names.labels == ["existing","concurrent"])
        await store.close()
    }
    @Test func readOnlyOwnerCannotPrepareOrApplyAnAddition() async throws {
        let fixture = try LabelFixture(), (writer, ids) = try await fixture.seeded()
        let edit = try await writer.prepareLabelAdditionFromSnapshots(captures(writer, ids), labels: ["new"])
        await writer.close()
        let reader = try await PersistentNameStore.open(directory: fixture.catalog)
        await #expect(throws: NameStoreFailure.readOnly) { try await reader.prepareLabelAdditionFromSnapshots(captures(reader, ids), labels: ["new"]) }
        await #expect(throws: NameStoreFailure.readOnly) { try await reader.applyLabelAddition(edit) }
        #expect(try await names(reader,ids[0]).names.labels == ["existing"])
        await reader.close()
    }
}

private final class LabelBoundaryCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
private final class LabelWriteHold: @unchecked Sendable {
    private let condition = NSCondition(); private var waiting = false, released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
    func pauseOnce() {
        condition.lock(); defer { condition.unlock() }
        if waiting { return }; waiting = true
        while !released { condition.wait() }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private final class LabelCompletion: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var finished: Bool { lock.withLock { value } }
    func finish() { lock.withLock { value = true } }
}

private extension PersistentNameStore {
    func prepareLabelAdditionFromSnapshots(_ snapshots: [StoredNameSnapshot], labels: [String]) throws -> PreparedNameLabelAddition {
        try prepareLabelAddition(snapshots.map { NameLabelTarget(id: $0.id, revision: $0.revision) }, labels: labels)
    }
}
