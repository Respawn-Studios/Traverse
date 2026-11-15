import Foundation
import Testing
@testable import StorageAnalysis

@Test func fileTypeHintsUseOnlyTheFinalASCIIExtension() {
    let cases: [(String, AnalysisFileType)] = [
        ("Movie.MP4", .video), ("a/b.tAr.Gz", .archives), ("archive.TBZ", .archives), ("x.dmg", .diskImages),
        ("x.qcow2", .virtualDisks), ("weights.safetensors", .models), ("x.heic", .images),
        ("notes.pages", .documents), ("budget.numbers", .spreadsheets), ("talk.key", .presentations),
        ("code.rs", .textAndSource), ("x.woff2", .fonts), ("x.flac", .audio),
        ("pak01_001.VPK", .archives), ("game.pak", .archives), ("data.pck", .archives),
        ("state.db-wal", .databases), ("state.sqlite3-shm", .databases),
        ("movie.mp4.txt", .textAndSource), ("x.pdf/README", .other), (".mp4", .other),
        ("README", .other), ("x.", .other), ("x.pdƒ", .other), ("x.unrecognized", .other)
    ]
    for (name, expected) in cases { #expect(AnalysisFileType.match(Data(name.utf8)) == expected) }
    #expect(AnalysisFileType.match(Data([255, 46, 77, 80, 52])) == .video)
}

private func typed(_ name: String, inode: UInt64, kind: AnalysisEntryKind = .regularFile,
                   value: AnalysisByteObservation) -> AnalysisEntryObservation {
    .init(relativePath: Data(name.utf8), kind: kind, identity: .returned(.init(device: 1, inode: inode)),
          linkCount: .returned(1), flags: .returned(0), bytes: value)
}

@Test func typePartitionsReconcileAllFourMetricsAndIgnoreNonfiles() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    for (i, name) in ["video.mp4", "notes.txt", "unknown", "disk.dmg", "other.zip"].enumerated() {
        model.consume(typed(name, inode: UInt64(i+2), value: .init(dataLogical: .returned(UInt64(i)),
            allForkLogical: .returned(UInt64(i+10)), dataAllocated: .returned(UInt64(i+20)), allForkAllocated: .returned(UInt64(i+30)))))
    }
    model.consume(typed("folder.mp4", inode: 8, kind: .directory, value: .init()))
    model.consume(typed("link.mp4", inode: 9, kind: .symbolicLink, value: .init()))
    let snapshot = model.finish(), report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated")
    #expect(snapshot.fileTypes.count == AnalysisClassificationRevision.v2.fileTypes.count)
    #expect(snapshot.fileTypes.reduce(UInt64(0)) { $0 + $1.files } == 5)
    #expect(snapshot.fileTypes[AnalysisFileType.video.rawValue].files == 1)
    for metric in AnalysisByteMetric.allCases {
        var total = AnalysisByteSubtotals()
        for row in report.fileTypes { total.merge(row.bytes) }
        #expect(total[metric] == snapshot.root.namespaceSubtotals[metric])
    }
}

@Test func typePartitionsPreserveUnknownFailedZeroAndOverflow() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(typed("a.mp4", inode: 2, value: .init(dataLogical: .returned(UInt64.max),
        allForkLogical: .notReturned, dataAllocated: .failed(code: 13), allForkAllocated: .returned(0))))
    model.consume(typed("b.mp4", inode: 3, value: .init(dataLogical: .returned(1),
        allForkLogical: .returned(0), dataAllocated: .returned(0), allForkAllocated: .returned(0))))
    let video = model.finish().fileTypes[AnalysisFileType.video.rawValue]
    #expect(video.files == 2 && video.bytes.dataLogical.overflowed)
    #expect(video.bytes.dataLogical.knownBytes == nil)
    #expect(video.bytes.allForkLogical.notReturnedCount == 1)
    #expect(video.bytes.dataAllocated.failedCount == 1)
    #expect(video.bytes.allForkAllocated.knownBytes == 0)
}

@Test func rejectedPathsCannotChangeTypeTotalsAndLiveSnapshotsStayIndependent() {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    let first = typed("a.zip", inode: 2, value: .init(dataLogical: .returned(7)))
    model.consume(first)
    let live = model.snapshot()
    model.consume(first)
    model.consume(typed("absent/b.mp4", inode: 3, value: .init(dataLogical: .returned(900))))
    model.consume(typed("b.txt", inode: 4, value: .init(dataLogical: .returned(11))))
    let final = model.finish()
    #expect(live.fileTypes.reduce(UInt64(0)) { $0 + $1.files } == 1)
    #expect(final.fileTypes.reduce(UInt64(0)) { $0 + $1.files } == 2)
    #expect(final.fileTypes[AnalysisFileType.video.rawValue].files == 0)
    #expect(final.fileTypes[AnalysisFileType.archives.rawValue].bytes.dataLogical.knownBytes == 7)
}

@Test func hardlinkedNamesPartitionByNameWithoutClaimingPhysicalBytes() {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    for name in ["a.mp4", "b.txt"] {
        model.consume(.init(relativePath: Data(name.utf8), kind: .regularFile,
            identity: .returned(.init(device: 1, inode: 2)), linkCount: .returned(2), flags: .returned(0),
            bytes: .init(dataLogical: .returned(10))))
    }
    let result = model.finish()
    #expect(result.fileTypes[AnalysisFileType.video.rawValue].bytes.dataLogical.knownBytes == 10)
    #expect(result.fileTypes[AnalysisFileType.textAndSource.rawValue].bytes.dataLogical.knownBytes == 10)
    #expect(result.distinctObjects.byteSubtotals.dataLogical.knownBytes == 10)
    #expect(result.root.namespaceSubtotals.dataLogical.knownBytes == 20)
}
