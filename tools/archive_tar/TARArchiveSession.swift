import ExplorerCore
import Foundation

public struct TARBreadcrumb: Sendable { public let folder:TARFolderID;public let name:String }
public struct TARDirectoryPage: Sendable {
    public let folder:TARFolderID,breadcrumbs:[TARBreadcrumb],items:[TARArchiveItem]
    public let offset:Int,total:Int
    public var hasNext:Bool{offset+items.count<total}
}
public struct TARNameSearchPage: Sendable {
    public let items:[TARArchiveItem];public let offset:Int,total:Int
    public var hasNext:Bool{offset+items.count<total}
}
public struct TARItemLocation: Sendable { public let folder:TARFolderID;public let offset:Int }
/// Opaque exact catalog/source choices, never destination or access authority.
public struct TARExtractionSelection: Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    internal struct Root: Sendable {let path:String;let kind:TARMemberKind}
    internal let binding:TARSourceBinding,roots:[Root],wholeArchive:Bool
    public var count:Int{roots.count}
    public var isWholeArchive:Bool{wholeArchive}
    public var displayNames:[String]{roots.map(\.path)}
    public var description:String{wholeArchive ? "whole archive selection":"\(count) archive selections"}
    public var debugDescription:String{description}
}
public actor TARArchiveSession {
    public nonisolated let root:TARFolderID
    public nonisolated let summary:TARArchiveSummary
    private var storage:TARCatalogStorage?
    private let binding:TARSourceBinding?
    private struct Query: Equatable {let folder:Int?;let text:String;let symbols:Bool;let order:TARArchiveOrder}
    private var cached:(Query,[Int])?
    internal init(_ storage:TARCatalogStorage,binding:TARSourceBinding?=nil){
        root = .init(owner:UUID(),node:0);summary=storage.summary;self.storage=storage;self.binding=binding
    }
    public func page(in folder:TARFolderID,offset:Int=0,filter:String="",symbolTolerant:Bool=true,sorting order:TARArchiveOrder = .init())throws->TARDirectoryPage{
        guard let storage else{throw TARArchiveFailure.closed}
        guard folder.owner==root.owner,storage.nodes.indices.contains(folder.node),storage.nodes[folder.node].kind == .directory else{throw TARArchiveFailure.invalidSelection}
        let ids=try matches(.init(folder:folder.node,text:filter,symbols:symbolTolerant,order:order),storage:storage)
        let rows=try pageItems(ids,offset:offset,nodes:storage.nodes)
        var crumbs=[TARBreadcrumb](),cursor:Int?=folder.node
        while let index=cursor{crumbs.append(.init(folder:.init(owner:root.owner,node:index),name:storage.nodes[index].name));cursor=storage.nodes[index].parent}
        return .init(folder:folder,breadcrumbs:crumbs.reversed(),items:rows,offset:min(offset,ids.count),total:ids.count)
    }
    public func searchNames(_ query:String,offset:Int=0,symbolTolerant:Bool=true,sorting order:TARArchiveOrder = .init())throws->TARNameSearchPage{
        guard let storage else{throw TARArchiveFailure.closed}
        let ids=try matches(.init(folder:nil,text:query,symbols:symbolTolerant,order:order),storage:storage)
        return .init(items:try pageItems(ids,offset:offset,nodes:storage.nodes),offset:min(offset,ids.count),total:ids.count)
    }
    public func location(of id:TARItemID,sorting order:TARArchiveOrder = .init())throws->TARItemLocation{
        guard let storage else{throw TARArchiveFailure.closed};try require(id,nodes:storage.nodes)
        guard let parent=storage.nodes[id.node].parent else{throw TARArchiveFailure.invalidSelection}
        let ids=try TARCatalogOrdering.ids(storage.nodes[parent].children,nodes:storage.nodes,order:order,check:{try Task.checkCancellation()})
        guard let offset=ids.firstIndex(of:id.node)else{throw TARArchiveFailure.invalidSelection}
        return .init(folder:.init(owner:root.owner,node:parent),offset:offset)
    }
    public func selectionForExtraction(_ ids:Set<TARItemID>)throws->TARExtractionSelection{
        guard let storage else{throw TARArchiveFailure.closed}
        guard let binding,!ids.isEmpty,ids.count<=1024 else{throw TARArchiveFailure.invalidSelection}
        var selected=Set<Int>()
        for id in ids{
            try Task.checkCancellation();try require(id,nodes:storage.nodes)
            guard [.file,.directory].contains(storage.nodes[id.node].kind)else{throw TARArchiveFailure.unsupported}
            selected.insert(id.node)
        }
        var roots=[TARExtractionSelection.Root]()
        for index in selected.sorted(){
            var parent=storage.nodes[index].parent,covered=false
            while let value=parent,value != 0{if selected.contains(value){covered=true;break};parent=storage.nodes[value].parent}
            if !covered{roots.append(.init(path:path(index,nodes:storage.nodes),kind:storage.nodes[index].kind))}
        }
        return .init(binding:binding,roots:roots,wholeArchive:false)
    }
    public func selectionForWholeExtraction()throws->TARExtractionSelection{
        guard storage != nil else{throw TARArchiveFailure.closed}
        guard let binding else{throw TARArchiveFailure.invalidSelection}
        return .init(binding:binding,roots:[],wholeArchive:true)
    }
    public func close(){storage=nil;cached=nil}
    private func matches(_ query:Query,storage:TARCatalogStorage)throws->[Int]{
        guard query.text.utf8.count<=128 else{throw TARArchiveFailure.limited}
        try Task.checkCancellation();if let cached,cached.0==query{return cached.1}
        let candidates=query.folder.map{storage.nodes[$0].children} ?? Array(storage.nodes.indices.dropFirst())
        let key=FilenameMatching.folded(query.text,symbolTolerant:query.symbols)
        var filtered=[Int]();filtered.reserveCapacity(candidates.count)
        for index in candidates{
            try Task.checkCancellation()
            if key.isEmpty || (query.symbols ? storage.nodes[index].symbols:storage.nodes[index].literal).contains(key){filtered.append(index)}
        }
        let ids=try TARCatalogOrdering.ids(filtered,nodes:storage.nodes,order:query.order,check:{try Task.checkCancellation()});cached=(query,ids);return ids
    }
    private func require(_ id:TARItemID,nodes:[TARCatalogNode])throws{
        guard id.owner==root.owner,id.node>0,nodes.indices.contains(id.node)else{throw TARArchiveFailure.invalidSelection}
    }
    private func pageItems(_ ids:[Int],offset:Int,nodes:[TARCatalogNode])throws->[TARArchiveItem]{
        guard offset>=0 else{throw TARArchiveFailure.limited};try Task.checkCancellation()
        let start=min(offset,ids.count),end=min(start+256,ids.count)
        return try ids[start..<end].map{index in
            try Task.checkCancellation();let node=nodes[index]
            return .init(id:.init(owner:root.owner,node:index),name:node.name,path:path(index,nodes:nodes),kind:node.kind,logicalBytes:node.logical,
                folder:node.kind == .directory ? .init(owner:root.owner,node:index):nil)
        }
    }
    private func path(_ index:Int,nodes:[TARCatalogNode])->String{
        var names=[String](),cursor=index
        while cursor != 0{names.append(nodes[cursor].name);guard let parent=nodes[cursor].parent else{break};cursor=parent}
        return names.reversed().joined(separator:"/")
    }
}
