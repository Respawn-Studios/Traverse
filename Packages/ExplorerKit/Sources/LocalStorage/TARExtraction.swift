import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

internal struct TARProductionHooks: Sendable {
    var writeChunk=65_536
    var failAfterBytes:UInt64?
    var failureErrno:Int32=ENOSPC
    var beforeWrite:(@Sendable(String)throws->Void)?
    var beforeSecurityWrite:(@Sendable(String,Int32)throws->Void)?
    var afterSecurityWriteBeforeReceipt:(@Sendable(String,Int32)throws->Void)?
    var inheritsQuarantine=true
}
/// Exact archive source/layout only. The recoverable worker supplies a fresh
/// private destination descriptor and independently checks every returned fact.
internal final class PreparedTARDirectory: PublicQuarantineTreeProducerV16,@unchecked Sendable {
    private typealias Security = TARCompressedOriginalProof.Security
    let preview:ArchiveProductionPreview
    var publicProducedTreeV16: PublicProducedTreePurposeV16? {
        guard publicQuarantineTree, case .publicProperties(let witness) = security else { return nil }
        return .tarExtraction(sourceMarked: witness.marked)
    }
    private let url:URL,observed:PinnedLocalFileSource.Stamp,witness:Data
    private let files: [(record: TARRecord, path: String)]
    private let folders: [String]
    private let security:Security
    private let expectedQuarantineSHA256:Data?
    private let hooks:TARProductionHooks
    private let publicQuarantineFile: Bool
    private let publicQuarantineTree: Bool
    private let wasCompressed: Bool
    private let spoolLock = NSLock()
    private var spool: TARCompressedSpoolLease?
    init(_ url:URL,selection:TARExtractionSelection,exportingFolder:Bool = false,
         check:@Sendable()throws->Void,hooks:TARProductionHooks = .init(),
         publicQuarantineFile: Bool = false, publicQuarantineTree: Bool = false)throws{
        try check();let source=try PinnedLocalFileSource(url)
        guard !publicQuarantineFile || !publicQuarantineTree else { throw FileOperationFailure.invalidRequest }
        if publicQuarantineFile {
            guard selection.singleFileName != nil, !exportingFolder else { throw TARArchiveFailure.invalidSelection }
        }
        guard source.url==selection.binding.source,source.observed==selection.binding.stamp else{throw FileOperationFailure.sourceChanged}
        let exportedComponents: [String]
        if exportingFolder {
            guard selection.singleFolderName != nil, let root = selection.roots.first else { throw TARArchiveFailure.invalidSelection }
            exportedComponents = root.path.split(separator: "/").map(String.init)
        } else { exportedComponents = [] }
        let security=try Self.security(source,hooks:hooks,
            publicQuarantine:publicQuarantineFile || publicQuarantineTree)
        let started=ProcessInfo.processInfo.systemUptime
        func checkpoint()throws{try check();guard ProcessInfo.processInfo.systemUptime-started<30 else{throw TARArchiveFailure.limited}}
        let compressed = selection.binding.compressed
        let catalog: TARCatalogStorage
        if let compressed {
            guard compressed.original.source == source.url,
                  compressed.original.stamp == source.observed,
                  compressed.original.security == security else {
                throw FileOperationFailure.sourceChanged
            }
            try compressed.verifyDigest(check: checkpoint)
            var limits = TARReadLimits(); limits.sourceBytes = TARCompressedDecoder.maximumBytes
            let parsed = try TARMetadataParser.parse(length: compressed.decodedBytes, limits: limits,
                check: checkpoint, read: { try compressed.read($0, $1, check: checkpoint) })
            catalog = try TARCatalogBuilder.build(parsed, limits: limits, check: checkpoint)
        } else {
            catalog=try TARSourceCatalog.read(source,limits:.init(),check:checkpoint)
        }
        guard catalog.witness==selection.binding.witness else{throw FileOperationFailure.sourceChanged}
        var selected=Set<Int>()
        if selection.wholeArchive{
            guard selection.roots.isEmpty else{throw TARArchiveFailure.invalidSelection};selected=Set(catalog.nodes.indices.dropFirst())
        }else{
            guard !selection.roots.isEmpty,selection.roots.count<=1024 else{throw TARArchiveFailure.invalidSelection}
            for root in selection.roots{
                try checkpoint();var index=0
                let parts=root.path.split(separator:"/").map(String.init)
                guard !parts.isEmpty else{throw TARArchiveFailure.invalidSelection}
                for part in parts{
                    guard let child=catalog.nodes[index].children.first(where:{catalog.nodes[$0].name.utf8.elementsEqual(part.utf8)})else{throw TARArchiveFailure.invalidSelection};index=child
                }
                guard catalog.nodes[index].kind==root.kind else{throw TARArchiveFailure.invalidSelection}
                var pending=[index]
                while let next=pending.popLast(){try checkpoint();if selected.insert(next).inserted{pending+=catalog.nodes[next].children}}
            }
        }
        var files: [(record: TARRecord, path: String)] = []
        var folders=Set<String>(),retainedPaths=0,logical:UInt64=0
        func retainFolder(_ path:String)throws{
            if !folders.contains(path){
                guard path.utf8.count<=(16<<20)-retainedPaths else{throw TARArchiveFailure.limited};retainedPaths+=path.utf8.count
                folders.insert(path)
            }
        }
        for index in selected.sorted(){
            try checkpoint();let node=catalog.nodes[index]
            guard node.kind == .file || node.kind == .directory else{throw TARArchiveFailure.unsupported}
            var names=[String](),cursor=index
            while cursor != 0{names.append(catalog.nodes[cursor].name);guard let parent=catalog.nodes[cursor].parent else{throw TARArchiveFailure.malformed};cursor=parent}
            let absolute = Array(names.reversed())
            guard absolute.starts(with: exportedComponents, by: { $0.utf8.elementsEqual($1.utf8) }) else {
                throw TARArchiveFailure.invalidSelection
            }
            let parts = absolute.dropFirst(exportedComponents.count), path = parts.joined(separator: "/")
            if node.kind == .file{
                guard let record=node.record,record.kind == .file,files.count<10_000,record.bytes<=UInt64(1<<30)-logical,
                      path.utf8.count<=(16<<20)-retainedPaths else{throw TARArchiveFailure.limited}
                retainedPaths+=path.utf8.count;logical+=record.bytes;files.append((record, path))
            }
            var prefix=""
            for part in(node.kind == .directory ? parts:parts.dropLast()){
                prefix=prefix.isEmpty ? part:prefix+"/"+part;try retainFolder(prefix)
            }
        }
        guard files.count+folders.count<20_000 else{throw TARArchiveFailure.limited}
        try source.validate();guard try Self.security(source,hooks:hooks,
            publicQuarantine:publicQuarantineFile || publicQuarantineTree)==security else{
            throw FileOperationFailure.sourceChanged
        };try checkpoint()
        self.url=url;observed=source.observed;witness=catalog.witness;self.files=files;self.folders=folders.sorted{a,b in a.utf8.count==b.utf8.count ? a.utf8.lexicographicallyPrecedes(b.utf8):a.utf8.count<b.utf8.count};self.security=security;self.hooks=hooks
        self.publicQuarantineFile = publicQuarantineFile
        self.publicQuarantineTree = publicQuarantineTree
        expectedQuarantineSHA256=security.exactDigest
        wasCompressed = compressed != nil; spool = compressed
        preview = .init(files:files.count,folders:folders.count,logicalBytes:logical,
            longestPathBytes:max(files.map{$0.path.utf8.count}.max() ?? 0,folders.map{$0.utf8.count}.max() ?? 0),
            largestFileBytes:files.map{$0.record.bytes}.max() ?? 0)
    }
    private func activeSpool() throws -> TARCompressedSpoolLease? {
        let value = spoolLock.withLock { spool }
        if wasCompressed && value == nil { throw TARArchiveFailure.closed }
        return value
    }
    func finished() { spoolLock.withLock { spool = nil } }
    func validate(check:@Sendable()throws->Void)throws{
        try check();let compressed=try activeSpool();let source=try PinnedLocalFileSource(url)
        guard source.observed==observed,
              try Self.security(source,hooks:hooks,
                  publicQuarantine:publicQuarantineFile || publicQuarantineTree)==security else{
            throw FileOperationFailure.sourceChanged
        }
        if let compressed {
            guard compressed.original.security == security else {
                throw FileOperationFailure.sourceChanged
            }
            try compressed.verifyDigest(check: check)
        }
        try source.validate();try check()
    }
    private func withSource<Result>(check: () throws -> Void,
        _ produce: (PinnedLocalFileSource, TARCompressedSpoolLease?, () throws -> Void) throws -> Result) throws -> Result {
        try withoutActuallyEscaping(check) { check in
            try readSource(check: check, produce)
        }
    }

    private func readSource<Result>(check: @escaping () throws -> Void,
        _ produce: (PinnedLocalFileSource, TARCompressedSpoolLease?, () throws -> Void) throws -> Result) throws -> Result {
        try check()
        let compressed = try activeSpool(), source = try PinnedLocalFileSource(url)
        func checkSource() throws {
            try source.validate()
            guard source.observed == observed,
                  try Self.security(source, hooks: hooks,
                      publicQuarantine: publicQuarantineFile || publicQuarantineTree) == security else {
                throw FileOperationFailure.sourceChanged
            }
            if let compressed {
                guard compressed.original.security == security else {
                    throw FileOperationFailure.sourceChanged
                }
            }
        }
        try checkSource()
        if let compressed {
            try compressed.verifyDigest(check: check)
        }
        let started = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < 300 else { throw TARArchiveFailure.limited }
            if let compressed { try checkSource(); try compressed.validate() }
        }
        do {
            let result = try produce(source, compressed, checkpoint)
            try checkSource(); try checkpoint()
            try compressed?.verifyDigest(check: checkpoint)
            return result
        } catch { try checkSource(); throw error }
    }

    private func writeFile(_ record: TARRecord, into output: Int32, relative: String, device: Int32?,
        source: PinnedLocalFileSource, compressed: TARCompressedSpoolLease?, written: inout UInt64,
        nodeURL: URL? = nil, publicTARFile: Bool = false, check: () throws -> Void,
        progress: (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        let before = try ArchiveProducedFacts.receipt(output, relative: relative, hash: nil,
            expectedQuarantineSHA256: expectedQuarantineSHA256)
        guard before.kind == S_IFREG, before.size == 0, device.map({ $0 == before.device }) != false else {
            throw FileOperationFailure.destinationChanged
        }
        let publicMark: OSManagedQuarantineCandidate.Witness?
        if let publicSource = security.publicWitness, let nodeURL {
            publicMark = try OSManagedQuarantineCandidate.prepareExtractedTreeNode(output,
                at: nodeURL, source: publicSource, archive: source.descriptor, at: source.url)
        } else {
            guard security.publicWitness == nil, nodeURL == nil else { throw FileOperationFailure.invalidRequest }
            publicMark = nil
        }
        var offset: UInt64 = 0, hash = SHA256()
        while offset < record.bytes {
            try check()
            let count = Int(min(65_536, record.bytes - offset))
            let data = try compressed?.read(record.dataOffset + offset, count, check: check)
                ?? source.read(record.dataOffset + offset, count, maximum: 65_536, check: check)
            try hooks.beforeWrite?(record.path)
            try data.withUnsafeBytes { bytes in
                var completed = 0
                while completed < bytes.count {
                    try check()
                    if let limit = hooks.failAfterBytes, written >= limit { throw ArchiveProducedFacts.failure(hooks.failureErrno) }
                    let amount = min(bytes.count - completed, max(1, hooks.writeChunk))
                    let result = pwrite(output, bytes.baseAddress!.advanced(by: completed), amount, off_t(offset) + off_t(completed))
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw ArchiveProducedFacts.failure() }
                    completed += result; written += UInt64(result); progress(UInt64(result), 0)
                }
                hash.update(bufferPointer: bytes)
            }
            offset += UInt64(data.count)
        }
        guard fchmod(output, 0o644) == 0 else { throw ArchiveProducedFacts.failure() }
        try hooks.beforeSecurityWrite?(record.path, output)
        if case .exact(let exact) = security { try exact.apply(to: output) }
        if let nodeURL { try publicMark?.require(output, at: nodeURL) }
        try hooks.afterSecurityWriteBeforeReceipt?(record.path, output)
        let after = try ArchiveProducedFacts.receipt(output, relative: relative, hash: Data(hash.finalize()),
            expectedQuarantineSHA256: expectedQuarantineSHA256)
        guard ArchiveProducedFacts.sameObject(before, after), after.size == Int64(record.bytes) else {
            throw FileOperationFailure.destinationChanged
        }
        if publicTARFile {
            guard let publicMark else { throw FileOperationFailure.invalidRequest }
            return ArchiveProducedNode(relative: after.relative, device: after.device, inode: after.inode,
                kind: after.kind, birthSeconds: after.birthSeconds, birthNanoseconds: after.birthNanoseconds,
                changedSeconds: after.changedSeconds, changedNanoseconds: after.changedNanoseconds,
                size: after.size, contentSHA256: after.contentSHA256,
                publicTARExtractionMarkRequired: publicMark.markRequired)
        }
        return after
    }

    func produceRootFile(into destination: Int32, at publicStage: URL? = nil,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        guard !publicQuarantineTree, publicQuarantineFile == (publicStage != nil),
              files.count == 1, let record = files.first?.record else {
            throw TARArchiveFailure.invalidSelection
        }
        let receipt = try withSource(check: check) { source, compressed, checkpoint in
            var written: UInt64 = 0
            let receipt = try writeFile(record, into: destination, relative: "", device: nil, source: source,
                compressed: compressed, written: &written, nodeURL: publicStage,
                publicTARFile: publicQuarantineFile, check: checkpoint, progress: progress)
            guard written == preview.logicalBytes else { throw FileOperationFailure.copyContentMismatch }
            return receipt
        }
        progress(0, 1); return receipt
    }

    func produce(in directory: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        guard !publicQuarantineTree else { throw FileOperationFailure.invalidRequest }
        return try withSource(check: check) { source, compressed, checkpoint in
            try produceDirectory(in: directory, privateStage: nil, source: source, compressed: compressed,
                checkpoint: checkpoint, progress: progress)
        }
    }
    func produce(in directory: Int32, at privateStage: URL, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        guard publicQuarantineTree else { throw FileOperationFailure.invalidRequest }
        return try withSource(check: check) { source, compressed, checkpoint in
            try produceDirectory(in: directory, privateStage: privateStage, source: source,
                compressed: compressed, checkpoint: checkpoint, progress: progress)
        }
    }

    private func produceDirectory(in directory: Int32, privateStage: URL?, source: PinnedLocalFileSource,
        compressed: TARCompressedSpoolLease?, checkpoint: () throws -> Void,
        progress: (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        guard (privateStage != nil) == (security.publicWitness != nil) else {
            throw FileOperationFailure.invalidRequest
        }
        let root=try ArchiveProducedFacts.receipt(directory,relative:"",hash:nil,
            expectedQuarantineSHA256:expectedQuarantineSHA256)
        guard root.kind==S_IFDIR,try ArchiveProducedFacts.empty(directory)else{throw FileOperationFailure.destinationChanged}
        var publicMarks: [String: OSManagedQuarantineCandidate.Witness] = [:]
        func nodeURL(_ relative: String) -> URL? {
            guard let privateStage else { return nil }
            return relative.isEmpty ? privateStage : URL(fileURLWithPath: privateStage.path + "/" + relative)
        }
        if let publicSource = security.publicWitness, let privateStage {
            publicMarks[""] = try OSManagedQuarantineCandidate.prepareExtractedTreeNode(directory,
                at: privateStage, source: publicSource, archive: source.descriptor, at: source.url)
        }
        var directories:[String:ArchiveProducedNode]=["":root],produced=[ArchiveProducedNode](),written:UInt64=0
        func openDirectory(_ components:ArraySlice<String>)throws->Int32{
            var descriptor=dup(directory),relative="";guard descriptor>=0 else{throw ArchiveProducedFacts.failure()}
            do{
                for component in components{
                    try checkpoint();relative=relative.isEmpty ? component:relative+"/"+component
                    let known=directories[relative]
                    if known==nil{guard directories.count+produced.count<20_000,mkdirat(descriptor,component,0o700)==0 else{throw ArchiveProducedFacts.failure()}}
                    let child=openat(descriptor,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                    guard child>=0 else{throw ArchiveProducedFacts.failure()}
                    do{
                        if known == nil, let publicSource = security.publicWitness, let path = nodeURL(relative) {
                            publicMarks[relative] = try OSManagedQuarantineCandidate.prepareExtractedTreeNode(child,
                                at: path, source: publicSource, archive: source.descriptor, at: source.url)
                        }
                        let node=try ArchiveProducedFacts.receipt(child,relative:relative,hash:nil,
                            expectedQuarantineSHA256:expectedQuarantineSHA256);var linked=stat()
                        guard node.kind==S_IFDIR,node.device==root.device,fstatat(descriptor,component,&linked,AT_SYMLINK_NOFOLLOW)==0,
                              linked.st_dev==node.device,linked.st_ino==node.inode,known.map({ArchiveProducedFacts.sameObject($0,node)}) ?? true else{throw FileOperationFailure.destinationChanged}
                        directories[relative]=node
                    }catch{close(child);throw error}
                    close(descriptor);descriptor=child
                }
                return descriptor
            }catch{close(descriptor);throw error}
        }
        for path in folders{let descriptor=try openDirectory(path.split(separator:"/").map(String.init)[...]);close(descriptor)}
        for file in files{
            try checkpoint();let parts=file.path.split(separator:"/").map(String.init)
            guard let name=parts.last else{throw TARArchiveFailure.unsafeName}
            let parent=try openDirectory(parts.dropLast());defer{close(parent)}
            let output=openat(parent,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard output>=0 else{throw ArchiveProducedFacts.failure()};defer{close(output)}
            let node = try writeFile(file.record, into: output, relative: file.path, device: root.device,
                source: source, compressed: compressed, written: &written, nodeURL: nodeURL(file.path),
                check: checkpoint, progress: progress)
            var linked = stat()
            guard fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW)==0,
                  linked.st_dev==node.device,linked.st_ino==node.inode else{throw FileOperationFailure.destinationChanged}
            produced.append(node);progress(0,1)
        }
        for path in directories.keys.sorted(by:{$0.utf8.count>$1.utf8.count}){
            try checkpoint();let descriptor=try openDirectory(path.isEmpty ? []:path.split(separator:"/").map(String.init)[...]);defer{close(descriptor)}
            guard fchmod(descriptor,0o755)==0 else{throw ArchiveProducedFacts.failure()}
            try hooks.beforeSecurityWrite?(path,descriptor)
            if case .exact(let exact) = security { try exact.apply(to: descriptor) }
            if let url = nodeURL(path) {
                guard let mark = publicMarks[path] else { throw FileOperationFailure.destinationChanged }
                try mark.require(descriptor, at: url)
            }
            try hooks.afterSecurityWriteBeforeReceipt?(path,descriptor)
            directories[path]=try ArchiveProducedFacts.receipt(descriptor,relative:path,hash:nil,
                expectedQuarantineSHA256:expectedQuarantineSHA256)
        }
        guard written==preview.logicalBytes,produced.count==preview.files,directories.count==preview.folders+1 else{throw FileOperationFailure.copyContentMismatch}
        return Array(directories.values)+produced
    }
    private static func exactSecurity(_ source:PinnedLocalFileSource,
        hooks:TARProductionHooks)throws->ZIPSourceSecurity.ExtractionWitness{
        let value=try ZIPSourceSecurity.extractionWitness(source.descriptor,url:source.url,allowingInheritance:hooks.inheritsQuarantine)
        try source.validate();return value
    }
    private static func security(_ source: PinnedLocalFileSource, hooks: TARProductionHooks,
        publicQuarantine: Bool) throws -> Security {
        if publicQuarantine {
            let witness = try OSManagedQuarantineCandidate.observeExtractionSource(source.descriptor, at: source.url)
            try source.validate()
            return .publicProperties(witness)
        }
        return .exact(try exactSecurity(source, hooks: hooks))
    }
}

private final class PreparedTARFile: PublicQuarantineTARExtractionFileProducer, Sendable {
    let preview: ArchiveProductionPreview
    let archiveSourceURL: URL
    private let archive: PreparedTARDirectory

    init(_ selection: TARExtractionSelection, check: @Sendable () throws -> Void,
        publicQuarantineFile: Bool = false) throws {
        guard selection.singleFileName != nil else { throw TARArchiveFailure.invalidSelection }
        archiveSourceURL = selection.archiveURL
        archive = try PreparedTARDirectory(selection.binding.source, selection: selection, check: check,
            publicQuarantineFile: publicQuarantineFile)
        guard archive.preview.files == 1 else { throw TARArchiveFailure.invalidSelection }
        preview = .init(files: 1, folders: 0, logicalBytes: archive.preview.logicalBytes,
            longestPathBytes: 0, largestFileBytes: archive.preview.largestFileBytes)
    }
    func validate(check: @Sendable () throws -> Void) throws { try archive.validate(check: check) }
    func produce(into destination: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try archive.produceRootFile(into: destination, check: check, progress: progress)
    }
    func producePublicExtracted(into destination: Int32, at stageURL: URL,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try archive.produceRootFile(into: destination, at: stageURL, check: check, progress: progress)
    }
    func finished() { archive.finished() }
}

extension RecoverableFileOperations {
    public func prepareTARFileExtraction(_ selection: TARExtractionSelection, parent: URL, name: String,
        observing destination: FileOperationSelection) async throws -> ReceivedFilePlan {
        try await prepareReceivedFile(parent: parent, name: name, observing: destination, origin: .tarExtraction) { check in
            try PreparedTARFile(selection, check: check)
        }
    }

    public func prepareTARFilePublicExtraction(_ selection: TARExtractionSelection, parent: URL, name: String,
        observing destination: FileOperationSelection) async throws -> ReceivedFilePlan {
        guard selection.singleFileName != nil else { throw TARArchiveFailure.invalidSelection }
        return try await prepareReceivedFile(parent: parent, name: name, observing: destination,
            origin: .tarExtraction, publicTARExtractionV17: true, archiveSource: selection.archiveURL) { check in
            try PreparedTARFile(selection, check: check, publicQuarantineFile: true)
        }
    }

    public func prepareTARExtraction(source:URL,parent:URL,name:String,observing selection:FileOperationSelection,
                                     members:TARExtractionSelection,observingParent expectedParent:FileOperationSelection?=nil,
                                     directly: Bool = false,
                                     publicQuarantineTreeV16: Bool = false)async throws->ArchiveExtractionPlan{
        try await prepareArchiveExtraction(source:source,parent:parent,name:name,observing:selection,
            observingParent:expectedParent,format:.tar,publicQuarantineTreeV16:publicQuarantineTreeV16){check in
            try PreparedTARDirectory(source,selection:members,exportingFolder:directly,check:check,
                publicQuarantineTree:publicQuarantineTreeV16)
        }
    }
}
