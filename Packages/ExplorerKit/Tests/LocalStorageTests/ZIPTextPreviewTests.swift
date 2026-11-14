import Darwin
import ExplorerCore
import Foundation
import Testing
import FileOperations
@testable import LocalStorage

private struct TextZIPFixture {
    let root: URL
    let source: URL
    init(_ bytes: Data) throws {
        guard let text = ProcessInfo.processInfo.environment["MAC_EXPLORER_ZIP_TEXT_TEST_ROOT"] else {
            root = try LocalStorageTestFixtures.directory()
            source = root.appendingPathComponent("Generated.zip")
            try bytes.write(to: source, options: .withoutOverwriting)
            return
        }
        let base = URL(fileURLWithPath: text)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let release = base.deletingLastPathComponent()
        let byteCase: Bool = {
            guard release.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
                  release.resolvingSymlinksInPath() == release, UUID(uuidString: release.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: release.appendingPathComponent("reservation.json")), data.count <= 4096,
                  let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return marker["action"] as? String == "traverse-archive-bytes-core"
        }()
        let originalCase = release.deletingLastPathComponent().path == repo.appendingPathComponent(".build/b09-text-preview").path
        guard base.lastPathComponent == "source", originalCase || byteCase,
            base.resolvingSymlinksInPath().path == base.path,
            UUID(uuidString: base.deletingLastPathComponent().lastPathComponent) != nil else {
            throw ZIPArchiveFailure.unavailable
        }
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = root.appendingPathComponent("Generated.zip")
        try bytes.write(to: source, options: .withoutOverwriting)
    }
    func selection(_ reader: ZIPArchiveReader = .init(), name: String? = nil) async throws -> ZIPTextPreviewSelection {
        let catalog = try await reader.open(source)
        let page = try await catalog.page(in: catalog.root, filter: name ?? "")
        let member = try #require(page.items.first(where: { name == nil || $0.name == name }))
        let chosen = try await catalog.selectionForTextPreview(member.id)
        await catalog.close()
        return chosen
    }
}

@Suite(.serialized) struct ZIPTextPreviewTests {
    @Test func completeStoredDeflatedUnicodeEmptyAndLiteralMarkup() async throws {
        let texts = ["", "Generated café 日本語 👩‍💻\n\tsecond line\r\n", "<script>never execute</script> & <b>plain text</b>"]
        for text in texts {
            for method: UInt16 in [0, 8] {
                let body = Data(text.utf8)
                let member = method == 0 ? GeneratedZIP.Member("Preview.txt", bytes: body) : try ContentZIP.member("Preview.txt", bytes: body)
                let fixture = try TextZIPFixture(GeneratedZIP.bytes([member]))
                let before = try Data(contentsOf: fixture.source)
                let reader = ZIPArchiveReader(), selected = try await fixture.selection(reader)
                let output = try await reader.previewText(selected)
                #expect(output.text == text && output.utf8Bytes == body.count)
                #expect(try Data(contentsOf: fixture.source) == before)
                if !text.isEmpty { #expect(!String(reflecting: output).contains(text)) }
                await reader.drain()
            }
        }
    }
    @Test func streamedSignedUnsignedAndZIP64WidthsUseTheSameDecoder() async throws {
        let text = "Complete generated streamed text 日本語\n"
        for signed in [false, true] {
            for wide in [(false,false),(true,false),(false,true),(true,true)] {
                let fixture = try TextZIPFixture(StreamedZIP.bytes(Data(text.utf8), signed: signed, localWide: wide.0, centralWide: wide.1))
                let selected = try await fixture.selection()
                #expect(try await ZIPArchiveReader().previewText(selected).text == text)
            }
        }
    }
    @Test func foreignIDsClosedCatalogsAndNonRegularMembersDoNotIssueSelections() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("file.txt"), .init("Folder/", mode: 0x4000, bytes: Data())]))
        let reader = ZIPArchiveReader(), first = try await reader.open(fixture.source), other = try await reader.open(fixture.source)
        let rows = try await first.page(in: first.root)
        let file = try #require(rows.items.first(where: { $0.kind == .file }))
        let folder = try #require(rows.items.first(where: { $0.kind == .directory }))
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await other.selectionForTextPreview(file.id) }
        await #expect(throws: ZIPTextPreviewFailure.unsupported) { try await first.selectionForTextPreview(folder.id) }
        await first.close()
        await #expect(throws: ZIPArchiveFailure.closed) { try await first.selectionForTextPreview(file.id) }
        await other.close()
        for (mode,flags,method): (UInt16,UInt16,UInt16) in [(0xa000,0x800,0),(0x8000,0x801,0),(0x8000,0x800,99)] {
            var member = GeneratedZIP.Member("ineligible", mode: mode);member.flags=flags;member.method=method
            let fixture = try TextZIPFixture(GeneratedZIP.bytes([member]))
            await #expect(throws: ZIPTextPreviewFailure.unsupported) { try await fixture.selection() }
        }
    }
    @Test func exactBoundaryPassesAndOversizeSelectionsRefuseBeforePayload() async throws {
        let body = Data(repeating: 65, count: Int(ZIPTextPreview.maximumUTF8Bytes))
        let good = try TextZIPFixture(GeneratedZIP.bytes([.init("Boundary.txt", bytes: body)]))
        #expect(try await ZIPArchiveReader().previewText(good.selection()).utf8Bytes == body.count)
        let large = try TextZIPFixture(GeneratedZIP.bytes([.init("Too large.txt", bytes: body + Data([65]))]))
        await #expect(throws: ZIPTextPreviewFailure.tooLarge) { try await large.selection() }
        var inflated = GeneratedZIP.Member("Packed.txt", bytes: Data("small".utf8))
        inflated.method = 8; inflated.packed = Data(repeating: 65, count: Int(ZIPTextPreview.maximumPackedBytes)+1)
        let packed = try TextZIPFixture(GeneratedZIP.bytes([inflated]))
        await #expect(throws: ZIPTextPreviewFailure.tooLarge) { try await packed.selection() }
    }
    @Test func binaryInvalidUTF8AndControlSequencesNeverPublishText() async throws {
        for bytes in [Data([0xff,0xfe]),Data([0]),Data([0x1b,0x5b,0x32,0x4a]),Data([0x7f]),
            Data("hidden\u{202e}text".utf8),Data("hidden\u{2066}text".utf8)] {
            let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("text.txt", bytes: bytes)]))
            let selected = try await fixture.selection()
            await #expect(throws: ZIPTextPreviewFailure.notText) { try await ZIPArchiveReader().previewText(selected) }
        }
    }
    @Test func unrelatedCorruptBodyIsNotDecodedOrBlessedBySelectedPreview() async throws {
        var bytes = GeneratedZIP.bytes([.init("Chosen.txt", bytes: Data("Chosen only".utf8)),.init("Other.bin", bytes: Data("unused body".utf8))])
        let records = try ContentZIP.records(bytes), other = records[1]
        bytes[Int(other.localOffset)+30+other.rawName.count] ^= 1
        let fixture = try TextZIPFixture(bytes), selected = try await fixture.selection(name: "Chosen.txt")
        #expect(try await ZIPArchiveReader().previewText(selected).text == "Chosen only")
        await #expect(throws: (any Error).self) { try await ZIPArchiveReader().checkContents(fixture.source) }
    }
    @Test func changedSourceAndReplacedSourceCannotReuseTheSelection() async throws {
        for replace in [false,true] {
            let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.txt")]))
            let selected = try await fixture.selection()
            let changed = GeneratedZIP.bytes([.init("Chosen.txt", bytes: Data("different".utf8))])
            try changed.write(to: fixture.source, options: replace ? .atomic : [])
            await #expect(throws: ZIPArchiveFailure.changed) { try await ZIPArchiveReader().previewText(selected) }
        }
    }
    @Test func malformedLocalFactsAndWrongCRCRefuseWithoutPartialText() async throws {
        let original = GeneratedZIP.bytes([.init("Chosen.txt", bytes: Data("Generated text".utf8))])
        for offset in [14,30+Data("Chosen.txt".utf8).count] {
            var changed = original;changed[offset] ^= 1
            let fixture = try TextZIPFixture(changed), selected = try await fixture.selection()
            await #expect(throws: (any Error).self) { try await ZIPArchiveReader().previewText(selected) }
        }
    }
    @Test func aSourceChangeDuringTheReadRejectsEvenValidDecodedBytes() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.txt")],comment:Data([65])))
        let selected = try await fixture.selection()
        let reader = ZIPArchiveReader { stage in
            if stage == .previewing {
                var bytes = try Data(contentsOf: fixture.source);bytes[bytes.count-1] = 66
                try bytes.write(to: fixture.source)
            }
        }
        await #expect(throws: ZIPArchiveFailure.changed) { try await reader.previewText(selected) }
    }
    @Test func cancellationAndBusyAdmissionRetainTheActualReadUntilRelease() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.txt")]))
        let selected = try await fixture.selection(), hold = TextPreviewHold(), gate = FileActivityGate()
        let reader = ZIPArchiveReader(activity: gate) { if $0 == .previewing { hold.pause() } }
        defer { hold.release() }
        let work = Task { try await reader.previewText(selected) }
        for _ in 0..<1000 { if hold.entered { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(hold.entered && gate.activeCount == 1)
        await #expect(throws: ZIPArchiveFailure.busy) { try await reader.open(fixture.source) }
        work.cancel()
        let drained = TextPreviewCompletion()
        let drain = Task { await reader.drain();drained.finish() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!drained.finished && gate.activeCount == 1)
        hold.release()
        await #expect(throws: ZIPArchiveFailure.stopped) { try await work.value }
        await drain.value
        #expect(drained.finished && gate.activeCount == 0)
    }
    @Test func expiredDeadlineAndClosedActivityNeverReachPayload() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.txt")]))
        let selected = try await fixture.selection()
        let reader = ZIPArchiveReader(previewLimits: .init(seconds:0),probe:{ _ in Issue.record("Expired preview touched source") })
        await #expect(throws: ZIPTextPreviewFailure.limitReached) { try await reader.previewText(selected) }
        let gate = FileActivityGate(), token = try #require(gate.closeAdmission())
        await #expect(throws: FileActivityError.self) { try await ZIPArchiveReader(activity:gate).previewText(selected) }
        #expect(gate.activeCount == 0);#expect(gate.reopen(token))
    }
    @Test func existingReaderContentCheckAndSelectedExtractionWitnessRemainUsable() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.txt",bytes:Data("Generated".utf8))]))
        let reader = ZIPArchiveReader(), session = try await reader.open(fixture.source)
        let item = try #require(try await session.page(in:session.root).items.first)
        #expect(try await session.selectionForExtraction([item.id]).count == 1)
        #expect(try await reader.checkContents(fixture.source).files == 1)
        let selected = try await session.selectionForTextPreview(item.id)
        #expect(try await reader.previewText(selected).text == "Generated")
        await session.close();await reader.drain()
    }
    @Test func wideMetadataDirectoryDoesNotTurnIntoBodyEnumeration() async throws {
        let members = (0..<24_000).map { GeneratedZIP.Member("Generated \($0).bin",bytes:Data()) }
            + [GeneratedZIP.Member("Preview.txt",bytes:Data("The selected text".utf8))]
        let fixture = try TextZIPFixture(GeneratedZIP.bytes(members)), selected = try await fixture.selection(name:"Preview.txt")
        #expect(try await ZIPArchiveReader().previewText(selected).text == "The selected text")
    }
    @Test func selectedRecordLookupReadsBoundedMetadataIndependentOfDirectoryWidth() throws {
        let bytes = GeneratedZIP.bytes((0..<2000).map { .init("Generated \($0).txt", bytes: Data()) }
            + [.init("Preview.txt", bytes: Data("Chosen".utf8))])
        let catalog = try GeneratedZIP.parse(bytes)
        let node = try #require(catalog.nodes.first(where: { $0.name == "Preview.txt" }))
        let position = try #require(node.centralEntryOffset), central = try #require(catalog.centralOffset)
        var readBytes = 0
        let selected = try ZIPMetadataParser.selectedRecord(at: position, centralOffset: central,
            centralEnd: central + UInt64(catalog.summary.centralBytes), sourceLength: UInt64(bytes.count), limits: .init()) { offset, count in
                readBytes += count
                return Data(bytes[Int(offset)..<(Int(offset)+count)])
            }
        #expect(selected.name == "Preview.txt" && selected.logical == 6 && readBytes < 1024)
    }
    @Test func selectedRecordBoundsCannotTurnAnOffsetIntoArbitrarySourceReads() throws {
        let bytes = GeneratedZIP.bytes([.init("Preview.txt")]), catalog = try GeneratedZIP.parse(bytes)
        let central = try #require(catalog.centralOffset), end = central + UInt64(catalog.summary.centralBytes)
        for position in [UInt64(0), central-1, end, UInt64.max] {
            #expect(throws: (any Error).self) {
                try ZIPMetadataParser.selectedRecord(at: position, centralOffset: central, centralEnd: end,
                    sourceLength: UInt64(bytes.count), limits: .init()) { _, _ in
                        Issue.record("Out-of-directory locator reached a source read")
                        return Data()
                    }
            }
        }
        #expect(throws: (any Error).self) {
            try ZIPMetadataParser.selectedRecord(at: central, centralOffset: central, centralEnd: UInt64(bytes.count)+1,
                sourceLength: UInt64(bytes.count), limits: .init()) { _, _ in
                    Issue.record("Invalid central boundary reached a source read");return Data()
                }
        }
    }
    @Test func quarantinedTextPreviewPreservesSecurityMetadataAndArchiveBytes() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Readme.txt", bytes: Data("Generated quarantined text".utf8))]))
        let descriptor = Darwin.open(fixture.source.path, O_RDWR|O_CLOEXEC|O_NOFOLLOW_ANY)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let quarantine = Data("0081;65000001;MacExplorer-B09-Qualification;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        let written = quarantine.withUnsafeBytes { fsetxattr(descriptor,"com.apple.quarantine",$0.baseAddress,$0.count,0,XATTR_CREATE) }
        #expect(written == 0)
        let original = try Data(contentsOf: fixture.source), selection = try await fixture.selection()
        #expect(try await ZIPArchiveReader().previewText(selection).text == "Generated quarantined text")
        var actual = [UInt8](repeating:0,count:256)
        let count = fgetxattr(descriptor,"com.apple.quarantine",&actual,actual.count,0,0)
        #expect(count == quarantine.count && Data(actual.prefix(max(0,count))) == quarantine)
        #expect(try Data(contentsOf: fixture.source) == original)
    }
    @Test func directoryWitnessRejectsChangesEvenWithAnApparentlyMatchingNativeStamp() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Readme.txt")],comment:Data([65])))
        let selected = try await fixture.selection()
        var changed = try Data(contentsOf: fixture.source);changed[changed.count-1]=66
        try changed.write(to:fixture.source)
        let fresh = try ZIPSourceFile(fixture.source)
        // Test-only construction models coarse native timestamps. Ordinary
        // callers cannot forge selections or update their source witness.
        let simulated = ZIPTextPreviewSelection(binding:.init(source:fixture.source,stamp:fresh.observed),
            path:selected.path,recordOffset:selected.recordOffset,centralOffset:selected.centralOffset,
            centralEnd:selected.centralEnd,directoryWitness:selected.directoryWitness)
        let reader = ZIPArchiveReader { if $0 == .previewing { Issue.record("Changed directory reached payload decoding") } }
        await #expect(throws:ZIPArchiveFailure.changed) { try await reader.previewText(simulated) }
    }
    @Test func sharedRecordDecoderKeepsGuardedExtractionAndColdUndoCompatible() async throws {
        let payload=Data("Generated extraction compatibility 日本語".utf8)
        let fixture=try TextZIPFixture(GeneratedZIP.bytes([try ContentZIP.member("Folder/Readme.txt",bytes:payload)]))
        let destination=fixture.root.appendingPathComponent("Destination"),journal=fixture.root.appendingPathComponent("journal")
        try FileManager().createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let original=try Data(contentsOf:fixture.source),engine=RecoverableFileOperations(journalDirectory:journal)
        let observed=try await engine.observeSelection([fixture.source])
        let plan=try await engine.prepareZIPExtraction(source:fixture.source,parent:destination,name:"Generated extraction",observing:observed)
        let result=await engine.performArchiveExtraction(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(try Data(contentsOf:plan.destination.appendingPathComponent("Folder/Readme.txt")) == payload)
        let cold=RecoverableFileOperations(journalDirectory:journal)
        #expect(await cold.undo(recordID:try #require(result.recordID)).result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath:plan.destination.path))
        #expect(try Data(contentsOf:fixture.source) == original)
    }
}

@Suite(.serialized) struct ZIPBytePreviewTests {
    @Test func storedDeflatedAndEveryByteValueHaveCompleteInertViews() async throws {
        let body = Data((0...255).map(UInt8.init))
        for compressed in [false, true] {
            let member = compressed ? try ContentZIP.member("All bytes.bin", bytes: body) : GeneratedZIP.Member("All bytes.bin", bytes: body)
            let fixture = try TextZIPFixture(GeneratedZIP.bytes([member]))
            let reader = ZIPArchiveReader(), selection = try await fixture.selection()
            let before = try Data(contentsOf: fixture.source)
            let preview = try await reader.previewBytes(selection)
            #expect(preview.byteCount == 256 && preview.hexadecimalText.utf8.count == 16 * 78)
            #expect(preview.hexadecimalText.hasPrefix("00000000  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  |................|\n"))
            #expect(preview.hexadecimalText.hasSuffix("000000F0  F0 F1 F2 F3 F4 F5 F6 F7 F8 F9 FA FB FC FD FE FF  |................|\n"))
            #expect(preview.hexadecimalText.unicodeScalars.allSatisfy { $0.value == 10 || (32...126).contains($0.value) })
            #expect(!String(reflecting: preview).contains("00000000"))
            #expect(try Data(contentsOf: fixture.source) == before)
            await #expect(throws: ZIPTextPreviewFailure.notText) { try await reader.previewText(selection) }
            await reader.drain()
        }
    }
    @Test func emptyPartialAndExactRowsHaveStableOffsetsAndPadding() throws {
        for count in [0, 1, 15, 16, 17, 31, 32, 33] {
            let text = try ZIPBytePreview.render(Data(repeating: 65, count: count), check: {})
            let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            #expect(rows.count == (count + 15) / 16)
            #expect(rows.allSatisfy { $0.utf8.count == 77 })
            for (index, row) in rows.enumerated() {
                #expect(Int(row.prefix(8), radix: 16) == index * 16)
                let actual = min(16, count - index * 16)
                #expect(row.suffix(17).dropLast() == String(repeating: "A", count: actual) + String(repeating: " ", count: 16 - actual))
            }
        }
    }
    @Test func exactLimitCompletesButOversizeIsRefusedBeforeFormatting() async throws {
        let body = Data(repeating: 65, count: Int(ZIPBytePreview.maximumBytes))
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([try ContentZIP.member("Boundary.bin", bytes: body)]))
        let preview = try await ZIPArchiveReader().previewBytes(fixture.selection())
        #expect(preview.byteCount == ZIPBytePreview.maximumBytes)
        #expect(preview.hexadecimalText.utf8.count == 16_384 * 78)
        #expect(preview.hexadecimalText.split(separator: "\n").last?.hasPrefix("0003FFF0") == true)
        #expect(throws: ZIPTextPreviewFailure.tooLarge) {
            try ZIPBytePreview.render(body + Data([65]), check: { Issue.record("Oversize bytes reached formatter") })
        }
        let tooLarge = try TextZIPFixture(GeneratedZIP.bytes([.init("Too large.bin", bytes: body + Data([65]))]))
        await #expect(throws: ZIPTextPreviewFailure.tooLarge) { try await tooLarge.selection() }
    }
    @Test func cancellationDuringFormattingNeverReturnsAPrefix() throws {
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ZIPBytePreview.render(Data(repeating: 0, count: 4096), check: {
                checks += 1
                if checks == 7 { throw CancellationError() }
            })
        }
        #expect(checks == 7)
    }
    @Test func wrongCRCAndLocalFactsAreStillRefused() async throws {
        let original = GeneratedZIP.bytes([.init("Binary.bin", bytes: Data([0, 1, 2, 255]))])
        for offset in [14, 30 + Data("Binary.bin".utf8).count] {
            var changed = original; changed[offset] ^= 1
            let fixture = try TextZIPFixture(changed), selection = try await fixture.selection()
            await #expect(throws: (any Error).self) { try await ZIPArchiveReader().previewBytes(selection) }
        }
    }
    @Test func unselectedCorruptPayloadIsNotReadOrBlessed() async throws {
        var bytes = GeneratedZIP.bytes([.init("Chosen.bin", bytes: Data([0, 255])), .init("Other.bin", bytes: Data([3, 4]))])
        let records = try ContentZIP.records(bytes), other = records[1]
        bytes[Int(other.localOffset) + 30 + other.rawName.count] ^= 1
        let fixture = try TextZIPFixture(bytes), selection = try await fixture.selection(name: "Chosen.bin")
        #expect(try await ZIPArchiveReader().previewBytes(selection).byteCount == 2)
        await #expect(throws: (any Error).self) { try await ZIPArchiveReader().checkContents(fixture.source) }
    }
    @Test func changedReplacedAndDuringReadSourcesReject() async throws {
        for replacement in [false, true] {
            let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.bin", bytes: Data([0, 255]))]))
            let selected = try await fixture.selection()
            try GeneratedZIP.bytes([.init("Chosen.bin", bytes: Data([1, 254]))]).write(to: fixture.source, options: replacement ? .atomic : [])
            await #expect(throws: ZIPArchiveFailure.changed) { try await ZIPArchiveReader().previewBytes(selected) }
        }
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Chosen.bin", bytes: Data([0, 255]))], comment: Data([65])))
        let selected = try await fixture.selection()
        let reader = ZIPArchiveReader { stage in
            if stage == .previewing {
                var data = try Data(contentsOf: fixture.source); data[data.count - 1] = 66
                try data.write(to: fixture.source)
            }
        }
        await #expect(throws: ZIPArchiveFailure.changed) { try await reader.previewBytes(selected) }
    }
    @Test func directoryWitnessStillRefusesApparentlyMatchingNativeStamp() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Binary.bin", bytes: Data([0, 255]))], comment: Data([65])))
        let original = try await fixture.selection()
        var data = try Data(contentsOf: fixture.source); data[data.count - 1] = 66; try data.write(to: fixture.source)
        let source = try ZIPSourceFile(fixture.source)
        let simulated = ZIPTextPreviewSelection(binding: .init(source: fixture.source, stamp: source.observed), path: original.path,
            recordOffset: original.recordOffset, centralOffset: original.centralOffset, centralEnd: original.centralEnd, directoryWitness: original.directoryWitness)
        let reader = ZIPArchiveReader { if $0 == .previewing { Issue.record("Changed directory reached byte decoding") } }
        await #expect(throws: ZIPArchiveFailure.changed) { try await reader.previewBytes(simulated) }
    }
    @Test func heldCancellationBusyAndActualDrainRetainTheRead() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Binary.bin", bytes: Data([0, 255]))]))
        let selection = try await fixture.selection(), hold = TextPreviewHold(), gate = FileActivityGate()
        let reader = ZIPArchiveReader(activity: gate) { if $0 == .previewing { hold.pause() } }
        defer { hold.release() }
        let task = Task { try await reader.previewBytes(selection) }
        for _ in 0..<1000 { if hold.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(hold.entered && gate.activeCount == 1)
        await #expect(throws: ZIPArchiveFailure.busy) { try await reader.previewText(selection) }
        task.cancel()
        let completed = TextPreviewCompletion(), drain = Task { await reader.drain() }
        let waiting = Task { await drain.value; completed.finish() }
        try await Task.sleep(for: .milliseconds(20)); #expect(!completed.finished && gate.activeCount == 1)
        hold.release()
        await #expect(throws: ZIPArchiveFailure.stopped) { try await task.value }
        await waiting.value; #expect(completed.finished && gate.activeCount == 0)
    }
    @Test func expiredDeadlineAndClosedAdmissionReachNoBytes() async throws {
        let fixture = try TextZIPFixture(GeneratedZIP.bytes([.init("Binary.bin", bytes: Data([0, 255]))]))
        let selection = try await fixture.selection()
        let expired = ZIPArchiveReader(previewLimits: .init(seconds: 0), probe: { _ in Issue.record("Expired byte preview touched source") })
        await #expect(throws: ZIPTextPreviewFailure.limitReached) { try await expired.previewBytes(selection) }
        let gate = FileActivityGate(), token = try #require(gate.closeAdmission())
        await #expect(throws: FileActivityError.self) { try await ZIPArchiveReader(activity: gate).previewBytes(selection) }
        #expect(gate.activeCount == 0); #expect(gate.reopen(token))
    }
}

private final class TextPreviewHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var started=false,released=false
    var entered:Bool { condition.lock();defer { condition.unlock() };return started }
    func pause() { condition.lock();defer { condition.unlock() };started=true
        while !released { if !condition.wait(until:Date().addingTimeInterval(5)) { return } }
    }
    func release() { condition.lock();released=true;condition.broadcast();condition.unlock() }
}
private final class TextPreviewCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var finished: Bool { lock.withLock { value } }
    func finish() { lock.withLock { value = true } }
}
