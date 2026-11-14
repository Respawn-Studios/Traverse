import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

public enum ZIPExtractionFailure: Error, Equatable, Sendable {
    case quarantinedOrUncertain, unsupportedSource, destinationChanged
}
internal struct ZIPProductionHooks: Sendable {
    var writeChunk = 65_536
    var failAfterBytes: UInt64?
    var failureErrno: Int32 = ENOSPC
    var beforeWrite: (@Sendable (String) throws -> Void)?
    var inheritsQuarantine = true // Exact inheritance; never removal/approval.
    var beforeSecurityWrite: (@Sendable (String, Int32) throws -> Void)?
    var afterSecurityWriteBeforeReceipt: (@Sendable (String, Int32) throws -> Void)?
}

/// Metadata and exact source stamp only; no fd or payload survives preparation.
/// This concrete producer is invoked exclusively by the recoverable worker.
internal final class PreparedZIPDirectory: PublicQuarantineTreeProducerV16, Sendable {
    private enum Security: Equatable, Sendable {
        case exact(ZIPSourceSecurity.ExtractionWitness)
        case publicProperties(OSManagedQuarantineCandidate.ExtractionSourceWitness)
        var exactDigest: Data? {
            if case .exact(let witness) = self { return witness.expectedQuarantineSHA256 }
            return nil
        }
    }
    let preview: ArchiveProductionPreview
    var publicProducedTreeV16: PublicProducedTreePurposeV16? {
        guard publicQuarantineTree, case .publicProperties(let witness) = security else { return nil }
        return .zipExtraction(sourceMarked: witness.marked)
    }
    private let url: URL
    private let observed: ZIPSourceFile.Stamp
    private let layout: ZIPContentVerifier.Layout
    private let limits: ZIPContentLimits
    private let hooks: ZIPProductionHooks
    private let security: Security
    private let expectedQuarantineSHA256: Data?
    private let publicQuarantineTree: Bool
    init(_ url: URL, selection: ZIPExtractionSelection? = nil, exporting root: ZIPExtractionSelection.Root? = nil,
        check: @Sendable () throws -> Void, hooks: ZIPProductionHooks = .init(),
        publicQuarantineFile: Bool = false, publicQuarantineTree: Bool = false) throws {
        try check()
        guard !publicQuarantineFile || !publicQuarantineTree else { throw FileOperationFailure.invalidRequest }
        if publicQuarantineFile {
            guard root?.kind == .file, selection?.roots.count == 1 else { throw ZIPArchiveFailure.invalidFolder }
        }
        let source = try ZIPSourceFile(url)
        if let selection {
            guard selection.source.path == source.url.path, selection.stamp == source.observed else { throw FileOperationFailure.sourceChanged }
        }
        let security = try Self.securityWitness(source, hooks: hooks,
            publicQuarantine: publicQuarantineFile || publicQuarantineTree)
        let started = ProcessInfo.processInfo.systemUptime, limits = ZIPContentLimits()
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < limits.seconds else { throw ZIPContentFailure.limitReached }
        }
        var readLimits = ZIPReadLimits(); readLimits.members = 20_000; readLimits.nodes = 20_000; readLimits.depth = 63
        var records: [ZIPPayloadRecord] = []
        let storage = try ZIPMetadataParser.parse(length: UInt64(source.observed.size), limits: readLimits,
            capture: { records.append($0) }, cancelled: { (try? checkpoint()) == nil },
            read: { try source.read($0, $1, maximum: max(readLimits.centralBytes, 65_557), check: checkpoint) })
        guard storage.summary.caseConflicts == 0,
              storage.nodes.allSatisfy({ $0.name.utf8.count <= 255 }) else { throw ZIPArchiveFailure.ambiguousNames }
        let fullLayout = try ZIPContentVerifier.prepare(records, limits: limits, check: checkpoint,
            read: { try source.read($0, $1, maximum: max(readLimits.centralBytes, 65_557), check: checkpoint) })
        let selected = try selection.map { try Self.selectedLayout($0, full: fullLayout, check: checkpoint) } ?? fullLayout
        let layout: ZIPContentVerifier.Layout
        if let root {
            guard let selection, selection.roots.count == 1, selection.roots[0].path == root.path,
                  selection.roots[0].kind == root.kind else { throw ZIPArchiveFailure.invalidFolder }
            layout = try Self.rootedLayout(root, selected: selected, check: checkpoint)
        } else { layout = selected }
        try source.validate(); guard try Self.securityWitness(source, hooks: hooks,
            publicQuarantine: publicQuarantineFile || publicQuarantineTree) == security else { throw FileOperationFailure.sourceChanged }; try checkpoint()
        self.url = url; observed = source.observed; self.layout = layout; self.limits = limits; self.hooks = hooks; self.security = security
        self.publicQuarantineTree = publicQuarantineTree
        expectedQuarantineSHA256 = security.exactDigest
        preview = .init(files: layout.files, folders: selection == nil ? storage.summary.folders : layout.folders, logicalBytes: layout.logical,
            longestPathBytes: layout.extents.map { $0.record.name.utf8.count }.max() ?? 0)
    }
    /// All archive headers/extents have already been validated against their
    /// original names. Rebase only publication names, never source offsets or
    /// the bytes/CRC/security witnesses used to read the archive.
    private static func rootedLayout(_ root: ZIPExtractionSelection.Root, selected: ZIPContentVerifier.Layout,
        check: () throws -> Void) throws -> ZIPContentVerifier.Layout {
        guard root.kind == .file || root.kind == .directory else { throw ZIPArchiveFailure.unsupported }
        var extents: [ZIPPayloadExtent] = [], folders = Set<String>()
        for extent in selected.extents {
            try check()
            let record = extent.record, path = record.name.hasSuffix("/") ? String(record.name.dropLast()) : record.name
            let name: String
            if root.kind == .directory, path == root.path {
                // Keep this extent so even a zero-byte directory stream/CRC
                // is checked. Its publication target is the staging root.
                guard record.kind == .directory else { throw ZIPArchiveFailure.invalidFolder }
                name = ""
            } else if root.kind == .file {
                guard path == root.path, record.kind == .file else { throw ZIPArchiveFailure.invalidFolder }
                name = String(path.split(separator: "/").last!)
            } else {
                guard path.hasPrefix(root.path + "/") else { throw ZIPArchiveFailure.invalidFolder }
                name = String(record.name.dropFirst(root.path.count + 1))
            }
            let parts = name.split(separator: "/").map(String.init)
            var prefix = ""
            for part in (record.kind == .directory ? parts[...] : parts.dropLast()) {
                prefix = prefix.isEmpty ? part : prefix + "/" + part; folders.insert(prefix)
            }
            let renamed = ZIPPayloadRecord(name: name, rawName: record.rawName, kind: record.kind, flags: record.flags,
                method: record.method, crc: record.crc, logical: record.logical, packed: record.packed,
                localOffset: record.localOffset, centralOffset: record.centralOffset, usesZIP64: record.usesZIP64)
            extents.append(.init(record: renamed, payload: extent.payload, end: extent.end))
        }
        guard root.kind != .file || (extents.count == 1 && selected.files == 1 && folders.isEmpty) else {
            throw ZIPArchiveFailure.invalidFolder
        }
        return .init(extents: extents, logical: selected.logical, packed: selected.packed, files: selected.files, folders: folders.count)
    }
    private static func selectedLayout(_ selection: ZIPExtractionSelection, full: ZIPContentVerifier.Layout,
                                       check: () throws -> Void) throws -> ZIPContentVerifier.Layout {
        guard !selection.roots.isEmpty, selection.roots.count <= 1_024 else { throw ZIPArchiveFailure.invalidFolder }
        let requested = Dictionary(selection.roots.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
        guard requested.count == selection.roots.count else { throw ZIPArchiveFailure.invalidFolder }
        let directories = Set(selection.roots.filter { $0.kind == .directory }.map(\.path))
        var found = Set<String>(), outputFolders = Set<String>(), extents: [ZIPPayloadExtent] = []
        var logical: UInt64 = 0, packed: UInt64 = 0, files = 0
        for extent in full.extents {
            try check()
            let record = extent.record, path = record.name.hasSuffix("/") ? String(record.name.dropLast()) : record.name
            var included = requested[path] != nil, prefix = ""
            let parts = path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                let kind: ZIPMemberKind = index == parts.count - 1 ? record.kind : .directory
                if let expected = requested[prefix] {
                    guard expected == kind else { throw ZIPArchiveFailure.invalidFolder }; found.insert(prefix)
                }
                if directories.contains(prefix) { included = true }
            }
            if included {
                prefix = ""
                for part in (record.kind == .directory ? parts[...] : parts.dropLast()) {
                    prefix = prefix.isEmpty ? part : prefix + "/" + part; outputFolders.insert(prefix)
                }
                extents.append(extent); logical += record.logical; packed += record.packed
                if record.kind == .file { files += 1 }
            }
        }
        guard found.count == requested.count, !extents.isEmpty else { throw ZIPArchiveFailure.invalidFolder }
        return .init(extents: extents, logical: logical, packed: packed, files: files, folders: outputFolders.count)
    }
    func validate(check: @Sendable () throws -> Void) throws {
        try check(); let source = try ZIPSourceFile(url)
        guard source.observed == observed else { throw FileOperationFailure.sourceChanged }
        try requireSecurity(source)
        try source.validate(); try check()
    }
    func produceRootFile(into output: Int32, at publicStage: URL? = nil, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try check()
        guard layout.extents.count == 1, layout.files == 1, layout.folders == 0,
              let extent = layout.extents.first, extent.record.kind == .file else { throw ZIPArchiveFailure.invalidFolder }
        let source = try ZIPSourceFile(url)
        guard source.observed == observed else {
            throw FileOperationFailure.sourceChanged
        }
        try requireSecurity(source)
        let publicWitness: OSManagedQuarantineCandidate.Witness?
        if let publicStage, case .publicProperties = security {
            publicWitness = try OSManagedQuarantineCandidate.prepareExtractedStage(output, at: publicStage,
                from: source.descriptor, at: source.url)
        } else {
            guard publicStage == nil, case .exact = security else { throw FileOperationFailure.invalidRequest }
            publicWitness = nil
        }
        let before = try Self.receipt(output, relative: "", hash: nil,
            expectedQuarantineSHA256: expectedQuarantineSHA256)
        guard before.kind == S_IFREG, before.size == 0 else { throw ZIPExtractionFailure.destinationChanged }
        let started = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < limits.seconds else { throw ZIPContentFailure.limitReached }
        }
        var produced: UInt64 = 0, hash = SHA256()
        do {
            let record = extent.record
            try ZIPContentDecoder.check(method: record.method, packed: record.packed, logical: record.logical, expectedCRC: record.crc,
                check: checkpoint, read: { try source.read(extent.payload + $0, $1, maximum: 65_536, check: checkpoint) },
                decoded: { count in
                    guard count <= limits.jobBytes - produced else { throw ZIPContentFailure.limitReached }
                    produced += count; progress(count, 0)
                }, consume: { bytes in
                    try hooks.beforeWrite?(record.name)
                    var offset = 0
                    while offset < bytes.count {
                        try checkpoint()
                        if let limit = hooks.failAfterBytes, produced + UInt64(offset) >= limit { throw Self.failure(hooks.failureErrno) }
                        let count = min(bytes.count - offset, max(1, hooks.writeChunk))
                        let written = pwrite(output, bytes.baseAddress!.advanced(by: offset), count, off_t(produced) + off_t(offset))
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw Self.failure() }; offset += written
                    }
                    hash.update(bufferPointer: bytes)
                })
            guard produced == preview.logicalBytes else { throw FileOperationFailure.copyContentMismatch }
            guard fchmod(output, 0o644) == 0 else { throw Self.failure() }
            try hooks.beforeSecurityWrite?(record.name, output)
            if case .exact(let witness) = security { try witness.apply(to: output) }
            try hooks.afterSecurityWriteBeforeReceipt?(record.name, output)
            try source.validate()
            try requireSecurity(source)
            if let publicWitness, let publicStage { try publicWitness.require(output, at: publicStage) }
            try checkpoint()
            let after = try Self.receipt(output, relative: "", hash: Data(hash.finalize()),
                expectedQuarantineSHA256: expectedQuarantineSHA256,
                publicZIPExtractionMarkRequired: publicWitness?.markRequired)
            guard Self.sameObject(before, after), after.size == record.logical else { throw ZIPExtractionFailure.destinationChanged }
            progress(0, 1); return after
        } catch {
            try source.validate()
            try requireSecurity(source)
            throw error
        }
    }
    func produce(in directory: Int32, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        try produce(in: directory, privateStage: nil, check: check, progress: progress)
    }
    func produce(in directory: Int32, at privateStage: URL, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        guard publicQuarantineTree else { throw FileOperationFailure.invalidRequest }
        return try produce(in: directory, privateStage: privateStage, check: check, progress: progress)
    }
    private func produce(in directory: Int32, privateStage: URL?, check: @Sendable () throws -> Void,
                         progress: @Sendable (UInt64, Int) -> Void) throws -> [ArchiveProducedNode] {
        try check()
        let source = try ZIPSourceFile(url)
        guard source.observed == observed else { throw FileOperationFailure.sourceChanged }
        let exactSecurity: ZIPSourceSecurity.ExtractionWitness?
        let publicSource: OSManagedQuarantineCandidate.ExtractionSourceWitness?
        switch security {
        case .exact(let witness):
            guard privateStage == nil else { throw FileOperationFailure.invalidRequest }
            exactSecurity = witness; publicSource = nil
        case .publicProperties(let witness):
            guard privateStage != nil, publicQuarantineTree else { throw FileOperationFailure.invalidRequest }
            exactSecurity = nil; publicSource = witness
        }
        try requireSecurity(source)
        let started = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < limits.seconds else { throw ZIPContentFailure.limitReached }
        }
        let root = try Self.receipt(directory, relative: "", hash: nil,
            expectedQuarantineSHA256: expectedQuarantineSHA256)
        guard root.kind == S_IFDIR, root.device != 0, try Self.empty(directory) else { throw ZIPExtractionFailure.destinationChanged }
        var publicMarks: [String: OSManagedQuarantineCandidate.Witness] = [:]
        func nodeURL(_ relative: String) -> URL? {
            guard let privateStage else { return nil }
            return relative.isEmpty ? privateStage : URL(fileURLWithPath: privateStage.path + "/" + relative)
        }
        if let publicSource, let privateStage {
            publicMarks[""] = try OSManagedQuarantineCandidate.prepareExtractedTreeNode(directory,
                at: privateStage, source: publicSource, archive: source.descriptor, at: source.url)
        }
        var directories: [String: ArchiveProducedNode] = ["": root], files: [ArchiveProducedNode] = []
        func openDirectory(_ components: ArraySlice<String>) throws -> Int32 {
            var descriptor = dup(directory), relative = ""
            guard descriptor >= 0 else { throw Self.failure() }
            do {
                for component in components {
                    try checkpoint(); relative = relative.isEmpty ? component : relative + "/" + component
                    let known = directories[relative]
                    if known == nil {
                        guard directories.count + files.count < 20_000,
                              mkdirat(descriptor, component, 0o700) == 0 else { throw Self.failure() }
                    }
                    let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Self.failure() }
                    let node: ArchiveProducedNode
                    do {
                        if known == nil, let publicSource, let path = nodeURL(relative) {
                            publicMarks[relative] = try OSManagedQuarantineCandidate.prepareExtractedTreeNode(child,
                                at: path, source: publicSource, archive: source.descriptor, at: source.url)
                        }
                        node = try Self.receipt(child, relative: relative, hash: nil,
                            expectedQuarantineSHA256: expectedQuarantineSHA256)
                        var linked = stat()
                        guard node.kind == S_IFDIR, node.device == root.device,
                              fstatat(descriptor, component, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                              linked.st_dev == node.device, linked.st_ino == node.inode,
                              known.map({ Self.sameObject($0, node) }) ?? true else { throw ZIPExtractionFailure.destinationChanged }
                    } catch { close(child); throw error }
                    directories[relative] = node; close(descriptor); descriptor = child
                }
                return descriptor
            } catch { close(descriptor); throw error }
        }
        var produced: UInt64 = 0
        do {
            for extent in layout.extents {
                try checkpoint()
                let record = extent.record, parts = record.name.split(separator: "/").map(String.init)
                let parent = try openDirectory(record.kind == .directory ? parts[...] : parts.dropLast())
                defer { close(parent) }
                var hash = SHA256()
                let output: Int32
                if record.kind == .file {
                    guard let name = parts.last else { throw ZIPArchiveFailure.unsafeName }
                    output = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard output >= 0 else { throw Self.failure() }
                    do {
                        let created = try Self.receipt(output, relative: record.name, hash: Data(),
                            expectedQuarantineSHA256: expectedQuarantineSHA256)
                        guard created.kind == S_IFREG, created.device == root.device else { throw ZIPExtractionFailure.destinationChanged }
                        if let publicSource, let path = nodeURL(record.name) {
                            publicMarks[record.name] = try OSManagedQuarantineCandidate.prepareExtractedTreeNode(output,
                                at: path, source: publicSource, archive: source.descriptor, at: source.url)
                        }
                    } catch { close(output); throw error }
                } else { output = -1 }
                defer { if output >= 0 { close(output) } }
                try ZIPContentDecoder.check(method: record.method, packed: record.packed, logical: record.logical, expectedCRC: record.crc,
                    check: checkpoint, read: { try source.read(extent.payload + $0, $1, maximum: 65_536, check: checkpoint) },
                    decoded: { count in
                        guard count <= limits.jobBytes - produced else { throw ZIPContentFailure.limitReached }
                        produced += count; progress(count, 0)
                    }, consume: { bytes in
                        guard output >= 0 else { throw ZIPContentFailure.contentMismatch }
                        try hooks.beforeWrite?(record.name)
                        var offset = 0
                        while offset < bytes.count {
                            try checkpoint()
                            if let limit = hooks.failAfterBytes, produced + UInt64(offset) >= limit { throw Self.failure(hooks.failureErrno) }
                            let count = min(bytes.count - offset, max(1, hooks.writeChunk))
                            let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count)
                            if written < 0 && errno == EINTR { continue }
                            guard written > 0 else { throw Self.failure() }
                            offset += written
                        }
                        hash.update(bufferPointer: bytes)
                    })
                if output >= 0 {
                    guard fchmod(output, 0o644) == 0 else { throw Self.failure() }
                    try hooks.beforeSecurityWrite?(record.name, output)
                    try exactSecurity?.apply(to: output)
                    if let path = nodeURL(record.name) {
                        guard let mark = publicMarks[record.name] else { throw ZIPExtractionFailure.destinationChanged }
                        try mark.require(output, at: path)
                    }
                    try hooks.afterSecurityWriteBeforeReceipt?(record.name, output)
                    let node = try Self.receipt(output, relative: record.name, hash: Data(hash.finalize()),
                        expectedQuarantineSHA256: expectedQuarantineSHA256)
                    guard node.size == record.logical else { throw FileOperationFailure.copyContentMismatch }
                    var linked = stat()
                    guard fstatat(parent, parts.last!, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                          linked.st_dev == node.device, linked.st_ino == node.inode else { throw ZIPExtractionFailure.destinationChanged }
                    files.append(node)
                }
                if !record.name.isEmpty { progress(0, 1) }
            }
            for path in directories.keys.sorted(by: { $0.utf8.count > $1.utf8.count }) {
                try checkpoint()
                let descriptor = try openDirectory(path.isEmpty ? [] : path.split(separator: "/").map(String.init)[...])
                defer { close(descriptor) }
                guard fchmod(descriptor, 0o755) == 0 else { throw Self.failure() }
                try hooks.beforeSecurityWrite?(path, descriptor)
                try exactSecurity?.apply(to: descriptor)
                if let nodeURL = nodeURL(path) {
                    guard let mark = publicMarks[path] else { throw ZIPExtractionFailure.destinationChanged }
                    try mark.require(descriptor, at: nodeURL)
                }
                try hooks.afterSecurityWriteBeforeReceipt?(path, descriptor)
                directories[path] = try Self.receipt(descriptor, relative: path, hash: nil,
                    expectedQuarantineSHA256: expectedQuarantineSHA256)
            }
            try source.validate(); try requireSecurity(source); try checkpoint()
        } catch {
            try source.validate(); try requireSecurity(source); throw error
        }
        guard produced == layout.logical, files.count == preview.files, directories.count == preview.folders + 1 else { throw ZIPContentFailure.contentMismatch }
        return Array(directories.values) + files
    }
    private func requireSecurity(_ source: ZIPSourceFile) throws {
        let current = try Self.securityWitness(source, hooks: hooks,
            publicQuarantine: { if case .publicProperties = security { return true }; return false }())
        guard current == security else { throw FileOperationFailure.sourceChanged }
    }
    private static func securityWitness(_ source: ZIPSourceFile, hooks: ZIPProductionHooks,
        publicQuarantine: Bool) throws -> Security {
        let witness: Security = publicQuarantine
            ? .publicProperties(try OSManagedQuarantineCandidate.observeExtractionSource(source.descriptor, at: source.url))
            : .exact(try ZIPSourceSecurity.extractionWitness(source.descriptor, url: source.url,
                allowingInheritance: hooks.inheritsQuarantine))
        try source.validate()
        return witness
    }
    private static func receipt(_ descriptor: Int32, relative: String, hash: Data?,
        expectedQuarantineSHA256: Data?, publicZIPExtractionMarkRequired: Bool? = nil) throws -> ArchiveProducedNode {
        var facts = stat()
        guard fstat(descriptor, &facts) == 0, facts.st_uid == geteuid(), facts.st_dev != 0,
              [S_IFREG, S_IFDIR].contains(facts.st_mode & S_IFMT), facts.st_mode & S_IFMT != S_IFREG || facts.st_nlink == 1 else { throw ZIPExtractionFailure.destinationChanged }
        return .init(relative: relative, device: facts.st_dev, inode: facts.st_ino, kind: facts.st_mode & S_IFMT,
            birthSeconds: facts.st_birthtimespec.tv_sec, birthNanoseconds: facts.st_birthtimespec.tv_nsec,
            changedSeconds: facts.st_ctimespec.tv_sec, changedNanoseconds: facts.st_ctimespec.tv_nsec,
            size: facts.st_size, contentSHA256: hash, expectedQuarantineSHA256: expectedQuarantineSHA256,
            publicZIPExtractionMarkRequired: publicZIPExtractionMarkRequired)
    }
    private static func sameObject(_ a: ArchiveProducedNode, _ b: ArchiveProducedNode) -> Bool {
        a.device == b.device && a.inode == b.inode && a.kind == b.kind && a.birthSeconds == b.birthSeconds && a.birthNanoseconds == b.birthNanoseconds
    }
    private static func empty(_ descriptor: Int32) throws -> Bool {
        let copied = dup(descriptor); guard copied >= 0 else { throw failure() }
        guard let directory = fdopendir(copied) else { close(copied); throw failure() }; defer { closedir(directory) }
        rewinddir(directory)
        while true {
            errno = 0
            guard let entry = readdir(directory) else { guard errno == 0 else { throw failure() }; return true }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { return false }
        }
    }
    private static func failure(_ value: Int32 = errno) -> FileOperationFailure {
        switch value {
        case EEXIST, ENOTEMPTY: .conflict
        case EACCES, EPERM, EROFS: .accessDenied
        case ENOSPC: .outOfSpace
        case EDQUOT: .quotaExceeded
        case ENOENT, ENODEV, ENXIO, ESTALE: .unavailable
        default: .ioFailure
        }
    }
}

extension RecoverableFileOperations {
    public func prepareZIPExtraction(source: URL, parent: URL, name: String,
                                     observing selection: FileOperationSelection, members: ZIPExtractionSelection? = nil,
                                     observingParent expectedParent: FileOperationSelection? = nil,
                                     publicQuarantineTreeV16: Bool = false) async throws -> ArchiveExtractionPlan {
        try await prepareArchiveExtraction(source: source, parent: parent, name: name, observing: selection,
            observingParent: expectedParent, format: .zip, publicQuarantineTreeV16: publicQuarantineTreeV16) { check in
            try PreparedZIPDirectory(source, selection: members, check: check, publicQuarantineTree: publicQuarantineTreeV16)
        }
    }
}
