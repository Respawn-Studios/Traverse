import Foundation
@_spi(ArchiveProduction) import FileOperations

/// An immutable, explicitly selected archive root. This is neither a local
/// path nor a destination grant. Preparation always reopens the observed ZIP.
public struct ZIPRootExportSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var archiveURL: URL { binding.source }
    public var name: String { root.path.split(separator: "/").last.map(String.init) ?? "" }
    /// Display/matching metadata within this immutable archive snapshot. This
    /// string is never a local URL or authority to select another root.
    public var archivePath: String { root.path }
    public var kind: ZIPMemberKind { root.kind }
    public var description: String { "Selected archive root" }
    public var debugDescription: String { description }
    internal let binding: ZIPSourceBinding
    internal let root: ZIPExtractionSelection.Root
}

extension ZIPArchiveSession {
    /// Bounded metadata work on this session's actor. Parent selection absorbs
    /// its selected descendants; closed/foreign/unsupported IDs are refused.
    public func rootsForExport(_ ids: Set<ZIPItemID>) throws -> [ZIPRootExportSelection] {
        guard !ids.isEmpty, ids.count <= 128 else { throw ZIPArchiveFailure.invalidFolder }
        let selection = try selectionForExtraction(ids)
        return selection.roots.map { .init(binding: .init(source: selection.source, stamp: selection.stamp), root: $0) }
    }
}

/// Concrete ZIP-to-local publication only. The enclosed engine plan retains
/// its existing one-use/engine ownership and guarded recovery/Undo rules.
public final class ZIPRootExportPlan: Sendable {
    internal enum Production: Sendable {
        case file(ReceivedFilePlan)
        case directory(ReceivedDirectoryPlan)
        case publicZIPDirectory(ArchiveExtractionPlan)
    }
    internal let production: Production
    internal init(_ production: Production) { self.production = production }
    public var destination: URL {
        switch production {
        case .file(let value): value.destination
        case .directory(let value): value.destination
        case .publicZIPDirectory(let value): value.destination
        }
    }
    public var logicalBytes: UInt64 {
        switch production {
        case .file(let value): value.logicalBytes
        case .directory(let value): value.logicalBytes
        case .publicZIPDirectory(let value): value.logicalBytes
        }
    }
    public var files: Int {
        switch production {
        case .file: 1
        case .directory(let value): value.files
        case .publicZIPDirectory(let value): value.files
        }
    }
    public var folders: Int {
        switch production {
        case .file: 0
        case .directory(let value): value.folders
        case .publicZIPDirectory(let value): value.folders
        }
    }
}

extension RecoverableFileOperations {
    /// The caller must hold real source/destination access through completion.
    /// Observation and a promised leaf URL do not grant parent-folder access.
    public func prepareZIPRootExport(_ selection: ZIPRootExportSelection, parent: URL, name: String,
        observing destination: FileOperationSelection,
        publicQuarantineTreeV16: Bool = false) async throws -> ZIPRootExportPlan {
        try await prepareZIPRootExport(selection, parent: parent, name: name,
            observing: destination, hooks: .init(), publicQuarantineTreeV16: publicQuarantineTreeV16)
    }
    /// Explicit source-only candidate. Ordinary extraction continues through
    /// the exact-mark route above; the engine independently holds this policy.
    public func prepareZIPRootFilePublicExtraction(_ selection: ZIPRootExportSelection,
        parent: URL, name: String, observing destination: FileOperationSelection) async throws -> ZIPRootExportPlan {
        guard selection.kind == .file else { throw ZIPArchiveFailure.unsupported }
        let plan = try await prepareReceivedFile(parent: parent, name: name, observing: destination,
            origin: .zipExtraction, publicZIPExtractionV1: true) { check in
            try PreparedZIPRootFile(selection, check: check, hooks: .init(), publicQuarantineFile: true)
        }
        return .init(.file(plan))
    }
    internal func prepareZIPRootExport(_ selection: ZIPRootExportSelection, parent: URL, name: String,
        observing destination: FileOperationSelection, hooks: ZIPProductionHooks,
        publicQuarantineTreeV16: Bool = false) async throws -> ZIPRootExportPlan {
        switch selection.kind {
        case .file:
            guard !publicQuarantineTreeV16 else { throw ZIPArchiveFailure.unsupported }
            let plan = try await prepareReceivedFile(parent: parent, name: name, observing: destination, origin: .zipExtraction) { check in
                try PreparedZIPRootFile(selection, check: check, hooks: hooks)
            }
            return .init(.file(plan))
        case .directory:
            if publicQuarantineTreeV16 {
                let source = try await observeSelection([selection.binding.source])
                let plan = try await prepareArchiveExtraction(source: selection.binding.source,
                    parent: parent, name: name, observing: source, observingParent: destination,
                    format: .zip, publicQuarantineTreeV16: true) { check in
                    try PreparedZIPDirectory(selection.binding.source, selection: .init(source: selection.binding.source,
                        stamp: selection.binding.stamp, roots: [selection.root]), exporting: selection.root,
                        check: check, hooks: hooks, publicQuarantineTree: true)
                }
                return .init(.publicZIPDirectory(plan))
            }
            let plan = try await prepareReceivedDirectory(parent: parent, name: name, observing: destination, origin: .zipExtraction) { check in
                try PreparedZIPDirectory(selection.binding.source, selection: .init(source: selection.binding.source,
                    stamp: selection.binding.stamp, roots: [selection.root]), exporting: selection.root, check: check, hooks: hooks)
            }
            return .init(.directory(plan))
        default: throw ZIPArchiveFailure.unsupported
        }
    }
    public func performZIPRootExport(_ plan: ZIPRootExportPlan,
        progress: (@Sendable (OperationProgress) -> Void)? = nil) async -> RecoverableOperationResult {
        switch plan.production {
        case .file(let file): await performReceivedFile(file, progress: progress)
        case .directory(let directory): await performReceivedDirectory(directory, progress: progress)
        case .publicZIPDirectory(let directory): await performArchiveExtraction(directory, progress: progress)
        }
    }
}

private final class PreparedZIPRootFile: PublicQuarantineZIPExtractionFileProducer, Sendable {
    let preview: ArchiveProductionPreview
    private let archive: PreparedZIPDirectory
    init(_ selection: ZIPRootExportSelection, check: @Sendable () throws -> Void, hooks: ZIPProductionHooks,
        publicQuarantineFile: Bool = false) throws {
        guard selection.kind == .file else { throw ZIPArchiveFailure.unsupported }
        archive = try PreparedZIPDirectory(selection.binding.source, selection: .init(source: selection.binding.source,
            stamp: selection.binding.stamp, roots: [selection.root]), exporting: selection.root, check: check,
            hooks: hooks, publicQuarantineFile: publicQuarantineFile)
        preview = .init(files: 1, folders: 0, logicalBytes: archive.preview.logicalBytes, longestPathBytes: 0)
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
    func finished() {}
}
