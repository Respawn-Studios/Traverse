import SwiftUI

struct CrashReportsView: View {
    @ObservedObject var owner: ApplicationCrashReports
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Crash Reports & Feedback").interfaceFont(.title2.bold())
                Spacer()
                if !owner.reports.isEmpty {
                    Menu("Reports (\(owner.reports.count))") {
                        ForEach(owner.reports) { report in
                            Button("\(report.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date") · \(report.signal.rawValue)") {
                                owner.select(report.id)
                            }
                        }
                    }
                }
            }
            Text("Native captures stay local. Review and edit the shareable text below; add what you were doing and steps to reproduce the problem.")
                .foregroundStyle(.secondary)
            TextEditor(text: $owner.document)
                .interfaceFont(.system(.body, design: .monospaced))
                .accessibilityLabel("Editable report to review before sharing")
                .border(.separator.opacity(0.4))
            ViewThatFits(in: .horizontal) {
                HStack { privacyControls; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { privacyControls }
            }.disabled(owner.working)
            Text(owner.notice).interfaceFont(.callout).foregroundStyle(.secondary)
                .accessibilityLabel("Report status: " + owner.notice)
            Divider()
            Text("Opening sends this text to GitHub and browser history. The issue stays a draft until you submit.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    secondaryShareControls
                    Spacer()
                    githubControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    githubControl
                    HStack { secondaryShareControls }
                }
            }.disabled(owner.working || owner.document.isEmpty)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 460)
    }

    @ViewBuilder private var privacyControls: some View {
        Button("Hide Private Details", action: owner.redact)
        Button("Add Current Device Info", action: owner.addCurrentDeviceInfo).disabled(owner.hasCurrentDeviceInfo)
        if owner.canDiscardPending {
            Button("Discard Unreadable Capture…", action: owner.discardUnreadableCapture)
        }
        if owner.selected != nil {
            Menu("More") {
                Button("Include Other Threads", action: owner.addOtherThreads).disabled(owner.includeOtherThreads)
                Button("Remove Local Copy…", action: owner.removeSelected)
            }
        }
    }
    @ViewBuilder private var secondaryShareControls: some View {
        Button("Save Report…", action: owner.saveReport)
        Button("Copy Report", action: owner.copyReport)
    }
    private var githubControl: some View {
        Button("Open GitHub Draft", action: owner.openGitHubDraft).buttonStyle(.borderedProminent)
            .help("Includes the reviewed text when it fits the browser URL limit; otherwise the draft is marked as abbreviated. Copy or save the full report separately.")
    }
}
