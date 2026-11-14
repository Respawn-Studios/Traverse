#if DEBUG
import Foundation

/// One operation plan per app process. Variant is sealed into the admitted
/// bundle's Info.plist by Root; a command-line negative flag cannot mutate code.
enum AnalysisReuseCase: String, CaseIterable, Sendable {
    case retention = "01", application = "02", scope = "03", replacedRoot = "04"
    case clearAdmission = "05", successfulProjection = "06", failedProjection = "07", stoppedProjection = "08"
    case fallbackFour = "09", failedProjectionFour = "10", saturationSix = "11", saturationEight = "12"
    case negativeClear = "13", negativeDate = "14", negativeFallback = "15", negativeHandoff = "16"
    var poolGiB: UInt64 {
        switch self { case .fallbackFour, .failedProjectionFour, .negativeFallback: 4; case .saturationSix: 6; default: 8 }
    }
    var variant: String {
        switch self { case .negativeClear: "negative01"; case .negativeDate: "negative02"
        case .negativeFallback: "negative03"; case .negativeHandoff: "negative04"; default: "positive" }
    }
    var expectedSemantic: String? {
        switch self {
        case .negativeClear: "held-clear-refuses-hover-picker-explicit-owner-before-enqueue"
        case .negativeDate, .negativeHandoff: "held-terminal-projection-native-old-chart-is-always-visibly-dated"
        case .negativeFallback: "readable-current-chart-has-independent-displayed-observation"
        default: nil
        }
    }
    var permitsVisible: Bool {
        switch self { case .application, .successfulProjection, .failedProjection, .stoppedProjection, .failedProjectionFour: true; default: false }
    }
    var needsBrowser: Bool { self == .scope || self == .clearAdmission || self == .negativeClear }
}
#endif
