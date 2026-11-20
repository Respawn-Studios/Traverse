import Darwin
import Foundation
@testable import FileOperations
import Testing

@Suite struct FolderComparisonTests {
    private struct Folders {
        let root: URL
        let left: URL
        let right: URL

        init() throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let base = package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
            guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
            root = base.appendingPathComponent("folder-comparison-" + UUID().uuidString, isDirectory: true)
            guard mkdir(root.path, 0o700) == 0 else { throw posixFailure() }
            left = root.appendingPathComponent("Left", isDirectory: true)
            right = root.appendingPathComponent("Right", isDirectory: true)
            do {
                for url in [left, right] {
                    try FileManager().createDirectory(at: url, withIntermediateDirectories: false)
                }
            } catch {
                try? FileManager().removeItem(at: root)
                throw error
            }
        }

        @discardableResult func file(_ name: String, in folder: URL, contents: String = "a",
                                    modified: TimeInterval = 1_700_000_000) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
            try FileManager().setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
            return url
        }

        func compare(hidden: Bool = false, limits: FolderMetadataComparison.Limits = .init(), contents: Bool = false,
                     check: () throws -> Void = {}) throws -> FolderComparisonReport {
            try FolderMetadataComparison.read(left: left, right: right, includingHidden: hidden,
                                              limits: limits, checkingContents: contents, checkCancellation: check)
        }

        func remove() { try? FileManager().removeItem(at: root) }
    }

    @Test func reportsOnlyDifferencesAndWalksSharedBranches() throws {
        let folders = try Folders()
        defer { folders.remove() }
        // Equal sizes and dates intentionally differ in byte content.
        try folders.file("Equal.txt", in: folders.left, contents: "AB")
        try folders.file("Equal.txt", in: folders.right, contents: "CD")
        try folders.file("Local branch/Unvisited.txt", in: folders.left)
        try folders.file("Shared/Size.txt", in: folders.left)
        try folders.file("Shared/Size.txt", in: folders.right, contents: "bbb")
        try folders.file("Shared/Time.txt", in: folders.left)
        try folders.file("Shared/Time.txt", in: folders.right, modified: 1_700_000_020)
        try folders.file("Shared/New.txt", in: folders.right)
        try folders.file("Type", in: folders.left)
        try folders.file("Type/Nested.txt", in: folders.right)

        let report = try folders.compare()
        #expect(report.matchingFiles == 1)
        #expect(report.comparedDirectories == 2)
        #expect(report.omissions == 0)
        #expect(report.rows.map(\.relativePath) == [
            "Local branch", "Shared/New.txt", "Shared/Size.txt", "Shared/Time.txt", "Type"
        ])
        #expect(report.rows.map(\.difference) == [
            .onlyOnLeft, .onlyOnRight, .differentSize, .differentModificationTime, .differentKind
        ])
        #expect(report.rows[2].left?.byteCount == 1)
        #expect(report.rows[2].right?.byteCount == 3)
        #expect(report.rows[3].right?.modifiedAt == Date(timeIntervalSince1970: 1_700_000_020))
    }

    @Test func textReviewUsesTheObservedFilesAndRequiresAbsenceToStillBeTrue() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let left = try folders.file("Shared/Éditions.txt", in: folders.left, contents: "before\r\n")
        let right = try folders.file("Shared/Éditions.txt", in: folders.right, contents: "and after\n")
        try folders.file("Shared/New.txt", in: folders.right, contents: "added\n")
        try folders.file("Unvisited/Nested.txt", in: folders.left)
        let report = try folders.compare()
        let pairID = try #require(report.rows.first { $0.relativePath == "Shared/Éditions.txt" }?.id)
        let pair = try #require(report.textSelection(for: pairID))
        let oneSidedID = try #require(report.rows.first { $0.relativePath == "Shared/New.txt" }?.id)
        let oneSided = try #require(report.textSelection(for: oneSidedID))
        let folderID = try #require(report.rows.first { $0.relativePath == "Unvisited" }?.id)
        #expect(report.textSelection(for: folderID) == nil)
        let text = try LocalTextComparisonRead.read(pair, checkCancellation: {})
        #expect(text.left.text == "before\n")
        #expect(text.left.format.lineEnding == .crlf)
        #expect(text.right.text == "and after\n")
        let added = try LocalTextComparisonRead.read(oneSided, checkCancellation: {})
        #expect(added.left.text.isEmpty && added.right.text == "added\n")
        #expect(throws: CancellationError.self) {
            try LocalTextComparisonRead.read(pair) { throw CancellationError() }
        }
        #expect(try Data(contentsOf: left) == Data("before\r\n".utf8))
        #expect(try Data(contentsOf: right) == Data("and after\n".utf8))
        try folders.file("Shared/New.txt", in: folders.left, contents: "now on both\n")
        #expect(throws: TextComparisonReadFailure.changed) {
            try LocalTextComparisonRead.read(oneSided, checkCancellation: {})
        }
        try Data("different\n".utf8).write(to: right, options: .atomic)
        #expect(throws: TextComparisonReadFailure.changed) {
            try LocalTextComparisonRead.read(pair, checkCancellation: {})
        }
    }

    @Test func contentCheckFindsEqualMetadataDifferencesAndSeparatesUninspectedPairs() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try folders.file(".git/Config", in: folders.left, contents: "a")
        try folders.file(".git/Config", in: folders.right, contents: "b")
        try folders.file("Changed.txt", in: folders.left, contents: "abc")
        try folders.file("Changed.txt", in: folders.right, contents: "abd")
        try folders.file("Same.txt", in: folders.left, contents: "same")
        try folders.file("Same.txt", in: folders.right, contents: "same", modified: 1_701_000_000)
        for index in 0..<63 {
            try folders.file("Z\(index).txt", in: folders.left)
            try folders.file("Z\(index).txt", in: folders.right)
        }
        let metadata = try folders.compare(hidden: true)
        #expect(metadata.contentReview == nil && metadata.rows.map(\.relativePath) == ["Same.txt"])
        let checked = try folders.compare(hidden: true, contents: true)
        let summary = try #require(checked.contentReview)
        #expect(summary.differences == 1 && summary.matches == 63 && summary.unchecked == 2)
        let differences = checked.rows.filter { $0.contents != .unchecked }
        let unchecked = checked.rows.filter { $0.contents == .unchecked }
        #expect(checked.differenceCount == 2 && differences.map(\.relativePath) == ["Changed.txt", "Same.txt"])
        #expect(differences.map(\.difference) == [.differentContents, .differentModificationTime])
        #expect(differences.last?.matchedContents == true)
        #expect(unchecked.count == 2 && unchecked.first?.relativePath == ".git/Config")
        #expect(unchecked.allSatisfy { $0.difference == .contentsNotChecked && checked.textSelection(for: $0.id) == nil })
        let changed = try #require(differences.first)
        let selection = try #require(checked.textSelection(for: changed.id))
        let texts = try LocalTextComparisonRead.read(selection, checkCancellation: {})
        #expect(texts.left.text == "abc" && texts.right.text == "abd")
    }

    @Test func editorSelectionKeepsTheChosenSideThroughTheOrdinaryOpen() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let selected = try folders.file("Nested/Version.txt", in: folders.right, contents: "actual right\n")
        try folders.file("Nested/Version.txt/Inside.txt", in: folders.left)
        let report = try folders.compare()
        let id = try #require(report.rows.first { $0.relativePath == "Nested/Version.txt" }?.id)
        #expect(report.textSelection(for: id) == nil)
        #expect(report.editorSelection(for: id, on: .left) == nil)
        let observation = try #require(report.editorSelection(for: id, on: .right))
        #expect(throws: CancellationError.self) {
            try LocalTextComparisonRead.editorSelection(observation) { throw CancellationError() }
        }
        let checked = try LocalTextComparisonRead.editorSelection(observation, checkCancellation: {})
        let engine = RecoverableFileOperations(journalDirectory: folders.root.appendingPathComponent("History"))
        let document = try await engine.readLocalTextDocument(at: selected, matching: checked)
        #expect(document.contents.text == "actual right\n")
        try Data("replacement\n".utf8).write(to: selected, options: .atomic)
        #expect(throws: TextComparisonReadFailure.changed) {
            try LocalTextComparisonRead.editorSelection(observation, checkCancellation: {})
        }
        await #expect(throws: FileOperationFailure.sourceChanged) {
            try await engine.readLocalTextDocument(at: selected, matching: checked)
        }
        #expect(try Data(contentsOf: selected) == Data("replacement\n".utf8))
    }

    @Test func completeMatchAndOversizedPairsReportDifferentCoverage() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try folders.file("Match.txt", in: folders.left)
        try folders.file("Match.txt", in: folders.right)
        let complete = try folders.compare(contents: true)
        #expect(complete.rows.isEmpty && complete.differenceCount == 0)
        #expect(complete.contentReview?.matches == 1 && complete.contentReview?.unchecked == 0)

        let bytes = String(repeating: "x", count: (1 << 20) + 1)
        try folders.file("Large.txt", in: folders.left, contents: bytes)
        let later = try folders.file("Large.txt", in: folders.right, contents: bytes)
        let partial = try folders.compare(contents: true)
        #expect(partial.differenceCount == 0 && partial.contentReview?.unchecked == 1)
        #expect(partial.rows.first?.relativePath == "Large.txt" && partial.rows.first?.difference == .contentsNotChecked)
        #expect(partial.rows.first.flatMap { partial.editorSelection(for: $0.id, on: .left) } == nil)
        try FileManager().setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_701_000_000)], ofItemAtPath: later.path)
        let changed = try folders.compare(contents: true)
        #expect(changed.differenceCount == 1 && changed.contentReview?.unchecked == 1)
        #expect(changed.rows.first?.difference == .differentModificationTime && changed.rows.first?.contents == .unchecked)
    }

    @Test func rawReviewBudgetChargesBothFileBodiesButOnlyOneDiskToGitRead() {
        var twoFiles = FileContentsReviewBudget(), git = FileContentsReviewBudget()
        for _ in 0..<4 {
            #expect(git.admit(size: 1 << 20, copies: 1) == .accepted(1 << 20))
        }
        for _ in 0..<2 {
            #expect(twoFiles.admit(size: 1 << 20, copies: 2) == .accepted(1 << 20))
        }
        #expect(twoFiles.admit(size: 1, copies: 2) == .exhaustedBytes)
        #expect(git.admit(size: 1, copies: 1) == .exhaustedBytes)
    }

    @Test func contentReviewKeepsRecoveryPayloadsOutEvenWithHiddenItemsShown() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let recovery = ".mac-explorer-recovery-\(UUID().uuidString)"
        try folders.file("\(recovery)/payload", in: folders.left, contents: "a")
        try folders.file("\(recovery)/payload", in: folders.right, contents: "b")
        try folders.file(".mac-explorer-recovery-notes.txt", in: folders.left)
        let checked = try folders.compare(hidden: true, contents: true)
        #expect(checked.rows.map(\.relativePath) == [".mac-explorer-recovery-notes.txt"])
        #expect(checked.contentReview?.differences == 0 && checked.contentReview?.unchecked == 0)
        #expect(throws: FolderComparisonFailure.unsupported(.left)) {
            try FolderMetadataComparison.read(left: folders.left.appendingPathComponent(recovery), right: folders.right,
                includingHidden: true, checkingContents: true, checkCancellation: {})
        }
    }

    @Test func missingFileGroupKeepsOriginalsAndSupportsOneColdUndo() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let bytes = Data("café original\n".utf8)
        let source = try folders.file("Shared/Éditions.txt", in: folders.left, contents: "café original\n")
        let extra = try folders.file("Shared/Extra.txt", in: folders.left, contents: "another")
        let peer = try folders.file("Shared/Peer.txt", in: folders.right, contents: "peer")
        try folders.file("Elsewhere/Single.txt", in: folders.left)
        try folders.file("Elsewhere/Existing.txt", in: folders.right)
        try folders.file("Unvisited/Nested.txt", in: folders.left)
        let report = try folders.compare()
        let row = try #require(report.rows.first { $0.relativePath == "Shared/Éditions.txt" })
        let extraRow = try #require(report.rows.first { $0.relativePath == "Shared/Extra.txt" })
        let copy = try #require(report.missingFileCopy(for: [row.id, extraRow.id]))
        let reverse = try #require(report.rows.first { $0.relativePath == "Shared/Peer.txt" })
        #expect(report.missingFileCopy(for: [reverse.id])?.destinationSide == .left)
        #expect(report.missingFileCopy(for: [row.id, reverse.id]) == nil)
        let elsewhere = try #require(report.rows.first { $0.relativePath == "Elsewhere/Single.txt" })
        #expect(report.missingFileCopy(for: [row.id, elsewhere.id]) == nil)
        let branch = try #require(report.rows.first { $0.relativePath == "Unvisited" })
        #expect(report.missingFileCopy(for: [branch.id]) == nil)
        #expect(Set(copy.sources) == [source, extra] && copy.destinationSide == .right)
        #expect(copy.destinationDirectory == peer.deletingLastPathComponent())

        let journal = folders.root.appendingPathComponent("history", isDirectory: true)
        let service = RecoverableFileOperations(journalDirectory: journal)
        let plan = try await service.prepareTransfer(sources: copy.sources, destinationDirectory: copy.destinationDirectory,
            move: false, observing: copy.observation, requireVacantDestination: true)
        let target = copy.destinationDirectory.appendingPathComponent(source.lastPathComponent)
        let counterpart = copy.destinationDirectory.appendingPathComponent(extra.lastPathComponent)
        let outcome = await service.perform(plan)
        let record = try #require(outcome.recordID)
        #expect(outcome.result.disposition == .succeeded)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: counterpart) == Data("another".utf8))
        #expect(try Data(contentsOf: source) == bytes)
        let cold = RecoverableFileOperations(journalDirectory: journal)
        #expect(await cold.undo(recordID: record).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: target.path))
        #expect(!FileManager().fileExists(atPath: counterpart.path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: peer) == Data("peer".utf8))
    }

    @Test func reportCopyRefusesStaleObjectsAndNamesOccupiedBeforeOrDuringTransfer() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let source = try folders.file("Shared/Copy.txt", in: folders.left, contents: "original")
        let peer = try folders.file("Shared/Peer.txt", in: folders.right, contents: "peer")
        let report = try folders.compare()
        let row = try #require(report.rows.first { $0.relativePath == "Shared/Copy.txt" })
        let copy = try #require(report.missingFileCopy(for: [row.id]))
        let journal = folders.root.appendingPathComponent("history", isDirectory: true)
        let service = RecoverableFileOperations(journalDirectory: journal)
        let target = try folders.file("Shared/Copy.txt", in: folders.right, contents: "occupied")
        await #expect(throws: FileOperationFailure.conflict) {
            try await service.prepareTransfer(sources: copy.sources, destinationDirectory: copy.destinationDirectory,
                move: false, observing: copy.observation, requireVacantDestination: true)
        }
        #expect(try Data(contentsOf: target) == Data("occupied".utf8))
        try FileManager().removeItem(at: target)

        let lateBytes = Data("late arrival".utf8)
        let racingService = RecoverableFileOperations(journalDirectory: journal, hooks: RecoveryHooks(
            beforeExclusiveRename: { _, destination in
                if destination == target { try lateBytes.write(to: target, options: .withoutOverwriting) }
            }))
        let plan = try await racingService.prepareTransfer(sources: copy.sources,
            destinationDirectory: copy.destinationDirectory, move: false, observing: copy.observation,
            requireVacantDestination: true)
        let outcome = await racingService.perform(plan)
        #expect(outcome.result.disposition == .failed)
        #expect(try Data(contentsOf: target) == lateBytes)
        #expect(try Data(contentsOf: source) == Data("original".utf8))
        try FileManager().removeItem(at: target)

        let parent = peer.deletingLastPathComponent()
        let parked = folders.right.appendingPathComponent("Parked", isDirectory: true)
        try FileManager().moveItem(at: parent, to: parked)
        try FileManager().createDirectory(at: parent, withIntermediateDirectories: false)
        await #expect(throws: FileOperationFailure.destinationChanged) {
            try await service.prepareTransfer(sources: copy.sources, destinationDirectory: copy.destinationDirectory,
                move: false, observing: copy.observation, requireVacantDestination: true)
        }
        try FileManager().removeItem(at: parent)
        try FileManager().moveItem(at: parked, to: parent)
        try Data("modified".utf8).write(to: source, options: .atomic)
        await #expect(throws: FileOperationFailure.sourceChanged) {
            try await service.prepareTransfer(sources: copy.sources, destinationDirectory: copy.destinationDirectory,
                move: false, observing: copy.observation, requireVacantDestination: true)
        }
        #expect(!FileManager().fileExists(atPath: target.path))
        #expect(try Data(contentsOf: peer) == Data("peer".utf8))
    }

    @Test func lateOccupiedNameRetainsPartialReviewAndKeepsTheNewOccupant() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let first = try folders.file("A.txt", in: folders.left, contents: "a")
        let second = try folders.file("B.txt", in: folders.left, contents: "b")
        let aTarget = folders.right.appendingPathComponent("A.txt")
        let bTarget = folders.right.appendingPathComponent("B.txt")
        let occupant = Data("late arrival".utf8)
        let report = try folders.compare()
        let copy = try #require(report.missingFileCopy(for: Set(report.rows.map(\.id))))
        let journal = folders.root.appendingPathComponent("history", isDirectory: true)
        let service = RecoverableFileOperations(journalDirectory: journal, hooks: RecoveryHooks(
            beforeExclusiveRename: { _, destination in
                if destination == bTarget { try occupant.write(to: bTarget, options: .withoutOverwriting) }
            }))
        let plan = try await service.prepareTransfer(sources: copy.sources, destinationDirectory: copy.destinationDirectory,
            move: false, observing: copy.observation, requireVacantDestination: true)
        let outcome = await service.perform(plan)
        let record = try #require(outcome.recordID)
        #expect(outcome.result.disposition == .partial)
        #expect(try Data(contentsOf: aTarget) == Data("a".utf8))
        #expect(try Data(contentsOf: bTarget) == occupant)
        let cold = RecoverableFileOperations(journalDirectory: journal)
        let history = try await cold.inspectExistingHistory()
        let partial = try #require(history.records.first { $0.id == record })
        #expect(partial.state == "needsReview" && partial.canRecover && !partial.canUndo)
        #expect(await cold.undo(recordID: record).result.disposition == .failed)
        #expect(try Data(contentsOf: aTarget) == Data("a".utf8))
        #expect(try Data(contentsOf: bTarget) == occupant)
        #expect(try Data(contentsOf: first) == Data("a".utf8))
        #expect(try Data(contentsOf: second) == Data("b".utf8))
    }

    @Test func hiddenNamesAndProtectedBranchesHaveDistinctRules() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try folders.file(".hidden.txt", in: folders.left)
        try folders.file(".ssh/GeneratedLeft.txt", in: folders.left)
        try folders.file(".ssh/GeneratedRight.txt", in: folders.right)
        try folders.file("Flagged.txt", in: folders.left)
        let flagged = try folders.file("Flagged.txt", in: folders.right)
        try #require(chflags(flagged.path, UInt32(UF_HIDDEN)) == 0)
        try folders.file("case.txt", in: folders.left)
        try folders.file("Case.txt", in: folders.right)
        let visible = try folders.compare()
        #expect(visible.rows.map(\.relativePath) == ["Case.txt", "Flagged.txt", "case.txt"])
        #expect(visible.rows[1].omission == .hidden)
        let all = try folders.compare(hidden: true)
        #expect(all.matchingFiles == 1)
        #expect(all.rows.map(\.relativePath) == [".hidden.txt", ".ssh", "Case.txt", "case.txt"])
        #expect(all.rows[1].omission == .protectedLocation)
    }

    @Test func symbolicLinksAreSkippedAndCannotBecomeComparisonRoots() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try folders.file("Other.txt", in: folders.root)
        for parent in [folders.left, folders.right] {
            try FileManager().createSymbolicLink(atPath: parent.appendingPathComponent("Alias").path,
                                                withDestinationPath: folders.root.path)
        }
        let report = try folders.compare()
        #expect(report.rows.first?.omission == .symbolicLink)
        #expect(report.rows.count == 1)
        #expect(throws: FolderComparisonFailure.unsupported(.left)) {
            try FolderMetadataComparison.read(left: folders.left.appendingPathComponent("Alias"),
                                              right: folders.right, includingHidden: false, checkCancellation: {})
        }
        #expect(throws: FolderComparisonFailure.sameFolder) {
            try FolderMetadataComparison.read(left: folders.left, right: folders.left, includingHidden: false,
                                              checkCancellation: {})
        }
    }

    @Test(.enabled(if: geteuid() != 0)) func unreadableSharedBranchNeverLooksEmpty() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try folders.file("Shared/Available.txt", in: folders.left)
        try folders.file("Shared/Denied.txt", in: folders.right)
        let denied = folders.right.appendingPathComponent("Shared")
        try #require(chmod(denied.path, 0o100) == 0)
        defer { _ = chmod(denied.path, 0o700) }
        let report = try folders.compare()
        #expect(report.rows.map(\.relativePath) == ["Shared"])
        #expect(report.rows.first?.omission == .unreadable)
    }

    @Test func cancellationAndLimitsRefuseIncompleteResults() throws {
        let folders = try Folders()
        defer { folders.remove() }
        for side in [folders.left, folders.right] {
            try folders.file("Shared/Generated.txt", in: side)
        }
        #expect(throws: FolderComparisonFailure.limitExceeded) { try folders.compare(limits: .init(entries: 1)) }
        #expect(throws: FolderComparisonFailure.limitExceeded) { try folders.compare(limits: .init(pathBytes: 4)) }
        #expect(throws: FolderComparisonFailure.limitExceeded) { try folders.compare(limits: .init(depth: 0)) }
        var checks = 0
        #expect(throws: CancellationError.self) {
            try folders.compare {
                checks += 1
                if checks >= 5 { throw CancellationError() }
            }
        }
        #expect(checks == 5)
    }

    @Test func refusesAChangedDirectorySnapshot() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try folders.file("Before.txt", in: folders.left)
        var checks = 0
        #expect(throws: FolderComparisonFailure.changed) {
            try folders.compare {
                checks += 1
                if checks == 3 {
                    // The root snapshots and handles exist by the time the
                    // worker starts enumerating the first directory.
                    try folders.file("During.txt", in: folders.left)
                }
            }
        }
    }
}
