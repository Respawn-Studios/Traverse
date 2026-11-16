import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import LocalStorage

struct TARPreviewTests {
    private func selection(_ session: TARArchiveSession, _ path: String) async throws -> TARTextPreviewSelection {
        let page = try await session.searchNames(path)
        let item = try #require(page.items.first { $0.path == path })
        return try await session.selectionForTextPreview(item.id)
    }
    private func source() throws -> URL {
        try TARReaderTestFixture.write(TARReaderTestFixture.bytes(.preview))
    }
    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func overwrite(_ source: URL, with data: Data) throws {
        let fd = open(source.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                try #require(count > 0); offset += count
            }
        }
        try #require(fsync(fd) == 0)
    }

    @Test func selectedTextReadsOnlyItsExactBodyWithBeforeAndAfterMetadata() async throws {
        let source = try source(), trace = TARReadTestProbe(), activity = FileActivityGate()
        let reader = TARArchiveReader(activity: activity, probe: trace.probe)
        let session = try await reader.open(source)
        let browse = trace.observations
        #expect(!browse.reads.isEmpty)
        #expect(browse.reads.reduce(0) { $0 + $1.1 } == session.summary.metadataBytes)
        for (offset, count) in browse.reads {
            for row in TARReaderTestFixture.rows(.preview) where row.kind == "file" && row.bytes > 0 {
                #expect(offset + UInt64(count) <= row.dataOffset || offset >= row.dataOffset + row.bytes)
            }
        }
        let before = trace.snapshot.count
        let selected = try await selection(session, "Text.txt")
        _ = try await selection(session, "Empty")
        #expect(trace.snapshot.count == before)
        trace.clear()
        let text = try await reader.previewText(selected)
        #expect(text.text == "Hello café\n\t<html>plain</html>\r\n")
        #expect(text.utf8Bytes == text.text.utf8.count)
        let expected = try #require(TARReaderTestFixture.rows(.preview).first { $0.path == "Text.txt" })
        let payload = trace.snapshot.filter { $0.0 == "previewPayload" }
        #expect(payload.count == 1 && payload[0].1 == expected.dataOffset && payload[0].2 == expected.bytes)
        #expect(trace.observations.reads.reduce(0) { $0 + $1.1 } == session.summary.metadataBytes * 2)
        #expect(!String(describing: selected).contains("Text.txt"))
        #expect(!String(reflecting: text).contains("Hello"))
        #expect(!trace.observations.mainThread)
        await session.close(); await reader.drain()
        #expect(activity.activeCount == 0)
    }

    @Test func emptyMaximumAndAllByteHexMatchIndependentPythonOracles() async throws {
        let reader = TARArchiveReader(), session = try await reader.open(source())
        let empty = try await selection(session, "Empty")
        #expect(try await reader.previewText(empty).text.isEmpty)
        #expect(try await reader.previewBytes(empty).hexadecimalText.isEmpty)
        let maximum = try await selection(session, "Maximum")
        let text = try await reader.previewText(maximum)
        #expect(text.utf8Bytes == 256 << 10 && text.text == String(repeating: "x", count: 256 << 10))
        let hex = try await reader.previewBytes(maximum)
        #expect(hex.byteCount == 256 << 10 && hex.hexadecimalText.utf8.count == 1_277_952)
        #expect(hash(hex.hexadecimalText) == "33b6ee9503722607773324f0ca850ce6c5edfbe1f2c7c064237c3e96c858b090")
        let all = try await reader.previewBytes(selection(session, "Bytes"))
        #expect(all.byteCount == 256 && all.hexadecimalText.utf8.count == 1248)
        #expect(hash(all.hexadecimalText) == "6dde018bb51c33efba52c7e41dc5a9a6ae1fd46ce7f0e670026f1a9f299e2b1c")
        await session.close(); await reader.drain()
    }

    @Test func oversizedAndUnsafeTextRefuseWithoutTruncation() async throws {
        let trace = TARReadTestProbe(), reader = TARArchiveReader(probe: trace.probe)
        let session = try await reader.open(source())
        trace.clear()
        await #expect(throws: TARTextPreviewFailure.tooLarge) { _ = try await selection(session, "TooLarge") }
        #expect(trace.snapshot.filter { $0.0 == "previewPayload" }.isEmpty)
        for index in 0..<8 {
            await #expect(throws: TARTextPreviewFailure.notText) {
                _ = try await reader.previewText(selection(session, "Invalid\(index)"))
            }
        }
        await session.close(); await reader.drain()
    }

    @Test func memberKindsForeignClosedAndUnboundSelectionsHaveNoPreviewAuthority() async throws {
        let source = try source(), reader = TARArchiveReader()
        let session = try await reader.open(source)
        for name in ["Folder", "Sym", "Hard", "FIFO"] {
            await #expect(throws: TARTextPreviewFailure.unsupported) { _ = try await selection(session, name) }
        }
        let item = try #require(try await session.searchNames("Text.txt").items.first)
        let foreign = try await reader.open(source)
        await #expect(throws: TARArchiveFailure.invalidSelection) { _ = try await foreign.selectionForTextPreview(item.id) }
        await foreign.close()
        await #expect(throws: TARArchiveFailure.closed) { _ = try await foreign.selectionForTextPreview(item.id) }
        let data = try Data(contentsOf: source)
        let parsed = try TARMetadataParser.parse(length: UInt64(data.count), check: {}, read: {
            data.subdata(in: Int($0)..<(Int($0) + $1))
        })
        let unbound = TARArchiveSession(try TARCatalogBuilder.build(parsed, check: {}))
        await #expect(throws: TARTextPreviewFailure.unsupported) { _ = try await selection(unbound, "Text.txt") }
        await unbound.close(); await session.close(); await reader.drain()
    }

    @Test(arguments: [TARReaderTestFixture.Variant.paxSize, .gnu])
    func effectivePAXAndGNURecordsRejectForgedExtents(variant: TARReaderTestFixture.Variant) async throws {
        let source = try TARReaderTestFixture.write(TARReaderTestFixture.bytes(variant))
        let reader = TARArchiveReader(), session = try await reader.open(source)
        let item = try #require(try await session.searchNames(variant == .gnu ? "long" : "nnn").items.first { $0.kind == .file })
        let choice = try await session.selectionForTextPreview(item.id)
        #expect(try await reader.previewText(choice).text == "abc")
        let record = choice.record
        let forged = TARTextPreviewSelection(binding: choice.binding, record: .init(
            ordinal: record.ordinal, path: record.path, kind: record.kind,
            headerOffset: record.headerOffset, dataOffset: record.dataOffset, bytes: record.bytes + 1,
            modification: record.modification, extensionOffset: record.extensionOffset))
        await #expect(throws: TARArchiveFailure.changed) { _ = try await reader.previewText(forged) }
        await session.close(); await reader.drain()
    }

    @Test(arguments: ["opened", "previewing", "previewPayload", "previewTransform", "previewComplete"])
    func sourceMutationAtEveryReadFenceRefuses(stage: String) async throws {
        let source = try source(), original = try Data(contentsOf: source)
        let trace = TARReadTestProbe(), reader = TARArchiveReader(probe: trace.probe)
        let session = try await reader.open(source), selected = try await selection(session, "Text.txt")
        trace.at(stage) { var changed = original; changed[512] = UInt8(ascii: "z"); try Self.overwrite(source, with: changed) }
        await #expect(throws: TARArchiveFailure.changed) { _ = try await reader.previewText(selected) }
        await session.close(); await reader.drain()
    }

    @Test(arguments: [false, true])
    func renamedAndReplacedSourcesCannotPublishCapturedText(replace: Bool) async throws {
        let source = try source(), original = try Data(contentsOf: source)
        let moved = source.appendingPathExtension("held")
        let trace = TARReadTestProbe(), reader = TARArchiveReader(probe: trace.probe)
        let session = try await reader.open(source), selected = try await selection(session, "Text.txt")
        trace.at("previewing") {
            try #require(rename(source.path, moved.path) == 0)
            if replace { try original.write(to: source, options: .withoutOverwriting) }
        }
        await #expect(throws: TARArchiveFailure.changed) { _ = try await reader.previewText(selected) }
        await session.close(); await reader.drain()
        #expect(try Data(contentsOf: moved) == original)
    }

    @Test func fullMetadataWitnessStillRefusesAValidHeaderChecksumAndFreshStamp() async throws {
        let source = try source(), original = try Data(contentsOf: source)
        let reader = TARArchiveReader(), session = try await reader.open(source)
        let selected = try await selection(session, "Text.txt")
        let altered = TARReaderTestFixture.changingFirstHeader(original) { $0[0] = UInt8(ascii: "Y") }
        try Self.overwrite(source, with: altered)
        let current = try PinnedLocalFileSource(source)
        let rebound = TARTextPreviewSelection(binding: .init(source: source, stamp: current.observed,
            witness: selected.binding.witness), record: selected.record)
        await #expect(throws: TARArchiveFailure.changed) { _ = try await reader.previewText(rebound) }
        await session.close(); await reader.drain()
    }

    @Test func deadlineMetadataQuotaAndSourceExclusionRefuse() async throws {
        let source = try source(), session = try await TARArchiveReader().open(source)
        let selected = try await selection(session, "Text.txt"), trace = TARReadTestProbe()
        let expired = TARArchiveReader(previewLimits: .init(seconds: 0), probe: trace.probe)
        await #expect(throws: TARTextPreviewFailure.limitReached) { _ = try await expired.previewText(selected) }
        var limits = TARReadLimits(); limits.metadataBytes = 6
        let quota = TARArchiveReader(limits: limits, probe: trace.probe)
        await #expect(throws: TARArchiveFailure.limited) { _ = try await quota.previewText(selected) }
        let excluded = TARArchiveReader(excludedRoots: [source.deletingLastPathComponent()], probe: trace.probe)
        await #expect(throws: TARArchiveFailure.unavailable) { _ = try await excluded.previewText(selected) }
        #expect(trace.snapshot.filter { $0.0 == "previewPayload" }.isEmpty)
        await session.close(); await expired.drain(); await quota.drain(); await excluded.drain()
    }

    private final class Lifetime: Sendable {}
    private final class WeakLife: @unchecked Sendable { weak var value: Lifetime?; init(_ value: Lifetime) { self.value = value } }
    @Test(arguments: ["metadata", "previewPayload", "previewTransform", "previewFinalMetadata"])
    func cancelledPreviewRetainsAccessUntilActualWorkerDrain(stage: String) async throws {
        let source = try source(), session = try await TARArchiveReader().open(source)
        let selected = try await selection(session, "Text.txt")
        let trace = TARReadTestProbe(); trace.at(stage, hold: true)
        let activity = FileActivityGate(), reader = TARArchiveReader(activity: activity, probe: trace.probe)
        var lifetime: Lifetime? = Lifetime()
        let weak = WeakLife(try #require(lifetime))
        var task: Task<TARTextPreview, Error>? = Task { [lifetime = lifetime!] in
            try await reader.previewText(selected, retaining: lifetime)
        }
        lifetime = nil
        defer { trace.release.signal() }
        try #require(await Task.detached { trace.waitForEntry() }.value)
        #expect(activity.activeCount == 1 && weak.value != nil)
        await #expect(throws: TARArchiveFailure.busy) { _ = try await reader.previewBytes(selected) }
        await #expect(throws: TARArchiveFailure.busy) { _ = try await reader.open(source) }
        task?.cancel()
        #expect(activity.activeCount == 1)
        trace.release.signal()
        if let active = task { await #expect(throws: TARArchiveFailure.stopped) { _ = try await active.value } }
        task = nil; await reader.drain()
        #expect(activity.activeCount == 0 && weak.value == nil)
        await session.close()
    }
}
