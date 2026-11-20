import AppKit
import Combine
import ExplorerCore
@_spi(Qualification) import LocalStorage
import SwiftUI

/// Exact image-volume review. The backend owns the erase and durable result;
/// this model reserves the App barrier and keeps it until terminal persistence.
@MainActor final class ApplicationAPFSVolumeFormat: ObservableObject {
    @Published var confirmedName = ""
    @Published private(set) var plan: APFSVolumeFormatPlan?
    @Published private(set) var isWorking = false
    @Published private(set) var isSubmitted = false
    @Published private(set) var result: APFSVolumeFormatResult?
    @Published private(set) var notice = ""
    private let backend = APFSVolumeFormat()
    private var witness: APFSAttachedImageWitness?
    private var work: Task<Void, Never>?
    private var runID: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private let permission = NativeAPFSRequestPermission()
    private(set) var target: ManagedVolume?
    private weak var operations: ApplicationOperationCoordinator?
    private var changed: (@MainActor () -> Void)?
    private var signedSubmitted: (@Sendable () -> Void)?

    var directFormatAvailable: Bool {
        guard let target, let drives = operations?.drives else { return false }
        return drives.canReviewOrdinaryFormat(target)
    }
    var canReview: Bool { directFormatAvailable && !isWorking }
    var canSubmit: Bool {
        canReview && plan?.selected == target && witness != nil && confirmedName == plan?.name
    }

    func configure(target: ManagedVolume, operations: ApplicationOperationCoordinator?,
                   changed: @escaping @MainActor () -> Void,
                   signedSubmitted: (@Sendable () -> Void)? = nil) {
        guard !isWorking else { return }
        self.target = target; self.operations = operations; self.changed = changed
        self.signedSubmitted = GeneratedDriveImageReview.selection?.caseMode == .ordinaryV3
            ? signedSubmitted : nil
        plan = nil; witness = nil; result = nil; confirmedName = ""; notice = ""
        isSubmitted = false; permission.reset()
        subscriptions.removeAll()
        operations?.drives.loadNativeDriveJobIfNeeded()
        if let drives = operations?.drives {
            drives.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }.store(in: &subscriptions)
            drives.$protectionRevision.combineLatest(drives.$volumes).dropFirst().sink { [weak self] _ in
                guard let self, self.permission.cancelBeforeSubmission() else { return }
                self.plan = nil; self.witness = nil; self.work?.cancel()
                self.notice = "Drive observations or protection changed. Review the selected volume again."
            }.store(in: &subscriptions)
        }
    }

    func review() {
        guard canReview, let target, let operations else { return }
        guard let inspection = operations.beginInspection() else {
            notice = "Finish current file work, then review the volume again."
            return
        }
        let activity: any Sendable
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch {
            operations.finishInspection(inspection)
            notice = "A drive task is still finishing. Try again after it completes."
            return
        }
        isWorking = true; result = nil; plan = nil; witness = nil; confirmedName = ""
        notice = "Checking the attached disk image and exact APFS volume…"
        work = Task { [self] in
            defer {
                withExtendedLifetime(activity) {}
                operations.finishInspection(inspection)
                isWorking = false; work = nil
            }
            do {
                let bound: APFSAttachedImageWitness
                if GeneratedDriveImageReview.requested {
                    guard let owner = GeneratedDriveImageReview.signedFormatReviewOwner(target) else {
                        throw APFSVolumeFormatFailure.unavailable
                    }
                    bound = try await APFSAttachedImageWitness.prepareSealedFixture(target, expectedOwner: owner)
                } else {
                    bound = try await APFSAttachedImageWitness.prepare(target)
                }
                let prepared = try await backend.prepare(target)
                try Task.checkCancellation()
                guard self.target == target, directFormatAvailable,
                      prepared.selected == target, bound.targetCurrentFast() else {
                    throw APFSVolumeFormatFailure.changed
                }
                witness = bound; plan = prepared; notice = ""
            } catch {
                notice = Task.isCancelled ? APFSVolumeFormatFailure.cancelled.userMessage
                    : (error as? APFSVolumeFormatFailure)?.userMessage
                        ?? "The attached image or APFS volume could not be verified. Refresh and review it again."
            }
        }
    }

    func format() {
        guard canSubmit, let plan, let witness, let target,
              let drives = operations?.drives else { return }
        isWorking = true; isSubmitted = false; result = nil
        notice = "Rechecking the selected volume…"
        permission.start()
        let permission = permission
        let runID = UUID()
        self.runID = runID
        let confirmed = confirmedName
        let signedSubmitted = self.signedSubmitted
        work = Task { [self] in
            var reservation: UUID?
            var recorderObtained = false
            defer {
                permission.reset()
                self.runID = nil
                if let reservation { drives.releaseOrdinaryFormat(reservation) }
                isWorking = false; work = nil
            }
            do {
                let id = try await drives.reserveOrdinaryFormat(target)
                reservation = id
                let signedGrant: GeneratedDriveImageReview.SignedFormatGrant?
                if GeneratedDriveImageReview.requested {
                    guard let claim = GeneratedDriveImageReview.claimSignedFormatTarget(target,
                        owner: witness.owner) else { throw APFSVolumeFormatFailure.unavailable }
                    signedGrant = claim
                } else { signedGrant = nil }
                guard let recording = drives.ordinaryFormatRecording(owner: witness.owner,
                    attachmentCurrent: { witness.ownerCurrentFast() }) else {
                    throw APFSVolumeFormatFailure.recoveryUnavailable
                }
                recorderObtained = true
                let completed = await backend.perform(plan, confirmedName: confirmed,
                    recording: recording, afterIntentBeforeLaunch: {
                        let drain = try await drives.quiesceOrdinaryFormat(id, target: target)
                        permission.requireDrained(drain.token, protectionCurrent: drain.protectionCurrent)
                    }, permitted: {
                        (GeneratedDriveImageReview.requested ? signedGrant != nil : NativeAPFSFormatFeature.ordinaryEnabled)
                            && permission.allowed && witness.targetCurrentFast()
                    }, attachmentStillCurrent: {
                        if GeneratedDriveImageReview.requested {
                            return signedGrant?.current() == true
                        }
                        return witness.attachmentCurrentAtLaunch()
                    }, submitted: {
                        permission.markSubmitted()
                        signedSubmitted?()
                        Task { @MainActor [weak self] in
                            guard let self, self.runID == runID, self.isWorking,
                                  self.result == nil else { return }
                            self.isSubmitted = true
                            self.notice = "Format submitted. Waiting for macOS and checking the saved result…"
                        }
                    })
                result = completed; self.plan = nil; self.witness = nil
                isSubmitted = completed.submitted
                notice = completed.formatted.map { "Formatted \($0.name)." +
                    ($0.mountPoint == nil ? " It is not mounted; inspect it in Disk Utility." : "") }
                    ?? (completed.failure == .busy && !drives.formatBlockerNotice.isEmpty
                        ? drives.formatBlockerNotice : completed.failure?.userMessage)
                    ?? "The final state needs review."
                if completed.submitted { changed?() }
            } catch {
                self.plan = nil; self.witness = nil
                if error is CancellationError { notice = APFSVolumeFormatFailure.cancelled.userMessage }
                else {
                    notice = (error as? APFSVolumeFormatFailure)?.userMessage
                        ?? "The selected image volume could not be checked. Format was not submitted."
                }
            }
            if recorderObtained { await drives.reloadNativeDriveJobAfterRecording() }
        }
    }

    func cancelCheck() {
        guard permission.cancelBeforeSubmission() else { return }
        work?.cancel()
    }
    func dismiss() {
        subscriptions.removeAll()
        if permission.cancelBeforeSubmission() { work?.cancel() }
    }
    func drain() async { if let work { await work.value } }
    func openDiskUtility() {
        guard DriveDiskUtilityHandoff.open() else { notice = "Disk Utility could not be opened."; return }
        notice = "Disk Utility opened separately. Select the intended APFS volume there. Traverse did not select a device or request a format in Disk Utility."
    }
}

struct APFSVolumeFormatView: View {
    @ObservedObject var model: ApplicationAPFSVolumeFormat
    @ObservedObject var settings: BrowserSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Format APFS Volume", systemImage: "externaldrive.badge.xmark")
                        .interfaceFont(.title2.bold())
                    if let target = model.target {
                        Text(target.name).interfaceFont(.headline)
                        if let path = target.url?.path {
                            Text(path).interfaceFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Text("Formatting erases everything on the selected volume. Other volumes in its APFS container are kept. You cannot Undo this action in Traverse.")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                    if let plan = model.plan {
                        GroupBox("Review erase") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Erase only “\(plan.name)” on the attached disk image.")
                                if let id = plan.selected.volumeUUID {
                                    Text("Selected volume ID: \(id.uuidString)")
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Text("Container ID: \(plan.containerID.uuidString)")
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                Text("Preserve \(plan.siblingNames.count) other APFS \(plan.siblingNames.count == 1 ? "volume" : "volumes") in this container.")
                                ForEach(plan.siblingNames.indices, id: \.self) { index in
                                    Text("• " + plan.siblingNames[index]).foregroundStyle(.secondary)
                                }
                                Text("Recreate it as \(plan.caseSensitive ? "case-sensitive APFS" : "APFS") with the same name.")
                                Text("Type the selected volume name exactly before submitting.")
                                    .foregroundStyle(.secondary)
                            }.interfaceFont(.callout).padding(8)
                        }
                        TextField("Selected volume name", text: $model.confirmedName)
                            .disabled(model.isWorking)
                    } else if !NativeAPFSFormatFeature.ordinaryEnabled {
                        Label("Formatting is not available here yet.", systemImage: "info.circle")
                        Text("Use Disk Utility to select and review the intended volume.")
                            .interfaceFont(.callout).foregroundStyle(.secondary)
                    }
                    if model.isWorking {
                        ProgressView(model.isSubmitted ? "Waiting for macOS and checking the saved result…" : "Checking the selected volume…")
                            .controlSize(.small)
                    }
                    if !model.notice.isEmpty {
                        Text(model.notice).interfaceFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let result = model.result, result.failure != nil {
                        if let status = result.toolExitStatus {
                            Text(status == -1 ? "The macOS request ended without a normal exit status."
                                 : "macOS request exit status: \(status)")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                        if let code = result.diskutilErrorCode {
                            Text("macOS disk utility error \(code)")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(idealHeight: 470, maxHeight: 580)
            Divider()
            HStack {
                Button("Open Disk Utility…", action: model.openDiskUtility).disabled(model.isWorking)
                Spacer()
                if model.isWorking {
                    if !model.isSubmitted { Button("Cancel Check", action: model.cancelCheck) }
                } else {
                    Button(model.result?.formatted != nil ? "Done" : "Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if model.plan != nil, model.result?.submitted != true {
                        Button("Format Volume", action: model.format).buttonStyle(.borderedProminent)
                            .disabled(!model.canSubmit)
                    } else if model.result == nil {
                        Button("Review…", action: model.review).buttonStyle(.borderedProminent)
                            .disabled(!model.canReview)
                    }
                }
            }.padding(20)
        }.frame(width: min(780, 580 * settings.interfaceSize.scale))
            .interactiveDismissDisabled(model.isWorking)
            .onDisappear { model.dismiss() }
    }
}
