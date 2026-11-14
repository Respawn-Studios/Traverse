import Foundation

// Only the active DFS ancestry, plus thirteen global type counters. Values are
// cumulative for each active folder, so persisting a checkpoint replaces its
// previous subtotal instead of merging the same observations twice.
final class BoundedDirectAggregates {
    private struct Frame {
        let id:Int64
        var total=PagedValue(),files=PagedValue()
        var dirty=false
    }
    private var frames=[Frame(id:0)]
    private var types=Array(repeating:PagedValue(),count:13)
    private var dirtyTypes=Set<Int>()
    private let direct:PagedStatement,files:PagedStatement,type:PagedStatement,marker:PagedStatement
    init(_ db:PagedDatabase) throws {
        direct=try PagedStatement(db.raw,"INSERT INTO direct_totals VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=excluded.value")
        files=try PagedStatement(db.raw,"INSERT INTO direct_files VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=excluded.value")
        type=try PagedStatement(db.raw,"INSERT INTO type_totals VALUES(?,?) ON CONFLICT(type) DO UPDATE SET value=excluded.value")
        marker=try PagedStatement(db.raw,"INSERT INTO markers VALUES(?,?) ON CONFLICT(node) DO UPDATE SET marker=min(markers.marker,excluded.marker)")
    }
    func leave(until parent:Int64) throws {
        while frames.count>1 && frames.last!.id != parent {
            try persist(frames.count-1);frames.removeLast()
        }
        guard frames.last!.id==parent else {throw PagedFailure(code:-202)}
    }
    func accept(id:Int64,parent:Int64,name:Data,kind:Int,payload:Data,descend:Bool) throws {
        guard frames.last!.id==parent else {throw PagedFailure(code:-203)}
        let value=try PagedValue(kind:kind,payload:payload),index=frames.count-1
        try frames[index].total.merge(value);frames[index].dirty=true
        if kind==0 {
            try frames[index].files.merge(value)
            let key=AnalysisFileType.match(name).rawValue
            try types[key].merge(value);dirtyTypes.insert(key)
        }
        let observationKind:AnalysisEntryKind=kind==0 ? .regularFile:kind==1 ? .directory:.other
        if let found=AnalysisProjectMarker.match(name,kind:observationKind) {
            try marker.integer(1,parent);try marker.integer(2,Int64(found.rawValue));_ = try marker.step();try marker.reset()
        }
        if descend {
            guard frames.count<65 else {throw PagedFailure(code:-204)}
            frames.append(Frame(id:id))
        }
    }
    private func put(_ statement:PagedStatement,_ key:Int64,_ value:PagedValue) throws {
        try statement.integer(1,key);try statement.blob(2,value.encoded);_ = try statement.step();try statement.reset()
    }
    private func persist(_ index:Int) throws {
        guard frames[index].dirty else {return}
        try put(direct,frames[index].id,frames[index].total)
        if frames[index].files.counts[0]>0 {try put(files,frames[index].id,frames[index].files)}
        frames[index].dirty=false
    }
    func flush() throws {
        for index in frames.indices {try persist(index)}
        for key in dirtyTypes.sorted() {try put(type,Int64(key),types[key])}
        dirtyTypes.removeAll(keepingCapacity:true)
    }
}
