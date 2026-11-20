import AppKit
import Combine
import LocalStorage
import SwiftUI

/// A review for one selected container. The domain owner performs every query
/// and mutation; this model only owns presentation and application admission.
@MainActor final class ApplicationAPFSVolumeCreation: ObservableObject {
    @Published var name = "Untitled"
    @Published var caseSensitive = false
    @Published private(set) var plan: APFSVolumeCreationPlan?
    @Published private(set) var isWorking = false
    @Published private(set) var isSubmitted = false
    @Published private(set) var result: APFSVolumeCreationResult?
    @Published private(set) var notice = ""
    private let backend = APFSVolumeCreation()
    private var work: Task<Void, Never>?
    private var runID: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private let permission = NativeAPFSRequestPermission()
    private(set) var target: ManagedVolume?
    private weak var operations: ApplicationOperationCoordinator?
    private var changed: (@MainActor () -> Void)?
    #if DEBUG
    private var verificationTarget: ManagedVolume?
    private var verificationAttemptsRemaining: Int?
    private(set) var verificationCreationAttempts = 0
    func restrictCreationForVerification(to target: ManagedVolume) {
        guard !isWorking, target.deviceKind == .diskImage else { return }
        verificationTarget = target; verificationAttemptsRemaining = 1; verificationCreationAttempts = 0
    }
    #endif
    nonisolated static func permitsInAppCreation(_ target: ManagedVolume?) -> Bool {
        // The signed image role calls the backend through its sealed runner;
        // no ordinary Drives sheet may obtain this capability.
        if GeneratedDriveImageReview.requested { return false }
        guard AppFeatureAvailability.allows(.apfsVolumeCreation), let target, target.deviceKind == .diskImage else { return false }
        return target.volumeUUID != nil && target.mediaID != nil && target.group != nil && target.url != nil
    }
    var directCreationAvailable: Bool {
        guard Self.permitsInAppCreation(target) else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--apfs-ui"), verificationTarget == nil { return false }
        if let verificationTarget, target != verificationTarget { return false }
        #endif
        return true
    }
    var unavailableTitle: String {
        AppFeatureAvailability.allows(.apfsVolumeCreation)
            ? "Use Disk Utility for this storage." : "In-app creation is unavailable in this edition."
    }
    var canReview: Bool {
        #if DEBUG
        if verificationAttemptsRemaining == 0 { return false }
        #endif
        return directCreationAvailable && !isWorking && target != nil && protectionAllowsTarget
    }
    private var protectionAllowsTarget: Bool {
        guard let target, let drives = operations?.drives, drives.protectionReady, !drives.isEditingProtection,
              !drives.isBusy, drives.volumes.contains(target) else { return false }
        let members = drives.volumes.filter { $0.group == target.group }
        guard !members.contains(where: { volume in
            guard let root = volume.url else { return false }
            return operations?.protectedStorageLocations.contains { $0.pathComponents.starts(with: root.pathComponents) } == true
        }) else { return false }
        return drives.permitsRemoval(target, action: .eject)
    }
    func configure(target: ManagedVolume?, operations: ApplicationOperationCoordinator?, changed: @escaping @MainActor () -> Void) {
        guard !isWorking else { return }
        self.target = target; self.operations = operations; self.changed = changed
        plan = nil; result = nil; notice = ""; isSubmitted = false; permission.reset()
        subscriptions.removeAll()
        if let drives = operations?.drives {
            drives.$protectionRevision.combineLatest(drives.$volumes).dropFirst().sink { [weak self] _ in
                guard let self, self.permission.cancelBeforeSubmission() else { return }
                self.plan = nil; self.work?.cancel()
                self.notice = "Drive observations or protection changed. Review the current container again."
            }.store(in: &subscriptions)
        }
    }
    func invalidateReview() { guard !isWorking else { return }; plan = nil; result = nil; notice = ""; permission.reset() }
    func review() {
        guard canReview, let target, let operations, let inspection = operations.beginInspection() else { return }
        let activity: any Sendable
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch { operations.finishInspection(inspection); notice = "A drive task is still finishing. Try again after it completes."; return }
        let name = name, sensitive = caseSensitive
        isWorking = true; notice = ""; plan = nil; result = nil
        work = Task { [self] in
            defer { withExtendedLifetime(activity) {}; operations.finishInspection(inspection); isWorking = false; work = nil }
            do {
                let prepared = try await backend.prepare(target, name: name, caseSensitive: sensitive)
                try Task.checkCancellation()
                guard self.target == target, directCreationAvailable else { throw APFSVolumeCreationFailure.changed }
                plan = prepared
            }
            catch { notice = Task.isCancelled ? "Volume check cancelled." : (error as? APFSVolumeCreationFailure)?.userMessage ?? "The selected container could not be read. Use Disk Utility to inspect its current state." }
        }
    }
    func create() {
        guard canReview, let plan, let target, plan.selected == target, Self.permitsInAppCreation(target), let operations else { return }
        let owner = UUID()
        guard operations.begin(owner: owner) else { notice = "Finish the current file or drive task before adding a volume."; return }
        let activity: any Sendable
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch { operations.finish(owner: owner); notice = "A drive task is still finishing. Try again after it completes."; return }
        #if DEBUG
        if let remaining = verificationAttemptsRemaining {
            guard remaining > 0 else { operations.finish(owner: owner); return }
            verificationAttemptsRemaining = remaining - 1; verificationCreationAttempts += 1
        }
        #endif
        permission.start()
        isWorking = true; isSubmitted = false; notice = "Rechecking the selected container…"
        let permission = permission
        let runID = UUID()
        self.runID = runID
        work = Task { [self] in
            defer {
                withExtendedLifetime(activity) {}; permission.reset()
                self.runID = nil
                operations.finish(owner: owner); isWorking = false; work = nil
            }
            let completed = await backend.perform(plan, permitted: { permission.allowed && Self.permitsInAppCreation(target) }) { [weak self] in
                permission.markSubmitted()
                Task { @MainActor in
                    guard let self, self.runID == runID, self.isWorking, self.result == nil else { return }
                    self.isSubmitted = true
                    self.notice = "Adding the volume. Waiting for macOS and checking the result…"
                }
            }
            result = completed; self.plan = nil
            isSubmitted = completed.submitted
            notice = completed.created.map { "Created \($0.name)." + ($0.mountPoint == nil ? " It is not mounted; inspect it in Disk Utility." : "") }
                ?? completed.failure?.userMessage ?? "The final state needs review."
            if completed.submitted { changed?() }
        }
    }
    func cancelCheck() { guard permission.cancelBeforeSubmission() else { return }; work?.cancel() }
    func dismiss() { subscriptions.removeAll(); if permission.cancelBeforeSubmission() { work?.cancel() } }
    func drain() async { if let work { await work.value } }
    func openDiskUtility() {
        guard DriveDiskUtilityHandoff.open() else {
            notice = "Disk Utility could not be opened."; return
        }
        notice = "Disk Utility opened separately. Select \(target?.name ?? "the intended APFS volume"), then choose Edit → Add APFS Volume. Traverse did not select a device or request creation in Disk Utility."
    }
}

struct APFSVolumeCreationView: View {
    @ObservedObject var model: ApplicationAPFSVolumeCreation
    @ObservedObject var settings: BrowserSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
          ScrollView {
           VStack(alignment: .leading, spacing: 18) {
            Label("Add APFS Volume", systemImage: "externaldrive.badge.plus").interfaceFont(.title2.bold())
            if let target = model.target {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Container of \(target.name)").interfaceFont(.headline)
                    if let path = target.url?.path { Text(path).interfaceFont(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            Text("An APFS volume shares its container’s free space. This adds a volume inside an existing container; it does not create a partition or erase existing volumes.")
                .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.directCreationAvailable {
                TextField("New volume name", text: $model.name).disabled(model.isWorking)
                    .onChange(of: model.name) { _, _ in model.invalidateReview() }
                Toggle("Case-sensitive APFS", isOn: $model.caseSensitive).disabled(model.isWorking)
                    .onChange(of: model.caseSensitive) { _, _ in model.invalidateReview() }
                if let plan = model.plan {
                    GroupBox("Review creation") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Create “\(plan.name)” beside \(plan.existingVolumeNames.count) existing \(plan.existingVolumeNames.count == 1 ? "volume" : "volumes").")
                            Text("Observed free space: \(FileSizeText.string(Int64(plan.observedFreeBytes))) of \(FileSizeText.string(Int64(plan.containerCapacity))).")
                            Text("Unencrypted \(plan.caseSensitive ? "case-sensitive APFS" : "APFS") · shared space · no quota or reserved allocation.")
                            Text("Once macOS accepts the request, closing or cancelling cannot undo it. The result is checked before completion is reported.")
                                .foregroundStyle(.secondary)
                        }.interfaceFont(.callout).padding(8)
                    }
                }
            } else {
                Label(model.unavailableTitle, systemImage: "info.circle").interfaceFont(.headline)
                Text("Use Disk Utility to select this APFS volume and add a volume to its container. Disk Utility checks your Mac’s permissions and offers reserve, quota and encryption options.")
                    .interfaceFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.isWorking { ProgressView(model.isSubmitted ? "Waiting for macOS and checking the result…" : "Checking the container…").controlSize(.small) }
            if !model.notice.isEmpty { Text(model.notice).interfaceFont(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let result = model.result, result.failure != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let stage = result.failureStage { Text("Step: " + stage.userMessage) }
                    if let status = result.toolExitStatus {
                        Text(status == -1 ? "The macOS creation request ended without a normal exit status."
                            : "macOS creation request exit status: \(status)")
                    }
                    if let category = result.diagnosticCategory { Text(category.userMessage) }
                    if let code = result.diskutilErrorCode { Text("macOS disk utility error \(code)") }
                    else if result.diagnosticCategory == nil, let status = result.toolExitStatus, status != 0 {
                        Text("No recognized error detail is available.")
                    }
                }.interfaceFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
           }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(idealHeight: model.directCreationAvailable ? 540 : 360, maxHeight: 600)
            Divider()
            HStack {
                Button("Open Disk Utility…", action: model.openDiskUtility).disabled(model.isWorking)
                Spacer()
                if model.isWorking {
                    if !model.isSubmitted { Button("Cancel Check", action: model.cancelCheck) }
                } else {
                    Button(model.result?.created != nil ? "Done" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if model.directCreationAvailable, model.result?.submitted != true {
                        if model.plan != nil { Button("Add Volume", action: model.create).buttonStyle(.borderedProminent).disabled(!model.canReview) }
                        else { Button("Review…", action: model.review).buttonStyle(.borderedProminent).disabled(!model.canReview) }
                    }
                }
            }.padding(20)
        }.frame(width: min(780, 580 * settings.interfaceSize.scale))
            .interactiveDismissDisabled(model.isWorking)
            .onDisappear { model.dismiss() }
    }
}
