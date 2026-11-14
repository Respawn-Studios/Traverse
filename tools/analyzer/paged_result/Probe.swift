import Darwin
import Foundation
import SQLite3

struct ProbeStats: Sendable {
    var counts:[UInt64]=[]
    var groups:Int64=0
    var folders:Int64=0
    var projects:Int64=0
    var maximumAncestors=0
    var writeSeconds=0.0
    var projectionSeconds=0.0
    var controls:[String]=[]
    var referenceOverflowDifferences=0
}

private func require(_ value:Bool,_ code:Int32) throws { if !value { throw PagedFailure(code:code) } }
func encodedTerminal(_ value:ScannerTerminal) throws -> Data {
    let fields=["data_logical","all_logical","data_allocated","all_allocated"]
    return try JSONSerialization.data(withJSONObject:["complete":value.complete,"reason":value.reason,
        "entries":String(value.entries),"errors":String(value.errors),"objects":String(value.objectCount),
        "kind_counts":value.kindCounts.map(String.init),
        "entry_totals":Dictionary(uniqueKeysWithValues:zip(fields,value.namespaceTotals.map(String.init))),
        "object_totals":Dictionary(uniqueKeysWithValues:zip(fields,value.objectTotals.map(String.init)))],options:[.sortedKeys])
}

func bindRoot(_ db:PagedDatabase,device:UInt64,inode:UInt64) throws {
    let query=try PagedStatement(db.raw,"UPDATE observations_v2 SET identity=? WHERE id=0")
    try db.transaction {try query.blob(1,packedUnsigned(device)+packedUnsigned(inode));_ = try query.step();try query.reset()}
}

private func stream(_ db:PagedDatabase,session:UUID,device:UInt64,inode:UInt64) throws -> ProbeStats {
    let began=ProcessInfo.processInfo.systemUptime
    let decoder=ScannerProtocolDecoder(session:session,root:.init(device:device,inode:inode))
    let writer=try PagedNodeWriter(db)
    var pending=Data(),terminal:ScannerTerminal?
    defer { writer.rollback() }
    while let data=try FileHandle.standardInput.read(upToCount:16384),!data.isEmpty {
        pending.append(data);try require(pending.count<=131072,-70)
        while let newline=pending.firstIndex(of:10) {
            let line=Data(pending[..<newline]);pending.removeSubrange(...newline)
            try autoreleasepool {
                switch try decoder.consume(line) {
                case .header:
                    try bindRoot(db,device:device,inode:inode)
                    FileHandle.standardOutput.write(Data("{\"phase\":\"header\"}\n".utf8))
                case .records(let records):
                    for record in records { try writer.accept(record) }
                case .issue: break
                case .terminal(let value): terminal=value
                }
            }
        }
        if b06_cancelled() != 0 { throw PagedFailure(code:SQLITE_INTERRUPT) }
    }
    try decoder.finish();try require(pending.isEmpty,-71)
    guard let terminal else { throw PagedFailure(code:-72) }
    try writer.commit();try require(writer.count==terminal.entries,-73)
    let update=try PagedStatement(db.raw,"UPDATE scan_state SET terminal=? WHERE id=1")
    try update.blob(1,encodedTerminal(terminal));_ = try update.step();try update.reset()
    return ProbeStats(maximumAncestors:writer.maximumAncestors,writeSeconds:ProcessInfo.processInfo.systemUptime-began)
}

func project(_ db:PagedDatabase,scope:String,stats:ProbeStats) throws -> ProbeStats {
    var value=stats
    let began=ProcessInfo.processInfo.systemUptime
    let report=try PagedProjection.build(db,scope:scope)
    value.projectionSeconds=ProcessInfo.processInfo.systemUptime-began
    value.counts=report.totals.counts;value.folders=report.folderCount;value.projects=report.projectCount;value.groups=report.groupCount
    // A completion flag is set only after the shared consumer has checked the
    // stored terminal and prepared the actual hierarchy/classification.
    let query=try PagedStatement(db.raw,"SELECT terminal FROM scan_state WHERE id=1")
    try require(try query.step(),-74)
    guard let data=try query.data(0),data.count<65536,
          let terminal=try JSONSerialization.jsonObject(with:data) as? [String:Any],
          let entries=terminal["entries"] as? String,let count=UInt64(entries),
          let complete=terminal["complete"] as? Bool else { throw PagedFailure(code:-75) }
    try require(count==report.totals.counts.reduce(0,+),-76)
    let fields=["data_logical","all_logical","data_allocated","all_allocated"]
    if complete {
        guard let totals=terminal["entry_totals"] as? [String:String] else { throw PagedFailure(code:-77) }
        for (metric,field) in zip(AnalysisByteMetric.allCases,fields) {
            try require(report.totals.bytes[metric].knownBytes==totals[field].flatMap(UInt64.init),-78)
        }
        let objects=try pagedObjects(db)
        guard !objects.uncertain,let count=terminal["objects"] as? String,UInt64(count)==objects.count,
              let totals=terminal["object_totals"] as? [String:String] else {throw PagedFailure(code:-108)}
        for (metric,field) in zip(AnalysisByteMetric.allCases,fields) {
            try require(objects.bytes[metric].knownBytes==totals[field].flatMap(UInt64.init),-109)
        }
    }
    try db.transaction { try db.exec(complete ? "UPDATE scan_state SET state=1 WHERE id=1" : "UPDATE scan_state SET state=2 WHERE id=1") }
    return value
}

private func controls(_ db:PagedDatabase) throws -> ProbeStats {
    try bindRoot(db,device:11,inode:99999)
    var records:[AnalysisEntryObservation]=[]
    var inode:UInt64=100
    func add(_ path:Data,_ kind:AnalysisEntryKind,_ value:AnalysisMetadata<UInt64> = .returned(7),identity:UInt64?=nil) {
        inode+=1
        records.append(.init(relativePath:path,kind:kind,identity:.returned(.init(device:11,inode:identity ?? inode)),
            linkCount:.returned(identity==900 ? 2:1),flags:.returned(0),bytes:kind == .regularFile
                ? .init(dataLogical:value,allForkLogical:value,dataAllocated:value,allForkAllocated:value) : .init()))
    }
    func path(_ text:String)->Data {Data(text.utf8)}
    add(path("Package.swift"),.regularFile)
    add(path("Work"),.directory)
    add(path("Work/Cargo.toml"),.regularFile)
    add(path("Work/build"),.directory)
    add(path("Work/build/zero.txt"),.regularFile,.returned(0))
    add(path("Work/build/missing.bin"),.regularFile,.notReturned)
    add(path("Work/build/failed.bin"),.regularFile,.failed(code:13))
    add(path("Work/.cache"),.directory)
    add(path("Work/.cache/shared.dat"),.regularFile)
    add(path("Work/node_modules"),.directory)
    add(path("Work/node_modules/package.json"),.regularFile)
    add(path("Work/node_modules/dependency.txt"),.regularFile)
    add(path("Library"),.directory)
    add(path("Library/Caches"),.directory)
    add(path("Library/Caches/huggingface"),.directory)
    add(path("Library/Caches/huggingface/model.gguf"),.regularFile,.returned(13))
    add(Data([255,95,97,46,77,80,52]),.regularFile,.returned(12))
    add(path("hard-one.txt"),.regularFile,.returned(9),identity:900)
    add(path("hard-two.txt"),.regularFile,.returned(9),identity:900)
    add(path("overflow-one.bin"),.regularFile,.returned(.max))
    add(path("overflow-two.bin"),.regularFile,.returned(1))
    add(path("alias"),.symbolicLink)
    let writer=try PagedNodeWriter(db)
    for record in records {try writer.accept(record)}
    try writer.commit()
    var oracle=StorageAnalysisAccumulator(rootIdentity:.init(device:11,inode:99999))
    for record in records {_ = oracle.consume(record)}
    let snapshot=oracle.finish()
    let expected=try AnalysisAttributionReport.make(snapshot,scopePath:"/Generated/Scope")
    let report=try PagedProjection.build(db,scope:"/Generated/Scope")
    try require(report.totals.bytes==snapshot.root.namespaceSubtotals,-80)
    let rootCounts=snapshot.root.counts
    try require(report.totals.counts==[rootCounts.regularFiles,rootCounts.directories,rootCounts.symbolicLinks,rootCounts.other,rootCounts.unknown],-81)
    var referenceDifferences=0
    for (kind,slices) in [(0,expected.fileTypes),(1,expected.categories)] {
        let query=try PagedStatement(db.raw,"SELECT key,value FROM groups WHERE kind=? ORDER BY key")
        try query.integer(1,Int64(kind));var count=0
        while try query.step() {
            guard let data=try query.data(1) else {throw PagedFailure(code:-82)}
            let actual=try PagedValue(data:data),index=Int(query.number(0))
            try require(index==count && actual.counts[0]==slices[index].files,-83)
            if actual.bytes != slices[index].bytes {
                try require(kind==1 && AnalysisByteMetric.allCases.contains { slices[index].bytes[$0].overflowed },-106)
                referenceDifferences+=1
            }
            count+=1
        }
        try require(count==slices.count,-84)
    }
    let project=try PagedStatement(db.raw,"SELECT key,value FROM groups WHERE kind=2 ORDER BY key")
    var observed:[String:PagedValue]=[:]
    while try project.step() {
        let id=project.number(0)
        guard let data=try project.data(1) else {throw PagedFailure(code:-85)}
        observed[id==0 ? "Unassigned / shared" : try storedPath(db,id:id-1,root:"Scope")]=try PagedValue(data:data)
    }
    try require(observed.count==expected.projects.count,-86)
    for slice in expected.projects {
        try require(observed[slice.title]?.counts[0]==slice.files,-87)
        if observed[slice.title]?.bytes != slice.bytes {
            try require(AnalysisByteMetric.allCases.contains {slice.bytes[$0].overflowed},-107)
            referenceDifferences+=1
        }
    }
    // Constraints run under a savepoint; no expected rejection is retained as
    // a failed scan, and no earlier actual case is reopened or repaired.
    for sql in ["INSERT INTO observations_v2 VALUES(200,199,x'61',0,NULL,NULL,NULL,zeroblob(52))",
                "INSERT INTO observations_v2 VALUES(200,1,x'61',0,NULL,NULL,NULL,zeroblob(52))",
                "INSERT INTO observations_v2 VALUES(200,0,x'2e2e',0,NULL,NULL,NULL,zeroblob(52))",
                "INSERT INTO observations_v2 VALUES(200,0,x'61',0,NULL,NULL,NULL,x'00')"] {
        try db.exec("SAVEPOINT rejection")
        do {try db.exec(sql);throw PagedFailure(code:-88)}
        catch let error as PagedFailure {try require(error.code==SQLITE_CONSTRAINT,-89)}
        try db.exec("ROLLBACK TO rejection;RELEASE rejection")
    }
    try db.exec("SAVEPOINT duplicate_parent")
    let alias=packedUnsigned(11)+packedUnsigned(999)
    let directory=try PagedStatement(db.raw,"INSERT INTO observations_v2 VALUES(?,0,?,1,?,NULL,NULL,zeroblob(52))")
    for id in [Int64(200),201] {
        try directory.integer(1,id);try directory.blob(2,Data("Alias-\(id)".utf8));try directory.blob(3,alias)
        _ = try directory.step();try directory.reset()
    }
    do {try db.exec("INSERT INTO observations_v2 VALUES(202,201,x'6368696c64',0,NULL,NULL,NULL,zeroblob(52))");throw PagedFailure(code:-213)}
    catch let error as PagedFailure {try require(error.code==SQLITE_CONSTRAINT,-214)}
    try db.exec("ROLLBACK TO duplicate_parent;RELEASE duplicate_parent")
    return ProbeStats(counts:report.totals.counts,groups:report.groupCount,folders:report.folderCount,projects:report.projectCount,
        maximumAncestors:writer.maximumAncestors,controls:["raw names and all four metric/support/overflow families",
        "root rollups and File Types match the existing pure model; role/project overflow differences require the separate independent oracle",
        "orphan/non-directory parents, traversal names and malformed metric lengths refused by SQLite"],referenceOverflowDifferences:referenceDifferences)
}

private func storedPath(_ db:PagedDatabase,id:Int64,root:String) throws -> String {
    var node=id,parts:[Data]=[]
    let query=try PagedStatement(db.raw,"SELECT parent,name FROM observations_v2 WHERE id=?")
    while node>0 {
        try require(parts.count<64,-90);try query.integer(1,node)
        guard try query.step(),let name=try query.data(1) else {throw PagedFailure(code:-91)}
        let parent=query.number(0);try require(parent<node,-92);node=parent;parts.append(name);try query.reset()
    }
    if parts.isEmpty {return root}
    return String(bytes:parts.reversed().joined(separator:Data([47])),encoding:.utf8) ?? "Folder with a non-UTF-8 name"
}

private final class HeldRead: @unchecked Sendable {
    private let lock=NSLock(),release=DispatchSemaphore(value:0)
    private var entered=false,closed=false,expired=false
    var hasEntered:Bool {lock.withLock {entered}}
    var hasClosed:Bool {lock.withLock {closed}}
    var timedOut:Bool {lock.withLock {expired}}
    func hold() {
        lock.withLock {entered=true}
        if release.wait(timeout:.now()+2) == .timedOut {lock.withLock {expired=true}}
    }
    func drain() {release.signal()}
    func didClose() {lock.withLock {closed=true}}
}

private func readerLifecycle(path:String) async throws {
    let held=HeldRead(),reader=PagedResultReader(path:path,beforeQuery:{held.hold()})
    let page=Task {try await reader.page(parent:0,cursor:0)}
    for _ in 0..<1000 {
        if held.hasEntered {break}
        try await Task.sleep(for:.milliseconds(1))
    }
    try require(held.hasEntered,-110)
    page.cancel()
    let close=Task {try await reader.closeAndDrain();held.didClose()}
    try await Task.sleep(for:.milliseconds(30))
    try require(!held.hasClosed,-111)
    held.drain()
    do {_ = try await page.value;throw PagedFailure(code:-112)}
    catch let error as PagedFailure {try require(error.code==SQLITE_INTERRUPT,-113)}
    try await close.value
    try require(held.hasClosed && !held.timedOut,-114)
    do {_ = try await reader.page(parent:0,cursor:0);throw PagedFailure(code:-115)}
    catch let error as PagedFailure {try require(error.code==SQLITE_INTERRUPT,-116)}
}

private func cachedCatalogChange(path:String) async throws {
    let reader=PagedResultReader(path:path)
    let original=try await reader.page(parent:0,cursor:0)
    guard original.contains(where:{$0.id==1 && $0.rawName==Data("Package.swift".utf8)}) else {throw PagedFailure(code:-219)}
    let writer=try PagedDatabase(path:path,readOnly:false)
    try writer.transaction {try writer.exec("UPDATE observations_v2 SET name=x'4368616e6765642e7377696674' WHERE id=1")}
    var returnedStale=false,rejection:Int32=0
    do {_ = try await reader.page(parent:0,cursor:0);returnedStale=true}
    catch let error as PagedFailure {rejection=error.code}
    // Intentional mutation is restored while this test still owns the lease.
    // The controller independently checks all logical data after actual exit.
    try writer.transaction {try writer.exec("UPDATE observations_v2 SET name=x'5061636b6167652e7377696674' WHERE id=1")}
    try writer.close();try await reader.closeAndDrain()
    guard !returnedStale else {throw PagedFailure(code:-220)}
    guard rejection == -230 else {throw PagedFailure(code:-221)}
}

private func resetVerifiedGeneratedStore(_ db:PagedDatabase) throws {
    // Called only by the held test-session controller after its independent
    // oracle, durable proof append and actual child/reader drain. No quota
    // credit, VACUUM, file replacement or failed-case retirement occurs.
    for (table,key) in [("groups","(kind,key)"),("folder_listing","node"),("contexts","node"),("markers","node"),("rollups","node"),("direct_totals","node"),("direct_files","node"),("type_totals","type")] {
        let selected=table=="groups" ? "kind,key":key
        while true {
            var count:Int64=0
            try db.transaction {
                try db.exec("DELETE FROM \(table) WHERE \(key) IN(SELECT \(selected) FROM \(table) LIMIT 128)")
                count=try db.scalar("SELECT changes()")
            }
            if count==0 {break}
        }
    }
    while true {
        var count:Int64=0
        try db.transaction {
            try db.exec("DELETE FROM observations_v2 WHERE id IN(SELECT id FROM observations_v2 WHERE id>0 ORDER BY id DESC LIMIT 128)")
            count=try db.scalar("SELECT changes()")
        }
        if count==0 {break}
    }
    try db.transaction {try db.exec("UPDATE observations_v2 SET identity=NULL WHERE id=0;UPDATE scan_state SET state=0,terminal=NULL WHERE id=1")}
}

@main private enum Main {
    @MainActor static func main() async {
        b06_install_cancellation()
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.count>=2,["prepare","controls","stream","project","inspect","native","reset","folders","configure","pump-fault","full-fault","cache-stale","recover-prefix","protocol-reject","object-vectors"].contains(args[0]) else {exit(64)}
        let began=ProcessInfo.processInfo.systemUptime
        do {
            if args[0]=="object-vectors" {
                print(String(decoding:try objectConsistencyVectors(),as:UTF8.self));return
            }
            if args[0]=="protocol-reject" {
                guard args.count==5,let device=UInt64(args[3]),let inode=UInt64(args[4]) else {throw PagedFailure(code:-260)}
                _ = try await Task.detached(priority:.utility) {
                    try runWorkerPump(lane:.memory,worker:args[1],path:"",scope:args[2],session:UUID(),device:device,inode:inode,
                        spawned:{ pid in FileHandle.standardError.write(Data("owned_worker_pid=\(pid)\n".utf8)) },progress:{_ in})
                }.value
                throw PagedFailure(code:-261) // Malformed output must refuse.
            }
            if args[0]=="cache-stale" {
                try await cachedCatalogChange(path:args[1]);print("{\"passed\":true,\"cached_change_refused\":true}");return
            }
            if args[0]=="folders" {
                guard args.count==4,["memory","paged"].contains(args[2]) else {throw PagedFailure(code:-122)}
                let result=try await SyntheticFolderInspection.run(path:args[1],memory:args[2]=="memory",capture:args[3]=="-" ? nil:args[3])
                print(String(decoding:result,as:UTF8.self));return
            }
            if args[0]=="native" {
                guard args.count==8,let lane=PagedLane(rawValue:args[2]),let dev=UInt64(args[5]),let ino=UInt64(args[6]) else {throw PagedFailure(code:-117)}
                let result=try await NativePagedPipeline.run(lane:lane,worker:args[3],path:args[1],scope:args[4],device:dev,inode:ino,capture:args[7]=="-" ? nil:args[7])
                print(String(decoding:result,as:UTF8.self));return
            }
            if args[0]=="pump-fault" {
                guard args.count==8,let lane=PagedLane(rawValue:args[2]),let dev=UInt64(args[5]),let ino=UInt64(args[6]),
                      (lane == .swift && args[7]=="stop_pending") || (lane == .rust && args[7]=="crash_committed") else {throw PagedFailure(code:-209)}
                _ = try await Task.detached(priority:.utility) {
                    try runWorkerPump(lane:lane,worker:args[3],path:args[1],scope:args[4],session:UUID(),device:dev,inode:ino,fault:args[7]) { _ in }
                }.value
                throw PagedFailure(code:-210)
            }
            let stats=try await Task.detached(priority:.utility) {
                let db=try PagedDatabase(path:args[1],readOnly:args[0]=="inspect")
                var stats=ProbeStats()
                if args[0]=="prepare" {
                    try db.exec(pagedSchema)
                    guard let profile=PagedProfile.named(args.count==3 ? args[2]:"baseline") else {throw PagedFailure(code:-206)}
                    try db.exec("UPDATE profile SET aggregates=\(profile.aggregates ? 1:0),transaction_rows=\(profile.rows) WHERE id=1")
                }
                else if args[0]=="full-fault" {
                    // A real SQLITE_FULL in the generated private result only.
                    // Existing pages and FULL/DELETE synchronization remain.
                    guard try db.scalar("SELECT count(*) FROM observations_v2")==1 else {throw PagedFailure(code:-211)}
                    let pages=try db.scalar("PRAGMA page_count")
                    try db.exec("PRAGMA max_page_count=\(pages)")
                    let writer=try PagedNodeWriter(db)
                    defer {writer.rollback()}
                    for id in 1...220000 {
                        let bytes=AnalysisByteObservation(dataLogical:.returned(7),allForkLogical:.returned(7),dataAllocated:.returned(7),allForkAllocated:.returned(7))
                        let record=AnalysisEntryObservation(relativePath:Data("Full-\(id).txt".utf8),kind:.regularFile,
                            identity:.returned(.init(device:11,inode:UInt64(id))),linkCount:.returned(1),flags:.returned(0),bytes:bytes)
                        try writer.accept(record)
                    }
                    throw PagedFailure(code:-212)
                }
                else if args[0]=="reset" {try resetVerifiedGeneratedStore(db)}
                else if args[0]=="recover-prefix" {
                    // Explicit generated-test cold open: SQLite performs its
                    // normal rollback recovery. No projection or resumption.
                    guard args.count==3,let count=Int64(args[2]),count==1024,
                          try db.scalar("SELECT state FROM scan_state WHERE id=1")==0,
                          try db.scalar("SELECT count(*)-1 FROM observations_v2")==count else {throw PagedFailure(code:-231)}
                    stats.controls=["Explicit generated-store SQLite recovery; state stays incomplete; source work does not resume"]
                }
                else if args[0]=="configure" {
                    guard args.count==3,let profile=PagedProfile.named(args[2]),try db.scalar("SELECT count(*) FROM observations_v2")==1,
                          try db.scalar("SELECT state FROM scan_state WHERE id=1")==0,
                          try db.scalar("SELECT (SELECT count(*) FROM groups)+(SELECT count(*) FROM rollups)+(SELECT count(*) FROM contexts)+(SELECT count(*) FROM direct_totals)+(SELECT count(*) FROM direct_files)+(SELECT count(*) FROM type_totals)+(SELECT count(*) FROM markers)+(SELECT count(*) FROM folder_listing)")==0 else {throw PagedFailure(code:-207)}
                    try db.transaction {try db.exec("UPDATE profile SET aggregates=\(profile.aggregates ? 1:0),transaction_rows=\(profile.rows) WHERE id=1")}
                }
                else if args[0]=="controls" {stats=try controls(db)}
                else if args[0]=="stream" {
                    guard args.count==6,let session=UUID(uuidString:args[2]),let dev=UInt64(args[3]),let ino=UInt64(args[4]) else {throw PagedFailure(code:-100)}
                    stats=try stream(db,session:session,device:dev,inode:ino)
                    stats=try project(db,scope:args[5],stats:stats)
                } else if args[0]=="project" {
                    guard args.count==3 else {throw PagedFailure(code:-101)}
                    stats=try project(db,scope:args[2],stats:stats)
                }
                try db.close();return stats
            }.value
            let reader=PagedResultReader(path:args[1])
            let rows=try await reader.page(parent:0,cursor:0)
            try require(rows.count<=256,-102)
            if args[0]=="controls" {
                let folders=try await reader.folderPage(parent:0,cursor:0)
                try require(folders.map(\.title)==["Work","Library"] && folders.map {$0.value?.bytes.allForkLogical.knownBytes} == [28,13],-118)
                let after=try await reader.folderPage(parent:0,cursor:folders[0].id)
                try require(after.map(\.title)==["Library"],-119)
                do {_ = try await reader.folderPage(parent:0,cursor:1);throw PagedFailure(code:-120)}
                catch let error as PagedFailure {try require(error.code == -42,-121)}
            }
            try await reader.closeAndDrain()
            do {_ = try await reader.page(parent:0,cursor:0);throw PagedFailure(code:-103)}
            catch let error as PagedFailure {try require(error.code==SQLITE_INTERRUPT,-104)}
            if args[0]=="controls" {try await readerLifecycle(path:args[1])}
            var resources=B06Resources();try require(b06_resources(&resources)==0,-105)
            let output:[String:Any]=["schema":1,"passed":true,"mode":args[0],"counts":stats.counts,
                "groups":stats.groups,"folders":stats.folders,"projects":stats.projects,"maximum_ancestors":stats.maximumAncestors,
                "write_seconds":stats.writeSeconds,"projection_seconds":stats.projectionSeconds,
                "elapsed_seconds":ProcessInfo.processInfo.systemUptime-began,"peak_bytes":resources.peak_rss,
                "page_rows":rows.count,"peak_cached_rows":reader.peakCachedRows,"controls":stats.controls]
            var result=output;result["reference_overflow_differences"]=stats.referenceOverflowDifferences
            print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
        } catch let error as PagedFailure {FileHandle.standardError.write(Data("paged_probe_\(error.code)\n".utf8));exit(2)}
        catch {FileHandle.standardError.write(Data("paged_probe_failed\n".utf8));exit(2)}
    }
}
