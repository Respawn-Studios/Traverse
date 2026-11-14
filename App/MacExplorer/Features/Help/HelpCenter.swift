import AppKit
import ExplorerCore
import LocalStorage
import SwiftUI
import UniformTypeIdentifiers

enum TraverseHelpPage: String, CaseIterable, Identifiable {
    case whatsNew, diagnostics, updates, support, community, about
    var id: Self { self }
    var title: String {
        switch self { case .whatsNew: "What's New"; case .diagnostics: "App Logs"; case .updates: "Updates"; case .support: "Get Help"; case .community: "Support Traverse"; case .about: "About" }
    }
    var symbol: String {
        switch self { case .whatsNew: "sparkles"; case .diagnostics: "terminal"; case .updates: "arrow.down.circle"; case .support: "questionmark.circle"; case .community: "heart"; case .about: "info.circle" }
    }
    var checkpoint: DiagnosticCheckpoint {
        switch self { case .whatsNew: .helpWhatsNew; case .diagnostics: .helpLogs; case .updates: .helpUpdates; case .support, .community: .helpSupport; case .about: .helpAbout }
    }
}

@MainActor final class DiagnosticHistoryModel: ObservableObject {
    @Published var events: [DiagnosticEvent] = []
    @Published var selected: UUID?
    @Published var errorsOnly = false
    @Published private(set) var traceFilter: UUID?
    @Published private(set) var working = false
    @Published private(set) var notice = ""
    @Published private(set) var interruptedExportNotice = ""
    @Published private(set) var incomplete = false
    @Published private(set) var canLoadOlder = false
    @Published private(set) var canLoadNewer = false
    private var next: DiagnosticHistoryCursor?
    private var current: DiagnosticHistoryCursor?
    private var previous: [DiagnosticHistoryCursor?] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var exportCancellation: DiagnosticExportCancellation?
    private var readCancellation: DiagnosticExportCancellation?
    private var exportPanel: NSSavePanel?
    var service: DiagnosticRecorder? { ApplicationDiagnostics.shared.recorder }
    var selectedEvent: DiagnosticEvent? { events.first { $0.id == selected } }
    var visibleEvents: [DiagnosticEvent] { events }
    var recording: Bool { service?.status.recording == true }
    var dropped: UInt64 { service?.status.dropped ?? 0 }
    var unavailable: Bool { service == nil || service?.status.failure != nil }

    func refresh() { watchStatus(); previous = []; current = nil; load(nil) }
    func followOperation(_ trace: UUID?) {
        guard traceFilter != trace || trace != nil && errorsOnly else { return }
        if trace != nil { errorsOnly = false }
        traceFilter = trace; refresh()
    }
    private func watchStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            var priorRecording: Bool?, priorDropped: UInt64?, priorFailure: DiagnosticHistoryFailure?
            while !Task.isCancelled {
                guard let self else { return }
                let status = self.service?.status
                if status?.recording != priorRecording || status?.dropped != priorDropped || status?.failure != priorFailure {
                    self.objectWillChange.send()
                    priorRecording = status?.recording; priorDropped = status?.dropped; priorFailure = status?.failure
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func older() {
        guard !working, let next else { return }
        if previous.count >= 64 { previous.removeFirst() }
        previous.append(current); current = next; load(next)
    }
    func newer() {
        guard !working, !previous.isEmpty else { return }
        current = previous.removeLast(); load(current)
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        readCancellation?.cancel(); readCancellation = nil
        statusTask?.cancel(); statusTask = nil
        exportPanel?.cancel(nil); exportPanel = nil
        exportCancellation?.cancel(); exportCancellation = nil; working = false
    }
    private func load(_ cursor: DiagnosticHistoryCursor?) {
        generation = UUID(); let token = generation
        task?.cancel(); readCancellation?.cancel()
        let cancellation = DiagnosticExportCancellation(); readCancellation = cancellation
        let scope = traceFilter.map(DiagnosticLogScope.operation) ?? .all
        working = true; notice = ""
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let service = self.service else { self.working = false; self.notice = "App logs are unavailable in this session."; return }
                let page = try await service.page(before: cursor, limit: 128, errorsOnly: errorsOnly,
                                                  scope: scope, cancellation: cancellation)
                guard self.generation == token, !Task.isCancelled else { return }
                self.events = page.events; self.next = page.next
                self.incomplete = page.incomplete; self.canLoadOlder = page.next != nil
                self.canLoadNewer = !self.previous.isEmpty
                if !self.visibleEvents.contains(where: { $0.id == self.selected }) { self.selected = self.visibleEvents.first?.id }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.events = []; self.selected = nil; self.next = nil
                self.canLoadOlder = false; self.canLoadNewer = !self.previous.isEmpty
                self.notice = "Some app logs could not be read. You can pause recording and try again."
            }
            if self.generation == token { self.working = false; self.task = nil; self.readCancellation = nil }
        }
    }
    func clear() {
        cancel(); let token = generation; working = true
        task = Task { [weak self] in
            guard let self else { return }
            do { try await service?.clear() }
            catch {
                if self.generation == token {
                    self.notice = "App logs could not be cleared completely. Some earlier entries may remain."
                    self.working = false; self.task = nil
                }
                return
            }
            guard self.generation == token, !Task.isCancelled else { return }
            self.working = false; self.refresh()
        }
    }
    func export(in window: NSWindow, scope: DiagnosticLogScope = .all) {
        guard !working, let service else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let operationExport: Bool
        if case .operation = scope { operationExport = true } else { operationExport = false }
        panel.nameFieldStringValue = (operationExport ? "Traverse-Operation-" : "Traverse-Diagnostics-") + formatter.string(from: Date()) + ".json"
        panel.canCreateDirectories = false; panel.prompt = "Save App Logs"
        exportPanel = panel
        panel.message = (operationExport
            ? "Export this operation and its linked steps from all retained app logs, including entries outside the current page. "
            : "Export all retained app logs, including events outside the current page and filter. ")
            + "The report contains app/system versions, technical checkpoints, state, timings, errors and correlation IDs. File names, paths, search text, passwords and contents are excluded. Review it before sharing and choose a new filename."
        let token = generation
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.exportPanel = nil
            guard response == .OK, let url = panel.url, self.generation == token else { return }
            let access = FolderAccessLease(url: url, backend: SystemFolderAccessBackend())
            let cancellation = DiagnosticExportCancellation(); self.exportCancellation = cancellation; self.working = true
            let metadata = ApplicationDiagnostics.shared.exportMetadata
            self.task = Task { [weak self] in
                let outcome = await service.export(to: url, retainingAccess: access, cancellation: cancellation,
                    scope: scope, metadata: metadata)
                switch outcome {
                case .saved(let records,_,_): ApplicationDiagnostics.shared.event(.diagnostics,.completed,count:UInt64(records))
                case .createdButIncomplete(let failure): ApplicationDiagnostics.shared.event(.diagnostics,.partial,error:DiagnosticErrors.project(failure))
                case .notCreated(let failure): ApplicationDiagnostics.shared.event(.diagnostics,failure == .cancelled ? .cancelled : .failed,error:DiagnosticErrors.project(failure))
                }
                guard let self else { return }
                if case .createdButIncomplete = outcome {
                    self.interruptedExportNotice = "An export left a partial file. Review or discard the file you chose before sharing it. Clearing history will not remove an export."
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.working = false; self.exportCancellation = nil; self.task = nil
                switch outcome {
                case .saved(let records, _, let partial):
                    self.notice = "Saved \(records) events." + (partial ? " Some earlier history was incomplete." : " Review the file before sharing it.")
                case .notCreated(.alreadyExists): self.notice = "That filename already exists. Choose a new name; nothing was replaced."
                case .notCreated(.empty): self.notice = operationExport ? "No retained app logs remain for this operation." : "There are no app logs to export."
                case .notCreated(.cancelled): self.notice = "Export cancelled. No file was created."
                case .notCreated(.accessDenied): self.notice = "Folder access was denied. Choose an ordinary local folder and try again."
                case .notCreated: self.notice = "App logs or their destination could not be read or written. No export was created. Refresh the logs and try again."
                case .createdButIncomplete: self.notice = "A partial export was created. Review or discard that file before sharing; it may be incomplete."
                }
            }
        }
    }
}

@MainActor final class TraverseHelpController: NSWindowController, NSWindowDelegate, ObservableObject {
    static let shared = TraverseHelpController()
    @Published var page = TraverseHelpPage.whatsNew
    @Published private(set) var sensitiveRevision = UUID()
    #if DEBUG
    var controlFramesForVerification: [String:CGRect] = [:]
    #endif
    let history = DiagnosticHistoryModel()
    private var settings: BrowserSettings?
    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { nil }
    func show(_ page: TraverseHelpPage, from browser: BrowserViewController, offscreen: Bool = false) {
        show(page, settings: browser.settings, offscreen: offscreen)
    }
    func showOperationLogs(_ trace: UUID, from browser: BrowserViewController) {
        show(.diagnostics, from: browser)
        history.followOperation(trace)
    }
    #if DEBUG
    func showForMotionVerification(_ page: TraverseHelpPage, settings: BrowserSettings) {
        show(page, settings: settings, offscreen: false)
    }
    #endif
    private func show(_ page: TraverseHelpPage, settings: BrowserSettings, offscreen: Bool) {
        self.page = page; self.settings = settings
        let window: NSWindow
        if let existing = self.window { window = existing }
        else {
            window = ToolWindowChrome.makeWindow(title: "Traverse Help", size: .init(width: 880, height: 650),
                minimumSize: .init(width: 720, height: 600), styleMask: [.titled, .closable, .resizable])
            window.delegate = self
            self.window = window; ToolWindowChrome.position(window, relativeTo: NSApp.mainWindow)
        }
        let firstPresentation = window.contentViewController == nil
        ToolWindowCloseMotion.cancel(window)
        if let content = (window.contentViewController as? ToolWindowChrome)?.children.first as? InterfaceHostingController<TraverseHelpView> {
            content.sizingOptions = []
            content.rootView = InterfaceRoot(content: TraverseHelpView(owner: self, settings: settings, history: history))
        } else {
            let content = InterfaceHostingController(rootView: TraverseHelpView(owner: self, settings: settings, history: history))
            content.sizingOptions = []
            window.contentViewController = content
        }
        ToolWindowChrome.install(in: window, settings: settings)
        window.minSize = .init(width: 720, height: 600)
        // Hosting can initially choose its minimum fitting size. Preserve a
        // useful first presentation; later visits retain the user's size.
        if firstPresentation {
            window.setContentSize(.init(width: 880, height: 650))
            ToolWindowChrome.position(window, relativeTo: NSApp.mainWindow)
        }
        if !offscreen { showWindow(nil); window.makeKeyAndOrderFront(nil) }
        if page == .diagnostics { history.refresh() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sensitiveRevision = UUID(); history.cancel()
        return ToolWindowCloseMotion.shouldClose(sender)
    }
    func windowWillClose(_ notification: Notification) { sensitiveRevision = UUID(); history.cancel() }
    func open(_ path: String) {
        let permitted = ["","support/","report-a-bug/","feedback/","privacy/","changelog/"]
        guard permitted.contains(path), let url = URL(string: "https://respawn-studios.com/products/traverse/" + path) else { return }
        ApplicationDiagnostics.shared.event(.support, .dispatched)
        NSWorkspace.shared.open(url)
    }
}

private struct TraverseHelpView: View {
    @ObservedObject var owner: TraverseHelpController
    @ObservedObject var settings: BrowserSettings
    @ObservedObject var history: DiagnosticHistoryModel
    @ObservedObject private var updates = ApplicationUpdates.shared
    @State private var invitation = ""
    @State private var rememberInvitation = false
    var body: some View {
        HStack(spacing: 0) {
            ToolNavigationSidebar(scale: settings.interfaceSize.scale) {
                Text("Help").interfaceFont(.headline)
            } content: {
                NativeToolPageNavigation(selection: $owner.page, scale: settings.interfaceSize.scale,
                    items: TraverseHelpPage.allCases.map { .init(id: $0, title: $0.title, symbolName: $0.symbol) },
                    identifier: "help-navigation", accessibilityLabel: "Help sections")
                    .frame(minHeight: ceil(CGFloat(TraverseHelpPage.allCases.count) * (34 * settings.interfaceSize.scale + 4)))
            } footer: {
                Text("Help, app logs and updates.\nYour files stay yours.").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Divider()
            NativeToolPageHost(page: owner.page, content: AnyView(detail(owner.page)), motion: settings.motion)
        }
        .helpControlFrame("help-body")
        .coordinateSpace(name: "traverse-help-layout")
        #if DEBUG
        .onPreferenceChange(HelpControlFrames.self) { frames in
            Task { @MainActor in
                let detail = owner.controlFramesForVerification.filter { !$0.key.hasPrefix("help-page-") && $0.key != "help-body" }
                owner.controlFramesForVerification = detail.merging(frames, uniquingKeysWith: { _, new in new })
            }
        }
        #endif
        .onChange(of: owner.page) { _, page in
            if page != .updates {
                // Clearing the private field editor must not end keyboard
                // navigation in this window's existing native page list.
                let navigation = owner.window?.firstResponder as? NSTableView
                invitation = ""; clearPrivateTextUndo(in:owner.window)
                if let navigation, navigation.identifier?.rawValue == "help-navigation",
                   navigation.window === owner.window {
                    owner.window?.makeFirstResponder(navigation)
                }
            }
            if page == .diagnostics { history.refresh() } else { history.cancel() }
            ApplicationDiagnostics.shared.event(.help, .presenting, context: .init(page.checkpoint))
        }
        .onChange(of: owner.sensitiveRevision) { _,_ in invitation = ""; rememberInvitation = false; clearPrivateTextUndo(in:owner.window) }
    }
    private func detail(_ page: TraverseHelpPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(page.title, systemImage: page.symbol).interfaceFont(.title2.bold())
            Group {
                switch page {
                case .whatsNew: releaseNotes
                case .diagnostics: diagnosticHistory
                case .updates: updateSettings
                case .support: support
                case .community: CommunitySupportView(settings: settings) { owner.window?.performClose(nil) }
                case .about: about
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "traverse-help-layout")
        #if DEBUG
        .backgroundPreferenceValue(HelpControlFrames.self) { frames in
            HelpDetailFrameBridge(owner: owner, page: page, frames: frames)
        }
        #endif
    }
    private var releaseNotes: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("Changes, fixes and improvements, version by version.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
                ForEach(TraverseReleaseNotes.all) { release in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("\(release.version) (\(release.build))").interfaceFont(.headline)
                            if release.state != .published { Text(release.state == .preview ? "Beta" : "In development").interfaceFont(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.12), in: Capsule()) }
                            Spacer(); Text(release.date).interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                        Text(release.title).interfaceFont(.title3.weight(.semibold))
                        Text(release.summary).foregroundStyle(.secondary)
                        ForEach(release.changes, id: \.self) { change in
                            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.secondary); Text(change).fixedSize(horizontal: false, vertical: true) }
                        }
                        Divider().padding(.top, 9)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var diagnosticHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Record app logs", isOn: $settings.diagnosticHistoryEnabled)
            Text("Technical logs for troubleshooting: checkpoints, worker stages, state, timings, error symbols and command/job correlations. Kept on this Mac for up to 14 days / 64 MiB. File names, paths, search text, passwords and file contents are excluded.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Warnings and errors", isOn: $history.errorsOnly).toggleStyle(.checkbox).onChange(of: history.errorsOnly) { _,_ in history.refresh() }
                Spacer()
                if history.working { ProgressView().controlSize(.small) }
                Button("Refresh") { history.refresh() }.disabled(history.working)
                Menu("Export…") {
                    Button("All Retained App Logs…") { if let window = owner.window { history.export(in: window) } }
                    Button("This Operation…") {
                        if let trace = history.selectedEvent?.trace, let window = owner.window {
                            history.export(in: window, scope: .operation(trace))
                        }
                    }.disabled(history.selectedEvent == nil)
                }.disabled(history.working || history.service == nil)
                    .accessibilityIdentifier("help-log-export")
                    .helpControlFrame("help-log-export")
            }
            HStack {
                Button("Follow Operation") { history.followOperation(history.selectedEvent?.trace) }.disabled(history.selectedEvent == nil)
                    .help("Show this operation and linked steps from all retained app logs, including older pages.")
                if history.traceFilter != nil { Button("All Operations") { history.followOperation(nil) } }
                Spacer(); Text("\(history.visibleEvents.count) entries on this page").interfaceFont(.caption.monospaced()).foregroundStyle(.secondary)
            }
            List(selection: $history.selected) {
                ForEach(history.visibleEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("[\(event.level.rawValue.uppercased())] \(event.action.rawValue).\(event.phase.rawValue)")
                                .interfaceFont(.system(.caption, design: .monospaced)).fontWeight(.medium)
                            Spacer()
                            if let error = event.error { Text(error.symbol ?? "\(error.domain.rawValue):\(error.code)").interfaceFont(.caption.monospaced()).foregroundStyle(event.level == .error ? .red : .secondary) }
                        }
                        Text(Self.timestamp(event.utcMilliseconds) + "  " + (event.context?.checkpoint.rawValue ?? Self.phaseTitle(event)))
                            .interfaceFont(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(event.id)
                }
            }.scrollContentBackground(.hidden).frame(minHeight: 100)
            if let selected = history.selectedEvent {
                ScrollView([.horizontal,.vertical]) {
                    Text(Self.rawEntry(selected)).interfaceFont(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 60, maxHeight: 140)
            }
            if history.unavailable || history.dropped > 0 || history.incomplete || !history.notice.isEmpty || !history.interruptedExportNotice.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if history.unavailable { Text("Recording is unavailable. File work and recovery remain separate.").foregroundStyle(.orange) }
                        if history.dropped > 0 || history.incomplete { Text("Some events are missing or unconfirmed. These logs are incomplete.").foregroundStyle(.orange) }
                        if !history.notice.isEmpty { Text(history.notice).foregroundStyle(.secondary) }
                        if !history.interruptedExportNotice.isEmpty { Text(history.interruptedExportNotice).foregroundStyle(.orange) }
                    }.interfaceFont(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 64)
            }
            HStack {
                Button("Newer") { history.newer() }.disabled(!history.canLoadNewer || history.working).accessibilityIdentifier("help-log-newer").helpControlFrame("help-log-newer")
                Button("Older") { history.older() }.disabled(!history.canLoadOlder || history.working).accessibilityIdentifier("help-log-older").helpControlFrame("help-log-older")
                Spacer(); DiagnosticClearButton(history: history)
            }.layoutPriority(1)
        }
    }
    private static func rawEntry(_ event: DiagnosticEvent) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "Log entry unavailable"
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Traverse")
                        .interfaceFont(.largeTitle.bold())
                    Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        + " · Build " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))
                        .interfaceFont(.callout.monospaced())
                    Text(AppFeatureAvailability.editionTitle)
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                }
            }
            Text("A native Mac file explorer for everyday work and more demanding workflows. Browse with tabs and panes, organise files, inspect storage and connect to your servers.")
            Text("Made by Respawn Studios.").foregroundStyle(.secondary)
            Text("Free and open source · GNU GPLv3 · no warranty").interfaceFont(.callout).foregroundStyle(.secondary)
            Button("GNU GPLv3 License…") { ApplicationNotices.projectLicense.show(settings: settings) }
            if Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "development-preview" {
                Text("Local preview · separate from your installed beta").interfaceFont(.callout).foregroundStyle(.secondary)
            } else if Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "development" {
                Text("Development build · separate from your installed beta").interfaceFont(.callout).foregroundStyle(.secondary)
            }
            Text("Your feedback helps us make Traverse more reliable. What’s New describes this build’s features and limits.")
                .interfaceFont(.callout).foregroundStyle(.secondary)
            Button("Visit Traverse ↗") { owner.open("") }
            Spacer()
        }
    }
    private var support: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tell us what you expected, what happened and the steps that led to it. Review any diagnostic export or screenshot before sharing.").foregroundStyle(.secondary)
            Button { ApplicationCrashReports.shared.show(settings: settings, newBug: true) } label: {
                Label("Report a Bug…", systemImage: "ladybug").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered)
            Button { ApplicationCrashReports.shared.show(settings: settings) } label: {
                Label("Crash Reports & Feedback…", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered)
            ForEach([("Support", "support/"), ("Send Feedback", "feedback/"), ("Privacy", "privacy/")], id: \.1) { title,path in
                Button { owner.open(path) } label: { Label(title, systemImage: "arrow.up.right").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.bordered).help("Opens the Traverse website in your browser")
            }
            Text("support@respawn-studios.com").textSelection(.enabled).interfaceFont(.callout)
            Spacer()
        }
    }
    private var updateSettings: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Traverse " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")
                + " (" + (Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "") + ")").interfaceFont(.headline)
            if updates.directUpdatesAvailable {
                Text("Review changes and choose when to install. Traverse asks before downloading an update and restarting.").foregroundStyle(.secondary)
                if updates.requiresInvitation {
                    Toggle("Automatically check every six hours", isOn:$settings.automaticUpdateChecks)
                } else {
                    Toggle("Automatically check every six hours", isOn:$settings.publicAutomaticUpdateChecks)
                    Text("Checks are optional. They retrieve the signed update list; no invitation or saved update password is needed.")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                }
                if updates.requiresInvitation && !updates.hasInvitation {
                    Text("Private beta access").interfaceFont(.headline)
                    Text("Use the invitation password supplied with your beta. It isn't included in diagnostic history.").interfaceFont(.callout).foregroundStyle(.secondary)
                    SecureField("Invitation password",text:$invitation).textFieldStyle(ToolTextEntryStyle()).privacySensitive()
                        .accessibilityIdentifier("help-update-invitation")
                        .onSubmit { submitInvitation() }
                    Toggle("Save beta access in Keychain",isOn:$rememberInvitation)
                    Text("Without saving, enter the invitation again after quitting Traverse.").interfaceFont(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Continue and Check") { submitInvitation() }.disabled(updates.working || invitation.isEmpty)
                        if updates.working { ProgressView().controlSize(.small) }
                    }
                } else {
                    HStack {
                        Button("Check for Updates") { updates.check() }.disabled(updates.working)
                        if updates.requiresInvitation {
                            Button("Use a Different Invitation") { rememberInvitation = settings.updateInvitationSaved; updates.enterDifferentInvitation() }.disabled(updates.working)
                        }
                        if updates.working { ProgressView().controlSize(.small) }
                    }
                }
                if updates.requiresInvitation {
                    Button(settings.updateInvitationSaved ? "Forget Saved Beta Access" : "Forget Beta Access") { updates.forgetInvitation() }.disabled(updates.working)
                }
                if updates.retryRestartAvailable { Button("Restart to Update") { updates.retryRestart() } }
                if let checked = updates.lastChecked { Text("Last checked " + checked.formatted(date:.abbreviated,time:.shortened)).interfaceFont(.caption).foregroundStyle(.secondary) }
                if !updates.notice.isEmpty { Text(updates.notice).interfaceFont(.callout).textSelection(.enabled) }
                if !updates.credentialNotice.isEmpty { Text(updates.credentialNotice).interfaceFont(.caption).foregroundStyle(.secondary) }
                Text("Updates use a verified download. Active file work and recovery must finish before Traverse can quit. Manual installers and your Undo history are kept.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            } else { Text(updates.editionMessage).foregroundStyle(.secondary) }
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func submitInvitation() {
        updates.useInvitation(invitation,remember:rememberInvitation)
        invitation = ""
        clearPrivateTextUndo(in:owner.window)
    }
    private static func diagnosticTitle(_ token: String) -> String {
        var result = ""
        for character in token {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(character)
        }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
    private static func phaseTitle(_ event: DiagnosticEvent) -> String {
        if event.action == .queue {
            switch event.phase {
            case .resolving: return "Checking access"
            case .preparing: return "Checking sources"
            case .verifying: return "Checking destination"
            case .dispatched: return "Starting transfer"
            case .waiting: return "Ready and waiting"
            default: break
            }
        }
        return diagnosticTitle(event.phase.rawValue)
    }
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS 'UTC'"
        return formatter
    }()
    private static func timestamp(_ milliseconds: Int64) -> String {
        timestampFormatter.string(from: Date(timeIntervalSince1970: Double(milliseconds)/1000))
    }
}

private struct DiagnosticClearButton: View {
    @ObservedObject var history: DiagnosticHistoryModel
    @State private var confirms = false
    var body: some View {
        Button("Clear Logs…", role: .destructive) { confirms = true }.disabled(history.working)
            .accessibilityIdentifier("help-log-clear")
            .helpControlFrame("help-log-clear")
            .alert("Clear local app logs?", isPresented: $confirms) {
                Button("Clear Logs", role: .destructive) { history.clear() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes Traverse's current diagnostic events. Your files, Undo/recovery data and exports you already saved stay in place.") }
    }
}

#if DEBUG
/// Preferences stop at an independent native host. Translate only generated
/// layout rectangles back into the outer Help coordinates for existing checks.
private struct HelpDetailFrameBridge: NSViewRepresentable {
    let owner: TraverseHelpController
    let page: TraverseHelpPage
    let frames: [String: CGRect]
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor [weak view, weak owner] in
            guard let view, let owner, owner.page == page,
                  let root = (view.window?.contentViewController as? ToolWindowChrome)?.children.first?.view else { return }
            view.window?.contentView?.layoutSubtreeIfNeeded()
            let translated = frames.mapValues { frame in
                let local = NSRect(x: frame.minX, y: view.isFlipped ? frame.minY : view.bounds.height - frame.maxY,
                    width: frame.width, height: frame.height)
                let native = view.convert(local, to: root)
                return NSRect(x: native.minX, y: root.isFlipped ? native.minY : root.bounds.height - native.maxY,
                    width: native.width, height: native.height)
            }
            let sidebar = owner.controlFramesForVerification.filter { $0.key.hasPrefix("help-page-") || $0.key == "help-body" }
            owner.controlFramesForVerification = sidebar.merging(translated, uniquingKeysWith: { _, new in new })
        }
    }
}

private struct HelpControlFrames: PreferenceKey {
    static var defaultValue: [String:CGRect] { [:] }
    static func reduce(value: inout [String:CGRect], nextValue: () -> [String:CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _,new in new })
    }
}
#endif

private extension View {
    @ViewBuilder func helpControlFrame(_ id: String) -> some View {
        #if DEBUG
        background(GeometryReader { geometry in
            Color.clear.preference(key: HelpControlFrames.self,
                value: [id:geometry.frame(in: .named("traverse-help-layout"))])
        })
        #else
        self
        #endif
    }
}

@MainActor extension BrowserViewController {
    @objc func showWhatsNew(_ sender: Any?) { ApplicationDiagnostics.shared.event(.releaseNotes,.requested); TraverseHelpController.shared.show(.whatsNew, from: self) }
    @objc func showCommunitySupport(_ sender: Any?) { TraverseHelpController.shared.show(.community, from: self) }
    @objc func showDiagnosticHistory(_ sender: Any?) { TraverseHelpController.shared.show(.diagnostics, from: self) }
    @objc func showTraverseAbout(_ sender: Any?) { TraverseHelpController.shared.show(.about, from: self) }
    @objc func showAppUpdates(_ sender: Any?) {
        TraverseHelpController.shared.show(.updates, from: self)
        if ApplicationUpdates.shared.hasUpdateAccess { ApplicationUpdates.shared.check() }
    }
    @objc func openTraverseSupport(_ sender: Any?) { TraverseHelpController.shared.open("support/") }
    @objc func openTraverseBugReport(_ sender: Any?) { ApplicationCrashReports.shared.show(settings: settings, newBug: true) }
    @objc func openTraverseFeedback(_ sender: Any?) { TraverseHelpController.shared.open("feedback/") }
}
