#if DEBUG
import AppKit
import Darwin

/// Generated native inputs only. This entry never opens an owner browser,
/// observes personal locations or starts a file/network operation.
@MainActor enum ExplorerPointerVerification {
    private enum Failure: Error { case scope }
    static func run() async {
        var root: URL?
        var report: [String: Any] = ["passed": false]
        do {
            guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: path)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("native-admission.json"))) as? [String: Any]
            guard area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                  area.resolvingSymlinksInPath() == area,
                  UUID(uuidString: area.lastPathComponent)?.uuidString == area.lastPathComponent,
                  marker?["action"] as? String == "native-explorer-pointer",
                  admission?["case"] as? String == area.lastPathComponent,
                  admission?["master"] as? String == "B9A65D62-0CFC-4400-A1DF-811F5A977962",
                  admission?["maximumNativeWindows"] as? Int == 1,
                  Bundle.main.bundleIdentifier == "local.macexplorer.development" else { throw Failure.scope }
            root = area
            report = try await ExplorerPointerAppChecks.check(fixtureRoot: area.appendingPathComponent("source/Generated Rows"))
        } catch {
            report["failure"] = String(describing: error)
        }
        report["activityDrained"] = ApplicationFileActivity.gate.activeCount == 0
        report["nativeWindowsClosed"] = NSApp.windows.filter { $0.isVisible }.isEmpty
        if let root {
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
            } catch { FileHandle.standardError.write(Data("Generated pointer report could not be saved\n".utf8)) }
        }
        NSApp.terminate(nil)
    }
}
#endif
