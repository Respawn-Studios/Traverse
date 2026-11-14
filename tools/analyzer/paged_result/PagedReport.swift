import Foundation
import SQLite3

func makePagedReport(_ db:PagedDatabase,scope:String,complete:Bool) throws -> AnalysisAttributionReport {
    func slices(_ kind:Int) throws -> [AnalysisAttributionSlice] {
        let query=try PagedStatement(db.raw,"SELECT key,value FROM groups WHERE kind=? ORDER BY key")
        try query.integer(1,Int64(kind));var result:[AnalysisAttributionSlice]=[]
        while try query.step() {
            guard let data=try query.data(1) else {throw PagedFailure(code:-130)}
            let key=Int(query.number(0)),value=try PagedValue(data:data)
            let title:String,explanation:String
            if kind==0,let type=AnalysisFileType(rawValue:key) {title=type.title;explanation=type.explanation}
            else if kind==1,let role=AnalysisCategory(rawValue:key) {title=role.title;explanation=role.explanation}
            else {throw PagedFailure(code:-131)}
            result.append(.init(title:title,explanation:explanation,bytes:value.bytes,files:value.counts[0],folder:nil))
        }
        return result
    }
    let projectCount=try db.scalar("SELECT count(*) FROM groups WHERE kind=2 AND key>0")
    let query=try PagedStatement(db.raw,"SELECT key,value FROM groups WHERE kind=2 AND key>0 ORDER BY substr(value,65,1),substr(value,41,8) DESC,key")
    var projects:[AnalysisAttributionSlice]=[],remainder=PagedValue()
    while try query.step() {
        guard let data=try query.data(1) else {throw PagedFailure(code:-132)}
        let key=query.number(0),value=try PagedValue(data:data)
        if projects.count<12 {
            let title=try pagedPath(db,id:key-1,root:(scope as NSString).lastPathComponent)
            projects.append(.init(title:title,explanation:"Observed project marker; nested projects excluded. Metadata-only namespace subtotal.",bytes:value.bytes,files:value.counts[0],folder:nil))
        } else {try remainder.merge(value)}
    }
    if projectCount>12 {projects.append(.init(title:"Other project scopes",explanation:"Remaining observed project scopes.",bytes:remainder.bytes,files:remainder.counts[0],folder:nil))}
    let shared=try PagedStatement(db.raw,"SELECT value FROM groups WHERE kind=2 AND key=0")
    guard try shared.step(),let data=try shared.data(0) else {throw PagedFailure(code:-133)}
    let unassigned=try PagedValue(data:data)
    projects.append(.init(title:"Unassigned / shared",explanation:"No project marker, or an observed shared cache layout.",bytes:unassigned.bytes,files:unassigned.counts[0],folder:nil))
    let objects=try pagedObjects(db)
    return try .init(categories:slices(1),fileTypes:slices(0),projects:projects,projectCount:Int(projectCount),isComplete:complete && !objects.uncertain,crossFolderHardlinkObjects:objects.crossFolder)
}

struct PagedObjectReport:Sendable {
    var count:UInt64=0,crossFolder:UInt64=0
    var bytes=AnalysisByteSubtotals()
    var uncertain=false
}
struct PagedObjectAccumulator {
    private(set) var report=PagedObjectReport()
    private var last:Data?,payload:Data?,links:Data?,flags:Data?,parent:Int64=0,cross=false,edges:UInt64=0
    private var entries=0
    mutating func consume(identity:Data?,parent currentParent:Int64,payload value:Data,links currentLinks:Data?,flags currentFlags:Data?) throws {
        guard entries<220000,currentParent>=0,
              currentLinks.map({$0.count==8}) ?? true,
              currentFlags.map({$0.count==4}) ?? true else {throw PagedFailure(code:-271)}
        entries+=1
        let observed=try PagedValue(kind:0,payload:value)
        if observed.bytes.hasUnavailableValues {report.uncertain=true}
        guard let identity else {report.uncertain=true;return}
        guard identity.count==16 else {throw PagedFailure(code:-138)}
        if let last,identity.lexicographicallyPrecedes(last) {throw PagedFailure(code:-272)}
        if identity != last {
            report.count+=1;report.bytes.merge(observed.bytes)
            if report.bytes.hasUnavailableValues {report.uncertain=true}
            last=identity;payload=value;links=currentLinks;flags=currentFlags;parent=currentParent;cross=false;edges=1
        } else {
            edges+=1
            if payload != value || links != currentLinks || flags != currentFlags {report.uncertain=true}
            if !cross && parent != currentParent {report.crossFolder+=1;cross=true}
        }
        if currentFlags==nil || currentLinks==nil || currentLinks.map({getUnsigned($0,at:0)<edges})==true {report.uncertain=true}
    }
}
func pagedObjects(_ db:PagedDatabase) throws -> PagedObjectReport {
    let query=try PagedStatement(db.raw,"SELECT identity,parent,payload,links,flags FROM observations_v2 WHERE kind=0 ORDER BY identity,id")
    var aggregate=PagedObjectAccumulator()
    while try query.step() {
        if b06_cancelled() != 0 {throw PagedFailure(code:9)}
        guard let value=try query.data(2) else {throw PagedFailure(code:-138)}
        try aggregate.consume(identity:query.data(0),parent:query.number(1),payload:value,links:query.data(3),flags:query.data(4))
    }
    return aggregate.report
}

func pagedPath(_ db:PagedDatabase,id:Int64,root:String) throws -> String {
    var node=id,parts:[Data]=[],total=0
    let query=try PagedStatement(db.raw,"SELECT parent,name FROM observations_v2 WHERE id=?")
    while node>0 {
        guard parts.count<64 else {throw PagedFailure(code:-134)}
        try query.integer(1,node)
        guard try query.step(),let name=try query.data(1) else {throw PagedFailure(code:-135)}
        let parent=query.number(0);guard parent<node else {throw PagedFailure(code:-136)}
        total+=name.count+1;guard total<=8193 else {throw PagedFailure(code:-137)}
        node=parent;parts.append(name);try query.reset()
    }
    return parts.isEmpty ? root : String(bytes:parts.reversed().joined(separator:Data([47])),encoding:.utf8) ?? "Folder with a non-UTF-8 name"
}
