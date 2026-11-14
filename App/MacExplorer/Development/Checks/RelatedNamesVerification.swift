#if DEBUG
import AppKit
import CryptoKit
import Darwin
import FileMemory
import Foundation

@MainActor enum RelatedNamesVerification {
    private struct Probe: Codable, Sendable {
        let sample: Int
        let state: String
        let sequence: Int
        let enumerated: Int
        let dimension: Int
        let milliseconds: Double
    }
    static func run(root: URL) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b08-related-names")
        try UIVerification.require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Related-name QA requires an admitted generated root")
        if ProcessInfo.processInfo.arguments.contains("--related-quality") { return try await quality(root: root) }
        let probes = try await Task.detached(priority: .utility) { () throws -> [Probe] in
            try autoreleasepool {
                let encoder = try AppleRelatedNameEncoder(cancelled: { false })
                defer { encoder.close() }
                var probes: [Probe] = []
                let samples = ["A winter travel checklist", "Unpaid invoices and receipts", "do not delete the backup",
                    "Café résumé naïve", "alpha_beta-render_cache-7", String(repeating: "q-", count: 64),
                    String(repeating: "x", count: 129), "🧭 research notes"]
                for (index, text) in samples.enumerated() {
                    let start = ProcessInfo.processInfo.systemUptime
                    do {
                        let values = try encoder.vector(for: text, cancelled: { false })
                        guard values.count == encoder.model.dimension && values.allSatisfy(\.isFinite) else { throw RelatedNameFailure.invalidVector }
                        probes.append(.init(sample: index, state: "encoded", sequence: encoder.lastSequenceLength,
                            enumerated: encoder.lastEnumerationCount, dimension: values.count,
                            milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000))
                    } catch let error as RelatedNameFailure {
                        probes.append(.init(sample: index, state: String(describing: error), sequence: encoder.lastSequenceLength,
                            enumerated: encoder.lastEnumerationCount, dimension: 0,
                            milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000))
                    }
                }
                return probes
            }
        }.value
        let encoded = try JSONEncoder().encode(probes)
        return ["passed": probes.prefix(3).allSatisfy { $0.state == "encoded" } && probes[6].state == "limited",
            "controls": try JSONSerialization.jsonObject(with: encoded), "metadataOnly": true,
            "ordinaryActivation": false, "personalInput": false, "requestedAssets": false,
            "notExercised": ["Retrieval quality", "Minimum supported OS", "Whole-OS network inactivity", "Personal catalog integration"]]
    }

    private struct Corpus: Decodable, Sendable {
        struct Row: Decodable, Sendable { let id: String; let text: String }
        struct Query: Decodable, Sendable { let id: String; let text: String; let partition: String; let kind: String; let relevant: [String] }
        let format: String
        let version: Int
        let records: [Row]
        let queries: [Query]
        let synonyms: [String: String]
    }
    private struct Hit: Codable, Sendable { let id: String; let score: Double }
    private struct Answer: Codable, Sendable {
        let id: String
        let direct: [String]
        let synonyms: [String]
        let related: [Hit]
        let milliseconds: Double
        let failure: String?
    }
    private static func quality(root: URL) async throws -> [String: Any] {
        let args = ProcessInfo.processInfo.arguments
        guard let position = args.firstIndex(of: "--related-partition"), position + 1 < args.count,
              ["tuning", "heldout", "latency"].contains(args[position + 1]) else { throw RelatedNameFailure.invalidInput }
        let partition = args[position + 1]
        let corpus = try await Task.detached { () throws -> Corpus in
            let bytes = try Data(contentsOf: root.appendingPathComponent("metadata/corpus.json"))
            guard bytes.count <= 1_048_576,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                    == "fc39eaccb9ce66418ae92ce72adbb30089ef6b8a8fb40a32a89ff76a440f029f" else { throw RelatedNameFailure.invalidInput }
            let value = try JSONDecoder().decode(Corpus.self, from: bytes)
            guard value.format == "MacExplorer.RelatedNames.Generated", value.version == 1, value.records.count == 512,
                  value.queries.count == 256, Set(value.records.map(\.id)).count == 512 else { throw RelatedNameFailure.invalidInput }
            return value
        }.value
        let baseline = resident(), started = ProcessInfo.processInfo.systemUptime
        let index = try SessionNameIndex()
        var snapshots: [RememberedNamesSnapshot] = [], external: [RememberedItemID: String] = [:]
        for row in corpus.records {
            let edit = try await index.prepareNew(AuthoredNames(nickname: row.text))
            let id = try await index.apply(edit)
            snapshots.append(try await index.snapshot(id)); external[id] = row.id
        }
        let input = try RelatedNameInput(items: snapshots, scope: UUID(), epoch: 1)
        let session = RelatedNameSession(input: input) { try AppleRelatedNameEncoder(cancelled: $0) }
        var answers: [Answer] = [], identity: RelatedNameModel?, firstMilliseconds = 0.0
        let selected = corpus.queries.filter { $0.partition == (partition == "latency" ? "heldout" : partition) }
        try UIVerification.require(selected.count == (partition == "tuning" ? 64 : 192), "Frozen query partition changed")
        do {
            let preparation = ProcessInfo.processInfo.systemUptime
            let prepared = try await session.query(RelatedNameQuery(selected[0].text, threshold: -1))
            identity = prepared.model
            firstMilliseconds = (ProcessInfo.processInfo.systemUptime - preparation) * 1_000
            if partition == "latency" {
                for query in selected.prefix(10) { _ = try await session.query(RelatedNameQuery(query.text, threshold: -1)) }
            }
            let measured = partition == "latency" ? Array(selected.prefix(100)) : selected
            for query in measured {
                let start = ProcessInfo.processInfo.systemUptime
                var related: [Hit] = [], failure: String?
                do {
                    let result = try await session.query(RelatedNameQuery(query.text, threshold: -1))
                    guard result.model == identity else { throw RelatedNameFailure.changed }
                    try UIVerification.require(result.publish { values in
                        related = values.compactMap { hit in external[hit.id].map { Hit(id: $0, score: hit.score) } }
                    }, "Generated related result lost publication")
                } catch { failure = String(describing: (error as? RelatedNameFailure) ?? .encoderFailed) }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                let direct = try await index.query(RememberedNameQuery(text: query.text, pageSize: 256))
                let translated = query.text.lowercased().split(separator: " ").map { corpus.synonyms[String($0)] ?? String($0) }.joined(separator: " ")
                let expanded = try await index.query(RememberedNameQuery(text: translated, pageSize: 256))
                answers.append(Answer(id: query.id, direct: direct.matches.compactMap { external[$0.item.id] },
                    synonyms: expanded.matches.compactMap { external[$0.item.id] }, related: related, milliseconds: elapsed, failure: failure))
            }
        } catch {
            session.withdraw(); await session.drain(); await index.close(); throw error
        }
        session.withdraw(); await session.drain(); await index.close()
        let model = try requireModel(identity)
        let peak = peakResident()
        return ["passed": answers.allSatisfy { $0.failure == nil }, "partition": partition, "records": 512,
            "answers": try JSONSerialization.jsonObject(with: JSONEncoder().encode(answers)),
            "preparationMilliseconds": firstMilliseconds,
            "completeMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            "baselineRSS": baseline, "peakRSS": peak, "addedRSS": peak > baseline ? peak - baseline : 0,
            "model": ["identifier": model.identifier, "revision": model.revision, "dimension": model.dimension,
                "maximumSequenceLength": model.maximumSequenceLength, "poolingVersion": model.poolingVersion, "language": model.language],
            "ordinaryActivation": false, "personalInput": false, "requestedAssets": false]
    }
    private static func requireModel(_ value: RelatedNameModel?) throws -> RelatedNameModel {
        guard let value else { throw RelatedNameFailure.unavailable }; return value
    }
    private static func resident() -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    private static func peakResident() -> UInt64 { var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage); return UInt64(max(0, usage.ru_maxrss)) }
}
#endif
