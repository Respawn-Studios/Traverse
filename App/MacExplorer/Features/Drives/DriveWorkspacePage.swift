import Foundation

enum DriveWorkspacePage: String, CaseIterable, Identifiable {
    case overview, volumes, health, benchmark, analysis
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .volumes: "Volumes & Protection"
        case .health: "Drive Health"
        case .benchmark: "Benchmark"
        case .analysis: "Storage Analysis"
        }
    }
    var navigationTitle: String { self == .volumes ? "Volumes" : title }
    var symbol: String {
        switch self {
        case .overview: "externaldrive"
        case .volumes: "lock.shield"
        case .health: "heart.text.square"
        case .benchmark: "speedometer"
        case .analysis: "chart.pie"
        }
    }
}
