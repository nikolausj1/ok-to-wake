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

    private let log = Logger(subsystem: "com.levelup.oktowake", category: "display")

    /// Session start: keep the device awake, capture the user's brightness,
    /// then dim. Returns the captured prior brightness for the caller to store
    /// in ActiveSession BEFORE this side effect runs (PRD invariant: persist
    /// first, then act - callers capture via `currentBrightness` first).
    func beginSession() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIScreen.main.brightness = Self.nightBrightness
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
        UIScreen.main.brightness = CGFloat(min(max(priorBrightness, 0), 1))
        log.notice("session display end: idle timer restored, brightness -> \(priorBrightness, format: .fixed(precision: 2))")
    }

    /// Wake (green) state: bright, but the idle timer stays disabled until the
    /// session is dismissed (green persists until Done - PRD C).
    func enterWakeBrightness() {
        UIScreen.main.brightness = 0.8
        log.notice("wake state: brightness raised")
    }
}
