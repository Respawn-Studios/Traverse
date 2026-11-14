import Foundation
import Testing
@testable import StorageAnalysis

/// Actual generated Rust streams, copied by the bounded qualification tool.
/// No source filesystem, personal location or synthetic transport is accessed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_ADAPTIVE_REPLAY_ROOT"] != nil))
struct AdaptiveCheckpointIntegrationTests {
    struct Fixture {
        let label: String
        let paired: Bool
        let frames: [[String: Any]]
    }
    private func fixtures() throws -> [Fixture] {
        let text = try #require(ProcessInfo.processInfo.environment["MAC_EXPLORER_ADAPTIVE_REPLAY_ROOT"])
        let root = URL(fileURLWithPath: text)
        #expect(root.resolvingSymlinksInPath() == root && root.lastPathComponent == "AdaptiveReplayFixtures")
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        #expect(data.count < 8192)
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(document["cases"] as? [[String: Any]])
        #expect(items.count == 5)
        return try items.enumerated().map { index, item in
            let filename = try #require(item["file"] as? String)
            #expect(filename == "f\(index).json")
            guard filename == "f\(index).json" else { throw StorageScanFailure.invalidOutput }
            let raw = try Data(contentsOf: root.appendingPathComponent(filename))
            #expect(raw.count <= 1 << 20)
            let wire = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            let frames = try #require(wire["frames"] as? [[String: Any]])
            #expect(frames.count <= 4096)
            return .init(label: try #require(item["label"] as? String),
                paired: try #require(item["paired"] as? Bool), frames: frames)
        }
    }
    private func decode(_ fixture: Fixture) throws -> (prefixes: Int, summary: [String: Any]) {
        let header = try #require(fixture.frames.first)
        let session = try #require((header["session"] as? String).flatMap(UUID.init(uuidString:)))
        let schema = fixture.paired ? 16 : 15
        let binding = try AnalysisPolicyBinding(header: header, startup: fixture.paired, policy: .standard, classificationRevision: .v3)
        #expect(binding.adaptiveCheckpoints && binding.maximumPathComponents == 128)
        let contract = try AnalysisCheckpointContract(rows: 16384, classification: .v3)
        var committed: UInt64 = 0, crossedSource = false, previous: CommittedAnalysisPrefix?, prefixes = 0
        var terminal: [String: Any]?
        for (sequence, frame) in fixture.frames.enumerated() {
            #expect(try storedNumber(frame["seq"]) == UInt64(sequence))
            #expect(frame["session"] as? String == session.uuidString && strictInteger(frame["schema"]) == schema)
            #expect(terminal == nil)
            switch frame["kind"] as? String {
            case "member_transition": crossedSource = true
            case "progress":
                let count = try storedNumber(frame["committed"])
                #expect(contract.acceptsProgress(count, previous: committed, crossedSource: crossedSource))
                guard contract.acceptsProgress(count, previous: committed, crossedSource: crossedSource) else { throw StorageScanFailure.invalidOutput }
                committed = count; crossedSource = false
            case "committed_totals":
                previous = try .decode(frame, session: session, policy: .standard, wireSchema: schema,
                    committed: committed, previous: previous, checkpointRows: 16384, classificationRevision: .v3)
                prefixes += 1
            case "summary": terminal = frame
            default: break
            }
        }
        let summary = try #require(terminal)
        #expect(summary["store_ready"] as? Bool == true)
        #expect(try storedNumber(summary["committed_entries"]) >= committed)
        return (prefixes, summary)
    }
    @Test func actualSingleAndPairedStreamsPassTheSameNativeDecoders() throws {
        let values = try fixtures()
        #expect(Set(values.map(\.label)) == ["wide", "mixed", "both", "denied-transition", "stop"])
        for value in values {
            let result = try decode(value)
            if ["wide", "mixed", "both"].contains(value.label) {
                #expect(result.prefixes > 0 && result.summary["complete"] as? Bool == true)
            }
        }
    }
    @Test func tinyFirstSourceProducesARealNonAlignedCheckpoint() throws {
        let paired = try #require(try fixtures().first { $0.label == "both" })
        let first = try #require(paired.frames.first { $0["kind"] as? String == "progress" })
        let count = try storedNumber(first["committed"])
        #expect(count > 4096 && count % 4096 != 0)
        let result = try decode(paired)
        #expect(result.prefixes > 0 && result.summary["complete"] as? Bool == true)
    }
    @Test func realStopAndDeniedTransitionNeverBecomeCompleteResults() throws {
        let values = try fixtures()
        for label in ["stop", "denied-transition"] {
            let value = try #require(values.first { $0.label == label })
            let result = try decode(value)
            #expect(result.summary["complete"] as? Bool == false)
            #expect(result.summary["reason"] as? String == (label == "stop" ? "cancelled" : "topology_changed"))
            if label == "stop" { #expect(result.prefixes > 0) }
            else {
                let count = try storedNumber(result.summary["committed_entries"])
                #expect(result.prefixes == 0 && count == 4)
            }
        }
    }
}
