import Foundation
import FileOperations
import LocalStorage

/// Two concrete, immutable catalog captures. Neither a displayed member path
/// nor an offered filename grants source or destination filesystem access.
enum ArchivePromiseRoots {
    case zip([ZIPRootExportSelection])
    case tar([TARExtractionSelection])

    var count: Int { switch self { case .zip(let roots): roots.count; case .tar(let roots): roots.count } }
    func offeredNames() throws -> [String] {
        switch self {
        case .zip(let roots): try ArchiveRootExportNames.offered(roots)
        case .tar(let roots): try ArchiveRootExportNames.offeredTAR(roots)
        }
    }
    func index(for path: String) -> Int? {
        switch self {
        case .zip(let roots): roots.firstIndex { $0.archivePath.utf8.elementsEqual(path.utf8) }
        case .tar(let roots): roots.firstIndex { $0.displayNames.first?.utf8.elementsEqual(path.utf8) == true }
        }
    }
    func isDirectory(at index: Int) -> Bool {
        switch self {
        case .zip(let roots): roots[index].kind == .directory
        case .tar(let roots): roots[index].singleFolderName != nil
        }
    }
    func prepare(_ index: Int, engine: RecoverableFileOperations, parent: URL, name: String,
                 observing destination: FileOperationSelection, publicFile: Bool, publicTree: Bool) async throws -> ArchivePromisePlan {
        switch self {
        case .zip(let roots):
            return .zip(try await ZIPRootExtractionPreparation.prepare(roots[index], engine: engine,
                parent: parent, name: name, observing: destination, publicFile: publicFile, publicTree: publicTree))
        case .tar(let roots):
            let root = roots[index]
            if root.singleFileName != nil {
                guard publicFile else { throw FileOperationFailure.unavailable }
                return .file(try await engine.prepareTARFilePublicExtraction(root,
                    parent: parent, name: name, observing: destination))
            }
            guard root.singleFolderName != nil, publicTree else { throw FileOperationFailure.unavailable }
            let source = try await engine.observeSelection([root.archiveURL])
            return .tree(try await engine.prepareTARExtraction(source: root.archiveURL,
                parent: parent, name: name, observing: source, members: root, observingParent: destination,
                directly: true, publicQuarantineTreeV16: true))
        }
    }
}

/// Existing engine plans keep their separate format/protection admission and
/// one-use ownership. This adapter adds no producer or publication mechanism.
enum ArchivePromisePlan {
    case zip(ZIPRootExportPlan)
    case file(ReceivedFilePlan)
    case tree(ArchiveExtractionPlan)

    var destination: URL {
        switch self { case .zip(let plan): plan.destination; case .file(let plan): plan.destination; case .tree(let plan): plan.destination }
    }
    func perform(using engine: RecoverableFileOperations, progress: (@Sendable (OperationProgress) -> Void)?) async -> RecoverableOperationResult {
        switch self {
        case .zip(let plan): await engine.performZIPRootExport(plan, progress: progress)
        case .file(let plan): await engine.performReceivedFile(plan, progress: progress)
        case .tree(let plan): await engine.performArchiveExtraction(plan, progress: progress)
        }
    }
}
