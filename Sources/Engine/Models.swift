import Foundation

/// The dim night clock's color (Phase 9 night controls). Tasteful DIM night
/// values with black text/graphics elsewhere; the actual RGB lives in the app
/// layer's Theme so the engine stays UIKit/SwiftUI-free. Persisted as its raw
/// string. `.white` is the default and the historical look.
public enum ClockColor: String, Codable, CaseIterable {
    case white
    case orange
    case red

    /// Cycle order for the panel toggle: White -> Orange -> Red -> White.
    public var next: ClockColor {
        let all = ClockColor.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

/// Persisted app settings (UserDefaults via Codable). Fields, defaults, and ranges
/// per PRD Section 8. Values are clamped to their legal ranges at init.
public struct AppSettings: Codable, Equatable {
    public var wakeTime: HourMinute
    public var whiteNoiseEnabled: Bool
    public var whiteNoiseSound: String
    public var whiteNoiseVolume: Double   // 0...1
    public var noiseStopEnabled: Bool
    public var noiseStopOffsetMin: Int    // -60...+60, minutes relative to wake time
    public var alarmEnabled: Bool
    public var alarmSound: String
    public var alarmVolume: Double        // 0...1
    public var alarmOffsetMin: Int        // 0...+60
    public var kidLockEnabled: Bool
    /// Night-level `UIScreen.brightness` for the sleep state (Phase 9 item 1).
    /// Persisted so it survives forever; readable from bed by default, tunable
    /// live from the panel slider and the horizontal quick-gesture.
    public var nightBrightness: Double    // 0.05...0.6
    /// Dim sleep-clock color (Phase 9 item 2). Applies only to the dim night
    /// clock, never the bright panel clock or the green wake screen.
    public var clockColor: ClockColor

    public static let noiseOffsetRange = -60...60
    public static let alarmOffsetRange = 0...60
    public static let nightBrightnessRange = 0.05...0.6

    public init(wakeTime: HourMinute = HourMinute(hour: 7, minute: 0),
                whiteNoiseEnabled: Bool = true,
                whiteNoiseSound: String = "classicWhite",
                whiteNoiseVolume: Double = 0.5,
                noiseStopEnabled: Bool = true,
                noiseStopOffsetMin: Int = 0,
                alarmEnabled: Bool = false,
                alarmSound: String = "gentleChime",
                alarmVolume: Double = 0.6,
                alarmOffsetMin: Int = 0,
                kidLockEnabled: Bool = false,
                nightBrightness: Double = 0.28,
                clockColor: ClockColor = .white) {
        self.wakeTime = wakeTime
        self.whiteNoiseEnabled = whiteNoiseEnabled
        self.whiteNoiseSound = whiteNoiseSound
        self.whiteNoiseVolume = min(max(whiteNoiseVolume, 0), 1)
        self.noiseStopEnabled = noiseStopEnabled
        self.noiseStopOffsetMin = Self.clampNoiseOffset(noiseStopOffsetMin)
        self.alarmEnabled = alarmEnabled
        self.alarmSound = alarmSound
        self.alarmVolume = min(max(alarmVolume, 0), 1)
        self.alarmOffsetMin = Self.clampAlarmOffset(alarmOffsetMin)
        self.kidLockEnabled = kidLockEnabled
        self.nightBrightness = Self.clampNightBrightness(nightBrightness)
        self.clockColor = clockColor
    }

    // Backward-compatible decoding: settings persisted before Phase 9 have no
    // `nightBrightness`/`clockColor` keys. Decode them if present, otherwise
    // fall back to the defaults - so an existing install keeps every other
    // setting instead of the whole struct failing to decode and resetting.
    private enum CodingKeys: String, CodingKey {
        case wakeTime, whiteNoiseEnabled, whiteNoiseSound, whiteNoiseVolume
        case noiseStopEnabled, noiseStopOffsetMin, alarmEnabled, alarmSound
        case alarmVolume, alarmOffsetMin, kidLockEnabled, nightBrightness, clockColor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            wakeTime: try c.decode(HourMinute.self, forKey: .wakeTime),
            whiteNoiseEnabled: try c.decode(Bool.self, forKey: .whiteNoiseEnabled),
            whiteNoiseSound: try c.decode(String.self, forKey: .whiteNoiseSound),
            whiteNoiseVolume: try c.decode(Double.self, forKey: .whiteNoiseVolume),
            noiseStopEnabled: try c.decode(Bool.self, forKey: .noiseStopEnabled),
            noiseStopOffsetMin: try c.decode(Int.self, forKey: .noiseStopOffsetMin),
            alarmEnabled: try c.decode(Bool.self, forKey: .alarmEnabled),
            alarmSound: try c.decode(String.self, forKey: .alarmSound),
            alarmVolume: try c.decode(Double.self, forKey: .alarmVolume),
            alarmOffsetMin: try c.decode(Int.self, forKey: .alarmOffsetMin),
            kidLockEnabled: try c.decode(Bool.self, forKey: .kidLockEnabled),
            nightBrightness: try c.decodeIfPresent(Double.self, forKey: .nightBrightness) ?? 0.28,
            clockColor: try c.decodeIfPresent(ClockColor.self, forKey: .clockColor) ?? .white
        )
    }

    public static func clampNoiseOffset(_ minutes: Int) -> Int {
        min(max(minutes, noiseOffsetRange.lowerBound), noiseOffsetRange.upperBound)
    }

    public static func clampAlarmOffset(_ minutes: Int) -> Int {
        min(max(minutes, alarmOffsetRange.lowerBound), alarmOffsetRange.upperBound)
    }

    public static func clampNightBrightness(_ value: Double) -> Double {
        min(max(value, nightBrightnessRange.lowerBound), nightBrightnessRange.upperBound)
    }
}

/// Persisted at Start, cleared at dismiss/end. Powers crash recovery (PRD edge
/// rows 1-2). At most one exists.
public struct ActiveSession: Codable, Equatable {
    /// When Start was tapped.
    public var startedAt: Date
    /// The resolved next-occurrence instant of `wakeTime` at Start. Fallback/debug
    /// aid only: the live value is re-derived from wall-clock `wakeTime` on every
    /// engine evaluation so timezone/DST changes are honored (PRD edge row 5).
    public var wakeDate: Date
    /// Offsets/sounds as of Start; live edits mid-session update the snapshot.
    public var settingsSnapshot: AppSettings
    /// Set on tap-to-stop or auto-stop; prevents alarm re-fire on relaunch.
    public var alarmStoppedAt: Date?
    /// UIScreen.brightness captured at Start; restored on every exit path,
    /// including relaunch recovery after a crash.
    public var priorBrightness: Double    // 0...1

    public init(startedAt: Date,
                wakeDate: Date,
                settingsSnapshot: AppSettings,
                alarmStoppedAt: Date? = nil,
                priorBrightness: Double) {
        self.startedAt = startedAt
        self.wakeDate = wakeDate
        self.settingsSnapshot = settingsSnapshot
        self.alarmStoppedAt = alarmStoppedAt
        self.priorBrightness = min(max(priorBrightness, 0), 1)
    }
}
