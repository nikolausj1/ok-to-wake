import Foundation

// OK to Wake — engine smoke test.
// Run via the Build Guide recipe (copied to main.swift, compiled with
// Sources/Engine/*.swift). Plain Foundation, top-level code, no XCTest.

var passCount = 0
var failCount = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("FAIL: \(name)")
    }
}

let chicago = TimeZone(identifier: "America/Chicago")!
let denver = TimeZone(identifier: "America/Denver")!

func cal(_ tz: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    return c
}

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, tz: TimeZone = chicago) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
    return cal(tz).date(from: c)!
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3600

// ─────────────────────────────────────────────────────────────
// 1. HourMinute basics + next-occurrence resolution
// ─────────────────────────────────────────────────────────────

check(HourMinute(hour: 25, minute: 0).hour == 23, "HourMinute clamps hour high")
check(HourMinute(hour: -1, minute: 0).hour == 0, "HourMinute clamps hour low")
check(HourMinute(hour: 7, minute: 75).minute == 59, "HourMinute clamps minute high")
check(HourMinute(hour: 7, minute: -5).minute == 0, "HourMinute clamps minute low")
check(HourMinute(hour: 7, minute: 0).description == "07:00", "HourMinute description")

let seven = HourMinute(hour: 7, minute: 0)

// Overnight: start 10:50 PM, wake 7:00 → 7:00 AM tomorrow (PRD locked rule)
let bedtime = date(2026, 6, 1, 22, 50)
let overnightWake = seven.nextOccurrence(after: bedtime, calendar: cal(chicago))
check(overnightWake == date(2026, 6, 2, 7, 0), "overnight start resolves to next-day 7:00")
check(overnightWake.timeIntervalSince(bedtime) == 8 * hour + 10 * minute, "overnight interval is 8h10m")

// Past-time rule: start 6:50 with 7:00 set → green in 10 minutes (edge row 4)
let earlyStart = date(2026, 6, 2, 6, 50)
let sameDayWake = seven.nextOccurrence(after: earlyStart, calendar: cal(chicago))
check(sameDayWake == date(2026, 6, 2, 7, 0), "6:50 start / 7:00 wake fires same day")
check(sameDayWake.timeIntervalSince(earlyStart) == 10 * minute, "6:50 start fires in exactly 10 minutes")

// Starting exactly at the wake time targets the NEXT occurrence (strictly after)
let exactStart = date(2026, 6, 2, 7, 0)
check(seven.nextOccurrence(after: exactStart, calendar: cal(chicago)) == date(2026, 6, 3, 7, 0),
      "start exactly at wake time resolves to tomorrow")

// ─────────────────────────────────────────────────────────────
// 2. AppSettings defaults, clamping, Codable
// ─────────────────────────────────────────────────────────────

let defaults = AppSettings()
check(defaults.wakeTime == HourMinute(hour: 7, minute: 0), "default wakeTime 7:00")
check(defaults.whiteNoiseEnabled == true, "default whiteNoiseEnabled true")
check(defaults.whiteNoiseSound == "classicWhite", "default whiteNoiseSound classicWhite")
check(defaults.whiteNoiseVolume == 0.5, "default whiteNoiseVolume 0.5")
check(defaults.noiseStopEnabled == true, "default noiseStopEnabled true")
check(defaults.noiseStopOffsetMin == 0, "default noiseStopOffsetMin 0")
check(defaults.alarmEnabled == false, "default alarmEnabled false")
check(defaults.alarmSound == "gentleChime", "default alarmSound gentleChime")
check(defaults.alarmVolume == 0.6, "default alarmVolume 0.6")
check(defaults.alarmOffsetMin == 0, "default alarmOffsetMin 0")
check(defaults.kidLockEnabled == false, "default kidLockEnabled false")

check(AppSettings(noiseStopOffsetMin: -100).noiseStopOffsetMin == -60, "noise offset clamps to -60")
check(AppSettings(noiseStopOffsetMin: 100).noiseStopOffsetMin == 60, "noise offset clamps to +60")
check(AppSettings(noiseStopOffsetMin: -60).noiseStopOffsetMin == -60, "noise offset -60 legal")
check(AppSettings(alarmOffsetMin: -5).alarmOffsetMin == 0, "alarm offset clamps to 0 (no negative)")
check(AppSettings(alarmOffsetMin: 90).alarmOffsetMin == 60, "alarm offset clamps to +60")
check(AppSettings(whiteNoiseVolume: 1.7).whiteNoiseVolume == 1.0, "noise volume clamps to 1")
check(AppSettings(alarmVolume: -0.2).alarmVolume == 0.0, "alarm volume clamps to 0")

do {
    let custom = AppSettings(wakeTime: HourMinute(hour: 6, minute: 45),
                             whiteNoiseSound: "rain",
                             noiseStopOffsetMin: -15,
                             alarmEnabled: true,
                             alarmOffsetMin: 10,
                             kidLockEnabled: true)
    let data = try JSONEncoder().encode(custom)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    check(decoded == custom, "AppSettings Codable round-trip preserves equality")
    check(decoded.wakeTime == HourMinute(hour: 6, minute: 45), "round-trip preserves wakeTime")
    check(decoded.noiseStopOffsetMin == -15, "round-trip preserves negative noise offset")
} catch {
    check(false, "AppSettings Codable threw: \(error)")
}

// ─────────────────────────────────────────────────────────────
// 3. ActiveSession Codable (incl. priorBrightness, alarmStoppedAt)
// ─────────────────────────────────────────────────────────────

do {
    let session = ActiveSession(startedAt: bedtime,
                                wakeDate: overnightWake,
                                settingsSnapshot: defaults,
                                alarmStoppedAt: nil,
                                priorBrightness: 0.65)
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(ActiveSession.self, from: data)
    check(decoded == session, "ActiveSession Codable round-trip (nil alarmStoppedAt)")
    check(decoded.priorBrightness == 0.65, "round-trip preserves priorBrightness")
    check(decoded.alarmStoppedAt == nil, "round-trip preserves nil alarmStoppedAt")

    var stopped = session
    stopped.alarmStoppedAt = overnightWake.addingTimeInterval(2 * minute)
    let data2 = try JSONEncoder().encode(stopped)
    let decoded2 = try JSONDecoder().decode(ActiveSession.self, from: data2)
    check(decoded2.alarmStoppedAt == stopped.alarmStoppedAt, "round-trip preserves set alarmStoppedAt")
} catch {
    check(false, "ActiveSession Codable threw: \(error)")
}

check(ActiveSession(startedAt: bedtime, wakeDate: overnightWake,
                    settingsSnapshot: defaults, priorBrightness: 1.8).priorBrightness == 1.0,
      "priorBrightness clamps to 0...1")

// ─────────────────────────────────────────────────────────────
// 4. startSession
// ─────────────────────────────────────────────────────────────

let started = Engine.startSession(settings: defaults, now: bedtime, timeZone: chicago, priorBrightness: 0.8)
check(started.session.startedAt == bedtime, "startSession records startedAt")
check(started.session.wakeDate == overnightWake, "startSession resolves next-occurrence wakeDate")
check(started.session.settingsSnapshot == defaults, "startSession snapshots settings")
check(started.session.alarmStoppedAt == nil, "startSession alarmStoppedAt starts nil")
check(started.session.priorBrightness == 0.8, "startSession stores priorBrightness")
check(started.effects == [.startNoise], "startSession emits startNoise when noise enabled")

let noNoise = Engine.startSession(settings: AppSettings(whiteNoiseEnabled: false),
                                  now: bedtime, timeZone: chicago, priorBrightness: 0.8)
check(noNoise.effects == [], "startSession emits nothing when noise disabled")

// ─────────────────────────────────────────────────────────────
// 5. Display state
// ─────────────────────────────────────────────────────────────

let session = started.session
check(Engine.displayState(session: nil, now: bedtime, timeZone: chicago) == .idle, "no session → idle")
check(Engine.displayState(session: session, now: bedtime, timeZone: chicago) == .sleep, "at start → sleep")
check(Engine.displayState(session: session, now: overnightWake.addingTimeInterval(-1), timeZone: chicago) == .sleep,
      "1s before wake → sleep")
check(Engine.displayState(session: session, now: overnightWake, timeZone: chicago) == .wake, "at wake instant → wake")
check(Engine.displayState(session: session, now: overnightWake.addingTimeInterval(5 * hour), timeZone: chicago) == .wake,
      "green persists hours later during a live session (no timeout)")

// ─────────────────────────────────────────────────────────────
// 6. Tick effects: wake + default noise stop (+0)
// ─────────────────────────────────────────────────────────────

func tick(_ s: ActiveSession, at instant: Date, tz: TimeZone = chicago) -> [Effect] {
    Engine.dueEffects(session: s, previousTick: instant.addingTimeInterval(-1), now: instant, timeZone: tz)
}

check(tick(session, at: overnightWake.addingTimeInterval(-10 * minute)) == [], "mid-night tick: no effects")
check(tick(session, at: overnightWake.addingTimeInterval(-1)) == [], "tick just before wake: no effects")
check(tick(session, at: overnightWake) == [.enterWake, .stopNoiseFade],
      "wake tick (defaults): enterWake then stopNoiseFade")
check(tick(session, at: overnightWake.addingTimeInterval(1)) == [], "tick after wake: no re-fire")
check(Engine.dueEffects(session: session, previousTick: overnightWake,
                        now: overnightWake.addingTimeInterval(1), timeZone: chicago) == [],
      "half-open window excludes previousTick instant")

// Missed ticks (app hiccup): one wide window still delivers everything once
check(Engine.dueEffects(session: session,
                        previousTick: overnightWake.addingTimeInterval(-5 * minute),
                        now: overnightWake.addingTimeInterval(5 * minute),
                        timeZone: chicago) == [.enterWake, .stopNoiseFade],
      "wide catch-up window delivers missed effects once")

// ─────────────────────────────────────────────────────────────
// 7. Negative and positive noise offsets
// ─────────────────────────────────────────────────────────────

let earlyStopSettings = AppSettings(noiseStopOffsetMin: -10)
let earlyStopSession = Engine.startSession(settings: earlyStopSettings, now: bedtime,
                                           timeZone: chicago, priorBrightness: 0.5).session
let earlyStopAt = overnightWake.addingTimeInterval(-10 * minute)
check(tick(earlyStopSession, at: earlyStopAt) == [.stopNoiseFade], "noise offset -10: fade fires 10 min early")
check(Engine.displayState(session: earlyStopSession, now: earlyStopAt, timeZone: chicago) == .sleep,
      "still sleep when early noise stop fires")
check(tick(earlyStopSession, at: overnightWake) == [.enterWake], "noise already stopped: wake tick is enterWake only")

let lateStopSettings = AppSettings(noiseStopOffsetMin: 10)
let lateStopSession = Engine.startSession(settings: lateStopSettings, now: bedtime,
                                          timeZone: chicago, priorBrightness: 0.5).session
check(tick(lateStopSession, at: overnightWake) == [.enterWake], "noise offset +10: wake tick is enterWake only")
check(tick(lateStopSession, at: overnightWake.addingTimeInterval(10 * minute)) == [.stopNoiseFade],
      "noise offset +10: fade fires 10 min after wake")

let noStopSettings = AppSettings(noiseStopEnabled: false)
let noStopSession = Engine.startSession(settings: noStopSettings, now: bedtime,
                                        timeZone: chicago, priorBrightness: 0.5).session
check(tick(noStopSession, at: overnightWake) == [.enterWake], "noise stop disabled: no fade ever")
check(Engine.schedule(for: noStopSession, timeZone: chicago).noiseStopDate == nil,
      "noise stop disabled: no scheduled stop date")

// ─────────────────────────────────────────────────────────────
// 8. Alarm: offset firing, auto-stop, tap-stop, no re-fire
// ─────────────────────────────────────────────────────────────

let alarmSettings = AppSettings(alarmEnabled: true, alarmOffsetMin: 10)
let alarmSession = Engine.startSession(settings: alarmSettings, now: bedtime,
                                       timeZone: chicago, priorBrightness: 0.5).session
let alarmStart = overnightWake.addingTimeInterval(10 * minute)
let alarmAutoStop = alarmStart.addingTimeInterval(5 * minute)

check(Engine.schedule(for: alarmSession, timeZone: chicago).alarmStartDate == alarmStart,
      "alarm offset +10 schedules 10 min after wake")
check(Engine.schedule(for: alarmSession, timeZone: chicago).alarmAutoStopDate == alarmAutoStop,
      "auto-stop scheduled 5 min after alarm start")
check(tick(alarmSession, at: overnightWake) == [.enterWake, .stopNoiseFade],
      "alarm +10: wake tick has no alarm")
check(tick(alarmSession, at: alarmStart) == [.startAlarm], "alarm fires at its offset")
check(tick(alarmSession, at: alarmAutoStop) == [.stopAlarm], "alarm auto-stops 5 min after start")

// App records the auto-stop → nothing ever fires again
let autoStopped = Engine.markAlarmStopped(session: alarmSession, now: alarmAutoStop)
check(autoStopped.alarmStoppedAt == alarmAutoStop, "markAlarmStopped sets alarmStoppedAt")
check(tick(autoStopped, at: alarmAutoStop) == [], "auto-stop not re-emitted once recorded")
check(Engine.dueEffects(session: autoStopped, previousTick: overnightWake,
                        now: alarmAutoStop.addingTimeInterval(hour), timeZone: chicago) == [],
      "stopped alarm never re-fires even across a wide window")

// Tap-to-stop
let tapped = Engine.stopAlarmTapped(session: alarmSession, now: alarmStart.addingTimeInterval(30))
check(tapped.effects == [.stopAlarm], "tap-to-stop emits stopAlarm")
check(tapped.session.alarmStoppedAt == alarmStart.addingTimeInterval(30), "tap-to-stop records alarmStoppedAt")
check(Engine.stopAlarmTapped(session: tapped.session, now: alarmStart.addingTimeInterval(60)).effects == [],
      "second tap is a no-op")
check(tick(tapped.session, at: alarmAutoStop) == [], "tap-stopped alarm skips its auto-stop")
check(tick(tapped.session, at: alarmStart) == [], "tap-stopped alarm cannot re-start (relaunch guard)")

check(Engine.schedule(for: session, timeZone: chicago).alarmStartDate == nil,
      "alarm disabled (default): no alarm date")

// ─────────────────────────────────────────────────────────────
// 9. Collision: wake + noise stop + alarm all at the same instant
// ─────────────────────────────────────────────────────────────

let collisionSettings = AppSettings(noiseStopOffsetMin: 0, alarmEnabled: true, alarmOffsetMin: 0)
let collisionSession = Engine.startSession(settings: collisionSettings, now: bedtime,
                                           timeZone: chicago, priorBrightness: 0.5).session
check(tick(collisionSession, at: overnightWake) == [.enterWake, .stopNoiseFade, .startAlarm],
      "collision order: green, noise fade, alarm start (edge row 11)")

// ─────────────────────────────────────────────────────────────
// 10. Relaunch recovery (edge rows 1-2)
// ─────────────────────────────────────────────────────────────

check(Engine.recovery(session: session, now: overnightWake.addingTimeInterval(-4 * hour), timeZone: chicago) == .resumeSleep,
      "relaunch before wake → resumeSleep")
check(Engine.recovery(session: session, now: overnightWake.addingTimeInterval(-1), timeZone: chicago) == .resumeSleep,
      "relaunch 1s before wake → resumeSleep")
check(Engine.recovery(session: session, now: overnightWake, timeZone: chicago) == .showWakeSilent,
      "relaunch at wake instant → green, silent")
check(Engine.recovery(session: session, now: overnightWake.addingTimeInterval(hour), timeZone: chicago) == .showWakeSilent,
      "relaunch 1h past wake → green, silent")
check(Engine.recovery(session: session, now: overnightWake.addingTimeInterval(3 * hour - 1), timeZone: chicago) == .showWakeSilent,
      "relaunch just under 3h past wake → green, silent")
check(Engine.recovery(session: session, now: overnightWake.addingTimeInterval(3 * hour), timeZone: chicago) == .clearSession,
      "relaunch at 3h past wake → clear session")
check(Engine.recovery(session: session, now: overnightWake.addingTimeInterval(9 * hour), timeZone: chicago) == .clearSession,
      "relaunch 9h past wake → clear session")
check(Engine.endSessionEffects() == [.sessionEnded], "endSession emits sessionEnded")

// ─────────────────────────────────────────────────────────────
// 11. Wall-clock re-derivation: stored wakeDate is a fallback only
// ─────────────────────────────────────────────────────────────

var corrupted = session
corrupted.wakeDate = overnightWake.addingTimeInterval(-6 * hour) // bogus stored value
check(Engine.schedule(for: corrupted, timeZone: chicago).wakeDate == overnightWake,
      "schedule ignores stored wakeDate, re-derives from wall clock")
check(Engine.displayState(session: corrupted, now: overnightWake.addingTimeInterval(-1), timeZone: chicago) == .sleep,
      "displayState uses re-derived wake, not the stored one")

// ─────────────────────────────────────────────────────────────
// 12. Timezone shift mid-session (edge row 5)
// ─────────────────────────────────────────────────────────────

// Session started 10 PM Chicago; wake 7:00. Fly to Denver overnight:
// green must move to 7:00 *Denver* time (one hour later as an instant).
let chicagoWake = Engine.schedule(for: session, timeZone: chicago).wakeDate
let denverWake = Engine.schedule(for: session, timeZone: denver).wakeDate
check(denverWake.timeIntervalSince(chicagoWake) == hour, "Denver wake instant is 1h after Chicago's")
check(denverWake == date(2026, 6, 2, 7, 0, tz: denver), "Denver wake is 7:00 Denver wall clock")

// 7:30 Chicago = 6:30 Denver: green under Chicago rules, still sleep under Denver
let sevenThirtyChicago = date(2026, 6, 2, 7, 30)
check(Engine.displayState(session: session, now: sevenThirtyChicago, timeZone: chicago) == .wake,
      "7:30 Chicago clock → wake in Chicago zone")
check(Engine.displayState(session: session, now: sevenThirtyChicago, timeZone: denver) == .sleep,
      "same instant re-evaluated in Denver (6:30) → still sleep")
check(Engine.recovery(session: session, now: sevenThirtyChicago, timeZone: denver) == .resumeSleep,
      "recovery honors the new zone too")

// Effects fire at the new-zone instant
check(Engine.dueEffects(session: session, previousTick: denverWake.addingTimeInterval(-1),
                        now: denverWake, timeZone: denver) == [.enterWake, .stopNoiseFade],
      "wake effects fire at 7:00 new local time")

// ─────────────────────────────────────────────────────────────
// 13. DST spring-forward (edge row 5): skipped minute fires immediately
// ─────────────────────────────────────────────────────────────

// US DST 2026 begins Sun Mar 8, 2:00 AM local: 2:00-2:59 don't exist.
// Wake set 2:30 → must fire the moment local time first passes it (3:00 CDT).
let dstEve = date(2026, 3, 7, 22, 0) // 10 PM CST the night before
let dstSettings = AppSettings(wakeTime: HourMinute(hour: 2, minute: 30))
let dstSession = Engine.startSession(settings: dstSettings, now: dstEve,
                                     timeZone: chicago, priorBrightness: 0.5).session
let expectedDstWake = date(2026, 3, 8, 3, 0) // 3:00 AM CDT, first instant past the gap
let dstWake = Engine.schedule(for: dstSession, timeZone: chicago).wakeDate
check(dstWake == expectedDstWake, "DST-skipped 2:30 resolves to 3:00 CDT")
check(dstWake.timeIntervalSince(dstEve) == 4 * hour, "10 PM CST → 3:00 CDT is 4 real hours")
check(tick(dstSession, at: expectedDstWake) == [.enterWake, .stopNoiseFade],
      "wake effects fire immediately when local time first passes the skipped minute")
check(Engine.displayState(session: dstSession, now: expectedDstWake.addingTimeInterval(-1), timeZone: chicago) == .sleep,
      "one second before the DST-adjusted wake → still sleep")

// A normal (non-skipped) time across the same DST night still lands on the wall clock
let dstSevenSession = Engine.startSession(settings: AppSettings(), now: dstEve,
                                          timeZone: chicago, priorBrightness: 0.5).session
let dstSeven = Engine.schedule(for: dstSevenSession, timeZone: chicago).wakeDate
check(dstSeven == date(2026, 3, 8, 7, 0), "7:00 wake across spring-forward is 7:00 CDT wall clock")
check(dstSeven.timeIntervalSince(dstEve) == 8 * hour, "10 PM CST → 7:00 CDT is 8 real hours (short night)")

// ─────────────────────────────────────────────────────────────
// Summary
// ─────────────────────────────────────────────────────────────

print("\(passCount + failCount) checks: \(passCount) passed, \(failCount) failed")
if failCount > 0 {
    exit(1)
}
print("OK")
