import Combine
import SwiftUI
import os

/// Owns the running session end-to-end (PRD Phase 4): ticks the pure engine
/// once per second, executes its emitted effects on the audio/display layers,
/// persists state through PersistenceStore, and recovers a persisted session
/// on relaunch (PRD edge rows 1-2). Views read state from here and call the
/// intent methods; they never touch the engine or persistence directly.
@MainActor
final class SessionCoordinator: ObservableObject {

    // MARK: - Published state

    @Published private(set) var displayState: DisplayState = .idle
    @Published private(set) var activeSession: ActiveSession?
    /// True while the session runs unplugged (at Start, or the charger was
    /// pulled): fully black screen, audio continues, tap peeks the clock
    /// (PRD B battery-saver dark mode). Automatic, never a setting.
    @Published private(set) var batterySaverActive = false
    /// Bind UI controls straight to this; changes persist immediately and,
    /// mid-session, update the session's settings snapshot (PRD Section 8).
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.settings = settings
            audio.setNoiseVolume(settings.whiteNoiseVolume)
            audio.setAlarmVolume(settings.alarmVolume)
            if var session = activeSession {
                session.settingsSnapshot = settings
                activeSession = session
                store.activeSession = session
            }
        }
    }

    let audio: AudioController
    let display: DisplayController

    private let store: PersistenceStore
    private let log = Logger(subsystem: "com.levelup.oktowake", category: "session")
    private var tickTimer: Timer?
    private var previousTick = Date()
    private var booted = false

    init(audio: AudioController, display: DisplayController, store: PersistenceStore = .shared) {
        self.audio = audio
        self.display = display
        self.store = store
        self.settings = store.settings
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.batteryStateChanged() }
        }
    }

    // MARK: - Battery / charging

    /// Charging check for Start (PRD A) and battery-saver mode (PRD B).
    /// `.unknown` (simulator, undetectable hardware) is treated as plugged in
    /// so it never nags and never falsely blacks out the screen.
    var isPluggedIn: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        case .unplugged: return false
        case .unknown: return true
        @unknown default: return true
        }
    }

    private func batteryStateChanged() {
        guard activeSession != nil, displayState == .sleep else { return }
        let saver = !isPluggedIn
        guard saver != batterySaverActive else { return }
        log.notice("battery state change: batterySaver -> \(saver)")
        withAnimation(.easeInOut(duration: 0.8)) { batterySaverActive = saver }
    }

    // MARK: - Boot (launch args + relaunch recovery)

    /// One-shot at first appearance: dev demo hooks, then normal relaunch
    /// recovery of a persisted session.
    func boot() {
        guard !booted else { return }
        booted = true
        startTicking()
        #if DEBUG
        if applyDemoLaunchArguments() { return }
        #endif
        recoverPersistedSession()
    }

    /// PRD edge rows 1-2: resume sleep / silent green under 3 h / clear beyond.
    private func recoverPersistedSession() {
        guard let persisted = store.activeSession else { return }
        let now = Date()
        let timeZone = TimeZone.current
        let action = Engine.recovery(session: persisted, now: now, timeZone: timeZone)
        log.notice("relaunch recovery: \(String(describing: action), privacy: .public)")
        previousTick = now
        switch action {
        case .resumeSleep:
            activeSession = persisted
            audio.activateSession()
            display.beginSession()
            // Restart white noise unless its scheduled stop already passed
            // (negative offsets can put the stop before the wake time).
            let snapshot = persisted.settingsSnapshot
            let schedule = Engine.schedule(for: persisted, timeZone: timeZone)
            if snapshot.whiteNoiseEnabled, schedule.noiseStopDate.map({ now < $0 }) ?? true {
                audio.startNoise(soundID: snapshot.whiteNoiseSound, volume: snapshot.whiteNoiseVolume)
            }
            batterySaverActive = !isPluggedIn
            displayState = .sleep
        case .showWakeSilent:
            // Session logically still running until Done; silent (no alarm
            // re-fire - previousTick = now means only future effects fire).
            activeSession = persisted
            display.resumeSessionInWake()
            displayState = .wake
        case .clearSession:
            display.endSession(restoring: persisted.priorBrightness)
            store.clearActiveSession()
        }
    }

    // MARK: - Session lifecycle (user intents)

    /// The Start Night tap (the charging notice, if any, happens in the view
    /// before this is called).
    func startNight() {
        guard activeSession == nil else { return }
        let now = Date()
        let (session, effects) = Engine.startSession(settings: settings,
                                                     now: now,
                                                     timeZone: .current,
                                                     priorBrightness: display.currentBrightness)
        store.settings = settings          // wake time remembered for next night
        store.activeSession = session      // persist BEFORE any side effect (PRD invariant)
        activeSession = session
        previousTick = now
        audio.activateSession()
        display.beginSession()
        execute(effects)
        batterySaverActive = !isPluggedIn
        log.notice("session started; wake \(session.wakeDate, privacy: .public), batterySaver=\(self.batterySaverActive)")
        setDisplayState(.sleep)
        startTicking()
    }

    /// Every deliberate end path: Done on green, End Session at night.
    /// Cleanup order: audio off, brightness/idle timer restored, session
    /// cleared (PRD invariants).
    func endSession() {
        let prior = activeSession?.priorBrightness ?? display.currentBrightness
        audio.deactivateSession()
        display.endSession(restoring: prior)
        store.clearActiveSession()
        activeSession = nil
        batterySaverActive = false
        log.notice("session ended -> Home")
        setDisplayState(.idle)
    }

    /// Tap anywhere on the green screen while the alarm sounds: stop the
    /// sound, keep the green (PRD C).
    func stopAlarmTapped() {
        guard let session = activeSession, audio.alarmIsPlaying else { return }
        let (updated, effects) = Engine.stopAlarmTapped(session: session, now: Date())
        activeSession = updated
        store.activeSession = updated
        execute(effects)
    }

    // MARK: - Tick

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        tickTimer = timer
    }

    private func tick() {
        guard let session = activeSession else { return }
        let now = Date()
        let timeZone = TimeZone.current
        let effects = Engine.dueEffects(session: session,
                                        previousTick: previousTick,
                                        now: now,
                                        timeZone: timeZone)
        previousTick = now
        execute(effects)
        // Safety net: keep the visible state in lockstep with the pure engine
        // (covers clock jumps and timezone changes between effect windows).
        let target = Engine.displayState(session: session, now: now, timeZone: timeZone)
        if target != displayState {
            switch target {
            case .wake:
                display.enterWakeBrightness()
            case .sleep:   // e.g. flew west mid-green: back to a dim night
                display.beginSession()
                batterySaverActive = !isPluggedIn
            case .idle:
                break      // unreachable with a live session
            }
            setDisplayState(target)
        }
    }

    /// Map engine-emitted effect values onto the real world (PRD Section 9).
    private func execute(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .startNoise:
                audio.startNoise(soundID: settings.whiteNoiseSound, volume: settings.whiteNoiseVolume)
            case .stopNoiseFade:
                audio.fadeOutNoise()
            case .startAlarm:
                audio.startAlarm(soundID: settings.alarmSound, volume: settings.alarmVolume)
            case .stopAlarm:
                audio.stopAlarm()
                // Record the stop so a relaunch can never re-fire it.
                if let session = activeSession {
                    let updated = Engine.markAlarmStopped(session: session, now: Date())
                    activeSession = updated
                    store.activeSession = updated
                }
            case .enterWake:
                display.enterWakeBrightness()
                setDisplayState(.wake)
            case .sessionEnded:
                break // endSession() performs the cleanup itself
            }
        }
    }

    private func setDisplayState(_ state: DisplayState) {
        guard state != displayState else { return }
        withAnimation(.easeInOut(duration: 0.8)) { displayState = state }
    }

    // MARK: - Dev-only demo hooks (Build Guide: simctl can't tap)

    #if DEBUG
    /// Launch-argument hooks for sim screenshots and non-interactive
    /// verification. Additive and dev-only; release builds compile them out.
    ///
    ///   -demoState home|sleep|wake   force a screen (sleep runs the REAL start path)
    ///   -demoWakeIn <seconds>        real session, wake time N seconds out
    ///                                (rounded up to the next whole minute)
    ///   -demoLandscape               handled in RootView (forces landscape)
    ///   -demoSettings                handled in HomeView (opens Settings)
    ///   -demoGate / -demoGateFlow    handled here (kid lock on) + SleepView
    ///                                (gate overlay / scripted gated end-session)
    ///   -demoNoiseSound <id>         select the white noise asset first
    ///   -demoAlarmSound <id>         enable the alarm + select its asset
    ///                                (both for per-asset load/play log checks)
    ///
    /// Returns true when a hook took over the launch path (skips recovery).
    private func applyDemoLaunchArguments() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        // Gate demos need kid lock on before the session snapshot is taken.
        if args.contains("-demoGate") || args.contains("-demoGateFlow") {
            settings.kidLockEnabled = true
            log.notice("DEMO: kid lock forced on for gate demo")
        }
        // Sound selection hooks (Phase 6): apply before any state hook so the
        // real start path picks up the chosen assets.
        if let id = value(after: "-demoNoiseSound") {
            settings.whiteNoiseSound = id
            log.notice("DEMO: -demoNoiseSound \(id, privacy: .public)")
        }
        if let id = value(after: "-demoAlarmSound") {
            settings.alarmEnabled = true
            settings.alarmSound = id
            log.notice("DEMO: -demoAlarmSound \(id, privacy: .public)")
        }
        if let state = value(after: "-demoState") {
            log.notice("DEMO: -demoState \(state, privacy: .public)")
            store.clearActiveSession()
            switch state {
            case "sleep":
                startNight()                       // real path: persists, dims, starts noise
            case "wake":
                // Synthetic persisted session whose wake time passed an hour
                // ago, then the real recovery path -> green, silent.
                let now = Date()
                var snapshot = settings
                let target = now.addingTimeInterval(-3600)
                let comps = Calendar.current.dateComponents([.hour, .minute], from: target)
                snapshot.wakeTime = HourMinute(hour: comps.hour ?? 7, minute: comps.minute ?? 0)
                let session = ActiveSession(startedAt: now.addingTimeInterval(-7200),
                                            wakeDate: target,
                                            settingsSnapshot: snapshot,
                                            priorBrightness: display.currentBrightness)
                store.activeSession = session
                recoverPersistedSession()
            default:                               // "home"
                break
            }
            return true
        }
        if let secsString = value(after: "-demoWakeIn"), let secs = TimeInterval(secsString), secs > 0 {
            store.clearActiveSession()
            // Wake times are minute-granular: round the target up to the next
            // whole minute, then run the REAL Start -> tick -> green path.
            let target = Date().addingTimeInterval(secs)
            let ceiled = Date(timeIntervalSince1970: ceil(target.timeIntervalSince1970 / 60) * 60)
            let comps = Calendar.current.dateComponents([.hour, .minute], from: ceiled)
            settings.wakeTime = HourMinute(hour: comps.hour ?? 7, minute: comps.minute ?? 0)
            log.notice("DEMO: -demoWakeIn \(Int(secs)) -> wake at \(ceiled, privacy: .public)")
            startNight()
            return true
        }
        return false
    }
    #endif
}
