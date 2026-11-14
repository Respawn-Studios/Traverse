import CoreFoundation
import Darwin
import Foundation

enum PagedLane:String,Sendable {case memory,swift,rust}
struct WorkerPumpResult:Sendable {
    let terminal:ScannerTerminal
    let snapshot:StorageAnalysisSnapshot?
    let coverage:AnalysisScanCoverage
    let peak:UInt64
    let seconds:Double
    let sql:[UInt64]
}

private func strictUnsigned(_ value:Any?) throws -> UInt64 {
    guard let text=value as? String,!text.isEmpty,text.utf8.allSatisfy({(48...57).contains($0)}),
          text=="0" || text.first != "0",let number=UInt64(text) else {throw PagedFailure(code:-150)}
    return number
}
func parsePagedSummary(_ frame:[String:Any],notices:UInt64) throws -> ScannerTerminal {
    guard let boolean=frame["complete"] as? NSNumber,CFGetTypeID(boolean)==CFBooleanGetTypeID(),
          let reason=frame["reason"] as? String,(1...64).contains(reason.utf8.count),
          reason.utf8.allSatisfy({(97...122).contains($0) || $0==95}) else {throw PagedFailure(code:-151)}
    let complete=boolean.boolValue,errors=try strictUnsigned(frame["errors"]),entries=try strictUnsigned(frame["entries"])
    guard errors>=notices,entries<=220000,!complete || (reason=="complete" && errors==0) else {throw PagedFailure(code:-152)}
    let counts=try ["regular_entries","directory_entries","symlink_entries","other_entries"].map {try strictUnsigned(frame[$0])}
    guard counts.allSatisfy({$0<=220000}),counts.reduce(0,+)==entries else {throw PagedFailure(code:-153)}
    func totals(_ name:String) throws -> [UInt64] {
        guard let values=frame[name] as? [String:Any],values.count==4 else {throw PagedFailure(code:-154)}
        return try ["data_logical","all_logical","data_allocated","all_allocated"].map {try strictUnsigned(values[$0])}
    }
    let objects=try strictUnsigned(frame["objects"])
    guard objects<=counts[0] else {throw PagedFailure(code:-155)}
    return try .init(complete:complete,reason:reason,entries:entries,peakResidentBytes:strictUnsigned(frame["peak_rss"]),
        elapsedNanoseconds:strictUnsigned(frame["elapsed_ns"]),kindCounts:counts,namespaceTotals:totals("entry_totals"),
        objectTotals:totals("object_totals"),objectCount:objects,errors:errors)
}

func runWorkerPump(lane:PagedLane,worker:String,path:String,scope:String,session:UUID,device:UInt64,inode:UInt64,
                   fault:String? = nil,
                   spawned: (@Sendable (Int32) -> Void)? = nil,
                   progress:@escaping @Sendable (UInt64)->Void) throws -> WorkerPumpResult {
    let allowed=FileManager.default.currentDirectoryPath+"/.build/"
    guard worker.hasPrefix(allowed),!worker.contains("/../"),scope.hasPrefix(allowed+"b06-analyzer/20261017T140537Z-6faf182f69/fixtures/") else {throw PagedFailure(code:-156)}
    var source=B06Identity()
    guard b06_identity(3,&source)==0,source.dev==device,source.ino==inode else {throw PagedFailure(code:-157)}
    var pathBytes=[CChar](repeating:0,count:1024)
    guard b06_root_path(3,&pathBytes,pathBytes.count)==0,
          String(bytes:pathBytes.prefix(while:{$0 != 0}).map {UInt8(bitPattern:$0)},encoding:.utf8)==scope else {throw PagedFailure(code:-158)}
    let began=ProcessInfo.processInfo.systemUptime
    var lastPublication=began-1
    func publish(_ count:UInt64) {
        let now=ProcessInfo.processInfo.systemUptime
        if count==0 || now-lastPublication>=0.25 {progress(count);lastPublication=now}
    }
    let decoder=ScannerProtocolDecoder(session:session,root:.init(device:device,inode:inode))
    var model:StorageAnalysisAccumulator?=lane == .memory ? .init(rootIdentity:.init(device:device,inode:inode)):nil
    let db=lane == .swift ? try PagedDatabase(path:path,readOnly:false):nil
    let writer=try db.map(PagedNodeWriter.init)
    let profile:PagedProfile
    if let db {profile=try db.profile()}
    else if lane == .rust {
        let configuration=try PagedDatabase(path:path,readOnly:true)
        profile=try configuration.profile();try configuration.close()
    } else {profile = .baseline}
    defer {writer?.rollback()}
    var pid:Int32=0,output:Int32 = -1,error:Int32 = -1
    let spawnResult=worker.withCString {binary in session.uuidString.withCString {token in
        if lane == .rust {return path.withCString {b06_paged_spawn(binary,$0,token,device,inode,&pid,&output,&error)}}
        return b06_paged_spawn(binary,nil,token,device,inode,&pid,&output,&error)
    }}
    guard spawnResult==0 else {throw PagedFailure(code:-159)}
    spawned?(pid)
    defer {if output>=0 {close(output)};if error>=0 {close(error)}}
    var pending=Data(),stderr=0,sequence:UInt64=0,header=false,progressCount:UInt64=0,notices:UInt64=0
    var terminal:ScannerTerminal?,coverage=AnalysisScanCoverage(),failure:Error?,exitCode:Int32=0,peak:UInt64=0
    var exited=false,outOpen=true,errOpen=true,escalated=false
    var terminationBegan:TimeInterval?
    var workerSQL=[UInt64](repeating:0,count:4)
    while !exited || outOpen || errOpen {
        if b06_cancelled() != 0 && failure==nil {failure=PagedFailure(code:9)}
        if failure != nil || b06_cancelled() != 0 {
            // This owner alone signals and reaps this read-only child. Match
            // the ordinary scanner's grace, then force only the still-owned,
            // unreaped process; demand cancellation is not actual drain.
            if !exited {
                let now=ProcessInfo.processInfo.systemUptime
                if terminationBegan==nil {kill(pid,SIGTERM);terminationBegan=now}
                else if !escalated,let began=terminationBegan,now-began>=2 {
                    kill(pid,SIGKILL);escalated=true
                }
            }
        }
        if !exited {
            let state=b06_paged_wait(pid,&exitCode,&peak)
            if state==1 {exited=true}
            else if state<0 {failure=PagedFailure(code:-160);exited=true}
        }
        var descriptors=[pollfd(fd:outOpen ? output:-1,events:Int16(POLLIN),revents:0),pollfd(fd:errOpen ? error:-1,events:Int16(POLLIN),revents:0)]
        let polled=descriptors.withUnsafeMutableBufferPointer {Darwin.poll($0.baseAddress,nfds_t($0.count),20)}
        if polled<0 {if errno != EINTR {failure=PagedFailure(code:-161)};continue}
        for index in descriptors.indices where descriptors[index].fd>=0 && descriptors[index].revents != 0 {
            var bytes=[UInt8](repeating:0,count:16384)
            let count=Darwin.read(descriptors[index].fd,&bytes,bytes.count)
            if count==0 {if index==0 {outOpen=false}else{errOpen=false};continue}
            if count<0 {
                if errno != EAGAIN && errno != EINTR {
                    failure=PagedFailure(code:-162)
                    if index==0 {outOpen=false}else{errOpen=false}
                }
                continue
            }
            if index==1 {stderr+=count;if stderr>0 {failure=PagedFailure(code:-163)};continue}
            if failure != nil {continue}
            pending.append(contentsOf:bytes.prefix(count))
            if pending.count>131072 {failure=PagedFailure(code:-164);continue}
            while let newline=pending.firstIndex(of:10),failure==nil {
                let line=Data(pending[..<newline]);pending.removeSubrange(...newline)
                do {try autoreleasepool {
                    if lane != .rust {
                        switch try decoder.consume(line) {
                        case .header:
                            if let db {try bindRoot(db,device:device,inode:inode)}
                            header=true;publish(0)
                        case .records(let records):
                            for record in records {
                                if writer != nil {try writer!.accept(record)}
                                else {_ = model!.consume(record)}
                                if fault=="stop_pending",writer?.count==profile.rows+1 {
                                    raise(SIGTERM);throw PagedFailure(code:9)
                                }
                            }
                            publish(decoder.receivedEntries)
                        case .issue(let code,let error):
                            coverage.record(code:code,error:error)
                            _ = model?.recordCoverageGap(AnalysisScanCoverage.gap(code:code,error:error))
                        case .terminal(let value):terminal=value;coverage.finish(reason:value.reason,errors:value.errors)
                        }
                    } else {
                        guard line.count<65536,!line.contains(0),terminal==nil,
                              let frame=try JSONSerialization.jsonObject(with:line) as? [String:Any],
                              let schema=frame["schema"] as? NSNumber,schema.doubleValue==4,
                              frame["store_contract"] as? String=="b06-paged-result-experiment-v2",
                              try strictUnsigned(frame["commit_rows"])==UInt64(profile.rows),
                              frame["aggregate_layout"] as? String==(profile.aggregates ? "direct_v1":"replay_v1"),
                              frame["session"] as? String==session.uuidString,
                              try strictUnsigned(frame["seq"])==sequence,
                              let kind=frame["kind"] as? String else {throw PagedFailure(code:-165)}
                        sequence+=1
                        switch kind {
                        case "header":
                            guard !header,sequence==1 else {throw PagedFailure(code:-166)}
                            var normalized=frame;normalized["schema"]=2
                            guard case .header=try decoder.consume(JSONSerialization.data(withJSONObject:normalized)) else {throw PagedFailure(code:-167)}
                            header=true;publish(0)
                        case "store_progress":
                            guard header else {throw PagedFailure(code:-168)}
                            let count=try strictUnsigned(frame["entries"])
                            guard count==progressCount+UInt64(profile.rows),count<=220000 else {throw PagedFailure(code:-169)}
                            progressCount=count;publish(count)
                            if fault=="crash_committed" {
                                if !exited {kill(pid,SIGKILL)}
                                throw PagedFailure(code:-208)
                            }
                        case "issue":
                            guard header,notices<100,let code=frame["code"] as? String,
                                  (1...64).contains(code.utf8.count),code.utf8.allSatisfy({(97...122).contains($0) || $0==95}),
                                  let number=frame["errno"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),
                                  number.doubleValue==Double(number.int64Value),number.int64Value>=0,number.int64Value<=Int32.max else {throw PagedFailure(code:-170)}
                            notices+=1;coverage.record(code:code,error:number.int32Value)
                        case "summary":
                            guard header else {throw PagedFailure(code:-171)}
                            let value=try parsePagedSummary(frame,notices:notices)
                            workerSQL=try ["worker_sql_statements","worker_sql_commits","worker_sql_profile_ns","worker_sql_commit_ns"].map {try strictUnsigned(frame[$0])}
                            guard value.entries>=progressCount,value.entries-progressCount<UInt64(profile.rows) else {throw PagedFailure(code:-172)}
                            terminal=value;coverage.finish(reason:value.reason,errors:value.errors)
                        default:throw PagedFailure(code:-173)
                        }
                    }
                }} catch {failure=error}
            }
        }
    }
    if let failure {throw failure}
    guard header,pending.isEmpty,stderr==0,let terminal,
          (terminal.complete && exitCode==0) || (!terminal.complete && exitCode==2) else {throw PagedFailure(code:-174)}
    if lane != .rust {try decoder.finish()}
    if let db,let writer {
        try writer.commit()
        guard writer.count==terminal.entries else {throw PagedFailure(code:-175)}
        let update=try PagedStatement(db.raw,"UPDATE scan_state SET terminal=? WHERE id=1")
        try update.blob(1,encodedTerminal(terminal));_ = try update.step();try update.reset()
    }
    let snapshot=model?.finish(terminal.complete ? .completed:.failed(.unavailable))
    return .init(terminal:terminal,snapshot:snapshot,coverage:coverage,peak:peak,seconds:ProcessInfo.processInfo.systemUptime-began,sql:workerSQL)
}
