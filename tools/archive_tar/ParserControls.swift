import CryptoKit
import Darwin
import Foundation

@main enum TARParserControls {
    struct Failed: Error { let check: String }
    static func require(_ value: Bool, _ check: String) throws { if !value { throw Failed(check: check) } }
    static func main() {
        do { try verify() }
        catch {
            let report:[String:Any] = ["passed":false,"failure":String(describing:error)]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) { FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10])) }
            Darwin.exit(1)
        }
    }
    static func verify() throws {
        guard CommandLine.arguments.count == 2 else { throw Failed(check: "exact generated fixture input") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(root.resolvingSymlinksInPath() == root && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
            && UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent,"canonical generated fixture root")
        let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json"))) as? [String:Any]
        try require(marker?["action"] as? String == "plain-tar-fixtures","fixture reservation")
        guard let inputs = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("inputs.json"))) as? [String:Any],
              inputs["generatedOnly"] as? Bool == true, let archives = inputs["archives"] as? [String:[String:Any]], archives.count <= 64 else { throw Failed(check: "fixture manifest") }
        var results = [[String:Any]](), checks = 0, readBytes = 0
        for name in archives.keys.sorted() {
            guard let oracle = archives[name], let expected = oracle["expected"] as? String else { throw Failed(check: "oracle") }
            try require(!name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }),"fixed archive name")
            let path = root.appendingPathComponent("source/archives/"+name+".tar")
            try require(path.resolvingSymlinksInPath() == path,"no redirected fixture")
            let bytes = try Data(contentsOf:path)
            try require(bytes.count == oracle["bytes"] as? Int && SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined() == oracle["sha256"] as? String,"frozen independent input")
            var reads = [(UInt64,Int)](), calls = 0
            do {
                let parsed = try TARMetadataParser.parse(length:UInt64(bytes.count),check:{ calls += 1 },read:{ offset,count in
                    reads.append((offset,count)); return bytes.subdata(in:Int(offset)..<(Int(offset)+count))
                })
                let storage = try TARCatalogBuilder.build(parsed,check:{ calls += 1 })
                try require(expected == "complete","negative catalog completed: "+name)
                guard let original = oracle["rows"] as? [[String:Any]], let bodies = oracle["payloadRanges"] as? [[String:Int]] else { throw Failed(check:"independent metadata/body map") }
                let rows = original.filter { !(($0["kind"] as? String == "directory") && ["",".","./"].contains($0["path"] as? String ?? "?")) }
                try require(rows.count == parsed.records.count,"independent record count: "+name)
                for (record,row) in zip(parsed.records,rows) {
                    try require(record.path == row["path"] as? String && record.kind.rawValue == row["kind"] as? String
                        && record.bytes == (row["bytes"] as? NSNumber)?.uint64Value
                        && record.dataOffset == (row["dataOffset"] as? NSNumber)?.uint64Value,"independent record identity: "+name)
                }
                for (offset,count) in reads {
                    for body in bodies {
                        guard let start = body["offset"], let length = body["bytes"] else { throw Failed(check:"body range") }
                        try require(offset+UInt64(count) <= UInt64(start) || offset >= UInt64(start+length),"member body read: "+name)
                    }
                }
                let total = reads.reduce(0){$0+$1.1};readBytes += total
                try require(total == parsed.metadataBytes && parsed.witness.count == 32 && storage.witness == parsed.witness,"exact metadata witness")
                try require(storage.nodes.count <= 20_000 && storage.summary.logicalBytes == parsed.logicalBytes,"catalog bounds/accounting")
                let expectedFiles = rows.filter{$0["kind"] as? String == "file"}.count
                try require(storage.summary.files == expectedFiles,"file total")
                for field in TARArchiveOrder.Field.allCases {
                    for descending in [false,true] {
                        let ids = try TARCatalogOrdering.ids(storage.nodes[0].children,nodes:storage.nodes,order:.init(field,descending:descending),check:{})
                        try require(Set(ids) == Set(storage.nodes[0].children),"sorting keeps exact items")
                    }
                }
                results.append(["archive":name,"records":parsed.records.count,"nodes":storage.nodes.count,"metadataReadBytes":total,"memberBodyReadBytes":0])
            } catch let error as TARArchiveFailure {
                try require(expected != "complete" && error.rawValue == expected,"unexpected parser refusal: "+name+" "+error.rawValue)
                results.append(["archive":name,"refused":error.rawValue])
            }
            try require(reads.isEmpty || calls > 0,"read cancellation checks present");checks += 1
        }
        if archives["ustar"] == nil { try report(checks:checks,results:results,readBytes:readBytes);return }
        let base = try Data(contentsOf:root.appendingPathComponent("source/archives/ustar.tar"))
        func limited(_ limits:TARReadLimits, expected:TARArchiveFailure = .limited) throws {
            do {
                let parsed = try TARMetadataParser.parse(length:UInt64(base.count),limits:limits,check:{},read:{ offset,count in base.subdata(in:Int(offset)..<(Int(offset)+count)) })
                _ = try TARCatalogBuilder.build(parsed,limits:limits,check:{})
                throw Failed(check:"bounded catalog unexpectedly completed")
            } catch let failure as TARArchiveFailure { try require(failure == expected,"typed limit result") }
            checks += 1
        }
        var limit = TARReadLimits();limit.records=0;try limited(limit)
        limit = .init();limit.nodes=1;try limited(limit)
        limit = .init();limit.metadataBytes=511;try limited(limit)
        limit = .init();limit.memberBytes=2;try limited(limit)
        limit = .init();limit.logicalBytes=2;try limited(limit)
        limit = .init();limit.nameBytes=1;try limited(limit)
        limit = .init();limit.searchBytes=1;try limited(limit)
        limit = .init();limit.pathBytes=1;try limited(limit)
        limit = .init();limit.records = -1;try limited(limit)
        var calls = 0
        do {
            _ = try TARMetadataParser.parse(length:UInt64(base.count),check:{ calls += 1;if calls == 3 { throw TARArchiveFailure.stopped } },read:{offset,count in base.subdata(in:Int(offset)..<(Int(offset)+count))})
            throw Failed(check:"Stop completed")
        } catch let failure as TARArchiveFailure { try require(failure == .stopped && calls == 3,"Stop propagates exact boundary") }
        checks += 1
        do {
            _ = try TARMetadataParser.parse(length:UInt64(base.count),check:{},read:{_,count in Data(repeating:0,count:max(0,count-1))})
            throw Failed(check:"short metadata read completed")
        } catch let failure as TARArchiveFailure { try require(failure == .malformed,"short metadata read refuses") }
        checks += 1
        try report(checks:checks,results:results,readBytes:readBytes)
    }
    static func report(checks:Int,results:[[String:Any]],readBytes:Int)throws {
        let value:[String:Any] = ["passed":true,"checks":checks,"archives":results,"metadataReadBytes":readBytes,"memberBodyReadBytes":0,"fileWrites":0,"sourceAuthority":"generated fixtures only; pure parser closure"]
        let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))
    }
}
