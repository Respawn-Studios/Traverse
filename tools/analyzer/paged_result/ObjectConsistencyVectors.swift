import Foundation

/// Pure stream controls for known-object accounting; no SQLite or filesystem.
func objectConsistencyVectors() throws -> Data {
    let identity=packedUnsigned(11)+packedUnsigned(100)
    let zeroFlags=Data([0,0,0,0]),changedFlags=Data([0,0,0,1])
    let payload=observationPayload(.init(dataLogical:.returned(7),allForkLogical:.returned(7),
        dataAllocated:.returned(8),allForkAllocated:.returned(8)))
    func pair(flags:Data?,second:Data?,links:UInt64) throws -> PagedObjectReport {
        var aggregate=PagedObjectAccumulator()
        try aggregate.consume(identity:identity,parent:0,payload:payload,links:packedUnsigned(links),flags:flags)
        try aggregate.consume(identity:identity,parent:1,payload:payload,links:packedUnsigned(links),flags:second)
        return aggregate.report
    }
    let normal=try pair(flags:zeroFlags,second:zeroFlags,links:2)
    guard !normal.uncertain,normal.count==1,normal.crossFolder==1,normal.bytes.dataLogical.knownBytes==7 else {throw PagedFailure(code:-270)}
    guard try pair(flags:zeroFlags,second:changedFlags,links:2).uncertain,
          try pair(flags:nil,second:nil,links:2).uncertain,
          try pair(flags:zeroFlags,second:zeroFlags,links:0).uncertain,
          try pair(flags:zeroFlags,second:zeroFlags,links:1).uncertain else {throw PagedFailure(code:-270)}
    var unknown=PagedObjectAccumulator()
    try unknown.consume(identity:nil,parent:0,payload:payload,links:packedUnsigned(1),flags:zeroFlags)
    guard unknown.report.uncertain,unknown.report.count==0 else {throw PagedFailure(code:-270)}
    var malformed=0
    for (id,links,flags) in [(Data([1]),packedUnsigned(1),zeroFlags),(identity,Data([1]),zeroFlags),(identity,packedUnsigned(1),Data([1]))] {
        do {
            var aggregate=PagedObjectAccumulator()
            try aggregate.consume(identity:id,parent:0,payload:payload,links:links,flags:flags)
        } catch {malformed+=1}
    }
    guard malformed==3 else {throw PagedFailure(code:-270)}
    let zeros=Dictionary(uniqueKeysWithValues:["data_logical","all_logical","data_allocated","all_allocated"].map {($0,"0")})
    let impossible:[String:Any]=["complete":true,"reason":"complete","entries":"1","errors":"0","regular_entries":"0",
        "directory_entries":"1","symlink_entries":"0","other_entries":"0","objects":"1","peak_rss":"1","elapsed_ns":"1",
        "entry_totals":zeros,"object_totals":zeros]
    do {_ = try parsePagedSummary(impossible,notices:0);throw PagedFailure(code:-273)}
    catch let error as PagedFailure {guard error.code == -155 else {throw error}}
    return try JSONSerialization.data(withJSONObject:["passed":true,"scope":"Pure known-object stream; no file/database mutation",
        "flags_changed_or_missing_refused_complete":true,"zero_or_insufficient_links_refused_complete":true,
        "cross_folder_once":true,"distinct_bytes":7,"malformed_refusals":malformed,
        "terminal_regular_object_bound":true],options:[.sortedKeys])
}
