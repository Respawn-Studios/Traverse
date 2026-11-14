import Foundation

/// Shared concrete TAR source admission. A format probe is charged to the same
/// metadata budget; no regular/AppleDouble payload is fetched by this function.
internal enum TARSourceCatalog {
    static func read(_ source:PinnedLocalFileSource,limits:TARReadLimits,check:()throws->Void,
                     didRead:((UInt64,Int)throws->Void)?=nil)throws->TARCatalogStorage{
        let parsed=try parse(source,limits:limits,check:check,didRead:didRead)
        let result=try TARCatalogBuilder.build(parsed,limits:limits,check:check)
        try check();try source.validate();return result
    }
    /// The same complete metadata witness without a second catalog/search index.
    static func parse(_ source:PinnedLocalFileSource,limits:TARReadLimits,check:()throws->Void,
                      didRead:((UInt64,Int)throws->Void)?=nil)throws->TARParsedDirectory{
        try check()
        guard source.observed.size>=0,UInt64(source.observed.size)<=limits.sourceBytes else{throw TARArchiveFailure.limited}
        let count=min(6,Int(source.observed.size));guard limits.metadataBytes>=count else{throw TARArchiveFailure.limited}
        let prefix=try source.read(0,count,maximum:6,check:check);try didRead?(0,count)
        if prefix.starts(with:[0x1f,0x8b]) || prefix.starts(with:Array("BZh".utf8)) || prefix.starts(with:[0xfd,0x37,0x7a,0x58,0x5a,0]) || prefix.starts(with:[0x28,0xb5,0x2f,0xfd]){
            throw TARArchiveFailure.compressed
        }
        var parserLimits=limits;parserLimits.metadataBytes-=count
        let parsed=try TARMetadataParser.parse(length:UInt64(source.observed.size),limits:parserLimits,check:check,read:{offset,size in
            let data=try source.read(offset,size,maximum:65_536,check:check);try didRead?(offset,size);return data
        })
        let complete=TARParsedDirectory(records:parsed.records,witness:parsed.witness,metadataBytes:parsed.metadataBytes+count,logicalBytes:parsed.logicalBytes)
        try check();try source.validate();return complete
    }
}
