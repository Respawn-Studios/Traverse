import CryptoKit
import Darwin
import ExplorerCore
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

@main enum TARExtractionControls {
    struct Failed: Error { let check:String }
    static func require(_ value:Bool,_ check:String)throws { if !value { throw Failed(check:check) } }
    final class Barrier: @unchecked Sendable {
        private let lock=NSLock();private var first=true
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        func hold()throws {
            let hold=lock.withLock{if !first{return false};first=false;return true}
            if hold { entered.signal();guard release.wait(timeout:.now()+5) == .success else { throw Failed(check:"held producer deadline") } }
        }
        func wait()->Bool { entered.wait(timeout:.now()+5) == .success }
    }
    struct Fixture {
        let root:URL,source:URL,parent:URL,journal:URL
        init(_ base:URL,_ name:String,source:URL)throws {
            root=base.appendingPathComponent("source/"+name);self.source=source
            parent=root.appendingPathComponent("Destination");journal=root.appendingPathComponent("history")
            try require(!FileManager().fileExists(atPath:root.path),"new generated extraction case")
            try FileManager().createDirectory(at:parent,withIntermediateDirectories:true)
        }
        func engine(_ hooks:RecoveryHooks = .init(),activity:FileActivityGate?=nil)->RecoverableFileOperations {
            let lease:(@Sendable()throws->any Sendable)?
            if let activity{lease={try activity.begin()}}else{lease=nil}
            return .init(journalDirectory:journal,hooks:hooks,activity:lease)
        }
        func selected(_ paths:Set<String>?=nil)async throws->TARExtractionSelection {
            let session=try await TARArchiveReader().open(source)
            let value:TARExtractionSelection
            if let paths {
                var pending=[session.root],ids=Set<TARItemID>()
                while let folder=pending.popLast() {
                    let page=try await session.page(in:folder)
                    for item in page.items { if paths.contains(item.path){ids.insert(item.id)};if let child=item.folder{pending.append(child)} }
                }
                try require(ids.count==paths.count,"exact selected paths")
                value=try await session.selectionForExtraction(ids)
            }else{value=try await session.selectionForWholeExtraction()}
            await session.close();return value
        }
        func plan(_ engine:RecoverableFileOperations,_ selected:TARExtractionSelection,hooks:TARProductionHooks = .init())async throws->ArchiveExtractionPlan {
            try await engine.prepareArchiveExtraction(source:source,parent:parent,name:"Extracted",observing:engine.observeSelection([source]),format:.tar){check in
                try PreparedTARDirectory(source,selection:selected,check:check,hooks:hooks)
            }
        }
    }
    static let mark=Data("0081;65000001;Traverse-TAR-Qualification;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
    static func quarantine(_ url:URL)throws->Data? {
        let size=getxattr(url.path,"com.apple.quarantine",nil,0,0,0)
        if size<0 && errno==ENOATTR{return nil}
        guard size>0,size<=4096 else{throw Failed(check:"generated quarantine read")}
        var value=Data(count:size)
        try require(value.withUnsafeMutableBytes{getxattr(url.path,"com.apple.quarantine",$0.baseAddress,size,0,0)}==size,"exact quarantine bytes")
        return value
    }
    static func tree(_ root:URL,expectedMark:Data?=nil)throws->[String:String] {
        // Foundation's macOS enumerator hides AppleDouble names. Test the exact
        // filesystem namespace, including opaque ordinary ._ entries.
        var children=[URL](),pending=[root]
        while let parent=pending.popLast() {
            guard let directory=opendir(parent.path)else{throw Failed(check:"generated output directory")}
            defer{closedir(directory)}
            while true {
                errno=0;guard let item=readdir(directory)else{try require(errno==0,"generated readdir");break}
                let name=withUnsafePointer(to:&item.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}}
                if name=="." || name==".."{continue}
                let url=parent.appendingPathComponent(name);var facts=stat()
                try require(lstat(url.path,&facts)==0 && children.count<32,"small exact generated output")
                children.append(url);if facts.st_mode&S_IFMT==S_IFDIR{pending.append(url)}
            }
        }
        var hashes=[String:String]()
        for url in [root]+children {
            var facts=stat();try require(lstat(url.path,&facts)==0 && facts.st_uid==geteuid(),"output owner")
            let folder=facts.st_mode&S_IFMT==S_IFDIR,regular=facts.st_mode&S_IFMT==S_IFREG
            try require(folder || regular,"no materialized links or special files")
            try require(facts.st_mode&0o7777==(folder ? 0o755:0o644),"fresh safe permissions")
            try require(try quarantine(url)==expectedMark,"exact inherited quarantine")
            if regular {
                try require(facts.st_nlink==1,"unaliased output")
                hashes[String(url.path.dropFirst(root.path.count+1))]=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
            }
        }
        return hashes
    }
    static func admitted()throws->(URL,URL,String) {
        guard CommandLine.arguments.count==4 else{throw Failed(check:"exact generated command")}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),fixtures=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for(url,action)in[(root,"plain-tar-extraction-controls"),(fixtures,"plain-tar-fixtures")] {
            try require(url.resolvingSymlinksInPath()==url && url.deletingLastPathComponent()==repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString:url.lastPathComponent)?.uuidString==url.lastPathComponent,"generated root")
            let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:url.appendingPathComponent("reservation.json")))as?[String:Any]
            try require(marker?["action"]as?String==action,"generated marker")
        }
        try require(["all","crash-synced","crash-committed","cold-crashes","zip-regressions"].contains(mode),"known control mode")
        return(root,fixtures,mode)
    }
    static func main()async {
        do {
            let(root,fixtures,mode)=try admitted()
            if mode.hasPrefix("crash-") {
                let f=try Fixture(root,mode,source:fixtures.appendingPathComponent("source/archives/ustar.tar"))
                var hooks=RecoveryHooks();hooks.archiveProduction.stage={stage,_ in
                    if stage.rawValue==String(mode.dropFirst(6)){Darwin._exit(77)}
                }
                let engine=f.engine(hooks),plan=try await f.plan(engine,f.selected())
                _=await engine.performArchiveExtraction(plan);throw Failed(check:"real crash stage not reached")
            }
            let report:[String:Any]
            if mode=="all"{report=try await verify(root,fixtures:fixtures)}
            else if mode=="zip-regressions"{report=try await zipRegressions(root)}
            else{report=try await inspectCrashes(root)}
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]));FileHandle.standardOutput.write(Data([10]))
        }catch{
            if let data=try? JSONSerialization.data(withJSONObject:["passed":false,"failure":String(describing:error)],options:[.sortedKeys]){FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))};Darwin.exit(1)
        }
    }
    static func verify(_ root:URL,fixtures:URL)async throws->[String:Any] {
        let source=fixtures.appendingPathComponent("source/archives/ustar.tar")
        var checks=[String](),outputs=[[String:Any]]()
        for(name,paths)in[("Whole",nil as Set<String>?), ("Selected",Set(["Folder/Member.bin","Folder/Empty"])),("Short",Set(["Folder/Member.bin"]))] {
            let f=try Fixture(root,name,source:source),engine=f.engine(),selected=try await f.selected(paths)
            var hooks=TARProductionHooks();if name=="Short"{hooks.writeChunk=7}
            let plan=try await f.plan(engine,selected,hooks:hooks)
            try require(!FileManager().fileExists(atPath:f.journal.path) && (try FileManager().contentsOfDirectory(atPath:f.parent.path)).isEmpty,"preparation stays observational")
            let outcome=await engine.performArchiveExtraction(plan)
            guard outcome.result.disposition == .succeeded,let id=outcome.recordID else{throw Failed(check:"actual TAR publication "+name+" "+String(describing:outcome.result.items.first?.status))}
            let before=try tree(plan.destination),history=try await engine.inspectExistingHistory()
            try require(history.records.count==1 && history.records[0].operation=="Extract TAR" && history.records[0].canUndo,"truthful source-bound TAR history")
            let cold=f.engine(),undo=await cold.undo(recordID:id)
            try require(undo.result.disposition == .succeeded && !FileManager().fileExists(atPath:plan.destination.path),"cold exact Undo")
            let retained=try await cold.retentionRecord(recordID:id)
            guard retained.canCleanup,retained.areas.count==1 else{throw Failed(check:"retained exact TAR output")}
            let payload=retained.areas[0].url.appendingPathComponent("payload")
            try require(try tree(payload)==before,"Undo retains exact generated bytes")
            outputs.append(["case":name,"hashes":before,"retainedPayload":String(payload.path.dropFirst(root.path.count+1)),"files":plan.files,"folders":plan.folders,"bytes":plan.logicalBytes])
            checks.append(name+" output, source authority, truthful history, cold Undo and retained bytes")
        }
        let empty=try Fixture(root,"Empty",source:fixtures.appendingPathComponent("source/archives/empty.tar")),emptyEngine=empty.engine()
        let emptyPlan=try await empty.plan(emptyEngine,empty.selected()),emptyResult=await emptyEngine.performArchiveExtraction(emptyPlan)
        try require(emptyResult.result.disposition == .succeeded && (try FileManager().contentsOfDirectory(atPath:emptyPlan.destination.path)).isEmpty,"empty archive fresh folder")
        checks.append("empty archive publishes an actual empty folder")

        let conflict=try Fixture(root,"Conflict",source:source),conflictEngine=conflict.engine()
        let conflictPlan=try await conflict.plan(conflictEngine,conflict.selected())
        try Data("keep-generated-conflict".utf8).write(to:conflictPlan.destination,options:.withoutOverwriting)
        let conflictResult=await conflictEngine.performArchiveExtraction(conflictPlan)
        try require(conflictResult.result.disposition != .succeeded && conflictResult.recordID==nil && (try Data(contentsOf:conflictPlan.destination))==Data("keep-generated-conflict".utf8),"no overwrite after prepared destination races")
        let blocked=try Fixture(root,"Blocked",source:fixtures.appendingPathComponent("source/archives/root-and-links.tar")),blockedEngine=blocked.engine()
        do{_=try await blocked.plan(blockedEngine,blocked.selected());throw Failed(check:"unsafe descendant materialized")}
        catch let error as TARArchiveFailure{try require(error == .unsupported,"blocked descendant refuses before history")}
        try require(!FileManager().fileExists(atPath:blocked.journal.path),"unsupported tree creates no history")
        checks.append("late conflict and unsupported descendants refuse without publication or invented history")

        let failed=try Fixture(root,"EIO",source:source),failedEngine=failed.engine()
        var fault=TARProductionHooks();fault.writeChunk=1;fault.failAfterBytes=5;fault.failureErrno=EIO
        let failedPlan=try await failed.plan(failedEngine,failed.selected(),hooks:fault),failure=await failedEngine.performArchiveExtraction(failedPlan)
        try require(failure.result.disposition != .succeeded && failure.recordID != nil && !FileManager().fileExists(atPath:failedPlan.destination.path),"EIO keeps partial staging without publishing")
        try require(try await failed.engine().inspectExistingHistory().records.count==1,"EIO has durable exact outcome")
        checks.append("real partial writes and EIO preserve a reviewable failed operation")

        let activity=FileActivityGate(),barrier=Barrier(),stop=try Fixture(root,"Stop",source:source),stopping=stop.engine(activity:activity)
        var stoppedHooks=TARProductionHooks();stoppedHooks.beforeWrite={_ in try barrier.hold()}
        let stopPlan=try await stop.plan(stopping,stop.selected(),hooks:stoppedHooks)
        let operation=Task{await stopping.performArchiveExtraction(stopPlan)}
        try require(await Task.detached{barrier.wait()}.value && activity.activeCount==1,"actual held producer")
        operation.cancel();try require(activity.activeCount==1,"Stop retains native lifetime")
        barrier.release.signal();let stopped=await operation.value
        try require(stopped.result.cancellationRequested && stopped.result.disposition != .succeeded && activity.activeCount==0 && stopping.pendingWorkerCount==0
            && !FileManager().fileExists(atPath:stopPlan.destination.path),"Stop drains and never publishes incomplete output")
        checks.append("actual held-write Stop and retained operation/activity lifetime")

        let mutable=root.appendingPathComponent("source/archives/Mutable.tar"),changed=try Fixture(root,"Changed",source:mutable),changedEngine=changed.engine()
        let stale=try await changed.plan(changedEngine,changed.selected());try require(chmod(mutable.path,0o640)==0,"generated source change")
        let refused=await changedEngine.performArchiveExtraction(stale)
        try require(refused.result.disposition != .succeeded && refused.recordID==nil && !FileManager().fileExists(atPath:stale.destination.path),"source change refuses before history")
        try require(mark.withUnsafeBytes{setxattr(mutable.path,"com.apple.quarantine",$0.baseAddress,$0.count,0,XATTR_CREATE)}==0,"generated source quarantine")
        let secure=try Fixture(root,"Quarantine",source:mutable),secureEngine=secure.engine(),securePlan=try await secure.plan(secureEngine,secure.selected())
        let secured=await secureEngine.performArchiveExtraction(securePlan)
        try require(secured.result.disposition == .succeeded && (try quarantine(mutable))==mark,"quarantined source remains unchanged")
        _=try tree(securePlan.destination,expectedMark:mark)
        checks.append("changed source refuses; exact existing quarantine is inherited without approval or removal")

        let changedOutput=try Fixture(root,"OutputSecurityRace",source:mutable),changedOutputEngine=changedOutput.engine()
        var securityHooks=TARProductionHooks();securityHooks.beforeSecurityWrite={_,descriptor in
            let other=Data("0081;65000002;Other-TAR-Qualification;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
            try require(other.withUnsafeBytes{fsetxattr(descriptor,"com.apple.quarantine",$0.baseAddress,$0.count,0,XATTR_CREATE)}==0,"generated output metadata race")
        }
        let securityPlan=try await changedOutput.plan(changedOutputEngine,changedOutput.selected(),hooks:securityHooks),securityResult=await changedOutputEngine.performArchiveExtraction(securityPlan)
        try require(securityResult.result.disposition != .succeeded && !FileManager().fileExists(atPath:securityPlan.destination.path),"conflicting output quarantine never weakened")
        checks.append("security metadata races preserve protected partial output")
        return["passed":true,"checks":checks,"outputs":outputs,"activityAfter":activity.activeCount]
    }
    static func inspectCrashes(_ root:URL)async throws->[String:Any] {
        var checks=[String]()
        for name in ["crash-synced","crash-committed"] {
            let base=root.appendingPathComponent("source/"+name),engine=RecoverableFileOperations(journalDirectory:base.appendingPathComponent("history"))
            let inspection=try await engine.inspectExistingHistory(),output=base.appendingPathComponent("Destination/Extracted")
            try require(inspection.records.count==1 && inspection.records[0].operation=="Extract TAR","cold crash record")
            if name=="crash-synced" {
                try require(!inspection.records[0].canUndo && !FileManager().fileExists(atPath:output.path),"unpublished crash cannot become successful output")
            }else{
                try require(inspection.records[0].canUndo && FileManager().fileExists(atPath:output.path),"durably committed crash output remains exact")
                try require(await engine.undo(recordID:inspection.records[0].id).result.disposition == .succeeded && !FileManager().fileExists(atPath:output.path),"cold committed-crash Undo")
            }
            checks.append(name+" cold durable state and guarded outcome")
        }
        return["passed":true,"checks":checks]
    }
    static func zipRegressions(_ root:URL)async throws->[String:Any] {
        let source=root.appendingPathComponent("source/archives/Generated.zip")
        var checks=[String]()
        for selected in [false,true] {
            let name=selected ? "ZIPSelected":"ZIPWhole",f=try Fixture(root,name,source:source),engine=f.engine()
            let session=try await ZIPArchiveReader().open(source)
            let members:ZIPExtractionSelection?
            if selected {
                let page=try await session.page(in:session.root)
                guard let folder=page.items.first(where:{$0.name=="Folder"})else{throw Failed(check:"generated ZIP folder")}
                members=try await session.selectionForExtraction([folder.id])
            }else{members=nil}
            let plan=try await engine.prepareZIPExtraction(source:source,parent:f.parent,name:"Extracted",observing:engine.observeSelection([source]),members:members)
            let result=await engine.performArchiveExtraction(plan),history=try await engine.inspectExistingHistory()
            guard result.result.disposition == .succeeded,let id=result.recordID else{throw Failed(check:"existing ZIP extraction")}
            try require(history.records.count==1 && history.records[0].operation=="Extract ZIP","unchanged default ZIP history title")
            let bodies=try tree(plan.destination)
            try require(Set(bodies.keys)==(selected ? Set(["Folder/Member.txt"]):Set(["Folder/Member.txt","Other.txt"])) && FileManager().fileExists(atPath:plan.destination.appendingPathComponent("Folder/Empty").path),"existing ZIP whole/selected shape")
            try require(await f.engine().undo(recordID:id).result.disposition == .succeeded,"existing ZIP cold Undo")
            await session.close();checks.append(name+" whole/selected output, default title and cold Undo")
        }
        return["passed":true,"checks":checks]
    }
}
