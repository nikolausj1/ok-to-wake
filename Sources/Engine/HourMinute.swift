import Foundation

/// A wall-clock time of day (no date, no timezone). The PRD's wake time is stored
/// this way so that crossing timezones "just works": the session always targets the
/// next wall-clock occurrence in the device's *current* local time.
public struct HourMinute: Codable, Equatable, Hashable, CustomStringConvertible {
    public var hour: Int   // 0-23
    public var minute: Int // 0-59 (UI steps by 5; the model tolerates any minute)

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    /// The next occurrence of this wall-clock time strictly after `date`, in
    /// `calendar`'s time zone.
    ///
    /// DST spring-forward: if the target minute is skipped, `.nextTime` resolves to
    /// the first instant after the gap, i.e. the event fires as soon as local time
    /// first passes the target (PRD edge row 5).
    public func nextOccurrence(after date: Date, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        // nextDate only fails for pathological calendars; falling back to `date`
        // keeps the engine total (never crashes at 3 AM).
        return calendar.nextDate(after: date,
                                 matching: components,
                                 matchingPolicy: .nextTime,
                                 direction: .forward) ?? date
    }
}
