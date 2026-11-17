import Darwin
import Foundation
import ExplorerCore
@testable import LocalStorage
import Testing

private struct DiagnosticFixture {
    let root: URL
    var store: URL { root.appendingPathComponent("diagnostics", isDirectory: true) }
    init() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base: URL
        if let text = ProcessInfo.processInfo.environment["TRAVERSE_DIAGNOSTIC_TEST_ROOT"] {
            // Preserve old explicit release packets, without requiring one for
            // the ordinary package-test command.
            base = URL(fileURLWithPath: text)
            guard base.path.hasPrefix(repo.appendingPathComponent(".build/traverse-release").path + "/"),
                  base.resolvingSymlinksInPath().path == base.path else { throw DiagnosticHistoryFailure.invalidInput }
        } else {
            base = repo.appendingPathComponent("Packages/ExplorerKit/.build/test-fixtures", isDirectory: true)
            guard base.resolvingSymlinksInPath().path == base.path else { throw DiagnosticHistoryFailure.invalidInput }
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        }
        root = base.appendingPathComponent("diagnostic-" + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var limits: DiagnosticHistoryLimits { get throws { try .init(bytes: 64 << 10, segmentBytes: 8 << 10) } }
    func event(_ n: UInt64 = 1) -> DiagnosticEvent {
        .init(session: UUID(), trace: UUID(), action: .copy, phase: .completed, count: n,
              build: try? .init(version: "0.1.3", number: 9))
    }
    func segments() throws -> [URL] {
        try FileManager().contentsOfDirectory(at: store, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".jsonl") }.sorted { $0.path < $1.path }
    }
}

@Suite(.serialized) struct DiagnosticHistoryTests {
    @Test func operationReviewAndExportFindLinkedStagesBeyondTheCurrentPage() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store,
            limits: try .init(bytes: 512 << 10, segmentBytes: 8 << 10), recording: true)
        let session = UUID(), trace = UUID(), worker = UUID(), child = UUID()
        func event(_ id: UUID, _ phase: DiagnosticPhase, related: UUID? = nil) -> DiagnosticEvent {
            .init(session: session, trace: id, action: .fileOperation, phase: phase,
                level: phase == .failed ? .error : .information, relatedTrace: related)
        }
        let failure = event(trace, .failed)
        let childStep = event(child, .verifying)
        let rootLink = event(worker, .admitted, related: trace)
        let childLink = event(worker, .committing, related: child)
        recorder.record(failure)
        for _ in 0..<150 { recorder.record(fixture.event()) }
        recorder.record(childStep); recorder.record(rootLink)
        for _ in 0..<150 { recorder.record(fixture.event()) }
        recorder.record(childLink)
        for _ in 0..<150 { recorder.record(fixture.event()) }
        await recorder.flush()
        do {
            let latest = try await recorder.page(limit: 128)
            try #require(!latest.events.contains { $0.id == failure.id })
            let first = try await recorder.page(limit: 2, scope: .operation(trace))
            try #require(first.events == [childLink, rootLink] && !first.incomplete)
            let second = try await recorder.page(before: first.next, limit: 2, scope: .operation(trace))
            try #require(second.events == [childStep, failure] && !second.incomplete)
            let warnings = try await recorder.page(errorsOnly: true, scope: .operation(trace))
            try #require(warnings.events == [failure] && !warnings.incomplete)
            let report = fixture.root.appendingPathComponent("operation.json")
            let metadata = DiagnosticExportMetadata(build: try .init(version: "0.1.5", number: 71),
                runtime: .init(osMajor: 27, osMinor: 2, osPatch: 0, architecture: .arm64,
                    edition: .developerID, processID: 42))
            let exported = await recorder.export(to: report, retainingAccess: (), scope: .operation(trace), metadata: metadata)
            guard case .saved(let count, _, let partial) = exported else {
                throw DiagnosticHistoryFailure.unavailable
            }
            try #require(count == 4 && !partial)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
            let records = try #require(object["events"] as? [[String: Any]])
            let exporter = try #require(object["exporter"] as? [String: Any])
            try #require(try JSONDecoder().decode(DiagnosticExportMetadata.self,
                from: JSONSerialization.data(withJSONObject: exporter)) == metadata)
            try #require(records.allSatisfy { $0["runtime"] == nil })
            var invalidExporter = exporter
            invalidExporter["build"] = ["version": "generated-private-text", "number": 71]
            let invalidMetadata = try JSONDecoder().decode(DiagnosticExportMetadata.self,
                from: JSONSerialization.data(withJSONObject: invalidExporter))
            let invalidReport = fixture.root.appendingPathComponent("invalid-metadata.json")
            try #require(await recorder.export(to: invalidReport, retainingAccess: (), scope: .operation(trace),
                metadata: invalidMetadata) == .notCreated(.io))
            try #require(!FileManager().fileExists(atPath: invalidReport.path))
            try #require(object["scope"] as? String == "operation" && object["rootTrace"] as? String == trace.uuidString)
            try #require(Set(records.compactMap { $0["id"] as? String }) == Set([failure, childStep, rootLink, childLink].map { $0.id.uuidString }))
            let absent = fixture.root.appendingPathComponent("absent-operation.json")
            try #require(await recorder.export(to: absent, retainingAccess: (), scope: .operation(UUID())) == .notCreated(.empty))
            try #require(!FileManager().fileExists(atPath: absent.path))
            let cancelled = DiagnosticExportCancellation(); cancelled.cancel()
            let cancelledURL = fixture.root.appendingPathComponent("cancelled-operation.json")
            try #require(await recorder.export(to: cancelledURL, retainingAccess: (), cancellation: cancelled,
                                               scope: .operation(trace)) == .notCreated(.cancelled))
            try #require(!FileManager().fileExists(atPath: cancelledURL.path))
            await recorder.closeAndDrain()
            try FileManager().removeItem(at: fixture.root)
        } catch {
            await recorder.closeAndDrain()
            throw error
        }
    }

    @Test func disabledConstructionAndReviewAreInert() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: false)
        recorder.record(fixture.event()); await recorder.flush()
        #expect(try await recorder.page().events.isEmpty)
        #expect(!FileManager().fileExists(atPath: fixture.store.path))
        await recorder.closeAndDrain()
    }

    @Test func durableReopenPreservesExactEventsAndPagination() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        let values = (0..<12).map { fixture.event(UInt64($0)) }
        for value in values { recorder.record(value) }; await recorder.closeAndDrain()
        let reader = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: false)
        let a = try await reader.page(limit: 5)
        let b = try await reader.page(before: a.next, limit: 5)
        let c = try await reader.page(before: b.next, limit: 5)
        #expect(a.events + b.events + c.events == Array(values.reversed()))
        #expect(!a.incomplete && !b.incomplete && !c.incomplete)
        #expect(c.next == nil)
        await reader.closeAndDrain()
    }

    @Test func closedVocabularyAndNumericBuildRejectSensitiveInputs() throws {
        #expect(throws: (any Error).self) { try DiagnosticBuild(version: "/Users/Private", number: 1) }
        #expect(throws: (any Error).self) { try DiagnosticBuild(version: "1.2.3\npassword", number: 1) }
        let fixture = try DiagnosticFixture(), bytes = try JSONEncoder().encode(fixture.event())
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys).isSubset(of: ["schema","id","session","trace","action","phase","level",
            "utcMilliseconds","uptimeNanoseconds","count","durationMilliseconds","error","build","command","ordinal","relatedTrace"]))
        var malformed = object; malformed["action"] = "private-file.txt"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: malformed)) }
    }

    @Test func generatedSMBSourceFailuresHaveOnlyClosedSymbols() {
        let expected = ["smb.generated.unsafe", "smb.generated.unavailable", "smb.generated.busy",
                        "smb.generated.capacity", "smb.generated.changed", "smb.generated.stopped", "smb.generated.retained"]
        for (offset, symbol) in expected.enumerated() {
            #expect(DiagnosticErrorCode(domain: .network, code: Int64(481 + offset)).symbol == symbol)
        }
        #expect(DiagnosticErrorCode(domain: .network, code: 488).symbol == nil)
    }
    @Test func firstOpenPermissionRefusalHasOnlyTheClosedDiagnosticSymbol() {
        #expect(DiagnosticErrorCode(domain: .network, code: 517).symbol == "sftp.upload.firstOpenPermissionRefused")
        #expect(DiagnosticErrorCode(domain: .network, code: 516).symbol == nil)
        #expect(DiagnosticErrorCode(domain: .network, code: 518).symbol == nil)
        #expect(DiagnosticErrorCode(domain: .network, code: 615).symbol == "sftp.upload.openingFinal")
        #expect(DiagnosticErrorCode(domain: .network, code: 704).symbol == "sftp.status.permissionDenied")
    }
    @Test func copyMetadataBoundariesRoundtripAsClosedSymbols() throws {
        for (offset, symbol) in ["copy.metadataComparison", "copy.receiptCoverage", "copy.nativeReceipt"].enumerated() {
            let event = DiagnosticEvent(session: UUID(), trace: UUID(), action: .fileOperation, phase: .failed,
                error: .init(domain: .operation, code: Int64(601 + offset)),
                context: .init(.nativeStatus), causes: [.init(domain: .operation, code: 8)])
            let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event))
            #expect(decoded == event && decoded.error?.symbol == symbol)
            #expect(decoded.causes?.first?.symbol == "copyMetadataMismatch")
        }
        #expect(DiagnosticErrorCode(domain: .operation, code: 600).symbol == nil)
        #expect(DiagnosticErrorCode(domain: .operation, code: 604).symbol == nil)
    }
    @Test func smbActionPreflightUsesOnlyFixedComparisonSymbols() {
        let expected = ["sourceDirectory", "sourceAttributes", "sourceSize", "sourceModifiedTime", "sourceObjectID",
                        "sourceLinkCount", "sourceVolumeSerial", "sourceVolumeCreation", "createAttributes", "createModifiedTime"]
        for (offset, suffix) in expected.enumerated() {
            #expect(DiagnosticErrorCode(domain: .network, code: Int64(1621 + offset)).symbol == "smb.fileAction." + suffix)
        }
        #expect(DiagnosticErrorCode(domain: .network, code: 1620).symbol == nil)
        #expect(DiagnosticErrorCode(domain: .network, code: 1631).symbol == "smb.fileAction.destinationUnavailable")
        #expect(DiagnosticErrorCode(domain: .network, code: 1632).symbol == nil)
    }
    @Test func smbMoveFaultsExposeOnlyFixedBoundarySymbols() {
        let expected = ["sourceCheck", "targetProbe", "renameRequest", "targetPin",
                        "sourceRelease", "finalVerification", "completeReceived", "journalConfirmed"]
        for (offset, suffix) in expected.enumerated() {
            #expect(DiagnosticErrorCode(domain: .network, code: Int64(1641 + offset)).symbol
                == "smb.fileAction.move." + suffix)
        }
        #expect(DiagnosticErrorCode(domain: .network, code: 1640).symbol == nil)
        #expect(DiagnosticErrorCode(domain: .network, code: 1649).symbol == nil)
    }
    @Test func smbCopyFaultsExposeOnlyFixedBoundarySymbols() {
        let expected = ["sourceCheck", "stageOpen", "chunkTransfer", "stageFlush",
                        "publish", "finalVerification", "completeReceived", "journalConfirmed"]
        for (offset, suffix) in expected.enumerated() {
            #expect(DiagnosticErrorCode(domain: .network, code: Int64(1651 + offset)).symbol
                == "smb.fileAction.copy." + suffix)
        }
        #expect(DiagnosticErrorCode(domain: .network, code: 1650).symbol == nil)
        #expect(DiagnosticErrorCode(domain: .network, code: 1659).symbol == nil)
    }

    @Test func interruptedTailIsPreservedAndReported() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        let event = fixture.event(); recorder.record(event); await recorder.closeAndDrain()
        let segment = try #require(fixture.segments().first)
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"interrupted\":".utf8)); try handle.close()
        let before = try Data(contentsOf: segment)
        let reopened = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        let page = try await reopened.page()
        #expect(page.events == [event] && page.incomplete)
        reopened.record(fixture.event()); await reopened.closeAndDrain()
        #expect(try Data(contentsOf: segment) == before)
    }

    @Test func technicalContextAndCanonicalErrorSymbolsSurviveReopen() async throws {
        let fixture = try DiagnosticFixture()
        let event = DiagnosticEvent(session: UUID(), trace: UUID(), action: .queue, phase: .failed,
            error: .init(domain: .operation, code: 8),
            context: .init(.queueMutation, flags: [.sourceObserved,.destinationObserved,.retainedScope,.paused],
                queueDepth: 3, preparingAdmissions: 1, smbCommandCounts: (0..<19).map(UInt64.init)),
            causes: [.init(domain: .posix, code: 13)],
            runtime: .init(osMajor: 27, osMinor: 0, osPatch: 1, architecture: .arm64, edition: .developerID, processID: 123))
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        recorder.record(event); await recorder.closeAndDrain()
        let reader = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: false)
        let saved = try #require(try await reader.page().events.first)
        #expect(saved == event && saved.error?.symbol == "copyMetadataMismatch")
        #expect(saved.causes?.first?.symbol == "EACCES" && saved.context?.queueDepth == 3)
        #expect(saved.runtime?.processID == 123 && saved.runtime?.architecture == .arm64)
        #expect(saved.context?.smbCommandCounts == (0..<19).map(UInt64.init))
        let encoded = try JSONEncoder().encode(saved)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var error = try #require(json["error"] as? [String: Any])
        error["symbol"] = "private-path-password-do-not-retain"; json["error"] = error
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("private-path-password"))
        var context = try #require(json["context"] as? [String: Any])
        context["flags"] = ["private-file.txt"]; json["context"] = context
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json)) }
        await reader.closeAndDrain()
    }

    @Test func technicalStateAndCauseBoundsRejectUntrustedDecodedRecords() throws {
        let context = DiagnosticContext(.queueAdmission, flags: Array(repeating: .paused, count: 100), queueDepth: 1000, preparingAdmissions: -1)
        #expect(context.flags == [.paused] && context.queueDepth == 16 && context.preparingAdmissions == 0)
        let event = DiagnosticEvent(session: UUID(), trace: UUID(), action: .queue, phase: .waiting, context: context,
            causes: Array(repeating: .init(domain: .posix, code: 13), count: 100))
        #expect(event.causes?.count == 3 && event.isValid)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        var malformed = try #require(json["context"] as? [String: Any])
        malformed["queueDepth"] = 255; json["context"] = malformed
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.isValid)
        malformed["queueDepth"] = 3
        malformed["smbCommandCounts"] = [UInt64](repeating: 0, count: 20); json["context"] = malformed
        let oversized = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!oversized.isValid)
        malformed.removeValue(forKey: "smbCommandCounts"); json["context"] = malformed
        let older = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.isValid && older.context?.smbCommandCounts == nil)
        #expect(DiagnosticErrorCode(domain: .operation, code: Int64.max).symbol == nil)
    }

    @Test func smbWorkerFailureCoordinatesRoundtripWithoutFreeFormText() throws {
        let coordinates = DiagnosticSMBFailure(boundary: 4, cause: 7, command: 5, status: 0xc0000022)
        let event = DiagnosticEvent(session: UUID(), trace: UUID(), action: .remoteUpload, phase: .failed,
            error: .init(domain: .network, code: 1507), context: .init(.nativeStatus, smbFailure: coordinates))
        let bytes = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: bytes)
        #expect(decoded == event && decoded.isValid && decoded.error?.symbol == "smb.folderUpload.denied")
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var context = try #require(json["context"] as? [String: Any])
        var fixed = try #require(context["smbFailure"] as? [String: Any])
        #expect(Set(fixed.keys) == ["boundary", "cause", "command", "status"])
        fixed["boundary"] = 11; context["smbFailure"] = fixed; json["context"] = context
        let invalid = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!invalid.isValid)
        context.removeValue(forKey: "smbFailure"); json["context"] = context
        let legacy = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.isValid && legacy.context?.smbFailure == nil)
    }

    @Test func competingWriterAndForeignStateAreRefused() async throws {
        let fixture = try DiagnosticFixture()
        let first = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        first.record(fixture.event()); await first.flush()
        let second = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        second.record(fixture.event()); await second.flush()
        #expect(second.status.failure == .busy && second.status.dropped > 0)
        await second.closeAndDrain(); await first.closeAndDrain()
        let foreign = fixture.root.appendingPathComponent("foreign")
        try FileManager().createDirectory(at: foreign, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let secret = foreign.appendingPathComponent("keep.txt"), data = Data("Generated unrelated data".utf8)
        try data.write(to: secret)
        let refused = DiagnosticRecorder(directory: foreign, limits: try fixture.limits, recording: true)
        refused.record(fixture.event()); await refused.closeAndDrain()
        #expect(refused.status.failure != nil)
        #expect(try Data(contentsOf: secret) == data)
        #expect(try FileManager().contentsOfDirectory(atPath: foreign.path) == ["keep.txt"])
    }

    @Test func rootReplacementAndLinkedFilesCannotRedirectWrites() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        recorder.record(fixture.event()); await recorder.flush()
        let retained = fixture.root.appendingPathComponent("retained")
        try FileManager().moveItem(at: fixture.store, to: retained)
        try FileManager().createDirectory(at: fixture.store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        recorder.record(fixture.event()); await recorder.flush()
        #expect(recorder.status.failure == .changed)
        #expect(try FileManager().contentsOfDirectory(at: fixture.store, includingPropertiesForKeys: nil).isEmpty)
        await recorder.closeAndDrain()
        let other = try DiagnosticFixture()
        let original = DiagnosticRecorder(directory: other.store, limits: try other.limits, recording: true)
        original.record(other.event()); await original.closeAndDrain()
        let file = try #require(other.segments().first)
        let linked = other.root.appendingPathComponent("keep-linked")
        #expect(link(file.path, linked.path) == 0)
        let copy = DiagnosticRecorder(directory: other.store, limits: try other.limits, recording: true)
        copy.record(other.event()); await copy.closeAndDrain()
        #expect(copy.status.failure != nil)
    }

    @Test func rotationStaysBoundedAndClearAffectsOnlyOwnedHistory() async throws {
        let fixture = try DiagnosticFixture()
        let outside = fixture.root.appendingPathComponent("unrelated-export.json"), data = Data("Generated export to retain".utf8)
        try data.write(to: outside)
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        for n in 0..<500 { recorder.record(fixture.event(UInt64(n))) }; await recorder.flush()
        #expect(recorder.status.failure == nil)
        let bytes = try FileManager().contentsOfDirectory(at: fixture.store, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        #expect(bytes <= 64 << 10)
        let page = try await recorder.page()
        #expect(!page.events.isEmpty && page.events.count <= 128)
        try await recorder.clear()
        #expect(try await recorder.page().events.isEmpty)
        #expect(try Data(contentsOf: outside) == data)
        recorder.record(fixture.event()); await recorder.closeAndDrain()
    }

    @Test func writeFailureIsVisibleAndDoesNotAffectCallerFiles() async throws {
        let fixture = try DiagnosticFixture(), sentinel = fixture.root.appendingPathComponent("sentinel")
        let data = Data("Generated original stays unchanged".utf8); try data.write(to: sentinel)
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true,
            probe: { stage in if stage == .beforeAppend { throw DiagnosticHistoryFailure.io(ENOSPC) } })
        recorder.record(fixture.event()); await recorder.flush()
        #expect(recorder.status.failure == .io(ENOSPC) && recorder.status.dropped == 1)
        recorder.record(fixture.event()); await recorder.closeAndDrain()
        #expect(recorder.status.dropped == 2)
        #expect(try Data(contentsOf: sentinel) == data)
    }

    @Test func boundedIngressDoesNotWaitForBlockedFilesystemAndReportsGaps() async throws {
        let fixture = try DiagnosticFixture(), hold = DiagnosticWriteHold()
        let limits = try DiagnosticHistoryLimits(bytes: 64 << 10, segmentBytes: 8 << 10, pendingEvents: 3)
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: limits, recording: true,
            probe: { stage in if stage == .beforeAppend { hold.blockOnce() } })
        defer { hold.release() }
        recorder.record(fixture.event())
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !hold.started && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(hold.started && !hold.wasMainThread)
        let began = ProcessInfo.processInfo.systemUptime
        for n in 0..<5 { recorder.record(fixture.event(UInt64(n))) }
        #expect(ProcessInfo.processInfo.systemUptime - began < 0.25)
        #expect(recorder.status.pending == 3 && recorder.status.dropped == 2)
        hold.release(); await recorder.flush()
        let page = try await recorder.page()
        #expect(page.events.count == 5)
        #expect(page.events.contains { $0.action == .historyGap && $0.count == 2 })
        await recorder.closeAndDrain()
    }

    @Test func pausedRecordingAndClearDoNotResumeRecording() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        recorder.record(fixture.event()); await recorder.flush(); recorder.setRecording(false)
        recorder.record(fixture.event()); await recorder.flush()
        #expect(try await recorder.page().events.count == 1)
        try await recorder.clear()
        #expect(!recorder.status.recording)
        recorder.record(fixture.event()); await recorder.flush()
        #expect(try await recorder.page().events.isEmpty)
        await recorder.closeAndDrain()
    }

    @Test func expiredSegmentsArePrunedWithoutChangingNewerRecords() throws {
        let fixture = try DiagnosticFixture()
        let owner = try OwnedDiagnosticFiles(directory: fixture.store, limits: fixture.limits)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try owner.append([fixture.event(1)], now: old)
        let newer = fixture.event(2)
        try owner.append([newer], now: old.addingTimeInterval(15 * 86400))
        let page = try owner.page(before: nil, limit: 10, errorsOnly: false)
        #expect(page.events == [newer])
    }

    @Test func replacedAppendTargetIsRefusedAfterTheLastHook() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true,
            probe: { stage in
                if stage == .beforeAppend {
                    let file = try #require(fixture.segments().first)
                    try FileManager().moveItem(at: file, to: fixture.root.appendingPathComponent("retained-original.jsonl"))
                    try Data("Generated replacement remains unchanged".utf8).write(to: file)
                    #expect(chmod(file.path, 0o600) == 0)
                }
            })
        recorder.record(fixture.event()); await recorder.flush()
        #expect(recorder.status.failure == .changed)
        let file = try #require(fixture.segments().first)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Generated replacement remains unchanged")
        await recorder.closeAndDrain()
    }

    @Test func typedExportStripsUnknownFieldsAndRefusesReplacement() async throws {
        let fixture = try DiagnosticFixture()
        let writer = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        writer.record(fixture.event()); await writer.closeAndDrain()
        let segment = try #require(fixture.segments().first)
        var lines = try Data(contentsOf: segment).split(separator: 10).map(Data.init)
        var value = try #require(JSONSerialization.jsonObject(with: lines[1]) as? [String: Any])
        value["untrustedPath"] = "/Users/GeneratedPrivate/Hidden.txt"
        value["untrustedPassword"] = "generated-secret-must-not-export"
        lines[1] = try JSONSerialization.data(withJSONObject: value)
        var encoded = Data(); for line in lines { encoded.append(line); encoded.append(10) }
        try encoded.write(to: segment)
        let reader = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: false)
        let destination = fixture.root.appendingPathComponent("export.json")
        let outcome = await reader.export(to: destination, retainingAccess: ())
        guard case .saved(let records, _, let incomplete) = outcome else { Issue.record("Export failed: \(outcome)"); return }
        #expect(records == 1 && !incomplete)
        let bytes = try Data(contentsOf: destination), text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("untrusted") && !text.contains("GeneratedPrivate") && !text.contains("generated-secret"))
        #expect(await reader.export(to: destination, retainingAccess: ()) == .notCreated(.alreadyExists))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: segment) == encoded)
        await reader.closeAndDrain()
    }

    @Test func cancelledExportCreatesNothingAndPartialExportIsRetained() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        recorder.record(fixture.event()); await recorder.flush()
        let cancelled = DiagnosticExportCancellation(); cancelled.cancel()
        let destination = fixture.root.appendingPathComponent("cancelled.json")
        #expect(await recorder.export(to: destination, retainingAccess: (), cancellation: cancelled) == .notCreated(.cancelled))
        #expect(!FileManager().fileExists(atPath: destination.path))
        let partial = fixture.root.appendingPathComponent("partial.json")
        let page = try await recorder.page()
        let outcome = DiagnosticExport.write(to: partial, protected: fixture.store, maximumBytes: 100,
            cancellation: .init()) { _ in page }
        #expect(outcome == .createdButIncomplete(.capacity))
        #expect(FileManager().fileExists(atPath: partial.path))
        #expect(try await recorder.page().events.count == 1)
        await recorder.closeAndDrain()
    }

    @Test func exportRejectsOwnStoreAndLinkedParent() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        recorder.record(fixture.event()); await recorder.flush()
        #expect(await recorder.export(to: fixture.store.appendingPathComponent("export.json"), retainingAccess: ()) == .notCreated(.invalidDestination))
        let alias = fixture.root.appendingPathComponent("linked-parent")
        #expect(symlink(fixture.store.path, alias.path) == 0)
        guard case .notCreated = await recorder.export(to: alias.appendingPathComponent("export.json"), retainingAccess: ()) else {
            Issue.record("Linked export parent was accepted"); return
        }
        #expect(!FileManager().fileExists(atPath: fixture.store.appendingPathComponent("export.json").path))
        await recorder.closeAndDrain()
    }

    @Test func reviewExpiresOldHistoryEvenWhileRecordingIsPaused() async throws {
        let fixture = try DiagnosticFixture()
        do {
            let owner = try OwnedDiagnosticFiles(directory: fixture.store, limits: fixture.limits)
            try owner.append([fixture.event()], now: Date().addingTimeInterval(-15 * 86400))
        }
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: false)
        #expect(try await recorder.page().events.isEmpty)
        #expect(try fixture.segments().isEmpty && !recorder.status.recording)
        await recorder.closeAndDrain()
    }

    @Test func replacedMarkerAndLockAreRefused() async throws {
        for name in ["owner.json", "writer.lock"] {
            let fixture = try DiagnosticFixture()
            let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
            recorder.record(fixture.event()); await recorder.flush()
            let file = fixture.store.appendingPathComponent(name), data = try Data(contentsOf: file)
            try FileManager().moveItem(at: file, to: fixture.root.appendingPathComponent("original-" + name))
            try data.write(to: file); #expect(chmod(file.path, 0o600) == 0)
            recorder.record(fixture.event()); await recorder.flush()
            #expect(recorder.status.failure == .changed)
            #expect(try Data(contentsOf: file) == data)
            await recorder.closeAndDrain()
        }
    }
    @Test func closedServiceCannotReopenAWriterThroughLateUIRequests() async throws {
        let fixture = try DiagnosticFixture()
        let recorder = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: true)
        recorder.record(fixture.event()); await recorder.closeAndDrain()
        await #expect(throws: (any Error).self) { try await recorder.page() }
        await #expect(throws: (any Error).self) { try await recorder.clear() }
        #expect(await recorder.export(to:fixture.root.appendingPathComponent("late.json"),retainingAccess:()) == .notCreated(.io))
        let next = DiagnosticRecorder(directory: fixture.store, limits: try fixture.limits, recording: false)
        #expect(try await next.page().events.count == 1 && next.status.failure == nil)
        await next.closeAndDrain()
    }
}

private final class DiagnosticWriteHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var began = false, released = false, onMain = false
    var started: Bool { condition.withLock { began } }
    var wasMainThread: Bool { condition.withLock { onMain } }
    func blockOnce() {
        condition.lock(); defer { condition.unlock() }
        if began { return }
        began = true; onMain = Thread.isMainThread
        while !released { condition.wait() }
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}
