#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

/// Fixed DEBUG-only state shared by successful phases and the original catch.
/// It preserves accumulated evidence when an extracted phase throws.
@MainActor final class UILegacyRunState {
    var checks: [String] = []
    var measurements: [String: Any] = [:]
    var evidence: URL?
}
struct UILegacyAdmission {
    let focusedModes: [String]
    let requestsFolderReopen: Bool
    let requestsForeground: Bool
    let requestsRecovery: Bool
}
@MainActor struct UILegacyFixture {
    let root: URL, output: URL
    let metadata: [String: Any]?
}
@MainActor struct UILegacyAdmittedContext {
    let windowController: BrowserWindowController
    let args: [String]
    let admission: UILegacyAdmission
    let fixture: UILegacyFixture
    let state: UILegacyRunState
}
@MainActor final class UILegacyClipboardCapture {
    var text: String?
    var urls: [URL] = []
}
@MainActor struct UILegacyWorkflowContext {
    let admitted: UILegacyAdmittedContext
    let before: [String: String]
    let clipboard: UILegacyClipboardCapture
    let privatePasteboard: NSPasteboard
}
#endif
