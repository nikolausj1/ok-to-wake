import Foundation

// The session engine: a pure function of (settings, session, current time) →
// display state + due effects, ticked once per second by the app layer
// (PRD Section 6 state machine). Plain Foundation only — no UIKit / SwiftUI /
// AVFoundation. The app layer maps emitted effects onto the real world.

/// What the screen should show.
public enum DisplayState: Equatable {
    case idle    // Home (no session)
    case sleep   // dim clock + red cue
    case wake    // full-screen green
}

/// Side effects the engine asks the app layer to perform. Values only; the
/// engine never touches audio or the screen itself.
public enum Effect: Equatable {
    case startNoise      // begin the white noise loop
    case stopNoiseFade   // fade white noise out (~3 s)
    case startAlarm      // play the alarm sound on loop
    case stopAlarm       // silence the alarm (tap or 5-minute auto-stop)
    case enterWake       // transition the screen to the green wake state
    case sessionEnded    // session is over: restore brightness/idle timer, clear persistence
}

/// What to do when the app launches and finds a persisted session
/// (PRD edge rows 1-2).
public enum RecoveryAction: Equatable {
    case resumeSleep     // now < wake: resume sleep state, restart noise, re-dim
    case showWakeSilent  // wake ≤ now < wake+3 h: open green, no alarm re-fire
    case clearSession    // ≥ 3 h past wake: clear the session, open Home
}

/// The absolute instants of a session's scheduled events, re-derived from
/// wall-clock `wakeTime` in the current time zone on every evaluation.
public struct SessionSchedule: Equatable {
    public let wakeDate: Date
    public let noiseStopDate: Date?      // nil unless white noise + its stop are enabled
    public let alarmStartDate: Date?     // nil unless the alarm is enabled
    public let alarmAutoStopDate: Date?  // alarmStartDate + 5 min
}

/// Injected time source so tests (and demo hooks) control "now" and the zone.
public struct EngineClock {
    public var now: () -> Date
    public var timeZone: () -> TimeZone

    public init(now: @escaping () -> Date, timeZone: @escaping () -> TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    public static let system = EngineClock(now: { Date() }, timeZone: { TimeZone.current })

    public static func fixed(now: Date, timeZone: TimeZone) -> EngineClock {
        EngineClock(now: { now }, timeZone: { timeZone })
    }
}

public enum Engine {
    /// Alarm silences itself this long after it starts, if untouched.
    public static let alarmAutoStopInterval: TimeInterval = 5 * 60
    /// A never-dismissed session is stale this long after wake time (edge row 2).
    public static let staleSessionInterval: TimeInterval = 3 * 60 * 60

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    // MARK: - Session lifecycle

    /// Start tapped: build the persisted session and the effects to run now.
    /// The caller persists the session BEFORE executing any effect (PRD invariant).
    public static func startSession(settings: AppSettings,
                                    now: Date,
                                    timeZone: TimeZone,
                                    priorBrightness: Double) -> (session: ActiveSession, effects: [Effect]) {
        let wake = settings.wakeTime.nextOccurrence(after: now, calendar: calendar(in: timeZone))
        let session = ActiveSession(startedAt: now,
                                    wakeDate: wake,
                                    settingsSnapshot: settings,
                                    alarmStoppedAt: nil,
                                    priorBrightness: priorBrightness)
        return (session, settings.whiteNoiseEnabled ? [.startNoise] : [])
    }

    /// Any deliberate end (Done on green, gated end at night, stale cleanup).
    public static func endSessionEffects() -> [Effect] { [.sessionEnded] }

    // MARK: - Evaluation

    /// Event instants for a session, re-derived from wall clock every call so a
    /// timezone/DST shift moves the events to the new local wall-clock time
    /// (edge row 5). The stored `session.wakeDate` is deliberately ignored.
    public static func schedule(for session: ActiveSession, timeZone: TimeZone) -> SessionSchedule {
        let s = session.settingsSnapshot
        let wake = s.wakeTime.nextOccurrence(after: session.startedAt, calendar: calendar(in: timeZone))
        let noiseStop: Date? = (s.whiteNoiseEnabled && s.noiseStopEnabled)
            ? wake.addingTimeInterval(TimeInterval(s.noiseStopOffsetMin) * 60)
            : nil
        let alarmStart: Date? = s.alarmEnabled
            ? wake.addingTimeInterval(TimeInterval(s.alarmOffsetMin) * 60)
            : nil
        return SessionSchedule(wakeDate: wake,
                               noiseStopDate: noiseStop,
                               alarmStartDate: alarmStart,
                               alarmAutoStopDate: alarmStart?.addingTimeInterval(alarmAutoStopInterval))
    }

    /// Pure display state. During a live session green persists until dismissed
    /// (no timeout — PRD C); the 3-hour staleness rule applies only at relaunch
    /// via `recovery`.
    public static func displayState(session: ActiveSession?, now: Date, timeZone: TimeZone) -> DisplayState {
        guard let session else { return .idle }
        return now < schedule(for: session, timeZone: timeZone).wakeDate ? .sleep : .wake
    }

    /// Effects due in the half-open window (previousTick, now]. Call once per
    /// second with the previous tick's `now`. Order at a shared instant is the
    /// PRD's collision rule (edge row 11): green transition, white-noise
    /// fade-out, alarm start.
    public static func dueEffects(session: ActiveSession,
                                  previousTick: Date,
                                  now: Date,
                                  timeZone: TimeZone) -> [Effect] {
        let sched = schedule(for: session, timeZone: timeZone)
        func due(_ instant: Date?) -> Bool {
            guard let instant else { return false }
            return instant > previousTick && instant <= now
        }
        var effects: [Effect] = []
        if due(sched.wakeDate) { effects.append(.enterWake) }
        if due(sched.noiseStopDate) { effects.append(.stopNoiseFade) }
        if session.alarmStoppedAt == nil {  // stopped alarm never re-fires
            if due(sched.alarmStartDate) { effects.append(.startAlarm) }
            if due(sched.alarmAutoStopDate) { effects.append(.stopAlarm) }
        }
        return effects
    }

    // MARK: - Panel actual-time accessors (Phase 9 night controls, item 2)

    // The night panel shows REAL wall-clock times, not offsets. These derive
    // from the session's resolved wake time (its snapshot's `wakeTime`, which
    // live edits mid-session keep current) plus each event's offset, honoring
    // the enabled flags. Pure wall-clock arithmetic (HourMinute.adding wraps
    // midnight), so the smoke test can cover midnight / AM-PM boundaries with
    // no dates or time zones. The app layer formats these as "7:00 AM".

    /// The wall-clock time the screen turns green ("Green at 7:00 AM").
    public static func wakeWallClock(for session: ActiveSession) -> HourMinute {
        session.settingsSnapshot.wakeTime
    }

    /// noiseStopAt = wake + noiseOffset, or nil when white noise or its stop is
    /// disabled ("Noise stops 6:50 AM").
    public static func noiseStopWallClock(for session: ActiveSession) -> HourMinute? {
        let s = session.settingsSnapshot
        guard s.whiteNoiseEnabled, s.noiseStopEnabled else { return nil }
        return s.wakeTime.adding(minutes: s.noiseStopOffsetMin)
    }

    /// alarmStartAt = wake + alarmOffset, or nil when the alarm is off
    /// ("Alarm 7:10 AM").
    public static func alarmStartWallClock(for session: ActiveSession) -> HourMinute? {
        let s = session.settingsSnapshot
        guard s.alarmEnabled else { return nil }
        return s.wakeTime.adding(minutes: s.alarmOffsetMin)
    }

    // MARK: - Alarm stopping

    /// Tap anywhere while the alarm sounds: stop it (green screen persists).
    public static func stopAlarmTapped(session: ActiveSession, now: Date) -> (session: ActiveSession, effects: [Effect]) {
        guard session.alarmStoppedAt == nil else { return (session, []) }
        var updated = session
        updated.alarmStoppedAt = now
        return (updated, [.stopAlarm])
    }

    /// The caller must record auto-stop the same way when it executes a
    /// `.stopAlarm` emitted by `dueEffects`, so relaunch can't re-fire it.
    public static func markAlarmStopped(session: ActiveSession, now: Date) -> ActiveSession {
        var updated = session
        updated.alarmStoppedAt = now
        return updated
    }

    // MARK: - Relaunch recovery (PRD edge rows 1-2)

    public static func recovery(session: ActiveSession, now: Date, timeZone: TimeZone) -> RecoveryAction {
        let wake = schedule(for: session, timeZone: timeZone).wakeDate
        if now < wake { return .resumeSleep }
        if now < wake.addingTimeInterval(staleSessionInterval) { return .showWakeSilent }
        return .clearSession
    }
}
