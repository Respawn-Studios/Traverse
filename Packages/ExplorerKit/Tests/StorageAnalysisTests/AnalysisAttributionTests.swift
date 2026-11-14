import Foundation
import Testing
@testable import StorageAnalysis

private func observed(_ path: String, folder: Bool = false, inode: UInt64, size: UInt64 = 0) -> AnalysisEntryObservation {
    .init(relativePath: Data(path.utf8), kind: folder ? .directory : .regularFile,
        identity: .returned(.init(device: 1, inode: inode)), linkCount: .returned(1), flags: .returned(0),
        bytes: folder ? .init() : .init(dataLogical: .returned(size), allForkLogical: .returned(size),
            dataAllocated: .returned(size * 2), allForkAllocated: .returned(size * 2)))
}

@Test func attributionIsIndependentOfMarkerOrderAndSeparatesNestedProjects() throws {
    func run(markerFirst: Bool) throws -> AnalysisAttributionReport {
        var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
        if markerFirst { model.consume(observed("Cargo.toml", inode: 2)) }
        model.consume(observed("target", folder: true, inode: 3))
        model.consume(observed("target/output", inode: 4, size: 10))
        model.consume(observed("nested", folder: true, inode: 5))
        model.consume(observed("nested/Package.swift", inode: 6))
        model.consume(observed("nested/code.swift", inode: 7, size: 20))
        model.consume(observed("node_modules", folder: true, inode: 8))
        model.consume(observed("node_modules/package.json", inode: 9, size: 30))
        if !markerFirst { model.consume(observed("Cargo.toml", inode: 2)) }
        return try .make(model.finish(), scopePath: "/Generated/Project")
    }
    let early = try run(markerFirst: true), late = try run(markerFirst: false)
    #expect(early.projectCount == 2 && late.projectCount == 2)
    #expect(early.categories.map { $0.bytes.dataLogical.knownBytes } == late.categories.map { $0.bytes.dataLogical.knownBytes })
    #expect(early.categories[AnalysisCategory.buildOutput.rawValue].bytes.dataLogical.knownBytes == 10)
    #expect(early.categories[AnalysisCategory.dependencies.rawValue].bytes.dataLogical.knownBytes == 30)
    #expect(early.projects.first { $0.title == "Project" }?.bytes.dataLogical.knownBytes == 40)
    #expect(early.projects.first { $0.title == "nested" }?.bytes.dataLogical.knownBytes == 20)
    #expect(early.projects.reduce(UInt64(0)) { $0 + ($1.bytes.dataLogical.knownBytes ?? 0) } == 60)
}

@Test func attributionDoesNotInferProjectsOrBuildSafetyFromNames() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("build", folder: true, inode: 2))
    model.consume(observed("build/notes", inode: 3, size: 40))
    model.consume(observed("cache", folder: true, inode: 4))
    model.consume(observed("cache/photo", inode: 5, size: 60))
    let report = try AnalysisAttributionReport.make(model.finish(), scopePath: "/Generated")
    #expect(report.projectCount == 0)
    #expect(report.categories[0].bytes.dataLogical.knownBytes == 100)
    #expect(report.projects.last?.bytes.dataLogical.knownBytes == 100)
    #expect(report.categories[AnalysisCategory.toolCache.rawValue].files == 0)
}

@Test func attributionLabelsGlobalCachesWithoutInventingProjectOwnership() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("huggingface", folder: true, inode: 2))
    model.consume(observed("huggingface/package.json", inode: 3, size: 3))
    model.consume(observed("huggingface/model", inode: 4, size: 7))
    let report = try AnalysisAttributionReport.make(model.finish(), scopePath: "/Users/Generated/.cache")
    #expect(report.projectCount == 0)
    #expect(report.categories[AnalysisCategory.modelStore.rawValue].bytes.dataLogical.knownBytes == 10)
    #expect(report.projects.last?.bytes.dataLogical.knownBytes == 10)
}

@Test func attributionRetainsAllProjectsInBoundedDisplayAndAllMetrics() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    for i in 0..<100 {
        model.consume(observed("p\(i)", folder: true, inode: UInt64(3*i+2)))
        model.consume(observed("p\(i)/go.mod", inode: UInt64(3*i+3)))
        model.consume(observed("p\(i)/file", inode: UInt64(3*i+4), size: UInt64(i)))
    }
    let snapshot = model.finish()
    let report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated")
    #expect(report.projectCount == 100)
    #expect(report.projects.count == 14)
    #expect(report.projects.contains { $0.title == "Other project scopes" })
    #expect(report.projects.reduce(UInt64(0)) { $0 + ($1.bytes.dataLogical.knownBytes ?? 0) } == 4950)
    #expect(report.projects.reduce(UInt64(0)) { $0 + ($1.bytes.allForkAllocated.knownBytes ?? 0) } == 9900)
    #expect(report.projects.reduce(UInt64(0)) { $0 + $1.files } == snapshot.root.counts.regularFiles)
}

@Test func attributionPreservesMissingAndOverflowInsteadOfInventingRemainders() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("Cargo.toml", inode: 2))
    model.consume(.init(relativePath: Data("unknown".utf8), kind: .regularFile,
        identity: .returned(.init(device: 1, inode: 3)), linkCount: .returned(1), flags: .returned(0),
        bytes: .init(dataLogical: .notReturned, allForkLogical: .failed(code: 13), dataAllocated: .returned(0))))
    model.consume(.init(relativePath: Data("large".utf8), kind: .regularFile,
        identity: .returned(.init(device: 1, inode: 4)), linkCount: .returned(1), flags: .returned(0),
        bytes: .init(dataLogical: .returned(UInt64.max))))
    model.consume(observed("one", inode: 5, size: 1))
    let report = try AnalysisAttributionReport.make(model.finish(), scopePath: "/Generated")
    #expect(!report.isComplete)
    #expect(report.categories[0].bytes.dataLogical.overflowed)
    #expect(report.categories[0].bytes.dataLogical.knownBytes == nil)
    #expect(report.categories[0].bytes.dataLogical.notReturnedCount == 1)
    #expect(report.categories[0].bytes.allForkLogical.failedCount == 1)
    #expect(report.projects[0].bytes.dataAllocated.knownBytes == 2)
}

@Test func attributionDoesNotFollowLinkMarkersAndPreservesNonUTF8Names() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(.init(relativePath: Data("Cargo.toml".utf8), kind: .symbolicLink,
        identity: .returned(.init(device: 1, inode: 2)), linkCount: .returned(1), flags: .returned(0)))
    model.consume(.init(relativePath: Data([0xff]), kind: .directory,
        identity: .returned(.init(device: 1, inode: 3)), linkCount: .returned(1), flags: .returned(0)))
    model.consume(.init(relativePath: Data([0xff,47,0xfe]), kind: .regularFile,
        identity: .returned(.init(device: 1, inode: 4)), linkCount: .returned(1), flags: .returned(0),
        bytes: .init(dataLogical: .returned(5))))
    let snapshot = model.finish()
    let report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated")
    #expect(report.projectCount == 0)
    #expect(snapshot.folders[1].relativePath == Data([0xff]))
    #expect(report.categories[0].bytes.dataLogical.knownBytes == 5)
}

@Test func attributionSpecificToolLayoutsRemainHintsWithoutFalseProjects() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("__pycache__", folder: true, inode: 2))
    model.consume(observed("__pycache__/pyproject.toml", inode: 3, size: 7))
    model.consume(observed(".dart_tool", folder: true, inode: 4))
    model.consume(observed(".dart_tool/pubspec.yaml", inode: 5, size: 11))
    let report = try AnalysisAttributionReport.make(model.finish(), scopePath: "/Generated")
    #expect(report.projectCount == 0)
    #expect(report.categories[AnalysisCategory.pythonCache.rawValue].bytes.dataLogical.knownBytes == 7)
    #expect(report.categories[AnalysisCategory.flutterState.rawValue].bytes.dataLogical.knownBytes == 11)
    #expect(report.projects.last?.bytes.dataLogical.knownBytes == 18)
}

@Test func attributionCrossProjectHardlinksDoNotBecomeExclusivePhysicalStorage() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    for (index, name) in ["a", "b"].enumerated() {
        model.consume(observed(name, folder: true, inode: UInt64(index+2)))
        model.consume(observed(name + "/Cargo.toml", inode: UInt64(index+4)))
        model.consume(.init(relativePath: Data((name + "/shared").utf8), kind: .regularFile,
            identity: .returned(.init(device: 1, inode: 6)), linkCount: .returned(2), flags: .returned(0),
            bytes: .init(dataLogical: .returned(10), allForkLogical: .returned(10),
                dataAllocated: .returned(10), allForkAllocated: .returned(10))))
    }
    let snapshot = model.finish()
    let report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated")
    #expect(report.projectCount == 2)
    #expect(report.crossFolderHardlinkObjects == 1)
    #expect(report.projects.reduce(UInt64(0)) { $0 + ($1.bytes.dataLogical.knownBytes ?? 0) } == 20)
    #expect(snapshot.distinctObjects.byteSubtotals.dataLogical.knownBytes == 10)
}

@Test func attributionLibraryLayoutWorksWhenLibraryIsInsideTheChosenScope() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("Library", folder: true, inode: 2))
    model.consume(observed("Library/Caches", folder: true, inode: 3))
    model.consume(observed("Library/Caches/data", inode: 4, size: 10))
    model.consume(observed("Library/Application Support", folder: true, inode: 5))
    model.consume(observed("Library/Application Support/data", inode: 6, size: 20))
    let report = try AnalysisAttributionReport.make(model.finish(), scopePath: "/Generated")
    #expect(report.categories[AnalysisCategory.toolCache.rawValue].bytes.dataLogical.knownBytes == 10)
    #expect(report.categories[AnalysisCategory.appSupport.rawValue].bytes.dataLogical.knownBytes == 20)
}

@Test func attributionDoesNotAssignSharedCachesToAnAncestorProject() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("Cargo.toml", inode: 2, size: 5))
    model.consume(observed(".cache", folder: true, inode: 3))
    model.consume(observed(".cache/data", inode: 4, size: 10))
    let report = try AnalysisAttributionReport.make(model.finish(), scopePath: "/Generated")
    #expect(report.projectCount == 1)
    #expect(report.projects.first?.bytes.dataLogical.knownBytes == 5)
    #expect(report.projects.last?.bytes.dataLogical.knownBytes == 10)
    #expect(report.projects.reduce(UInt64(0)) { $0 + ($1.bytes.dataLogical.knownBytes ?? 0) } == 15)
}

@Test func attributionSubtractsKnownSupportCountsEvenWhenByteSumOverflowed() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    model.consume(observed("Cargo.toml", inode: 2))
    for (name, inode, size) in [("huge", UInt64(3), UInt64.max), ("one", UInt64(4), UInt64(1))] {
        model.consume(.init(relativePath: Data(name.utf8), kind: .regularFile,
            identity: .returned(.init(device: 1, inode: inode)), linkCount: .returned(1), flags: .returned(0),
            bytes: .init(dataLogical: .returned(size), allForkLogical: .returned(size),
                dataAllocated: .returned(size), allForkAllocated: .returned(size))))
    }
    model.consume(observed(".cache", folder: true, inode: 5))
    model.consume(.init(relativePath: Data(".cache/unknown".utf8), kind: .regularFile,
        identity: .returned(.init(device: 1, inode: 6)), linkCount: .returned(1), flags: .returned(0),
        bytes: .init(dataLogical: .notReturned, allForkLogical: .failed(code: 13),
            dataAllocated: .notReturned, allForkAllocated: .failed(code: 5))))
    let snapshot = model.finish()
    let report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated/Project")
    let direct = report.categories[AnalysisCategory.other.rawValue]
    let cache = report.categories[AnalysisCategory.toolCache.rawValue]
    let project = try #require(report.projects.first { $0.folder == .root })
    let shared = try #require(report.projects.first { $0.title == "Unassigned / shared" })
    for metric in AnalysisByteMetric.allCases {
        #expect(direct.bytes[metric].knownBytes == nil)
        #expect(direct.bytes[metric].overflowed)
        #expect(direct.bytes[metric].notReturnedCount == 0)
        #expect(direct.bytes[metric].failedCount == 0)
        #expect(project.bytes[metric].notReturnedCount == 0)
        #expect(project.bytes[metric].failedCount == 0)
        #expect(cache.bytes[metric].notReturnedCount + direct.bytes[metric].notReturnedCount
            == snapshot.root.namespaceSubtotals[metric].notReturnedCount)
        #expect(shared.bytes[metric].failedCount + project.bytes[metric].failedCount
            == snapshot.root.namespaceSubtotals[metric].failedCount)
    }
}

@Test func attributionPartitionsSupportCountsAcrossGeneratedNestedProjectsAndCaches() throws {
    // Fixed seeds vary missing/failed/overflowing fields independently. The
    // oracle is conservation of disjoint observations, not subtraction's code.
    for seed in UInt64(1)...128 {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 24
        }
        func metric() -> AnalysisMetadata<UInt64> {
            switch next() % 7 {
            case 0: return .notReturned
            case 1: return .failed(code: 13)
            case 2: return .returned(UInt64.max)
            default: return .returned(next() % 4096)
            }
        }
        var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
        var inode: UInt64 = 2
        model.consume(observed("Cargo.toml", inode: inode)); inode += 1
        let scopes = ["project", "project/nested", "project/.cache", "project/node_modules",
            "project/nested/.cache", "project/nested/build", "project/Library", "project/Library/Caches",
            "__pycache__", "loose", "loose/child", "loose/child/target"]
        for path in scopes {
            model.consume(observed(path, folder: true, inode: inode)); inode += 1
            if next() % 2 == 0 {
                model.consume(observed(path + "/Cargo.toml", inode: inode)); inode += 1
            }
            for file in 0..<32 {
                model.consume(.init(relativePath: Data((path + "/item-\(file).txt").utf8), kind: .regularFile,
                    identity: .returned(.init(device: 1, inode: inode)), linkCount: .returned(1), flags: .returned(0),
                    bytes: .init(dataLogical: metric(), allForkLogical: metric(),
                        dataAllocated: metric(), allForkAllocated: metric())))
                inode += 1
            }
        }
        let snapshot = model.finish()
        let report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated/Workspace")
        #expect(snapshot.rejectedRecords == 0)
        for partition in [report.fileTypes, report.categories, report.projects] {
            #expect(partition.reduce(UInt64(0)) { $0 + $1.files } == snapshot.root.counts.regularFiles)
            for metric in AnalysisByteMetric.allCases {
                let missing = partition.reduce(UInt64(0)) { $0 + $1.bytes[metric].notReturnedCount }
                let failed = partition.reduce(UInt64(0)) { $0 + $1.bytes[metric].failedCount }
                #expect(missing == snapshot.root.namespaceSubtotals[metric].notReturnedCount)
                #expect(failed == snapshot.root.namespaceSubtotals[metric].failedCount)
            }
        }
    }
}

@Test func attributionRecognizesSteamAppsAndCachesWithoutReadingManifests() throws {
    var model = StorageAnalysisAccumulator(rootIdentity: .init(device: 1, inode: 1))
    var inode: UInt64 = 2
    func directory(_ path: String) { model.consume(observed(path, folder: true, inode: inode)); inode += 1 }
    func file(_ path: String, _ size: UInt64) { model.consume(observed(path, inode: inode, size: size)); inode += 1 }
    directory("steamapps"); directory("steamapps/common"); directory("steamapps/common/Game"); file("steamapps/common/Game/game.dat", 30)
    directory("steamapps/workshop"); file("steamapps/workshop/123.bin", 40)
    directory("fake"); directory("fake/steamapps"); file("fake/steamapps/archive.dat", 60)
    directory("Tool.app"); file("Tool.app/Package.swift", 20)
    directory(".cargo"); directory(".cargo/registry"); file(".cargo/registry/Cargo.toml", 10)
    directory("Library"); directory("Library/Caches"); directory("Library/Caches/huggingface"); file("Library/Caches/huggingface/model.gguf", 100)
    directory("Project"); file("Project/.git", 1); directory("Project/build"); file("Project/build/Package.swift", 2); file("Project/build/artifact.o", 3)
    let snapshot = model.finish(), report = try AnalysisAttributionReport.make(snapshot, scopePath: "/Generated")
    #expect(report.projectCount == 1)
    let expected: [(AnalysisCategory, UInt64)] = [(.steamLibrary,70),(.other,61),(.applicationBundle,20),(.developerCache,10),(.modelStore,100),(.buildOutput,5)]
    for (kind, size) in expected { #expect(report.categories[kind.rawValue].bytes.dataLogical.knownBytes == size) }
    for metric in AnalysisByteMetric.allCases {
        for partition in [report.categories, report.projects, report.fileTypes] {
            #expect(partition.reduce(UInt64(0)) { $0 + ($1.bytes[metric].knownBytes ?? 0) } == snapshot.root.namespaceSubtotals[metric].knownBytes)
        }
    }
    #expect(AnalysisFileType.match(Data("data.SQLITE".utf8)) == .databases)
    #expect(AnalysisFileType.match(Data("file.dylib".utf8)) == .compiledFiles)
}
