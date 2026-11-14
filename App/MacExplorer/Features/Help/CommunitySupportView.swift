import AppKit
import SwiftUI

struct CommunitySupportView: View {
    @ObservedObject var settings: BrowserSettings
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Free to use. Yours to improve.").interfaceFont(.title2.bold())
                Text("Traverse is free and open source under GNU GPLv3. You can use, study, modify and share it. Supporting development is optional and unlocks no extra features.")
                    .interfaceFont(.body)
                Text("Bug reports, translations, documentation and code contributions help make Traverse better for everyone.")
                    .foregroundStyle(.secondary)
                if let funding = CommunitySupportLinks.funding {
                    Button("Support the Developers ↗") { NSWorkspace.shared.open(funding) }
                        .buttonStyle(.borderedProminent)
                        .help("Opens voluntary support in your browser. No payment is required to use Traverse.")
                } else {
                    Text("Optional tip links are being prepared. You can still help by reporting a bug or sharing feedback through Help.")
                        .interfaceFont(.callout).foregroundStyle(.secondary)
                }
                if let source = CommunitySupportLinks.source {
                    Button("Source Code & Contributing ↗") { NSWorkspace.shared.open(source) }
                }
                if let discord = CommunitySupportLinks.discord {
                    Button("Join the Respawn Studios Community ↗") { NSWorkspace.shared.open(discord) }
                }
                Button("GNU GPLv3 License…") { ApplicationNotices.projectLicense.show(settings: settings) }
                Button("Continue Browsing", action: close).keyboardShortcut(.cancelAction)
                Toggle("Don't show this message after updates", isOn: Binding(
                    get: { !settings.supportReminders.enabled }, set: { settings.supportReminders.enabled = !$0 }))
                    .interfaceFont(.callout)
                    .help("The choice and release history stay on this Mac. Support Traverse is always available in Help.")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("community-support")
    }
}
