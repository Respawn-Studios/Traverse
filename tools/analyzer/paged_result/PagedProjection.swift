import Foundation
import SQLite3

func installPagedMerge(_ database: OpaquePointer) throws {
    let callback: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context,count,args in
        guard let context,count==2,let args else { return }
        do {
            func bytes(_ index: Int) throws -> Data {
                guard let value=args[index],sqlite3_value_bytes(value)==140,let pointer=sqlite3_value_blob(value) else { throw PagedFailure(code:-50) }
                return Data(bytes:pointer,count:140)
            }
            var value=try PagedValue(data:bytes(0));try value.merge(PagedValue(data:bytes(1)))
            let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            value.encoded.withUnsafeBytes { sqlite3_result_blob(context,$0.baseAddress,140,transient) }
        } catch { sqlite3_result_error_code(context,SQLITE_MISMATCH) }
    }
    try sqlCheck(sqlite3_create_function_v2(database,"b06_merge",2,SQLITE_UTF8|SQLITE_DETERMINISTIC,nil,callback,nil,nil,nil))
}

struct PagedProjectionReport: Sendable {
    let totals: PagedValue
    let folderCount: Int64
    let projectCount: Int64
    let groupCount: Int64
}

private struct StoredNode {
    let id:Int64,parent:Int64,kind:Int
    let name:Data,payload:Data
}

enum PagedProjection {
    static func build(_ db: PagedDatabase,scope: String) throws -> PagedProjectionReport {
        try db.fresh()
        let profile=try db.profile()
        let merge=try PagedStatement(db.raw,"INSERT INTO rollups VALUES(?,?) ON CONFLICT(node) DO UPDATE SET value=b06_merge(rollups.value,excluded.value)")
        let empty=try PagedStatement(db.raw,"INSERT INTO rollups VALUES(?,?) ON CONFLICT(node) DO NOTHING")
        let marker=try PagedStatement(db.raw,"INSERT INTO markers VALUES(?,?) ON CONFLICT(node) DO UPDATE SET marker=min(markers.marker,excluded.marker)")
        if !profile.aggregates {try db.transaction {
            try empty.integer(1,0);try empty.blob(2,PagedValue().encoded);_ = try empty.step();try empty.reset()
        }}
        var cursor:Int64=0,folders:Int64=1
        while !profile.aggregates {
            let page=try observations_v2(db,after:cursor,directories:false)
            if page.isEmpty { break }
            for batch in stride(from:0,to:page.count,by:128) {
                try db.transaction {
                    for row in page[batch..<min(batch+128,page.count)] {
                        try cancelled()
                        let value=try PagedValue(kind:row.kind,payload:row.payload)
                        try merge.integer(1,row.parent);try merge.blob(2,value.encoded);_ = try merge.step();try merge.reset()
                        if row.kind==1 {
                            folders+=1;try empty.integer(1,row.id);try empty.blob(2,PagedValue().encoded);_ = try empty.step();try empty.reset()
                        }
                        let kind:AnalysisEntryKind=row.kind==0 ? .regularFile : row.kind==1 ? .directory : .other
                        if let found=AnalysisProjectMarker.match(row.name,kind:kind) {
                            try marker.integer(1,row.parent);try marker.integer(2,Int64(found.rawValue));_ = try marker.step();try marker.reset()
                        }
                    }
                }
            }
            cursor=page.last!.id
        }
        if profile.aggregates {
            // One bounded directory page at a time; empty folders get only one
            // zero total, never thirteen possible type rows.
            cursor = -1;folders=0
            while true {
                let page=try observations_v2(db,after:cursor,directories:true)
                if page.isEmpty {break}
                try db.transaction {
                    let insert=try PagedStatement(db.raw,"INSERT INTO rollups SELECT n.id,coalesce(d.value,zeroblob(140)) FROM observations_v2 n LEFT JOIN direct_totals d ON d.node=n.id WHERE n.kind=1 AND n.id>? AND n.id<=?")
                    try insert.integer(1,cursor);try insert.integer(2,page.last!.id);_ = try insert.step()
                }
                folders+=Int64(page.count);cursor=page.last!.id
            }
        }
        // IDs are admitted parent-first; reverse directory IDs merge each
        // subtree once. The parent's direct directory count is already present.
        cursor=220001
        while true {
            let query=try PagedStatement(db.raw,"SELECT n.id,n.parent,r.value FROM observations_v2 n JOIN rollups r ON r.node=n.id WHERE n.kind=1 AND n.id>0 AND n.id<? ORDER BY n.id DESC LIMIT 128")
            try query.integer(1,cursor)
            var page:[(id:Int64,parent:Int64,value:Data)]=[]
            while try query.step() { guard let data=try query.data(2) else { throw PagedFailure(code:-51) };page.append((query.number(0),query.number(1),data)) }
            if page.isEmpty { break }
            // Read each current value inside the transaction: a child in this
            // same page may have just updated its parent's stored subtotal.
            let current=try PagedStatement(db.raw,"SELECT value FROM rollups WHERE node=?")
            try db.transaction {
                for row in page {
                    try cancelled();try current.integer(1,row.id)
                    guard try current.step(),let data=try current.data(0) else { throw PagedFailure(code:-52) };try current.reset()
                    try merge.integer(1,row.parent);try merge.blob(2,data);_ = try merge.step();try merge.reset()
                }
            }
            cursor=page.last!.id
        }
        var listed:Int64=0
        while true {
            var next=listed,changed:Int64=0
            try db.transaction {
                let query=try PagedStatement(db.raw,"INSERT INTO folder_listing SELECT n.id,n.parent,n.name,substr(r.value,66,8),substr(r.value,90,1) FROM observations_v2 n JOIN rollups r ON r.node=n.id WHERE n.kind=1 AND n.id>? ORDER BY n.id LIMIT 128 RETURNING node")
                try query.integer(1,listed)
                while try query.step() {next=max(next,query.number(0));changed+=1}
            }
            if changed==0 {break};listed=next
        }
        try contexts(db,scope:scope)
        try groups(db,direct:profile.aggregates)
        let root=try PagedStatement(db.raw,"SELECT value FROM rollups WHERE node=0")
        guard try root.step(),let bytes=try root.data(0) else { throw PagedFailure(code:-53) }
        return try .init(totals:PagedValue(data:bytes),folderCount:folders,
            projectCount:db.scalar("SELECT count(*) FROM groups WHERE kind=2 AND key>0"),
            groupCount:db.scalar("SELECT count(*) FROM groups"))
    }

    private static func observations_v2(_ db:PagedDatabase,after cursor:Int64,directories:Bool) throws -> [StoredNode] {
        let query=try PagedStatement(db.raw,directories
            ? "SELECT id,parent,name,kind,payload FROM observations_v2 WHERE kind=1 AND id>? ORDER BY id LIMIT 256"
            : "SELECT id,parent,name,kind,payload FROM observations_v2 WHERE id>? ORDER BY id LIMIT 256")
        try query.integer(1,cursor);var result:[StoredNode]=[]
        while try query.step() {
            guard let name=try query.data(2),let payload=try query.data(4) else { throw PagedFailure(code:-54) }
            result.append(.init(id:query.number(0),parent:query.number(1),kind:Int(query.number(3)),name:name,payload:payload))
        }
        return result
    }

    private static func contexts(_ db:PagedDatabase,scope:String) throws {
        let rootParts=scope.split(separator:"/").map(String.init)
        let rootRole=AnalysisAttributionReport.classify(rootParts,inherited:.other,hasProject:false)
        let parent=try PagedStatement(db.raw,"SELECT c.role,c.project,n.name FROM contexts c JOIN observations_v2 n ON n.id=c.node WHERE c.node=?")
        let marker=try PagedStatement(db.raw,"SELECT marker FROM markers WHERE node=?")
        let insert=try PagedStatement(db.raw,"INSERT INTO contexts VALUES(?,?,?)")
        let project=try PagedStatement(db.raw,"INSERT INTO groups VALUES(2,?,?) ON CONFLICT DO NOTHING")
        var cursor:Int64 = -1
        while true {
            let page=try observations_v2(db,after:cursor,directories:true)
            if page.isEmpty { break }
            for batch in stride(from:0,to:page.count,by:128) {
                try db.transaction {
                    for row in page[batch..<min(batch+128,page.count)] {
                        try cancelled()
                        var role=rootRole,nearest:Int64=0,context:[String]=[]
                        let name=String(bytes:row.name,encoding:.utf8)
                        if row.id>0 {
                            try parent.integer(1,row.parent)
                            guard try parent.step(),let inherited=AnalysisCategory(rawValue:Int(parent.number(0))) else { throw PagedFailure(code:-55) }
                            nearest=parent.number(1);let parentName=try parent.data(2).flatMap { String(bytes:$0,encoding:.utf8) }
                            try parent.reset()
                            context=name.map {[$0]} ?? []
                            if name=="Caches" || name=="Application Support",
                               (row.parent==0 ? rootParts.last : parentName)=="Library" { context.insert("Library",at:0) }
                            role=inherited
                        }
                        try marker.integer(1,row.id);let marked=try marker.step();try marker.reset()
                        if row.id>0 { role=AnalysisAttributionReport.classify(context,inherited:role,hasProject:nearest>0 || marked) }
                        let suppress:[AnalysisCategory]=[.dependencies,.toolCache,.modelStore,.versionControl,.pythonCache,.flutterState]
                        if marked && !suppress.contains(role) {
                            nearest=row.id+1;try project.integer(1,nearest);try project.blob(2,PagedValue().encoded);_ = try project.step();try project.reset()
                        }
                        if nearest>0 && (name==".cache" || context==["Library","Caches"]) { nearest=0 }
                        try insert.integer(1,row.id);try insert.integer(2,Int64(role.rawValue));try insert.integer(3,nearest);_ = try insert.step();try insert.reset()
                    }
                }
            }
            cursor=page.last!.id
        }
    }

    private static func groups(_ db:PagedDatabase,direct:Bool) throws {
        let insert=try PagedStatement(db.raw,"INSERT INTO groups VALUES(?,?,?) ON CONFLICT(kind,key) DO UPDATE SET value=b06_merge(groups.value,excluded.value)")
        try db.transaction {
            for (kind,count) in [(0,AnalysisFileType.allCases.count),(1,AnalysisCategory.allCases.count),(2,1)] {
                for key in 0..<count {
                    try insert.integer(1,Int64(kind));try insert.integer(2,Int64(key));try insert.blob(3,PagedValue().encoded);_ = try insert.step();try insert.reset()
                }
            }
        }
        if direct {
            try db.transaction {
                try db.exec("UPDATE groups SET value=(SELECT value FROM type_totals WHERE type=groups.key) WHERE kind=0 AND EXISTS(SELECT 1 FROM type_totals WHERE type=groups.key)")
            }
            var cursor:Int64 = -1
            while true {
                let query=try PagedStatement(db.raw,"SELECT d.node,d.value,c.role,c.project FROM direct_files d JOIN contexts c ON c.node=d.node WHERE d.node>? ORDER BY d.node LIMIT 128")
                try query.integer(1,cursor)
                var page:[(id:Int64,value:Data,role:Int64,project:Int64)]=[]
                while try query.step() {
                    guard let value=try query.data(1) else {throw PagedFailure(code:-205)}
                    page.append((query.number(0),value,query.number(2),query.number(3)))
                }
                if page.isEmpty {break}
                try db.transaction {
                    for row in page {
                        try cancelled()
                        for (kind,key) in [(1,row.role),(2,row.project)] {
                            try insert.integer(1,Int64(kind));try insert.integer(2,key);try insert.blob(3,row.value);_ = try insert.step();try insert.reset()
                        }
                    }
                }
                cursor=page.last!.id
            }
            return
        }
        var cursor:Int64=0
        while true {
            let query=try PagedStatement(db.raw,"SELECT n.id,n.name,n.payload,c.role,c.project FROM observations_v2 n JOIN contexts c ON c.node=n.parent WHERE n.kind=0 AND n.id>? ORDER BY n.id LIMIT 128")
            try query.integer(1,cursor)
            var page:[(id:Int64,type:Int,role:Int64,project:Int64,value:PagedValue)]=[]
            while try query.step() {
                guard let name=try query.data(1),let payload=try query.data(2) else { throw PagedFailure(code:-56) }
                page.append(try (query.number(0),AnalysisFileType.match(name).rawValue,query.number(3),query.number(4),PagedValue(kind:0,payload:payload)))
            }
            if page.isEmpty { break }
            try db.transaction {
                for row in page {
                    try cancelled()
                    for (kind,key) in [(0,Int64(row.type)),(1,row.role),(2,row.project)] {
                        try insert.integer(1,Int64(kind));try insert.integer(2,key);try insert.blob(3,row.value.encoded);_ = try insert.step();try insert.reset()
                    }
                }
            }
            cursor=page.last!.id
        }
    }
    private static func cancelled() throws { if b06_cancelled() != 0 { throw PagedFailure(code:SQLITE_INTERRUPT) } }
}
