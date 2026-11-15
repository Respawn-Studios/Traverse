import Foundation
@_spi(ArchiveProduction) import FileOperations

/// An immutable rewrite description, not an extracted filesystem tree. Source
/// records retain their raw metadata; only changed names/bodies get new headers.
internal struct TARMutationLayout: Sendable {
    enum Payload: Sendable { case archive(TARRecord), local(ZIPCreationInventory.Node), bytes(Data) }
    struct Entry: Sendable {
        var path: String
        let kind: TARMemberKind
        let payload: Payload
        var header: Data?
        let modification: ArchiveMemberModification?
        var bytes: UInt64 {
            switch payload { case .archive(let r): r.bytes; case .local(let n): n.stamp.directory ? 0 : UInt64(n.stamp.size); case .bytes(let d): UInt64(d.count) }
        }
        var metadataBytes: Int {
            if let header { return header.count }
            if case .archive(let record) = payload { return Int(record.dataOffset - (record.extensionOffset ?? record.headerOffset)) }
            return 0
        }
        var physicalRecords: Int {
            if let header { return [UInt8(120), UInt8(76)].contains(header[156]) ? 2 : 1 }
            if case .archive(let record) = payload { return record.extensionOffset == nil ? 1 : 2 }
            return 0
        }
    }
    let originalRecords: [TARRecord]
    var originals: [Entry?]
    var appended: [Entry] = []
    let endOffset: UInt64
    var additions: ZIPCreationInventory?
    var replacement: TARTextEditDocument?
    private var replacedAdditions = Set<Data>()
    private(set) var preview: ArchiveProductionPreview
    private let binding: TARSourceBinding
    private let preservedPhysicalRecords: Int
    var entries: [Entry] { originals.compactMap { $0 } + appended }

    init(_ mutation: TARMemberMutation, source: TARMutationSource, parsed: TARParsedDirectory,
        additionCollisions: ZIPMemberAdditionCollisionPolicy = .keepBoth, check: () throws -> Void) throws {
        originalRecords = parsed.records; endOffset = parsed.endOffset
        binding = mutation.binding
        preservedPhysicalRecords = parsed.physicalRecords - parsed.records.reduce(0) { $0 + ($1.extensionOffset == nil ? 1 : 2) }
        originals = parsed.records.map { .init(path: $0.path, kind: $0.kind, payload: .archive($0),
            header: nil, modification: $0.modification) }
        preview = .init(files: 0, folders: 0, logicalBytes: 0, longestPathBytes: 0)
        let catalog = try TARCatalogBuilder.build(parsed, check: check)
        guard catalog.summary.blockedMembers == 0 else { throw TARMemberEditFailure.unsupportedArchive }
        let namespace = try Self.namespace(parsed.records, check: check)
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try source.read(offset, count, check: check)
        }
        switch mutation {
        case .replace(let document, let contents):
            _ = try TARTextPreview.decode(contents.encoded, check: check)
            guard let index = parsed.records.firstIndex(where: { $0.path.utf8.elementsEqual(document.archivePath.utf8) }),
                  parsed.records[index].kind == .file,
                  parsed.records[index].headerOffset == document.selection.record.headerOffset,
                  parsed.records[index].bytes == document.selection.record.bytes else { throw FileOperationFailure.sourceChanged }
            let old = parsed.records[index]
            originals[index] = .init(path: old.path, kind: .file, payload: .bytes(contents.encoded),
                header: try TARMemberHeader.replacingSize(old, with: UInt64(contents.encoded.count), read: read),
                modification: old.modification)
            replacement = document
        case .rename(let selection, let name):
            try validate(selection, namespace: namespace)
            guard selection.roots.count == 1, let root = selection.roots.first else { throw TARArchiveFailure.invalidSelection }
            try Self.validateName(name)
            let target = Self.join(Self.parent(root.path), name)
            guard !target.utf8.elementsEqual(root.path.utf8) else { throw TARMemberEditFailure.invalidMemberName }
            try remap(selection.roots, targets: [target], duplicate: false, namespace: namespace, read: read, check: check)
        case .batchRename(let selection, let names):
            try validate(selection, namespace: namespace)
            guard selection.roots.count == names.count else { throw TARArchiveFailure.invalidSelection }
            var targets: [String] = []
            for (root, name) in zip(selection.roots, names) {
                try check(); try Self.validateName(name)
                targets.append(Self.join(Self.parent(root.path), name))
            }
            guard zip(selection.archivePaths, targets).contains(where: { !$0.utf8.elementsEqual($1.utf8) }) else {
                throw TARMemberEditFailure.invalidMemberName
            }
            try remap(selection.roots, targets: targets, duplicate: false, namespace: namespace, read: read, check: check)
        case .remove(let selection):
            try validate(selection, namespace: namespace)
            for index in originalRecords.indices {
                try check()
                if selection.roots.contains(where: { Self.covers($0.path, originalRecords[index].path) }) { originals[index] = nil }
            }
        case .duplicate(let selection, let destination):
            try validate(selection, namespace: namespace)
            if let destination { try validate(destination, namespace: namespace) }
            var targets: [String] = [], reservations: [String: ZIPNameReservations] = [:]
            let children = try Self.childrenIndex(namespace, check: check)
            for root in selection.roots {
                try check()
                let folder = destination?.virtualFolder ?? Self.parent(root.path)
                var names = reservations[folder] ?? ZIPNameReservations(children[folder] ?? [])
                let leaf = root.path.split(separator: "/").last.map(String.init) ?? ""
                let name = try names.name(for: leaf, isDirectory: root.kind == .directory,
                    keepOriginal: destination != nil, check: check)
                reservations[folder] = names; targets.append(Self.join(folder, name))
            }
            try remap(selection.roots, targets: targets, duplicate: true, namespace: namespace, read: read, check: check)
        case .move(let selection, let destination):
            try validate(selection, namespace: namespace); try validate(destination, namespace: namespace)
            for root in selection.roots {
                guard Self.parent(root.path) != destination.virtualFolder,
                      !Self.covers(root.path, destination.virtualFolder) else { throw TARMemberEditFailure.invalidDestination }
            }
            let targets = selection.roots.map { Self.join(destination.virtualFolder, $0.path.split(separator: "/").last.map(String.init) ?? "") }
            try remap(selection.roots, targets: targets, duplicate: false, namespace: namespace, read: read, check: check)
        case .newFile(let destination, let name), .newFolder(let destination, let name):
            try validate(destination, namespace: namespace); try Self.validateName(name)
            let folder: Bool = if case .newFolder = mutation { true } else { false }
            let path = Self.join(destination.virtualFolder, name)
            guard !namespace.keys.contains(where: { ZIPNameReservations.key($0) == ZIPNameReservations.key(path) }) else { throw TARMemberEditFailure.conflict }
            appended.append(try Self.empty(path, directory: folder, index: 0))
        case .add(let destination, let sources):
            try validate(destination, namespace: namespace)
            guard !sources.isEmpty, sources.count <= 511 else { throw TARArchiveFailure.invalidSelection }
            let inventory = try ZIPCreationInventory(sources, prefix: destination.virtualFolder,
                allowNativeMarkedSources: true,
                reserving: additionCollisions == .keepBoth ? Self.children(in: destination.virtualFolder, namespace: namespace) : nil,
                check: check)
            additions = inventory
            if additionCollisions != .keepBoth {
                var existing: [String: String] = [:], ambiguous = Set<String>()
                for path in namespace.keys {
                    try check(); let key = ZIPNameReservations.key(path)
                    if existing.updateValue(path, forKey: key) != nil { ambiguous.insert(key) }
                }
                for root in inventory.roots {
                    try check()
                    let key = ZIPNameReservations.key(root.archivePath)
                    guard let collision = existing[key] else { continue }
                    // Replace authorizes only an exact regular-file root. A
                    // directory, implicit tree or case variant never merges.
                    guard additionCollisions == .replaceFiles, !root.isDirectory, !ambiguous.contains(key),
                          collision.utf8.elementsEqual(root.archivePath.utf8), namespace[collision] == .file,
                          let index = originalRecords.firstIndex(where: { $0.path.utf8.elementsEqual(collision.utf8) }) else {
                        throw TARMemberEditFailure.conflict
                    }
                    originals[index] = nil; replacedAdditions.insert(Data(collision.utf8))
                }
            }
            for (index, node) in inventory.nodes.enumerated() {
                try check()
                let header = try TARCreationHeader(node, index: index)
                appended.append(.init(path: node.path, kind: node.stamp.directory ? .directory : .file,
                    payload: .local(node), header: header.encoded,
                    modification: .unix(header.modification.timeIntervalSince1970)))
            }
        case .group(let selection, let name):
            try validate(selection, namespace: namespace); try Self.validateName(name)
            guard let first = selection.roots.first,
                  selection.roots.allSatisfy({ Self.parent($0.path) == Self.parent(first.path) }) else {
                throw TARMemberEditFailure.invalidDestination
            }
            let folder = Self.join(Self.parent(first.path), name)
            guard !namespace.keys.contains(where: { ZIPNameReservations.key($0) == ZIPNameReservations.key(folder) }) else { throw TARMemberEditFailure.conflict }
            let targets = selection.roots.map { Self.join(folder, $0.path.split(separator: "/").last.map(String.init) ?? "") }
            try remap(selection.roots, targets: targets, duplicate: false, namespace: namespace, read: read, check: check)
            appended.append(try Self.empty(folder, directory: true, index: 0))
        }
        try finalize(check: check)
    }

    private func validate(_ selection: TARMemberSelection, namespace: [String: TARMemberKind]) throws {
        try validateBinding(selection.binding)
        guard (1...128).contains(selection.roots.count), Set(selection.archivePaths).count == selection.roots.count,
              selection.roots.allSatisfy({ !$0.path.isEmpty && namespace[$0.path] == $0.kind }),
              !selection.roots.enumerated().contains(where: { index, root in
                  selection.roots.enumerated().contains { $0.offset != index && Self.covers(root.path, $0.element.path) }
              }) else { throw TARArchiveFailure.invalidSelection }
    }
    private func validate(_ destination: TARMemberDestination, namespace: [String: TARMemberKind]) throws {
        try validateBinding(destination.binding)
        guard destination.virtualFolder.isEmpty || namespace[destination.virtualFolder] == .directory else {
            throw TARMemberEditFailure.invalidDestination
        }
    }
    private func validateBinding(_ value: TARSourceBinding) throws {
        // The writer separately binds its source stamp/witness. Both selected
        // source and destination must describe that same catalog generation.
        guard value.source == binding.source, value.stamp == binding.stamp,
              value.compressed?.digest == binding.compressed?.digest,
              value.witness == binding.witness else { throw FileOperationFailure.sourceChanged }
    }

    private mutating func remap(_ roots: [TARExtractionSelection.Root], targets: [String], duplicate: Bool,
        namespace: [String: TARMemberKind], read: (UInt64, Int) throws -> Data, check: () throws -> Void) throws {
        guard roots.count == targets.count else { throw TARArchiveFailure.invalidSelection }
        var occupied = Set<String>()
        for path in namespace.keys {
            try check()
            if duplicate || !roots.contains(where: { Self.covers($0.path, path) }) {
                occupied.insert(ZIPNameReservations.key(path))
            }
        }
        for target in targets {
            try check()
            guard !occupied.contains(ZIPNameReservations.key(target)) else {
                throw TARMemberEditFailure.conflict
            }
        }
        // Distinct selected roots must remain distinct, including implicit
        // directories with no own TAR record. A final catalog alone would miss
        // two implicit trees merging when their descendants have different names.
        let keys = targets.map(ZIPNameReservations.key)
        for (index, key) in keys.enumerated() {
            try check()
            guard !keys[..<index].contains(where: { Self.covers($0, key) || Self.covers(key, $0) }) else {
                throw TARMemberEditFailure.conflict
            }
        }
        for index in originalRecords.indices {
            try check(); let record = originalRecords[index]
            guard let rootIndex = roots.firstIndex(where: { Self.covers($0.path, record.path) }) else { continue }
            let path = targets[rootIndex] + record.path.dropFirst(roots[rootIndex].path.count)
            if !duplicate, path.utf8.elementsEqual(record.path.utf8) { continue }
            let header = try TARMemberHeader.rewriting(record, path: path, read: read)
            let entry = Entry(path: path, kind: record.kind, payload: .archive(record), header: header, modification: record.modification)
            if duplicate { appended.append(entry) } else { originals[index] = entry }
        }
        // Empty implicit folders have no record only if the source was invalid;
        // a selected real folder's explicit record or descendant must move.
    }
    private mutating func finalize(check: () throws -> Void) throws {
        let entries = entries
        guard entries.count < 20_000 else { throw TARMemberEditFailure.limitReached }
        var logical: UInt64 = 0, metadataBytes = 0, physicalRecords = preservedPhysicalRecords, records: [TARRecord] = []
        for (index, entry) in entries.enumerated() {
            try check()
            let safe = try TARMetadataParser.path(entry.path, directory: entry.kind == .directory, limits: .init())
            guard safe.utf8.elementsEqual(entry.path.utf8), entry.bytes <= 256 << 20,
                  entry.bytes <= UInt64(1 << 30) - logical else { throw TARMemberEditFailure.limitReached }
            logical += entry.bytes
            let headerBytes = entry.metadataBytes
            guard headerBytes <= (32 << 20) - metadataBytes else { throw TARMemberEditFailure.limitReached }
            metadataBytes += headerBytes
            physicalRecords += entry.physicalRecords
            guard physicalRecords <= 20_000 else { throw TARMemberEditFailure.limitReached }
            records.append(.init(ordinal: index, path: entry.path, kind: entry.kind,
                headerOffset: 0, dataOffset: 512, bytes: entry.bytes, modification: entry.modification))
        }
        let catalog: TARCatalogStorage
        do {
            catalog = try TARCatalogBuilder.build(.init(records: records, witness: Data(),
                metadataBytes: metadataBytes, logicalBytes: logical), check: check)
        } catch TARArchiveFailure.ambiguousNames { throw TARMemberEditFailure.conflict }
          catch TARArchiveFailure.limited { throw TARMemberEditFailure.limitReached }
        guard catalog.summary.files <= 10_000 else { throw TARMemberEditFailure.limitReached }
        let addedItems = additions?.roots.map {
            ArchiveAddedItemPreview(originalName: $0.originalName, archivePath: $0.archivePath,
                isDirectory: $0.isDirectory, replacesExistingFile: replacedAdditions.contains(Data($0.archivePath.utf8)))
        } ?? []
        preview = .init(files: catalog.summary.files, folders: catalog.summary.folders, logicalBytes: logical,
            longestPathBytes: records.map { $0.path.utf8.count }.max() ?? 0, addedItems: addedItems)
    }
    private static func namespace(_ records: [TARRecord], check: () throws -> Void) throws -> [String: TARMemberKind] {
        var result: [String: TARMemberKind] = [:], bytes = 0
        func retain(_ path: String, kind: TARMemberKind) throws {
            try check()
            if result[path] == nil {
                guard path.utf8.count <= (16 << 20) - bytes else { throw TARMemberEditFailure.limitReached }
                bytes += path.utf8.count
            }
            result[path] = kind
        }
        for record in records {
            try retain(record.path, kind: record.kind)
            let parts = record.path.split(separator: "/")
            for count in 1..<parts.count { try retain(parts.prefix(count).joined(separator: "/"), kind: .directory) }
        }
        return result
    }
    private static func childrenIndex(_ namespace: [String: TARMemberKind], check: () throws -> Void) throws -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for path in namespace.keys {
            try check()
            if let leaf = path.split(separator: "/").last { index[parent(path), default: []].insert(String(leaf)) }
        }
        return index
    }
    private static func children(in folder: String, namespace: [String: TARMemberKind]) -> Set<String> {
        Set(namespace.keys.filter { parent($0) == folder }.compactMap { $0.split(separator: "/").last.map(String.init) })
    }
    private static func empty(_ path: String, directory: Bool, index: Int) throws -> Entry {
        let header = try TARCreationHeader(path: path, directory: directory, mode: directory ? 0o755 : 0o644,
            seconds: Int(Date().timeIntervalSince1970), index: index)
        return .init(path: path, kind: directory ? .directory : .file, payload: .bytes(Data()),
            header: header.encoded, modification: .unix(header.modification.timeIntervalSince1970))
    }
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              name.utf8.count <= 255,
              (try? TARMetadataParser.path(name, directory: false, limits: .init()))?.utf8.elementsEqual(name.utf8) == true else {
            throw TARMemberEditFailure.invalidMemberName
        }
    }
    private static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    private static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }
    private static func covers(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    func encodedBytes(sourceLength: UInt64) throws -> UInt64 {
        func padded(_ value: UInt64) -> UInt64 { ((value + 511) / 512) * 512 }
        let old = originalRecords.reduce(UInt64(0)) { $0 + $1.dataOffset - ($1.extensionOffset ?? $1.headerOffset) + padded($1.bytes) }
        guard old <= sourceLength else { throw TARMemberEditFailure.unsupportedArchive }
        var count = sourceLength - old
        for entry in entries {
            let amount = UInt64(entry.metadataBytes) + padded(entry.bytes)
            guard amount <= UInt64(1 << 30), count <= UInt64(1 << 30) - amount else { throw TARMemberEditFailure.limitReached }
            count += amount
        }
        return count
    }
}
