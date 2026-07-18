import Foundation

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

    public static let noiseOffsetRange = -60...60
    public static let alarmOffsetRange = 0...60

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
                kidLockEnabled: Bool = false) {
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
    }

    public static func clampNoiseOffset(_ minutes: Int) -> Int {
        min(max(minutes, noiseOffsetRange.lowerBound), noiseOffsetRange.upperBound)
    }

    public static func clampAlarmOffset(_ minutes: Int) -> Int {
        min(max(minutes, alarmOffsetRange.lowerBound), alarmOffsetRange.upperBound)
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
