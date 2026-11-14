import CryptoKit
import Darwin
import ExplorerCore
import Foundation

@main enum TARReaderControls {
    struct Failed: Error { let check:String }
    static func require(_ value:Bool,_ check:String)throws { if !value { throw Failed(check:check) } }
    final class Trace: @unchecked Sendable {
        private let lock=NSLock()
        private var ranges=[(UInt64,Int)](),badThread=false
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        var pause=false
        func probe(_ stage:TARArchiveReader.Stage,_ offset:UInt64,_ size:Int)throws {
            var shouldPause=false
            lock.withLock {
                badThread = badThread || Thread.isMainThread
                if case .metadata=stage { ranges.append((offset,size));if pause { pause=false;shouldPause=true } }
            }
            if shouldPause { entered.signal();guard release.wait(timeout:.now()+5) == .success else { throw Failed(check:"reader release deadline") } }
        }
        var state:([(UInt64,Int)],Bool) { lock.withLock { (ranges,badThread) } }
        func waitForEntry()->DispatchTimeoutResult { entered.wait(timeout:.now()+5) }
    }
    final class Held: @unchecked Sendable {}
    final class WeakHeld: @unchecked Sendable { weak var value:Held?;init(_ value:Held?){self.value=value} }
    actor StartGate {
        var continuation:CheckedContinuation<Void,Never>?
        var waiting=false
        func wait()async { await withCheckedContinuation { continuation=$0;waiting=true } }
        func release(){continuation?.resume();continuation=nil}
    }
    static func main()async {
        do { try await verify() }
        catch {
            let data=try? JSONSerialization.data(withJSONObject:["passed":false,"failure":String(describing:error)],options:[.sortedKeys])
            if let data { FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10])) };Darwin.exit(1)
        }
    }
    static func verify()async throws {
        guard CommandLine.arguments.count==3 else { throw Failed(check:"two exact generated roots") }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (url,action) in [(root,"plain-tar-reader-controls"),(fixture,"plain-tar-fixtures")] {
            try require(url.resolvingSymlinksInPath()==url && url.deletingLastPathComponent()==repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString:url.lastPathComponent)?.uuidString==url.lastPathComponent,"generated root")
            let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:url.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(marker?["action"] as? String==action,"generated reservation")
        }
        guard let inputs=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("inputs.json"))) as? [String:Any],
              let archives=inputs["archives"] as? [String:[String:Any]] else { throw Failed(check:"frozen manifest") }
        let base=fixture.appendingPathComponent("source/archives/ustar.tar"),gate=FileActivityGate()
        let trace=Trace(),reader=TARArchiveReader(activity:gate,probe:trace.probe)
        let session=try await reader.open(base)
        try require(gate.activeCount==0,"actual reader drain before result")
        try require(session.summary.files==4 && session.summary.folders==2 && session.summary.logicalBytes==65_592,"independent summary")
        guard let bodies=archives["ustar"]?["payloadRanges"] as? [[String:Int]] else { throw Failed(check:"body ranges") }
        let (ranges,badThread)=trace.state
        try require(!badThread && !ranges.isEmpty,"all positioned opening and reads off main")
        for (offset,size) in ranges { for body in bodies {
            guard let start=body["offset"],let length=body["bytes"] else { throw Failed(check:"body map") }
            try require(offset+UInt64(size)<=UInt64(start) || offset>=UInt64(start+length),"metadata reader fetched member body")
        } }
        try require(ranges.reduce(0){$0+$1.1}==session.summary.metadataBytes,"format probe charged to metadata budget")
        var checks=["off-main pinned reader reads headers and trailer only, including opaque AppleDouble entries"]
        let first=try await session.page(in:session.root)
        try require(first.items.map(\.name)==["Folder","Note.txt"] && first.breadcrumbs.count==1 && !first.hasNext,"root rows")
        guard let folder=first.items.first,let folderID=folder.folder else { throw Failed(check:"folder identity") }
        let children=try await session.page(in:folderID)
        try require(children.items.count==4 && children.items.first?.name=="Empty" && children.breadcrumbs.count==2,"folder-first nested listing")
        let note=try await session.searchNames("nOtE")
        try require(note.items.map(\.path)==["Note.txt"],"name-only search")
        for field in TARArchiveOrder.Field.allCases { for descending in [false,true] {
            let page=try await session.page(in:session.root,sorting:.init(field,descending:descending))
            try require(Set(page.items.map(\.id))==Set(first.items.map(\.id)) && page.items.first?.folder != nil,"sort preserves identities and folders first")
        } }
        let member=children.items.first{$0.name=="Member.bin"}!
        let selection=try await session.selectionForExtraction([folder.id,member.id])
        try require(selection.count==1 && selection.displayNames==["Folder"] && !selection.description.contains(base.path),"selected ancestor deduplication and private description")
        let location=try await session.location(of:member.id)
        try require(location.folder==folderID && location.offset==children.items.firstIndex{$0.id==member.id},"search location lookup")
        let foreign=try await TARArchiveReader().open(base)
        do { _=try await foreign.page(in:session.root);throw Failed(check:"foreign folder accepted") }
        catch let error as TARArchiveFailure { try require(error == .invalidSelection,"foreign folder refusal") }
        do { _=try await foreign.selectionForExtraction([member.id]);throw Failed(check:"foreign selection accepted") }
        catch let error as TARArchiveFailure { try require(error == .invalidSelection,"foreign item refusal") }
        do { _=try await session.page(in:session.root,offset:-1);throw Failed(check:"negative page accepted") }
        catch let error as TARArchiveFailure { try require(error == .limited,"negative offset refusal") }
        do { _=try await session.searchNames(String(repeating:"x",count:129));throw Failed(check:"oversized query accepted") }
        catch let error as TARArchiveFailure { try require(error == .limited,"bounded query") }
        let distant=try await session.page(in:session.root,offset:Int.max)
        try require(distant.items.isEmpty && distant.offset==2,"overflow-safe end page")
        let taskGate=StartGate()
        let cancelledQuery=Task { await taskGate.wait();return try await session.searchNames("member") }
        while !(await taskGate.waiting) { await Task.yield() };cancelledQuery.cancel();await taskGate.release()
        do { _=try await cancelledQuery.value;throw Failed(check:"cancelled query completed") } catch is CancellationError {}
        await foreign.close();await session.close()
        do { _=try await session.page(in:session.root);throw Failed(check:"closed catalog accepted") }
        catch let error as TARArchiveFailure { try require(error == .closed,"closed catalog refusal") }
        checks.append("native paging, ordering, name filtering, opaque identities, exact selection and close/cancel contracts")

        let many=try await TARArchiveReader().open(fixture.appendingPathComponent("source/archives/metadata-limit.tar"))
        var offset=0,seen=Set<TARItemID>()
        while true {
            let page=try await many.page(in:many.root,offset:offset)
            try require(page.items.count<=256 && page.offset==offset && page.total==19_999,"large bounded page")
            for item in page.items { try require(seen.insert(item.id).inserted,"duplicate paged identity") }
            offset+=page.items.count;if !page.hasNext { break }
        }
        try require(seen.count==19_999,"large catalog completeness");await many.close();checks.append("19,999-member catalog with bounded 256-row pages")

        let blocked=try await TARArchiveReader().open(fixture.appendingPathComponent("source/archives/root-and-links.tar"))
        let blockedPage=try await blocked.page(in:blocked.root)
        try require(blocked.summary.blockedMembers==3,"links and special entries remain typed")
        for item in blockedPage.items where item.kind != .file && item.kind != .directory {
            do { _=try await blocked.selectionForExtraction([item.id]);throw Failed(check:"blocked member selected") }
            catch let error as TARArchiveFailure { try require(error == .unsupported,"blocked member refusal") }
        }
        await blocked.close();checks.append("links and special entries never authorize extraction")

        let paused=Trace();paused.pause=true
        let active=FileActivityGate(),held=Held(),weakHeld=WeakHeld(held)
        let cancellable=TARArchiveReader(activity:active,probe:paused.probe)
        let operation=Task { try await cancellable.open(base,retaining:held) }
        let entered=await Task.detached { paused.waitForEntry() }.value
        try require(entered == .success && active.activeCount==1 && weakHeld.value != nil,"pending native lifetime retained")
        do { _=try await cancellable.open(base);throw Failed(check:"overlapping source admission accepted") }
        catch let error as TARArchiveFailure { try require(error == .busy,"one reader admission") }
        guard let token=active.closeAdmission() else { throw Failed(check:"close activity") }
        operation.cancel();try require(active.activeCount==1 && !active.ownsDrainedAdmission(token),"task cancellation cannot release active native work")
        paused.release.signal()
        do { _=try await operation.value;throw Failed(check:"cancelled read completed") }
        catch let error as TARArchiveFailure { try require(error == .stopped,"pending native Stop") }
        await cancellable.drain();try require(await active.waitUntilDrained(token) && active.activeCount==0,"actual queue and activity drain")
        try require(active.reopen(token),"reopen exact drained gate")
        let reopened=try await cancellable.open(base);await reopened.close()
        checks.append("Stop, busy refusal, retained activity and reusable reader after actual drain")

        let own=root.appendingPathComponent("source/archives/Mutable.tar")
        let changed=TARArchiveReader(probe:{stage,_,_ in if case .parsed=stage {
            guard chmod(own.path,0o640)==0 else { throw Failed(check:"generated mode change") }
        }})
        do { _=try await changed.open(own);throw Failed(check:"changed source accepted") }
        catch let error as TARArchiveFailure { try require(error == .changed,"source metadata revalidation") }
        let link=root.appendingPathComponent("source/Linked.tar")
        do { _=try await TARArchiveReader().open(link);throw Failed(check:"symlink source accepted") }
        catch let error as TARArchiveFailure { try require(error == .unavailable,"no-follow source policy") }
        do { _=try await TARArchiveReader(excludedRoots:[fixture]).open(base);throw Failed(check:"excluded source accepted") }
        catch let error as TARArchiveFailure { try require(error == .unavailable,"excluded source policy") }
        let compressed=root.appendingPathComponent("source/archives/Compressed.tar.gz")
        do { _=try await TARArchiveReader().open(compressed);throw Failed(check:"compressed stream accepted") }
        catch let error as TARArchiveFailure { try require(error == .compressed,"compressed format refusal") }
        var limits=TARReadLimits();limits.seconds=0
        do { _=try await TARArchiveReader(limits:limits,probe:{_,_,_ in}).open(base);throw Failed(check:"deadline accepted") }
        catch let error as TARArchiveFailure { try require(error == .limited,"reader deadline") }
        checks.append("changed, excluded, symlinked, compressed and time-limited sources refuse explicitly")
        let data=try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"memberBodyReadBytes":0,
            "metadataReadBytes":ranges.reduce(0){$0+$1.1},"largeMembers":seen.count,"activityCountAfter":active.activeCount],options:[.sortedKeys])
        FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))
    }
}
