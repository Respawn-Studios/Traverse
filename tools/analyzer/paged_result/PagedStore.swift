// Isolated generated-store/result-interface qualification. Not app routing.
import Darwin
import Foundation
import SQLite3

struct PagedFailure: Error { let code: Int32 }
func sqlCheck(_ value: Int32) throws { if value != SQLITE_OK { throw PagedFailure(code: value) } }

final class PagedStatement {
    let raw: OpaquePointer
    init(_ db: OpaquePointer, _ sql: String) throws {
        var value: OpaquePointer?
        try sqlCheck(sqlite3_prepare_v2(db, sql, -1, &value, nil))
        guard let value else { throw PagedFailure(code: -1) }; raw = value
    }
    deinit { sqlite3_finalize(raw) }
    func integer(_ index: Int32, _ value: Int64) throws { try sqlCheck(sqlite3_bind_int64(raw,index,value)) }
    func blob(_ index: Int32, _ value: Data?) throws {
        guard let value else { try sqlCheck(sqlite3_bind_null(raw,index)); return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if value.isEmpty { try sqlCheck(sqlite3_bind_zeroblob(raw,index,0)) }
        else { try value.withUnsafeBytes { try sqlCheck(sqlite3_bind_blob(raw,index,$0.baseAddress,Int32($0.count),transient)) } }
    }
    func step() throws -> Bool {
        let code = sqlite3_step(raw)
        if code == SQLITE_DONE { return false }
        guard code == SQLITE_ROW else { throw PagedFailure(code: code) }; return true
    }
    func reset() throws { try sqlCheck(sqlite3_reset(raw)); try sqlCheck(sqlite3_clear_bindings(raw)) }
    func data(_ column: Int32) throws -> Data? {
        if sqlite3_column_type(raw,column) == SQLITE_NULL { return nil }
        let length = Int(sqlite3_column_bytes(raw,column))
        guard length <= 8192 else { throw PagedFailure(code: -2) }
        if length == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(raw,column) else { throw PagedFailure(code: -3) }
        return Data(bytes:pointer,count:length)
    }
    func number(_ column: Int32) -> Int64 { sqlite3_column_int64(raw,column) }
}

final class PagedDatabase {
    let raw: OpaquePointer
    let path: String
    private var closed = false
    init(path: String, readOnly: Bool) throws {
        self.path = path
        try Self.authorize(path)
        var value: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_PRIVATECACHE
        let code = sqlite3_open_v2(path,&value,flags,nil)
        guard code == SQLITE_OK, let value else {
            if let value { sqlite3_close(value) }; throw PagedFailure(code: code)
        }
        raw = value
        do {
            try Self.authorize(path)
            try sqlCheck(sqlite3_busy_timeout(raw,50))
            try sqlCheck(b06_sql_profile(UnsafeMutableRawPointer(raw)))
            try exec("PRAGMA foreign_keys=ON; PRAGMA cache_size=-1024; PRAGMA temp_store=MEMORY")
            if !readOnly {try exec("PRAGMA synchronous=FULL;PRAGMA max_page_count=6144")}
            try installPagedMerge(raw)
            guard readOnly || sqlite3_db_readonly(raw,"main") == 0 else { throw PagedFailure(code: SQLITE_READONLY) }
        } catch { sqlite3_close(raw); closed = true; throw error }
    }
    deinit { if !closed { sqlite3_close_v2(raw) } }
    static func authorize(_ path: String) throws {
        let prefix = FileManager.default.currentDirectoryPath + "/.build/b06-analyzer/paged-result-stores-20261018/"
        guard path.hasPrefix(prefix), !path.contains("/../"), !path.contains("/./"), path.hasSuffix("/result.sqlite"),
              b06_store_check(path,4,5,6) == 0 else { throw PagedFailure(code: -10) }
    }
    func fresh() throws { guard !closed else { throw PagedFailure(code: -11) }; try Self.authorize(path) }
    func exec(_ sql: String) throws { try sqlCheck(sqlite3_exec(raw,sql,nil,nil,nil)) }
    func scalar(_ sql: String) throws -> Int64 {
        let statement = try PagedStatement(raw,sql)
        guard try statement.step() else { throw PagedFailure(code: -12) }; return statement.number(0)
    }
    func profile() throws -> PagedProfile {
        guard try scalar("PRAGMA user_version")==2 else {throw PagedFailure(code:-200)}
        let statement=try PagedStatement(raw,"SELECT revision,aggregates,transaction_rows FROM profile WHERE id=1")
        guard try statement.step(),statement.number(0)==2,
              let value=PagedProfile(aggregates:statement.number(1),rows:statement.number(2)),try !statement.step() else {throw PagedFailure(code:-201)}
        return value
    }
    func transaction(_ body: () throws -> Void) throws {
        try fresh(); try exec("BEGIN IMMEDIATE")
        do { try body(); try fresh(); try exec("COMMIT"); try fresh() }
        catch { try? exec("ROLLBACK"); throw error }
    }
    func close() throws {
        guard !closed else { return }
        try sqlCheck(sqlite3_close(raw)); closed = true
    }
}

struct PagedProfile:Sendable {
    let aggregates:Bool
    let rows:Int64
    init?(aggregates:Int64,rows:Int64) {
        guard (aggregates==0 || aggregates==1),(rows==128 || rows==1024) else {return nil}
        self.aggregates=aggregates==1;self.rows=rows
    }
    static let baseline=PagedProfile(aggregates:0,rows:128)!
    static func named(_ name:String) -> Self? {
        switch name {
        case "baseline":return .baseline
        case "aggregates":return .init(aggregates:1,rows:128)
        case "transactions":return .init(aggregates:0,rows:1024)
        case "combined":return .init(aggregates:1,rows:1024)
        default:return nil
        }
    }
}

func putUnsigned(_ value: UInt64, into data: inout Data) {
    for shift in stride(from:56,through:0,by:-8) { data.append(UInt8(truncatingIfNeeded:value >> shift)) }
}
func getUnsigned(_ data: Data, at offset: Int) -> UInt64 {
    data[offset..<(offset+8)].reduce(0) { ($0 << 8) | UInt64($1) }
}
func packedUnsigned(_ value: UInt64) -> Data { var data = Data(); putUnsigned(value,into:&data); return data }

struct PagedValue: Equatable, Sendable {
    // Five namespace-kind counts, then four checked sum/support records.
    var counts = [UInt64](repeating:0,count:5)
    var bytes = AnalysisByteSubtotals()
    init() {}
    init(kind: Int, payload: Data) throws {
        guard (0..<5).contains(kind), payload.count == 52 else { throw PagedFailure(code:-20) }
        counts[kind] = 1
        for metric in AnalysisByteMetric.allCases {
            let start = metric.rawValue*13, state = payload[start]
            let value = getUnsigned(payload,at:start+1)
            let error = payload[(start+9)..<(start+13)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard state <= 2, error <= Int32.max,
                  state == 1 || value == 0, state == 2 || error == 0 else { throw PagedFailure(code:-21) }
            if kind == 0 {
                let observation: AnalysisMetadata<UInt64> = state == 1 ? .returned(value)
                    : state == 2 ? .failed(code:Int32(error)) : .notReturned
                _ = bytes[metric].add(observation)
            }
        }
    }
    init(data: Data) throws {
        guard data.count == 140 else { throw PagedFailure(code:-22) }
        for i in 0..<5 { counts[i] = getUnsigned(data,at:i*8) }
        guard counts.allSatisfy({ $0<=220000 }) else { throw PagedFailure(code:-25) }
        for metric in AnalysisByteMetric.allCases {
            let start = 40+metric.rawValue*25
            guard data[start+24] <= 1 else { throw PagedFailure(code:-23) }
            var result = AnalysisMetricSubtotal()
            result.overflowed = data[start+24] == 1
            result.knownBytes = result.overflowed ? nil : getUnsigned(data,at:start)
            result.notReturnedCount = getUnsigned(data,at:start+8)
            result.failedCount = getUnsigned(data,at:start+16)
            guard result.notReturnedCount<=220000, result.failedCount<=220000,
                  !result.overflowed || getUnsigned(data,at:start)==0 else { throw PagedFailure(code:-26) }
            bytes[metric] = result
        }
    }
    mutating func merge(_ other: Self) throws {
        for i in 0..<5 {
            let (sum,overflow) = counts[i].addingReportingOverflow(other.counts[i])
            guard !overflow, sum<=220000 else { throw PagedFailure(code:-24) }; counts[i] = sum
        }
        bytes.merge(other.bytes)
    }
    var encoded: Data {
        var data = Data(); for count in counts { putUnsigned(count,into:&data) }
        for metric in AnalysisByteMetric.allCases {
            let value = bytes[metric]
            putUnsigned(value.knownBytes ?? 0,into:&data)
            putUnsigned(value.notReturnedCount,into:&data); putUnsigned(value.failedCount,into:&data)
            data.append(value.overflowed ? 1 : 0)
        }
        return data
    }
}

func observationPayload(_ bytes: AnalysisByteObservation) -> Data {
    var result = Data()
    for metric in AnalysisByteMetric.allCases {
        let value: UInt64, error: UInt32
        switch bytes[metric] {
        case .notReturned: result.append(0); value=0;error=0
        case .returned(let number): result.append(1);value=number;error=0
        case .failed(let code): result.append(2);value=0;error=UInt32(bitPattern:code)
        }
        putUnsigned(value,into:&result)
        for shift in stride(from:24,through:0,by:-8) { result.append(UInt8(truncatingIfNeeded:error >> shift)) }
    }
    return result
}

final class PagedNodeWriter {
    let database: PagedDatabase
    private let insert: PagedStatement
    private var ancestors: [(path:Data,id:Int64)] = [(Data(),0)]
    private(set) var count: Int64 = 0
    private(set) var maximumAncestors = 1
    private var batchOpen = false
    private let profile:PagedProfile
    private let aggregates:BoundedDirectAggregates?
    init(_ database: PagedDatabase) throws {
        self.database = database
        profile=try database.profile()
        aggregates=profile.aggregates ? try BoundedDirectAggregates(database):nil
        insert = try PagedStatement(database.raw,"INSERT INTO observations_v2 VALUES(?,?,?,?,?,?,?,?)")
    }
    func accept(_ record: AnalysisEntryObservation) throws {
        guard count < 220000, !record.relativePath.isEmpty, record.relativePath.count <= 8192 else { throw PagedFailure(code:-30) }
        let components = record.relativePath.split(separator:47,omittingEmptySubsequences:false)
        guard components.count <= 64, components.allSatisfy({ !$0.isEmpty && $0.count <= 255 && !$0.contains(0)
            && !$0.elementsEqual([46]) && !$0.elementsEqual([46,46]) }) else { throw PagedFailure(code:-31) }
        let name = Data(components.last!), parent = Data(record.relativePath.dropLast(name.count+(components.count>1 ? 1:0)))
        while ancestors.count>1 && ancestors.last!.path != parent { ancestors.removeLast() }
        guard ancestors.last!.path == parent else { throw PagedFailure(code:-32) }
        try aggregates?.leave(until:ancestors.last!.id)
        let kind: Int
        switch record.kind { case .regularFile:kind=0;case .directory:kind=1;case .symbolicLink:kind=2;case .other:kind=3;case .unknown:kind=4 }
        if !batchOpen { try database.fresh(); try database.exec("BEGIN IMMEDIATE"); batchOpen=true }
        try insert.integer(1,count+1);try insert.integer(2,ancestors.last!.id);try insert.blob(3,name);try insert.integer(4,Int64(kind))
        let identity = record.identity.value.map { packedUnsigned($0.device)+packedUnsigned($0.inode) }
        try insert.blob(5,identity);try insert.blob(6,record.linkCount.value.map(packedUnsigned))
        let flags = record.flags.value.map { value in Data((0..<4).map { UInt8(truncatingIfNeeded:value >> ((3-$0)*8)) }) }
        try insert.blob(7,flags);try insert.blob(8,observationPayload(record.bytes))
        guard try !insert.step() else { throw PagedFailure(code:-33) };try insert.reset();count+=1
        try aggregates?.accept(id:count,parent:ancestors.last!.id,name:name,kind:kind,payload:observationPayload(record.bytes),descend:kind==1 && components.count<64)
        if kind==1 && components.count<64 { ancestors.append((record.relativePath,count));maximumAncestors=max(maximumAncestors,ancestors.count) }
        if count%profile.rows==0 { try commit() }
    }
    func commit() throws {
        guard batchOpen else { return }
        try aggregates?.flush();try database.fresh();try database.exec("COMMIT");batchOpen=false;try database.fresh()
    }
    func rollback() { if batchOpen { try? database.exec("ROLLBACK");batchOpen=false } }
}

struct PagedRow: Sendable {
    let id: Int64
    let rawName: Data
    let kind: Int
    let value: PagedValue?
    var title: String { String(bytes:rawName,encoding:.utf8) ?? "Name is not UTF-8" }
}

// One connection is confined to this explicit worker queue. Cancellation never
// closes its handle concurrently with sqlite3_step; close is queued after work.
final class PagedResultReader: @unchecked Sendable {
    private let queue = DispatchQueue(label:"b06.paged-result-reader",qos:.utility)
    private var database: PagedDatabase?
    private var closed = false
    private var seal:PagedReadSeal?
    private var cache: [(parent:Int64,cursor:Int64,folders:Bool,rows:[PagedRow])] = []
    private(set) var peakCachedRows = 0
    private let path: String
    private let beforeQuery: (@Sendable () -> Void)?
    init(path: String, beforeQuery: (@Sendable () -> Void)? = nil) { self.path=path;self.beforeQuery=beforeQuery }
    func page(parent: Int64,cursor: Int64) async throws -> [PagedRow] {
        try await orderedPage(parent:parent,cursor:cursor,folders:false)
    }
    func folderPage(parent:Int64,cursor:Int64) async throws -> [PagedRow] {
        try await orderedPage(parent:parent,cursor:cursor,folders:true)
    }
    private func orderedPage(parent:Int64,cursor:Int64,folders:Bool) async throws -> [PagedRow] {
        guard (0...220000).contains(parent),(0...220000).contains(cursor) else {throw PagedFailure(code:-42)}
        let cancellation = PagedReadCancellation()
        return try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.closed, !cancellation.isCancelled else { throw PagedFailure(code:SQLITE_INTERRUPT) }
                    if self.database == nil { self.database=try PagedDatabase(path:self.path,readOnly:true) }
                    guard let db=self.database else { throw PagedFailure(code:-40) }
                    try db.fresh()
                    _ = try db.profile();try self.validate(db)
                    if let value = self.cache.first(where: { $0.parent==parent && $0.cursor==cursor && $0.folders==folders }) {
                        guard !cancellation.isCancelled else {throw PagedFailure(code:SQLITE_INTERRUPT)}
                        continuation.resume(returning:value.rows);return
                    }
                    self.beforeQuery?()
                    let stmt:PagedStatement
                    if folders {
                        if cursor>0 {
                            let guardCursor=try PagedStatement(db.raw,"SELECT parent FROM folder_listing WHERE node=?")
                            try guardCursor.integer(1,cursor)
                            guard try guardCursor.step(),guardCursor.number(0)==parent else {throw PagedFailure(code:-42)}
                        }
                        stmt=try PagedStatement(db.raw,"WITH c AS(SELECT unknown,logical,name,node FROM folder_listing WHERE node=?) SELECT n.id,n.name,n.kind,r.value,n.payload FROM folder_listing f JOIN observations_v2 n ON n.id=f.node JOIN rollups r ON r.node=n.id LEFT JOIN c ON 1 WHERE f.parent=? AND (?=0 OR f.unknown>c.unknown OR (f.unknown=c.unknown AND (f.logical<c.logical OR (f.logical=c.logical AND (f.name>c.name OR (f.name=c.name AND f.node>c.node)))))) ORDER BY f.unknown,f.logical DESC,f.name,f.node LIMIT 256")
                        try stmt.integer(1,cursor);try stmt.integer(2,parent);try stmt.integer(3,cursor)
                    } else {
                        stmt=try PagedStatement(db.raw,"SELECT n.id,n.name,n.kind,r.value,n.payload FROM observations_v2 n LEFT JOIN rollups r ON r.node=n.id WHERE n.parent=? AND n.id>? ORDER BY n.id LIMIT 256")
                        try stmt.integer(1,parent);try stmt.integer(2,cursor)
                    }
                    var rows:[PagedRow]=[]
                    while try stmt.step() {
                        guard !cancellation.isCancelled, b06_cancelled()==0,let name=try stmt.data(1),let payload=try stmt.data(4) else { throw PagedFailure(code:SQLITE_INTERRUPT) }
                        let kind=Int(stmt.number(2)),data=try stmt.data(3)
                        let value=try data.map(PagedValue.init(data:)) ?? (kind==1 ? nil : PagedValue(kind:kind,payload:payload))
                        rows.append(.init(id:stmt.number(0),rawName:name,kind:kind,value:value))
                    }
                    try db.fresh();try self.validate(db)
                    // Evict before inserting the new page; never hold a third
                    // cached page just to update an LRU counter.
                    if self.cache.count==2 { self.cache.removeFirst() }
                    self.cache.append((parent,cursor,folders,rows));self.peakCachedRows=max(self.peakCachedRows,self.cache.reduce(0){$0+$1.rows.count})
                    continuation.resume(returning:rows)
                } catch { continuation.resume(throwing:error) }
            }
        }} onCancel: { cancellation.cancel() }
    }
    private func validate(_ db:PagedDatabase) throws {
        let current=try PagedReadSeal(db)
        if let seal,seal != current {cache=[];throw PagedFailure(code:-230)}
        if seal==nil {seal=current}
    }
    func closeAndDrain() async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            queue.async {
                do { self.closed=true;self.cache=[];self.seal=nil;try self.database?.close();self.database=nil;continuation.resume() }
                catch { continuation.resume(throwing:error) }
            }
        }
    }
    func inspectionParent() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.closed else {throw PagedFailure(code:SQLITE_INTERRUPT)}
                    if self.database==nil {self.database=try PagedDatabase(path:self.path,readOnly:true)}
                    guard let db=self.database else {throw PagedFailure(code:-41)}
                    try db.fresh();try self.validate(db)
                    let query=try PagedStatement(db.raw,"SELECT parent FROM folder_listing GROUP BY parent ORDER BY count(*) DESC,parent LIMIT 1")
                    let parent=try query.step() ? query.number(0):0
                    try db.fresh();try self.validate(db);continuation.resume(returning:parent)
                } catch {continuation.resume(throwing:error)}
            }
        }
    }
}

private struct PagedReadSeal:Equatable {
    let size:Int64,modifiedSeconds:Int64,modifiedNanoseconds:Int64
    let changedSeconds:Int64,changedNanoseconds:Int64,version:Int64
    init(_ db:PagedDatabase) throws {
        try db.fresh()
        var value=stat()
        guard fstat(5,&value)==0 else {throw PagedFailure(code:-230)}
        size=value.st_size;modifiedSeconds=Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds=Int64(value.st_mtimespec.tv_nsec)
        changedSeconds=Int64(value.st_ctimespec.tv_sec);changedNanoseconds=Int64(value.st_ctimespec.tv_nsec)
        // Same-connection data_version is compared only within this reader;
        // timestamps additionally catch raw edits that do not make a commit.
        version=try db.scalar("PRAGMA data_version")
    }
}

private final class PagedReadCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled=true } }
}
