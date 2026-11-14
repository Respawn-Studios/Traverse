import AppKit
import FileOperations

enum DuplicateActivation {
    static let enabled = true
    static var available: Bool {
        #if DEBUG
        enabled || ProcessInfo.processInfo.arguments.contains("--check-duplicate")
        #else
        enabled
        #endif
    }
}

@MainActor extension BrowserViewController {
    var canDuplicateSelection: Bool {
        if isArchiveLocation {
            return !isBrowserSuspended && !(view.window?.firstResponder is NSTextView)
                && currentArchive?.canDuplicate == true
        }
        if isSFTPLocation, let owner = sftpTabs[activeID] { return sftpFileActions.canCopy(from: owner) }
        if isSMBLocation, let owner = smbTabs[activeID] { return smbFileActions.canCopy(from: owner) }
        return DuplicateActivation.available && canAdmitTransfer && recoverableFileOperations != nil
            && (1...1_024).contains(selectedItemCount) && !showsComputerVolumes
            && !(view.window?.firstResponder is NSTextView)
    }

    @objc func duplicateSelection(_ sender: Any?) {
        if isArchiveLocation {
            if canDuplicateSelection { currentArchive?.duplicateSelection() }
            return
        }
        if isSFTPLocation, let owner = sftpTabs[activeID] { sftpFileActions.requestCopy(from: owner, duplicate: true); return }
        if isSMBLocation, let owner = smbTabs[activeID] {
            smbFileActions.requestCopy(from: owner, duplicate: true); return
        }
        guard canDuplicateSelection, let engine = recoverableFileOperations,
              let parent = location.directoryURL else { return }
        let sources = orderedSelectedURLs(upTo: 1_025)
        guard !sources.isEmpty, sources.count <= 1_024,
              sources.allSatisfy({ $0.deletingLastPathComponent() == parent }) else { return }
        let id = operationCoordinator.transfers.enqueue(sources: sources, destination: parent,
            move: false, title: "Duplicating items…", origin: self, engine: engine,
            metadataPolicy: .strict, duplicate: true)
        if id != nil { status.stringValue = "Duplicate added to the queue." }
    }
}

/// Presentation intent only. The ordinary Copy planner and exclusive publication
/// remain the authority; this cannot redirect a general transfer or choose Replace.
enum DuplicateChoices {
    static func resolutions(for plan: TransferPlan) throws -> [UUID: TransferConflictResolution] {
        let sources = Set(plan.sources)
        guard !plan.isMove, !plan.sources.isEmpty, plan.sources.count <= 1_024,
              plan.conflicts.count == plan.sources.count,
              sources.count == plan.sources.count,
              plan.sources.allSatisfy({ $0.deletingLastPathComponent() == plan.destinationDirectory }),
              Set(plan.conflicts.map(\.source)) == sources,
              plan.conflicts.allSatisfy({ $0.source == $0.destination }) else {
            throw FileOperationFailure.invalidRequest
        }
        return Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, .keepBoth) })
    }
}
