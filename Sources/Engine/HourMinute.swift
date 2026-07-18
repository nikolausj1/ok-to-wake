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

    /// 12-hour display, e.g. "7:00 AM" (the app is 12-hour everywhere - PRD A).
    public var display12h: String {
        let h = ((hour + 11) % 12) + 1
        return String(format: "%d:%02d %@", h, minute, hour < 12 ? "AM" : "PM")
    }

    /// The wall-clock time this many minutes later (or earlier, if negative),
    /// wrapping around midnight. Used for offset labels like "Alarm at 7:10".
    public func adding(minutes: Int) -> HourMinute {
        let total = ((hour * 60 + minute + minutes) % 1440 + 1440) % 1440
        return HourMinute(hour: total / 60, minute: total % 60)
    }

    /// Whole minutes (ceiling) until the next occurrence of this wall-clock
    /// time after `date` — the Home screen's "Green in Xh Ym" line. Ceiling so
    /// 30 s out reads "0h 1m", never a premature "0h 0m"; at the exact target
    /// instant the next occurrence is tomorrow (1440). Lives in the engine
    /// layer so the smoke test covers midnight and AM/PM boundaries.
    public func minutesUntilNextOccurrence(after date: Date, calendar: Calendar) -> Int {
        let next = nextOccurrence(after: date, calendar: calendar)
        return max(0, Int(ceil(next.timeIntervalSince(date) / 60)))
    }

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
