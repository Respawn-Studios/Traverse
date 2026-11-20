import LocalStorage
import SwiftUI

struct DriveBenchmarkLatencyHistogram: View {
    @Environment(\.interfaceScale) private var scale
    let result: DriveBenchmarkResult

    private var writeBands: [DriveBenchmarkLatency.PercentileBand]? {
        result.outcome == .completed ? result.writeLatency.percentileBands : nil
    }
    private var readBands: [DriveBenchmarkLatency.PercentileBand]? {
        result.outcome == .completed ? result.readLatency.percentileBands : nil
    }
    private var write: DriveBenchmarkLatency.Distribution? {
        writeBands == nil ? nil : result.writeLatency.distribution
    }
    private var read: DriveBenchmarkLatency.Distribution? {
        readBands == nil ? nil : result.readLatency.distribution
    }
    private var buckets: [DriveBenchmarkLatency.Distribution.Bucket] { (write ?? read)?.buckets ?? [] }
    private var largestCount: Int {
        max(1, max(write?.buckets.map(\.count).max() ?? 0,
                   read?.buckets.map(\.count).max() ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text("I/O latency distribution").interfaceFont(.headline)
            if result.outcome != .completed {
                Text("Distribution unavailable for a stopped or failed run.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
            } else if buckets.isEmpty {
                Text("No valid block timings are available for this run.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
            } else {
                Text("Completed block calls by duration range (ms)")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18 * scale) {
                    if write != nil {
                        HStack(spacing: 5 * scale) {
                            Circle().fill(Color.accentColor).frame(width: 8 * scale, height: 8 * scale)
                            Text("W · Write")
                        }
                    }
                    if read != nil {
                        HStack(spacing: 5 * scale) {
                            Circle().fill(Color.teal).frame(width: 8 * scale, height: 8 * scale)
                            Text("R · Read & verify")
                        }
                    }
                }.interfaceFont(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    ForEach(buckets.indices, id: \.self) { index in
                        let range = Self.range(buckets[index])
                        HStack(alignment: .center, spacing: 8 * scale) {
                            Text(range).interfaceFont(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 105 * scale, alignment: .trailing)
                            VStack(spacing: 2 * scale) {
                                if let write {
                                    BucketBar(phase: "Write", abbreviation: "W", range: range,
                                        count: write.buckets[index].count, largestCount: largestCount,
                                        markers: Self.markers(index: index, in: writeBands),
                                        color: .accentColor, scale: scale)
                                }
                                if let read {
                                    BucketBar(phase: "Read & verify", abbreviation: "R", range: range,
                                        count: read.buckets[index].count, largestCount: largestCount,
                                        markers: Self.markers(index: index, in: readBands),
                                        color: .teal, scale: scale)
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                if write == nil {
                    Text("Write block timings unavailable.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                if read == nil {
                    Text("Read & verify block timings unavailable.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                }
                Text("P50/P95/P99 mark the range containing each nearest-rank observed I/O call. Bars share the largest count as their scale. Ranges include their lower bound and exclude their upper bound; the final range has no upper bound.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func range(_ bucket: DriveBenchmarkLatency.Distribution.Bucket) -> String {
        func number(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...3)))
        }
        guard let upper = bucket.upperBoundMilliseconds else {
            return "≥\(number(bucket.lowerBoundMilliseconds))"
        }
        return bucket.lowerBoundMilliseconds == 0 ? "<\(number(upper))"
            : "\(number(bucket.lowerBoundMilliseconds))–\(number(upper))"
    }

    private static func markers(index: Int, in bands: [DriveBenchmarkLatency.PercentileBand]?) -> String {
        bands?.filter { $0.bucketIndex == index }.map { "P\($0.percentile)" }.joined(separator: " ") ?? ""
    }
}

private struct BucketBar: View {
    let phase: String
    let abbreviation: String
    let range: String
    let count: Int
    let largestCount: Int
    let markers: String
    let color: Color
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            HStack(spacing: 5 * scale) {
                Text(abbreviation).interfaceFont(.caption2)
                    .frame(width: 12 * scale, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        if count > 0 {
                            Capsule().fill(color)
                                .frame(width: max(2 * scale,
                                    geometry.size.width * CGFloat(count) / CGFloat(largestCount)))
                        }
                    }
                }.frame(height: 7 * scale)
                Text(count.formatted()).interfaceFont(.caption).monospacedDigit()
                    .frame(width: 65 * scale, alignment: .trailing)
            }.frame(height: 13 * scale)
            if !markers.isEmpty {
                Text(markers).interfaceFont(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12 * scale)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phase), \(range) milliseconds, \(count) completed block calls"
            + (markers.isEmpty ? "" : ", contains \(markers) histogram band"))
    }
}
