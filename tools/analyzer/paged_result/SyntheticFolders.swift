// In-memory model inputs only; creates no new source filesystem corpus.
import AppKit
import Foundation

private struct GeneratedFolderResult:Sendable {
    let rows:StorageAnalysisPreparedRows?
    let report:AnalysisAttributionReport
    let ingest:Double
    let projection:Double
}

@MainActor
enum SyntheticFolderInspection {
    static let count=32000
    static func run(path:String,memory:Bool,capture:String?) async throws -> Data {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let began=ProcessInfo.processInfo.systemUptime
        let inspector=PagedNativeInspection(title:"B06 generated folder model qualification"),token:UUID
        token=inspector.generation
        let recordCount=count
        var reader:PagedResultReader?
        do {
            let prepared=try await Task.detached(priority:.utility) { [inspector,recordCount] in
                let root=AnalysisObjectIdentity(device:11,inode:99999)
                let began=ProcessInfo.processInfo.systemUptime
                var model:StorageAnalysisAccumulator?=memory ? .init(rootIdentity:root):nil
                let db=memory ? nil:try PagedDatabase(path:path,readOnly:false)
                if let db {try bindRoot(db,device:root.device,inode:root.inode)}
                let writer=try db.map(PagedNodeWriter.init)
                defer {writer?.rollback()}
                Task { @MainActor in inspector.progress(0,token:token) }
                for index in 1...recordCount {
                    if b06_cancelled() != 0 {throw PagedFailure(code:9)}
                    let digits=String(index),name="Folder-"+String(repeating:"0",count:6-digits.count)+digits
                    let record=AnalysisEntryObservation(relativePath:Data(name.utf8),kind:.directory,
                        identity:.returned(.init(device:11,inode:UInt64(100000+index))),linkCount:.returned(1),flags:.returned(0))
                    if writer != nil {try writer!.accept(record)}else{_ = model!.consume(record)}
                }
                try writer?.commit()
                let ingested=ProcessInfo.processInfo.systemUptime-began,projectionBegan=ProcessInfo.processInfo.systemUptime
                if var model {
                    let snapshot=model.finish()
                    guard snapshot.isComplete,snapshot.root.counts.directories==recordCount else {throw PagedFailure(code:-200)}
                    let rows=try StorageAnalysisPreparedRows.make(snapshot,sort:.init(field:.logical,ascending:false))
                    return try GeneratedFolderResult(rows:rows,report:AnalysisAttributionReport.make(snapshot,scopePath:"/Generated/Folders"),ingest:ingested,
                        projection:ProcessInfo.processInfo.systemUptime-projectionBegan)
                }
                guard let db else {throw PagedFailure(code:-201)}
                let terminal=ScannerTerminal(complete:true,reason:"complete",entries:UInt64(recordCount),peakResidentBytes:nil,elapsedNanoseconds:0,
                    kindCounts:[0,UInt64(recordCount),0,0],namespaceTotals:[0,0,0,0],objectTotals:[0,0,0,0],objectCount:0,errors:0)
                let update=try PagedStatement(db.raw,"UPDATE scan_state SET terminal=? WHERE id=1")
                try update.blob(1,encodedTerminal(terminal));_ = try update.step();try update.reset()
                _ = try project(db,scope:"/Generated/Folders",stats:ProbeStats())
                let report=try makePagedReport(db,scope:"/Generated/Folders",complete:true)
                // The writer's statement must finalize before an explicit close.
                return GeneratedFolderResult(rows:nil,report:report,ingest:ingested,projection:ProcessInfo.processInfo.systemUptime-projectionBegan)
            }.value
            if let rows=prepared.rows {inspector.showMemory(rows)}
            else {
                let value=PagedResultReader(path:path);reader=value
                var cursor:Int64=0,seen:Set<Int64>=[]
                for _ in 0..<4 {
                    let rows=try await value.folderPage(parent:0,cursor:cursor)
                    guard rows.count==256 else {throw PagedFailure(code:-202)}
                    for row in rows {guard row.kind==1,seen.insert(row.id).inserted else {throw PagedFailure(code:-203)}}
                    inspector.showPage(rows);cursor=rows.last!.id
                }
                guard value.peakCachedRows==512 else {throw PagedFailure(code:-204)}
            }
            for kind in 0..<3 {inspector.showChart(prepared.report,kind:kind);try await Task.sleep(for:.milliseconds(30))}
            inspector.completed(UInt64(count),complete:true)
            if let capture {try inspector.snapshot(path:capture)}
            let cached=reader?.peakCachedRows ?? 0
            try await reader?.closeAndDrain()
            var output=inspector.finish(),resources=B06Resources()
            guard b06_resources(&resources)==0 else {throw PagedFailure(code:-205)}
            output["schema"]=1;output["passed"]=true;output["scope"]="32000 generated in-memory directory observations; not a filesystem scan"
            output["lane"]=memory ? "memory":"paged";output["records"]=count
            output["parent_peak_bytes"]=resources.peak_rss;output["parent_current_rss_bytes"]=resources.current_rss
            output["ingest_seconds"]=prepared.ingest;output["projection_seconds"]=prepared.projection
            output["model_to_display_seconds"]=ProcessInfo.processInfo.systemUptime-began;output["peak_cached_rows"]=cached
            withExtendedLifetime(prepared) {}
            return try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys])
        } catch {
            try? await reader?.closeAndDrain();_ = inspector.finish();throw error
        }
    }
}
