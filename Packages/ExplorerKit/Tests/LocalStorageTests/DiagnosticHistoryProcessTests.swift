import Darwin
import Foundation
@testable import LocalStorage
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_DIAGNOSTIC_PROCESS_ACTION"] != nil))
struct DiagnosticHistoryProcessTests {
    @Test func child() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: try #require(env["TRAVERSE_DIAGNOSTIC_TEST_ROOT"]))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(base.path.hasPrefix(repo.appendingPathComponent(".build/traverse-release").path + "/")
            && base.resolvingSymlinksInPath() == base)
        let action = try #require(env["TRAVERSE_DIAGNOSTIC_PROCESS_ACTION"])
        let boundary = try #require(env["TRAVERSE_DIAGNOSTIC_PROCESS_BOUNDARY"])
        try #require(["beforeAppend","beforeSync"].contains(boundary) && ["interrupt","reopen"].contains(action))
        let store = base.appendingPathComponent("process-" + boundary)
        let event = DiagnosticEvent(session: UUID(), trace: UUID(), action: .copy, phase: .completed)
        if action == "interrupt" {
            let recorder = DiagnosticRecorder(directory: store, limits: try .init(bytes: 64 << 10, segmentBytes: 8 << 10),
                recording: true, probe: { stage in
                    if (boundary == "beforeAppend" && stage == .beforeAppend) || (boundary == "beforeSync" && stage == .beforeSync) {
                        Self.emit(action: "interrupted", boundary: boundary, count: 0); _exit(86)
                    }
                })
            recorder.record(event); await recorder.flush()
            Issue.record("Requested diagnostic interruption did not occur")
        } else {
            let recorder = DiagnosticRecorder(directory: store, limits: try .init(bytes: 64 << 10, segmentBytes: 8 << 10), recording: true)
            let page = try await recorder.page()
            // Process interruption is qualified, not a simulated power-loss guarantee.
            #expect(page.events.count == (boundary == "beforeAppend" ? 0 : 1))
            recorder.record(event); await recorder.flush()
            let resumed = try await recorder.page()
            #expect(resumed.events.count == page.events.count + 1 && resumed.events.first == event)
            await recorder.closeAndDrain()
            Self.emit(action: "reopened", boundary: boundary, count: resumed.events.count)
        }
    }
    private static func emit(action: String, boundary: String, count: Int) {
        let value: [String: Any] = ["action":action,"boundary":boundary,"pid":getpid(),"records":count]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("TRAVERSE_DIAGNOSTIC_CHILD " + String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
}
