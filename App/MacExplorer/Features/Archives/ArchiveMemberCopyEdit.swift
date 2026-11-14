import Foundation
import LocalStorage
import FileOperations

/// An explicit local selection for the existing Add review. A paste capture
/// must stay current until the review adopts its URLs and their access lifetime.
struct ArchiveAdditionInput {
    let urls: [URL]
    var access: FileAccessLifetimes? = nil
    var isCurrent: @MainActor () -> Bool = { true }
}

enum ZIPOriginalUpdateFeature {
    static var available: Bool {
        if GeneratedSandboxReview.publicationOnlyReviewAdmitted || GeneratedSandboxReview.archiveInternalAdmitted { return false }
        // The newly sealed local-files review selects the separate v13 policy;
        // older immutable Create/Copy receipts do not qualify Original Update.
        if GeneratedSandboxReview.localFileReviewAdmitted {
            return GeneratedSandboxReview.nativeAuthoredOriginalUpdateAdmitted
        }
        if GeneratedSandboxReview.admitted { return ZIPMemberRenameFeature.available }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy") {
            return ProcessInfo.processInfo.arguments.contains("--update-original")
        }
        #endif
        if NativeLocalProtectionPolicy.authoredZIPOriginalUpdateAvailable {
            return ZIPMemberRenameFeature.available
        }
        #if !DEBUG
        // Preview must not fall back to the earlier original-update contract
        // when its native policy is held. Ordinary development keeps its route.
        guard AppFeatureAvailability.policy.edition == .development else { return false }
        #endif
        return AppFeatureAvailability.allows(.archiveMemberChanges) && ZIPMemberRenameFeature.available
    }
}

/// Concrete file-operation plans used by the native archive reviews.
/// This wrapper carries no staging descriptor or additional mutation authority.
enum ArchiveWritePlan: Sendable {
    case create(ArchiveCreationPlan), update(ArchiveUpdatePlan)
    case extract(ArchiveExtractionPlan), export(ZIPRootExportPlan), extractFile(ReceivedFilePlan)
    var destination: URL {
        switch self {
        case .create(let p): p.destination
        case .update(let p): p.destination
        case .extract(let p): p.destination
        case .export(let p): p.destination
        case .extractFile(let p): p.destination
        }
    }
    var directorySources: [URL] {
        switch self { case .create(let p): p.directorySources; case .update(let p): p.directorySources; case .extract, .export, .extractFile: [] }
    }
    var addedItems: [ArchiveAddedItemPreview] {
        switch self { case .create(let p): p.addedItems; case .update(let p): p.addedItems; case .extract, .export, .extractFile: [] }
    }
    var files: Int {
        switch self {
        case .create(let p): p.files
        case .update(let p): p.files
        case .extract(let p): p.files
        case .export(let p): p.files
        case .extractFile: 1
        }
    }
    var folders: Int {
        switch self {
        case .create(let p): p.folders
        case .update(let p): p.folders
        case .extract(let p): p.folders
        case .export(let p): p.folders
        case .extractFile: 0
        }
    }
    var logicalBytes: UInt64 {
        switch self {
        case .create(let p): p.logicalBytes
        case .update(let p): p.logicalBytes
        case .extract(let p): p.logicalBytes
        case .export(let p): p.logicalBytes
        case .extractFile(let p): p.logicalBytes
        }
    }
    func perform(using engine: RecoverableFileOperations,
                 progress: (@Sendable (OperationProgress) -> Void)?) async -> RecoverableOperationResult {
        switch self {
        case .create(let plan): await engine.performArchiveCreation(plan, progress: progress)
        case .update(let plan): await engine.performArchiveOriginalUpdate(plan, progress: progress)
        case .extract(let plan): await engine.performArchiveExtraction(plan, progress: progress)
        case .export(let plan): await engine.performZIPRootExport(plan, progress: progress)
        case .extractFile(let plan): await engine.performReceivedFile(plan, progress: progress)
        }
    }
}

/// The creation review receives a sealed intent from a live archive session.
/// Displayed member names never become local file paths or operation authority.
enum ArchiveMemberCopyEdit: Sendable {
    case rename(ZIPMemberRenameSelection)
    case batchRename(ZIPMemberSetSelection)
    case remove(ZIPMemberSetSelection)
    case duplicate(ZIPMemberSetSelection, ZIPMemberAdditionSelection?)
    case move(ZIPMemberSetSelection, ZIPMemberAdditionSelection)
    case add(ZIPMemberAdditionSelection)
    case newFolder(ZIPMemberAdditionSelection)
    case newFile(ZIPMemberAdditionSelection)
    case group(ZIPMemberSetSelection)

    var archiveURL: URL {
        switch self {
        case .rename(let value): value.archiveURL
        case .remove(let value), .duplicate(let value, _), .move(let value, _), .batchRename(let value), .group(let value): value.archiveURL
        case .add(let value), .newFolder(let value), .newFile(let value): value.archiveURL
        }
    }
    var paths: [String] {
        switch self {
        case .rename(let value): [value.archivePath]
        case .remove(let value), .duplicate(let value, _), .move(let value, _), .batchRename(let value), .group(let value): value.archivePaths
        case .add(let value), .newFolder(let value), .newFile(let value): value.virtualFolder.isEmpty ? [] : [value.virtualFolder]
        }
    }
    var isRename: Bool { if case .rename = self { true } else { false } }
    var isBatchRename: Bool { if case .batchRename = self { true } else { false } }
    var isRemoval: Bool { if case .remove = self { true } else { false } }
    var isDuplicate: Bool { if case .duplicate = self { true } else { false } }
    var isMove: Bool { if case .move = self { true } else { false } }
    var isAddition: Bool { if case .add = self { true } else { false } }
    var isNewFolder: Bool { if case .newFolder = self { true } else { isGrouping } }
    var isGrouping: Bool { if case .group = self { true } else { false } }
    var isNewFile: Bool { if case .newFile = self { true } else { false } }
    var available: Bool {
        switch self {
        case .rename(let value): value.isDirectory ? ZIPMemberRenameFeature.directoriesAvailable : ZIPMemberRenameFeature.available
        case .remove(let value): value.folderPaths.isEmpty ? ZIPMemberRemovalFeature.available : ZIPMemberRemovalFeature.directoriesAvailable
        case .duplicate(let value, _), .move(let value, _), .batchRename(let value), .group(let value):
            value.folderPaths.isEmpty ? ZIPMemberRenameFeature.available : ZIPMemberRenameFeature.directoriesAvailable
        case .add: ZIPMemberAdditionFeature.available
        case .newFolder, .newFile: ZIPMemberCreationFeature.available
        }
    }
}

enum ZIPMemberCreationFeature {
    static var available: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            && ProcessInfo.processInfo.arguments.contains("--new-folder") { return true }
        #endif
        return ZIPMemberRenameFeature.available
    }
}

enum ZIPMemberAdditionFeature {
    static var available: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            && ProcessInfo.processInfo.arguments.contains("--add-members") { return true }
        #endif
        return ZIPMemberRenameFeature.available
    }
}

enum ZIPMemberRemovalFeature {
    static var available: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            && ProcessInfo.processInfo.arguments.contains("--remove-members") { return true }
        #endif
        return ZIPMemberRenameFeature.available
    }
    static var directoriesAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-zip-rename-copy")
            && ProcessInfo.processInfo.arguments.contains("--remove-folders") { return true }
        #endif
        return available
    }
}
