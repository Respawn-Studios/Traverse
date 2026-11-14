import CryptoKit
import Darwin
import ExplorerCore
import Foundation

@main private enum TARPreviewControls {
    struct Failed:Error{let name:String}
    final class Trace:@unchecked Sendable {
        let lock=NSLock(),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        var rows=[(String,UInt64,Int)](),onStage:String?,action:(@Sendable()throws->Void)?,holding=false
        func set(_ stage:String,hold:Bool=false,action:(@Sendable()throws->Void)?=nil){lock.withLock{onStage=stage;holding=hold;self.action=action}}
        func probe(_ stage:TARArchiveReader.Stage,_ offset:UInt64,_ count:Int)throws {
            let name=String(describing:stage)
            let work:(Bool,(@Sendable()throws->Void)?)=lock.withLock{
                rows.append((name,offset,count))
                guard onStage==name else{return(false,nil)}
                onStage=nil;let result=(holding,action);action=nil;return result
            }
            if work.0{entered.signal();guard release.wait(timeout:.now()+10) == .success else{throw Failed(name:"hold-timeout")}}
            try work.1?()
        }
        var snapshot:[(String,UInt64,Int)]{lock.withLock{rows}}
        func clear(){lock.withLock{rows=[]}}
        func awaitEntry()->Bool{entered.wait(timeout:.now()+10) == .success}
    }
    final class Lifetime:@unchecked Sendable{}
    final class WeakLife:@unchecked Sendable{weak var value:Lifetime?;init(_ value:Lifetime){self.value=value}}
    static func require(_ value:Bool,_ name:String)throws{if !value{throw Failed(name:name)}}
    static func expect(_ name:String,_ errorName:String,_ body:()async throws->Void)async throws{
        do{try await body();throw Failed(name:name+"-accepted")}
        catch let error as Failed{throw error}
        catch{try require(String(describing:error)==errorName,name+"-wrong-error-"+String(describing:error))}
    }
    static func selection(_ session:TARArchiveSession,_ path:String)async throws->TARTextPreviewSelection{
        let page=try await session.searchNames(path)
        guard let item=page.items.first(where:{$0.path==path})else{throw Failed(name:"missing-selection")}
        return try await session.selectionForTextPreview(item.id)
    }
    static func hash(_ bytes:Data)->String{SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func overwrite(_ url:URL,_ data:Data)throws{
        let fd=Darwin.open(url.path,O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw Failed(name:"generated-write-open")};defer{close(fd)}
        try data.withUnsafeBytes{buffer in
            var offset=0
            while offset<buffer.count{let n=write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset);guard n>0 else{throw Failed(name:"generated-write")};offset+=n}
        }
        guard fsync(fd)==0 else{throw Failed(name:"generated-sync")}
    }
    static func main()async {
        do{try await verify()}
        catch{print("{\"passed\":false,\"failure\":\"\((error as? Failed)?.name ?? String(describing:type(of:error)))\"}");Darwin.exit(1)}
    }
    static func verify()async throws {
        guard CommandLine.arguments.count==4 else{throw Failed(name:"case-arguments")}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=URL(fileURLWithPath:CommandLine.arguments[2]),mutable=URL(fileURLWithPath:CommandLine.arguments[3])
        let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json"))) as? [String:Any]
        try require(marker?["action"] as? String == "tar-explicit-preview" && mutable.deletingLastPathComponent()==root.appendingPathComponent("source"),"generated-identity")
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("fixture.json"))) as! [String:Any]
        let oracle=manifest["files"] as! [String:[[String:Any]]]
        let source=fixture.appendingPathComponent("source/Main.tar"),trace=Trace(),gate=FileActivityGate()
        let reader=TARArchiveReader(activity:gate,probe:trace.probe),session=try await reader.open(source)
        let context=Context(root:root,fixture:fixture,mutable:mutable,manifest:manifest,oracle:oracle,source:source,trace:trace,gate:gate,reader:reader,session:session)
        try await basic(context);try await values(context);try await selections(context)
        try await mutations(context);try await limits(context);try await ownership(context)
        await session.close();await reader.drain()
        try require(gate.activeCount==0,"all-activity-drained")
        context.checks.append("all-readers-sessions-and-worker-activity-drained")
        let output:[String:Any]=["passed":true,"checks":context.checks,"activityAfter":gate.activeCount,"sourceBoundProduction":true,"appLaunches":0,"networkRequests":0]
        print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:.sortedKeys),as:UTF8.self))
    }
    final class Context {
        let root:URL,fixture:URL,mutable:URL,source:URL
        let manifest:[String:Any],oracle:[String:[[String:Any]]],trace:Trace,gate:FileActivityGate,reader:TARArchiveReader,session:TARArchiveSession
        var checks=[String]()
        init(root:URL,fixture:URL,mutable:URL,manifest:[String:Any],oracle:[String:[[String:Any]]],source:URL,trace:Trace,gate:FileActivityGate,reader:TARArchiveReader,session:TARArchiveSession){self.root=root;self.fixture=fixture;self.mutable=mutable;self.manifest=manifest;self.oracle=oracle;self.source=source;self.trace=trace;self.gate=gate;self.reader=reader;self.session=session}
    }
    static func basic(_ c:Context)async throws {
        let oracle=c.oracle
        let trace=c.trace
        let reader=c.reader
        let session=c.session
        var checks=[String]()
        let browse=trace.snapshot
        let ranges=oracle["Main.tar"]!.filter{$0["file"] as? Bool == true && ($0["bytes"] as! Int)>0}
        for row in browse where row.0=="metadata"{for body in ranges{
            let a=UInt64(body["offset"] as! Int),b=a+UInt64(body["bytes"] as! Int)
            try require(row.1+UInt64(row.2)<=a || row.1>=b,"browse-read-body")
        }}
        checks.append("ordinary-browse-zero-payload-ranges")
        let selected=try await selection(session,"Text.txt")
        let beforeSelection=trace.snapshot.count
        _=try await selection(session,"Empty")
        try require(trace.snapshot.count==beforeSelection,"selection-read-body")
        trace.clear();let text=try await reader.previewText(selected)
        try require(text.text=="Hello café\n\t<html>plain</html>\r\n" && text.utf8Bytes==UInt64(text.text.utf8.count),"complete-utf8")
        let body=oracle["Main.tar"]!.first{$0["path"] as? String == "Text.txt"}!
        let payload=trace.snapshot.filter{$0.0=="previewPayload"}
        try require(payload.count==1 && payload[0].1==UInt64(body["offset"] as! Int) && payload[0].2==body["bytes"] as! Int,"exact-selected-extent")
        try require(trace.snapshot.filter{$0.0=="metadata"}.reduce(0){$0+$1.2}==session.summary.metadataBytes*2,"two-complete-metadata-budgets")
        try require(!String(describing:selected).contains("Text.txt") && !String(reflecting:text).contains("Hello"),"redacted-value-diagnostics")
        checks.append("complete-utf8-full-before-after-metadata-exact-extent-and-redacted-values")
        c.checks+=checks
    }
    static func values(_ c:Context)async throws {
        let manifest=c.manifest
        let reader=c.reader
        let session=c.session
        var checks=[String]()
        let empty=try await selection(session,"Empty")
        let emptyText=try await reader.previewText(empty),emptyHex=try await reader.previewBytes(empty)
        try require(emptyText.text=="" && emptyHex.hexadecimalText=="","empty-complete-modes")
        let maximum=try await selection(session,"Maximum")
        let maxText=try await reader.previewText(maximum)
        try require(maxText.utf8Bytes==256<<10 && maxText.text==String(repeating:"x",count:256<<10),"exact-256KiB")
        let maxHex=try await reader.previewBytes(maximum)
        let hexDigests=manifest["hexSHA256"] as! [String:String]
        try require(maxHex.byteCount==256<<10 && maxHex.hexadecimalText.utf8.count==1_277_952 && hash(Data(maxHex.hexadecimalText.utf8))==hexDigests["Maximum"],"maximum-hex-python-oracle")
        let bytes=try await reader.previewBytes(selection(session,"Bytes"))
        try require(hash(Data(bytes.hexadecimalText.utf8))==hexDigests["Bytes"],"all-byte-hex-python-oracle")
        checks.append("empty-exact-maximum-text-and-full-hex-independent-python-oracles")
        try await expect("too-large","tooLarge"){_ = try await selection(session,"TooLarge")}
        for i in 0..<8{try await expect("not-text-\(i)","notText"){_ = try await reader.previewText(selection(session,"Invalid\(i)"))}}
        checks.append("oversized-before-body-and-strict-utf8-control-bidi-refusals")
        c.checks+=checks
    }
    static func selections(_ c:Context)async throws {
        let fixture=c.fixture
        let source=c.source
        let reader=c.reader
        let session=c.session
        var checks=[String]()
        for name in ["Folder","Sym","Hard","FIFO"]{try await expect("kind-"+name,"unsupported"){_ = try await selection(session,name)}}
        let foreign=try await reader.open(source),item=try await session.searchNames("Text.txt").items.first!
        try await expect("foreign","invalidSelection"){_ = try await foreign.selectionForTextPreview(item.id)}
        await foreign.close();try await expect("closed","closed"){_ = try await foreign.selectionForTextPreview(item.id)}
        let fake=try TARCatalogBuilder.build(TARSourceCatalog.parse(PinnedLocalFileSource(source),limits:.init(),check:{}),check:{})
        let unbound=TARArchiveSession(fake),unboundItem=try await unbound.searchNames("Text.txt").items.first!
        try await expect("unbound","unsupported"){_ = try await unbound.selectionForTextPreview(unboundItem.id)}
        await unbound.close();checks.append("opaque-foreign-closed-unbound-and-member-kind-refusal")
        for (file,expected) in [("PAX.tar","pax"),("GNU.tar","gnu")] {
            let s=try await reader.open(fixture.appendingPathComponent("source/"+file))
            let p=try await s.searchNames(expected=="pax" ? "ppp":"ggg")
            let choice=try await s.selectionForTextPreview(p.items.first{$0.kind == .file}!.id)
            try require(try await reader.previewText(choice).text==expected,"effective-"+file)
            let r=choice.record
            let forged=TARTextPreviewSelection(binding:choice.binding,record:.init(ordinal:r.ordinal,path:r.path,kind:r.kind,headerOffset:r.headerOffset,dataOffset:r.dataOffset,bytes:r.bytes+1))
            try await expect("record-"+file,"changed"){_ = try await reader.previewText(forged)}
            await s.close()
        }
        checks.append("pax-size-path-gnu-longname-effective-record-fences")
        c.checks+=checks
    }
    static func mutations(_ c:Context)async throws {
        let mutable=c.mutable
        let trace=c.trace
        let reader=c.reader
        var checks=[String]()
        let original=try Data(contentsOf:mutable)
        for stage in ["opened","previewing","previewPayload","previewTransform","previewComplete"] {
            let s=try await reader.open(mutable),choice=try await selection(s,"Text.txt")
            trace.set(stage){var data=original;data[512]=UInt8(ascii:"z");try overwrite(mutable,data)}
            try await expect("mutate-"+stage,"changed"){_ = try await reader.previewText(choice)}
            try overwrite(mutable,original);await s.close()
        }
        checks.append("before-during-after-payload-transform-and-final-fence-source-mutation")
        for mode in ["rename","replacement"] {
            let s=try await reader.open(mutable),choice=try await selection(s,"Text.txt")
            let moved=mutable.appendingPathExtension("held")
            trace.set("previewing"){
                guard rename(mutable.path,moved.path)==0 else{throw Failed(name:"generated-rename")}
                if mode=="replacement"{guard FileManager.default.createFile(atPath:mutable.path,contents:original) else{throw Failed(name:"replacement-create")}}
            }
            try await expect(mode,"changed"){_ = try await reader.previewText(choice)}
            if mode=="replacement"{try FileManager.default.removeItem(at:mutable)}
            guard rename(moved.path,mutable.path)==0 else{throw Failed(name:"generated-restore")};await s.close()
        }
        checks.append("original-path-rename-and-replacement-refusal")
        let s=try await reader.open(mutable),choice=try await selection(s,"Text.txt")
        var altered=original;altered[0]=UInt8(ascii:"Y");for i in 148..<156{altered[i]=32}
        let checksum=altered.prefix(512).reduce(0){$0+Int($1)}
        altered.replaceSubrange(148..<156,with:Array(String(format:"%06o",checksum).utf8)+[0,32])
        try overwrite(mutable,altered)
        do {
        let fresh=try PinnedLocalFileSource(mutable)
        let nativeMiss=TARTextPreviewSelection(binding:.init(source:mutable,stamp:fresh.observed,witness:choice.binding.witness),record:choice.record)
        try await expect("full-witness-beyond-valid-header-checksum","changed"){_ = try await reader.previewText(nativeMiss)}
        }
        try overwrite(mutable,original);await s.close()
        checks.append("full-metadata-witness-independent-of-valid-header-checksum-and-native-stamp")
        c.checks+=checks
    }
    static func limits(_ c:Context)async throws {
        let fixture=c.fixture
        let trace=c.trace
        var checks=[String]()
        let selected=try await selection(c.session,"Text.txt")
        let tiny=TARArchiveReader(limits:.init(),previewLimits:.init(seconds:0),probe:trace.probe)
        try await expect("deadline","limitReached"){_ = try await tiny.previewText(selected)}
        var limits=TARReadLimits();limits.metadataBytes=6
        let quota=TARArchiveReader(limits:limits,probe:trace.probe)
        try await expect("metadata-quota","limited"){_ = try await quota.previewText(selected)}
        let excluded=TARArchiveReader(excludedRoots:[fixture],probe:trace.probe)
        try await expect("excluded","unavailable"){_ = try await excluded.previewText(selected)}
        checks.append("fixed-deadline-metadata-quota-and-original-source-exclusion")
        c.checks+=checks
        await tiny.drain();await quota.drain();await excluded.drain()
    }
    static func ownership(_ c:Context)async throws {
        let source=c.source
        var checks=[String]()
        let selected=try await selection(c.session,"Text.txt")
        for stage in ["metadata","previewPayload","previewTransform","previewFinalMetadata"] {
            let held=Trace();held.set(stage,hold:true)
            let activity=FileActivityGate(),r=TARArchiveReader(activity:activity,probe:held.probe)
            var access:Lifetime?=Lifetime();let weak=WeakLife(access!)
            var task:Task<TARTextPreview,Error>?=Task{[access=access!]in try await r.previewText(selected,retaining:access)};access=nil
            try require(await Task.detached{held.awaitEntry()}.value,"held-entry-"+stage)
            try require(activity.activeCount==1 && weak.value != nil,"held-actual-ownership")
            try await expect("busy-preview","busy"){_ = try await r.previewBytes(selected)}
            try await expect("busy-open","busy"){_ = try await r.open(source)}
            task!.cancel();try require(activity.activeCount==1,"stop-not-drain")
            held.release.signal()
            do{_ = try await task!.value;throw Failed(name:"cancel-published")}catch let e as TARArchiveFailure{try require(e == .stopped,"cancel-kind")}
            task=nil;await r.drain();try require(activity.activeCount==0 && weak.value==nil,"actual-held-drain")
        }
        checks.append("held-metadata-payload-transform-final-pass-stop-busy-retained-access-actual-drain")
        c.checks+=checks
    }
}
