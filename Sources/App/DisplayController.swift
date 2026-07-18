import UIKit
import os

/// App-layer display control for the foreground-all-night model (PRD Section 9):
/// idle timer disabled for the session only, and UIScreen.brightness
/// captured/set/restored around it. `priorBrightness` is persisted inside
/// ActiveSession so a crash mid-session can still restore on relaunch
/// (PRD Section 8 + Risks).
@MainActor
final class DisplayController: ObservableObject {
    /// Night-level brightness for the sleep state; Phase 3's design pass may tune it.
    static let nightBrightness: CGFloat = 0.1
    /// Wake (green) state brightness - loud, visually (PRD C).
    static let wakeBrightness: CGFloat = 0.8

    /// Floor for the night-panel brightness boost (Phase 8 night controls).
    static let controlsMinBrightness: Double = 0.4

    private let log = Logger(subsystem: "com.levelup.oktowake", category: "display")
    private var rampTask: Task<Void, Never>?

    /// Session start: keep the device awake, capture the user's brightness,
    /// then dim. Returns the captured prior brightness for the caller to store
    /// in ActiveSession BEFORE this side effect runs (PRD invariant: persist
    /// first, then act - callers capture via `currentBrightness` first).
    func beginSession() {
        UIApplication.shared.isIdleTimerDisabled = true
        setBrightness(Self.nightBrightness)
        log.notice("session display begin: idle timer disabled, brightness -> \(Self.nightBrightness, format: .fixed(precision: 2))")
    }

    /// What ActiveSession.priorBrightness should be set to at Start.
    var currentBrightness: Double {
        Double(UIScreen.main.brightness)
    }

    /// Every session end path (dismiss, gated end, stale cleanup, relaunch
    /// recovery of a dead session): restore what the user had.
    func endSession(restoring priorBrightness: Double) {
        UIApplication.shared.isIdleTimerDisabled = false
        setBrightness(CGFloat(min(max(priorBrightness, 0), 1)))
        log.notice("session display end: idle timer restored, brightness -> \(priorBrightness, format: .fixed(precision: 2))")
    }

    /// Wake (green) state: bright, but the idle timer stays disabled until the
    /// session is dismissed (green persists until Done - PRD C).
    func enterWakeBrightness() {
        setBrightness(Self.wakeBrightness)
        log.notice("wake state: brightness raised")
    }

    /// Relaunch recovery straight into the green state (PRD edge row 2): the
    /// session is still logically running until Done, so keep the device
    /// awake and go bright.
    func resumeSessionInWake() {
        UIApplication.shared.isIdleTimerDisabled = true
        setBrightness(Self.wakeBrightness)
        log.notice("session resumed in wake state: idle timer disabled, bright")
    }

    // MARK: - Night controls panel boost (Phase 8 spec)

    /// Tap at night: ramp brightness up to a clearly usable level (the
    /// stored priorBrightness, floored at 0.4) over the standard 800 ms ease
    /// while the controls panel is up.
    func boostForControls(to target: Double) {
        let clamped = CGFloat(min(max(target, Self.controlsMinBrightness), 1))
        log.notice("night controls: brightness ramp -> \(clamped, format: .fixed(precision: 2))")
        ramp(to: clamped)
    }

    /// Panel hidden (auto-fade or outside tap): ramp back down to the night
    /// level. Never called outside the sleep state.
    func returnToNight() {
        log.notice("night controls hidden: brightness ramp -> night \(Self.nightBrightness, format: .fixed(precision: 2))")
        ramp(to: Self.nightBrightness)
    }

    /// Hard set (session begin/end, wake): cancel any in-flight ramp so a
    /// stale panel animation can never overwrite the new state.
    private func setBrightness(_ value: CGFloat) {
        rampTask?.cancel()
        UIScreen.main.brightness = value
    }

    /// UIScreen.brightness has no system animation; step it over ~800 ms with
    /// an ease-in-out curve to match the app's transition timing.
    private func ramp(to target: CGFloat, duration: TimeInterval = 0.8) {
        rampTask?.cancel()
        let start = UIScreen.main.brightness
        guard abs(start - target) > 0.01 else {
            UIScreen.main.brightness = target
            return
        }
        let steps = 16
        rampTask = Task { @MainActor in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                guard !Task.isCancelled else { return }
                let t = CGFloat(i) / CGFloat(steps)
                let eased = t * t * (3 - 2 * t)   // smoothstep ease-in-out
                UIScreen.main.brightness = start + (target - start) * eased
            }
        }
    }
}
