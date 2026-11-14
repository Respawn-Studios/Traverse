import AppKit
import Foundation

private struct PreparedPipeline:Sendable {
    let scan:WorkerPumpResult
    let report:AnalysisAttributionReport
    let referenceRows:StorageAnalysisPreparedRows?
    let projectionSeconds:Double
}

@MainActor
enum NativePagedPipeline {
    static func run(lane:PagedLane,worker:String,path:String,scope:String,device:UInt64,inode:UInt64,capture:String?) async throws -> Data {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let began=ProcessInfo.processInfo.systemUptime,session=UUID()
        let inspector=PagedNativeInspection(title:"B06 generated result qualification")
        let token=inspector.generation
        var reader:PagedResultReader?
        do {
        let value=try await Task.detached(priority:.utility) { [inspector] in
            let scan=try runWorkerPump(lane:lane,worker:worker,path:path,scope:scope,session:session,device:device,inode:inode) {count in
                Task { @MainActor in inspector.progress(count,token:token) }
            }
            let projectionBegan=ProcessInfo.processInfo.systemUptime
            if let snapshot=scan.snapshot {
                let report=try AnalysisAttributionReport.make(snapshot,scopePath:scope)
                let rows=try StorageAnalysisPreparedRows.make(snapshot,sort:.init(field:.logical,ascending:false))
                let actual=[snapshot.root.counts.regularFiles,snapshot.root.counts.directories,snapshot.root.counts.symbolicLinks,snapshot.root.counts.other+snapshot.root.counts.unknown]
                guard actual==scan.terminal.kindCounts else {throw PagedFailure(code:-190)}
                return PreparedPipeline(scan:scan,report:report,referenceRows:rows,projectionSeconds:ProcessInfo.processInfo.systemUptime-projectionBegan)
            }
            let db=try PagedDatabase(path:path,readOnly:false)
            _ = try project(db,scope:scope,stats:ProbeStats())
            let report=try makePagedReport(db,scope:scope,complete:scan.terminal.complete)
            try db.close()
            return PreparedPipeline(scan:scan,report:report,referenceRows:nil,projectionSeconds:ProcessInfo.processInfo.systemUptime-projectionBegan)
        }.value
        if let reference=value.referenceRows {inspector.showMemory(reference);reader=nil}
        else {
            let paged=PagedResultReader(path:path);reader=paged
            inspector.showPage(try await paged.folderPage(parent:0,cursor:0))
        }
        for kind in 0..<3 {
            inspector.showChart(value.report,kind:kind)
            try await Task.sleep(for:.milliseconds(30))
        }
        inspector.completed(value.scan.terminal.entries,complete:value.report.isComplete)
        let finalDisplay=ProcessInfo.processInfo.systemUptime-began
        var pages=0,cacheRows=0
        if let reader {
            let parent=try await reader.inspectionParent();var cursor:Int64=0
            for _ in 0..<4 {
                let rows=try await reader.folderPage(parent:parent,cursor:cursor)
                pages+=1
                guard let last=rows.last else {break}
                inspector.showPage(rows);cursor=last.id
            }
            cacheRows=reader.peakCachedRows
            try await reader.closeAndDrain()
        }
        if let capture {try inspector.snapshot(path:capture)}
        var output=inspector.finish(),resources=B06Resources()
        guard b06_resources(&resources)==0 else {throw PagedFailure(code:-191)}
        output["schema"]=1;output["passed"]=true;output["lane"]=lane.rawValue
        output["entries"]=value.scan.terminal.entries;output["complete_scope"]=value.report.isComplete
        output["worker_complete_scope"]=value.scan.terminal.complete
        output["coverage_notices"]=value.scan.terminal.errors;output["kind_counts"]=value.scan.terminal.kindCounts
        output["worker_peak_bytes"]=value.scan.peak;output["parent_peak_bytes"]=resources.peak_rss
        output["worker_and_ingest_seconds"]=value.scan.seconds;output["projection_seconds"]=value.projectionSeconds
        output["scan_to_prepared_display_seconds"]=finalDisplay
        output["inspection_pages"]=pages;output["peak_cached_rows"]=cacheRows
        output["parent_current_rss_bytes"]=resources.current_rss
        var sql=B06SQLStats();b06_sql_stats(&sql)
        output["parent_sql_statements"]=sql.statements;output["parent_sql_commits"]=sql.commits
        output["parent_sql_profile_ns"]=sql.profile_ns;output["parent_sql_commit_ns"]=sql.commit_ns
        output["worker_sql"]=value.scan.sql
        output["native_scope"]="Offscreen native controls and actual chart view; live compositor, signed-app TCC and production adoption remain separate."
        withExtendedLifetime(value) {}
        return try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys])
        } catch {
            try? await reader?.closeAndDrain()
            _ = inspector.finish()
            throw error
        }
    }
}
