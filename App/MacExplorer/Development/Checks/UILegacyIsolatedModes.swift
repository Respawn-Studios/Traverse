#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import Darwin
import Carbon
import ExplorerCore
@_spi(Qualification) import LocalStorage
import FileOperations
import StorageAnalysis

@MainActor extension UIVerification {
    static func legacyDriveMode(_ context: UILegacyAdmittedContext) async throws -> Bool {
        let browser = context.windowController.browser
        let args = context.args
        let root = context.fixture.root, output = context.fixture.output
        let state = context.state
            if args.contains("--verify-drive-lifecycle") {
                state.checks += try await NativeDriveLifecycleVerification.run(browser: browser, fixture: root, output: output)
                let report: [String: Any] = ["passed": true, "checks": state.checks, "mode": "native-drive-lifecycle",
                    "notExercised": ["Force unmount", "Other physical devices", "Power loss"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyResponsivenessMode(_ context: UILegacyAdmittedContext) async throws -> Bool {
        let browser = context.windowController.browser
        let args = context.args
        let root = context.fixture.root, output = context.fixture.output
        func argument(_ key: String) throws -> String { try legacyArgument(key, in: args) }
            if args.contains("--verify-grouped-copy-responsiveness") {
                try require(args.contains("--offscreen") && !args.contains(where: { $0.hasPrefix("--grouped-") }),
                            "Responsiveness qualification requires its separate controlled mode")
                guard let descriptor = Int32(try argument("--fixture-lease-fd")), descriptor > 2 else {
                    throw Failure(message: "Responsiveness fixture lease descriptor is missing")
                }
                let report = await verifyGroupedCopyResponsiveness(browser, in: root, output: output, inheritedLease: descriptor)
                try requireControlledWindowsHidden("generated responsiveness diagnostic")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyQueueMode(_ context: UILegacyAdmittedContext) async throws -> Bool {
        let browser = context.windowController.browser
        let args = context.args
        let root = context.fixture.root, output = context.fixture.output
        let state = context.state
            if args.contains("--verify-grouped-copy-queue") {
                try require(args.contains("--offscreen") && !args.contains(where: { $0.hasPrefix("--grouped-") }),
                            "Preview queue qualification requires its separate controlled mode")
                state.checks += try await verifyGroupedCopyQueue(browser, in: root, output: output, interactive: false)
                try requireControlledWindowsHidden("generated preview queue")
                let report: [String: Any] = ["passed": true, "mode": "grouped-copy-queue-controlled",
                    "checks": state.checks,
                    "preferences": "In memory; session, pins and folder access stores are disabled for verification",
                    "routing": "DEBUG generated-fixture session only; ordinary owner routing remains closed",
                    "notExercised": ["Physical pointer/keyboard delivery", "Personal-file mutation", "Native Trash", "Power loss", "Ordinary application grouped-copy routing"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyRecoveryMode(_ context: UILegacyAdmittedContext) async throws -> Bool {
        let browser = context.windowController.browser
        let args = context.args
        let root = context.fixture.root, output = context.fixture.output
        let state = context.state
        func argument(_ key: String) throws -> String { try legacyArgument(key, in: args) }
            if args.contains("--verify-grouped-recovery") {
                try require(args.contains("--offscreen"), "Copied-file fixture review requires its separate controlled offscreen mode")
                guard let recordID = UUID(uuidString: try argument("--grouped-record")),
                      let count = Int(try argument("--grouped-items")), (1...1024).contains(count) else {
                    throw Failure(message: "Copied-file fixture review requires a valid record and 1–1,024 members")
                }
                let journal = URL(fileURLWithPath: try argument("--grouped-journal"), isDirectory: true).standardizedFileURL
                try require(journal.path == root.appendingPathComponent("journal", isDirectory: true).path,
                            "Copied-file fixture journal must be the marked fixture’s exact journal directory")
                let action: CopyRecoveryAction?
                if args.contains("--grouped-action") {
                    guard let requested = CopyRecoveryAction(rawValue: try argument("--grouped-action")) else {
                        throw Failure(message: "Unknown copied-file confirmation action")
                    }
                    action = requested
                } else { action = nil }
                let undo = args.contains("--grouped-undo")
                try require(!(action != nil && undo), "Choose one explicit copied-file confirmation or Undo")
                let engine = RecoverableFileOperations(journalDirectory: journal)
                state.checks += try await verifyGroupedCopyRecovery(browser, engine: engine, recordID: recordID,
                    expectedItems: count, in: root, output: output, interactive: false, action: action, undo: undo)
                try requireControlledWindowsHidden("copied-file fixture review")
                let report: [String: Any] = ["passed": true, "mode": "grouped-copy-recovery-controlled",
                    "checks": state.checks, "members": count, "action": action?.rawValue ?? (undo ? "undo" : "inspectOnly"),
                    "preferences": "In memory; session, pins and folder access stores are disabled for verification",
                    "catalog": "Externally seeded generated schema-4 catalog; public engine initializer only",
                    "notExercised": ["Physical pointer/keyboard delivery", "Personal-file mutation", "Native Trash", "Power loss", "Ordinary application grouped-copy routing"]]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("ui-verification.json"), options: .withoutOverwriting)
                NSApplication.shared.terminate(nil)
                return true
            }
        return false
    }

    static func legacyControlledReopen(args: [String]) throws {
            if args.contains("--offscreen") {
                guard let delegate = NSApplication.shared.delegate as? ApplicationDelegate else {
                    throw Failure(message: "Controlled verification has no application lifecycle delegate")
                }
                try require(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false),
                            "Controlled verification accepted reopening a hidden test window")
                try requireControlledWindowsHidden("explicit controlled reopen")
            }
    }

}
#endif
