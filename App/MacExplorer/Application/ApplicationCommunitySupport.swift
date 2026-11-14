import AppKit

/// Uses the existing Help window; no new startup dialog, network request or
/// donation tracking. Preview/beta builds do not present automatic reminders.
@MainActor final class ApplicationCommunitySupport {
    static let shared = ApplicationCommunitySupport()
    private var presentation: IdleBrowserPresentation?
    private var recordedLaunch = false

    func configure(browser: BrowserViewController) {
        guard CommunitySupportLinks.isPublicLaunch else { return }
        if !recordedLaunch {
            browser.settings.supportReminders.recordLaunch()
            recordedLaunch = true
        }
        presentation = IdleBrowserPresentation(browser: browser) { browser in
            guard ApplicationCrashReports.shared.allowsOptionalStartupMessage else { return }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            guard browser.settings.supportReminders.shouldPresent(version: version, build: build) else { return }
            browser.settings.supportReminders.recordPresentation(version: version, build: build)
            TraverseHelpController.shared.show(.community, from: browser)
        }
    }
    func reconsider() { presentation?.consider() }
}
