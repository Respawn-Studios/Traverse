import Foundation

/// Recorded metadata only. A DOS ZIP date is a wall clock value without a
/// time zone; UTC is just its neutral carrier for formatting the components.
public struct ArchiveMemberModification: Equatable, Sendable {
    public let date: Date
    public let hasTimeZone: Bool
    private static let daysPerMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    private static let elapsedDaysByMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

    internal static func unix(_ seconds: TimeInterval) -> Self? {
        guard seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds) else { return nil }
        return .init(date: Date(timeIntervalSince1970: seconds), hasTimeZone: true)
    }

    internal static func dos(date: UInt16, time: UInt16) -> Self? {
        let year = 1980 + Int(date >> 9), month = Int(date >> 5 & 15), day = Int(date & 31)
        let hour = Int(time >> 11), minute = Int(time >> 5 & 63), second = Int(time & 31) * 2
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        guard (1...12).contains(month), (1...(daysPerMonth[month - 1] + (leap && month == 2 ? 1 : 0))).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        // No Calendar construction or date formatting while reading a large catalog.
        func leaps(before y: Int) -> Int { (y - 1) / 4 - (y - 1) / 100 + (y - 1) / 400 }
        let days = (year - 1970) * 365 + leaps(before: year) - leaps(before: 1970)
            + elapsedDaysByMonth[month - 1] + (leap && month > 2 ? 1 : 0) + day - 1
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
        return .init(date: Date(timeIntervalSince1970: TimeInterval(seconds)), hasTimeZone: false)
    }

    /// Undated entries stay last in either direction. With a wall clock value,
    /// order compares the date and time as recorded, without guessing a zone.
    internal static func order(_ lhs: Self?, _ rhs: Self?, descending: Bool) -> Bool? {
        switch (lhs?.date, rhs?.date) {
        case (nil, nil): nil
        case (nil, _): false
        case (_, nil): true
        case (let a?, let b?) where a != b: descending ? a > b : a < b
        default: nil
        }
    }
}
