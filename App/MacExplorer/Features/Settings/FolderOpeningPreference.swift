import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum FolderOpeningFeature {
    // Actual installed consent/readback/restore acceptance is still required.
    static let ordinaryEnabled = false
    static var ownerReview: Bool {
        ProcessInfo.processInfo.arguments.contains("--review-folder-opening")
            && Bundle.main.bundleIdentifier == "com.respawnstudios.traverse"
    }
}

struct FolderOpeningApplication: Equatable, Sendable {
    let url: URL
    let name: String
}

enum FolderOpeningFailure: Error, Equatable { case declined, unavailable, failed, notQualified }

protocol FolderOpeningService: Sendable {
    func current() async throws -> FolderOpeningApplication?
    func request(application: URL) async throws
}

/// Launch Services work is submitted off the main actor. This adapter has no
/// startup observer or preference write; the actual setter remains gated.
struct NativeFolderOpeningService: FolderOpeningService {
    var permitsOwnerReview = false
    private static let queue = DispatchQueue(label: "Traverse.FolderOpening", qos: .utility)
    func current() async throws -> FolderOpeningApplication? {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                let app = NSWorkspace.shared.urlForApplication(toOpen: .folder).map {
                    FolderOpeningApplication(url: $0, name: $0.deletingPathExtension().lastPathComponent)
                }
                continuation.resume(returning: app)
            }
        }
    }
    func request(application: URL) async throws {
        guard FolderOpeningFeature.ordinaryEnabled || permitsOwnerReview && FolderOpeningFeature.ownerReview else { throw FolderOpeningFailure.notQualified }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                NSWorkspace.shared.setDefaultApplication(at: application, toOpen: .folder) { error in
                    if let error {
                        continuation.resume(throwing: (error as NSError).code == NSUserCancelledError
                            ? FolderOpeningFailure.declined : FolderOpeningFailure.failed)
                    } else { continuation.resume() }
                }
            }
        }
    }
}

/// Native presentation owner, independent of the Settings view's lifetime.
/// It keeps an in-flight system request alive even after presentation closes.
@MainActor final class FolderOpeningPreferenceModel: ObservableObject {
    enum Phase: Equatable { case idle, checking, requesting }
    enum Outcome: Equatable {
        case none, current, other, unavailable, changedElsewhere, declined, failed, unverified
    }
    struct Proposal: Equatable {
        fileprivate let epoch: UUID
        fileprivate let previous: FolderOpeningApplication
        fileprivate let target: URL
    }
    @Published private(set) var current: FolderOpeningApplication?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var outcome: Outcome = .none
    private(set) var isPresented = false
    private let service: any FolderOpeningService
    private let target: URL
    private let settings: BrowserSettings?
    private var epoch = UUID(), pendingRefresh = false
    private var work: Task<Void, Never>?

    init(service: any FolderOpeningService, application: URL = Bundle.main.bundleURL, settings: BrowserSettings? = nil) {
        self.service = service; target = application.standardizedFileURL; self.settings = settings
    }
    var isCurrent: Bool { current?.url.standardizedFileURL == target }
    var canRequest: Bool { isPresented && phase == .idle && current != nil && !isCurrent }
    var canRestore: Bool { isPresented && phase == .idle && isCurrent && settings?.previousFolderApplication != nil }
    var status: String {
        switch phase {
        case .checking: return "Checking folder opening…"
        case .requesting: return "Waiting for macOS to finish the request…"
        case .idle: break
        }
        switch outcome {
        case .none: return "Choose which app opens folders."
        case .current: return "Folders are set to open in Traverse."
        case .other: return current.map { "Folders currently open in \($0.name)." } ?? "The current folder-opening app is unavailable."
        case .unavailable: return "The current folder-opening app could not be checked. Try Refresh."
        case .changedElsewhere: return "The folder-opening app changed. Review the current choice before trying again."
        case .declined: return "The request was cancelled. The previous folder-opening app is still selected."
        case .failed: return "The request could not be completed. Review the current choice before trying again."
        case .unverified: return "The requested choice could not be confirmed. Try Refresh."
        }
    }
    func open() {
        isPresented = true; epoch = UUID(); refresh()
    }
    func close() {
        isPresented = false; epoch = UUID(); pendingRefresh = false
        current = nil; outcome = .none
        // Do not cancel or discard a still-running native request.
        if work == nil { phase = .idle }
    }
    func refresh() {
        guard isPresented else { return }
        guard work == nil else { pendingRefresh = true; return }
        let ticket = epoch; phase = .checking
        work = Task { [self] in
            defer { finished() }
            do {
                let observed = try await service.current()
                guard isPresented, epoch == ticket else { return }
                current = observed
                outcome = observed == nil ? .unavailable : isCurrent ? .current : .other
            } catch {
                guard isPresented, epoch == ticket else { return }
                current = nil; outcome = .unavailable
            }
        }
    }
    func proposal() -> Proposal? {
        guard canRequest, let current else { return nil }
        return Proposal(epoch: epoch, previous: current, target: target)
    }
    @discardableResult func confirm(_ proposal: Proposal) -> Bool {
        guard canRequest, proposal.epoch == epoch, proposal.previous == current,
              proposal.target == target, work == nil else { return false }
        // Consume the exact confirmation once, including declined requests.
        epoch = UUID(); let ticket = epoch; phase = .requesting
        work = Task { [self] in
            defer { finished() }
            var failure: FolderOpeningFailure?
            do {
                let fresh = try await service.current()
                guard isPresented, epoch == ticket else { return }
                guard fresh == proposal.previous else {
                    current = fresh; outcome = .changedElsewhere; return
                }
                try await settings?.rememberPreviousFolderApplication(proposal.previous.url)
                do { try await service.request(application: proposal.target) }
                catch { failure = (error as? FolderOpeningFailure) ?? .failed }
                // A callback is not proof of the currently selected handler.
                let readback = try await service.current()
                guard isPresented, epoch == ticket else { return }
                current = readback
                if isCurrent { outcome = .current }
                else if readback == nil { outcome = .unverified }
                else if failure == .declined && readback == proposal.previous { outcome = .declined }
                else if failure != nil { outcome = .failed }
                else { outcome = .unverified }
            } catch {
                guard isPresented, epoch == ticket else { return }
                current = nil; outcome = .unverified
            }
        }
        return true
    }
    func restorePrevious() {
        guard canRestore, work == nil, let previous = settings?.previousFolderApplication else { return }
        epoch = UUID(); let ticket = epoch; phase = .requesting
        work = Task { [self] in
            defer { finished() }
            do {
                let fresh = try await service.current()
                guard isPresented, epoch == ticket else { return }
                guard fresh?.url.standardizedFileURL == target else {
                    current = fresh; outcome = .changedElsewhere; return
                }
                try await service.request(application: previous)
                let readback = try await service.current()
                guard isPresented, epoch == ticket else { return }
                current = readback
                if readback?.url.standardizedFileURL == previous.standardizedFileURL {
                    try await settings?.rememberPreviousFolderApplication(nil)
                    outcome = .other
                } else { outcome = .unverified }
            } catch {
                guard isPresented, epoch == ticket else { return }
                outcome = .failed // Preserve the exact recovery choice.
            }
        }
    }
    private func finished() {
        work = nil; phase = .idle
        if pendingRefresh && isPresented { pendingRefresh = false; refresh() }
    }
    func drain() async { while let work { await work.value } }
}

struct FolderOpeningPreferenceView: View {
    @ObservedObject var model: FolderOpeningPreferenceModel
    let onRequest: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Open folders with Traverse", systemImage: "folder.badge.gearshape").interfaceFont(.headline)
            HStack(spacing: 12) {
                Text(model.status).interfaceFont(.callout)
                Spacer(minLength: 8)
                if model.phase != .idle { ProgressView().controlSize(.small) }
                Button("Refresh", action: model.refresh).disabled(model.phase != .idle)
            }
            Text("Use Traverse when another app asks your Mac to open a folder. Some apps open Finder directly. Open and Save windows keep their usual behaviour.")
                .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(model.isCurrent ? "Traverse is selected" : "Use Traverse…", action: onRequest).disabled(!model.canRequest)
            if model.canRestore { Button("Restore Previous App", action: model.restorePrevious) }
        }
    }
}

struct FolderOpeningSettingsView: View {
    @StateObject private var model: FolderOpeningPreferenceModel
    @State private var window: NSWindow?
    init(settings: BrowserSettings) {
        _model = StateObject(wrappedValue: FolderOpeningPreferenceModel(service: NativeFolderOpeningService(permitsOwnerReview: true), settings: settings))
    }
    var body: some View {
        FolderOpeningPreferenceView(model: model) {
            if let window { FolderOpeningConfirmation.present(model: model, window: window) }
        }
        .background(FolderOpeningWindowReader(changed: { window = $0 }).frame(width: 0, height: 0))
        .onAppear { model.open() }.onDisappear { model.close() }
    }
}

private struct FolderOpeningWindowReader: NSViewRepresentable {
    let changed: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(changed) }
    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }
    final class Reader: NSView {
        var changed: @MainActor (NSWindow?) -> Void
        init(_ changed: @escaping @MainActor (NSWindow?) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed(window) }
    }
}

@MainActor enum FolderOpeningConfirmation {
    @discardableResult static func present(model: FolderOpeningPreferenceModel, window: NSWindow) -> Bool {
        guard window.isVisible, window.attachedSheet == nil, let proposal = model.proposal() else { return false }
        let alert = NSAlert()
        alert.messageText = "Open folders with Traverse?"
        alert.informativeText = "This asks macOS to use Traverse for folders in place of \(proposal.previous.name). macOS may ask you to confirm. Finder remains available."
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak model, weak window] response in
            guard response == .alertFirstButtonReturn, let model, window?.isVisible == true else { return }
            _ = model.confirm(proposal)
        }
        return true
    }
}
