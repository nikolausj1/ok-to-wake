import AVFoundation
import Foundation
import os

/// App-layer audio: executes the engine's noise/alarm effects on AVFoundation.
/// The engine never touches this; the app maps Effect values onto these calls.
///
/// - AVAudioSession `.playback`, activated at session start, deactivated at end.
/// - White noise: AVAudioPlayer, `numberOfLoops = -1`, loop-clean LPCM CAF
///   (AVAudioEngine scheduled buffers are the pre-approved fallback if the soak
///   test ever hears a seam - PRD Section 9).
/// - Alarm: separate looping player, runs until stopAlarm().
/// - Interruptions (PRD edge row 6): on end, auto-resume; retry once on
///   failure; then stay silent and raise `audioUnavailable` for the UI's
///   muted glyph. Never an alert at night.
@MainActor
final class AudioController: NSObject, ObservableObject {
    /// True when audio could not be started/resumed (missing asset, failed
    /// resume after retry). The visual contract is never blocked by this
    /// (PRD A error states, edge row 12).
    @Published private(set) var audioUnavailable = false
    @Published private(set) var noiseIsPlaying = false
    @Published private(set) var alarmIsPlaying = false

    static let noiseFadeDuration: TimeInterval = 3.0

    private let log = Logger(subsystem: "com.levelup.oktowake", category: "audio")
    private var noisePlayer: AVAudioPlayer?
    private var alarmPlayer: AVAudioPlayer?
    private var previewPlayer: AVAudioPlayer?
    private var fadeStopWorkItem: DispatchWorkItem?
    private var previewStopWorkItem: DispatchWorkItem?
    private var noiseVolume: Float = 0.5

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }

    // MARK: - Audio session lifecycle

    /// Call when a night session starts (before starting noise).
    func activateSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            log.notice("audio session activated (.playback)")
        } catch {
            log.error("audio session activation failed: \(error.localizedDescription, privacy: .public)")
            audioUnavailable = true
        }
    }

    /// Call when the night session ends.
    func deactivateSession() {
        stopNoiseImmediately()
        stopAlarm()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            log.notice("audio session deactivated")
        } catch {
            log.error("audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - White noise

    func startNoise(soundID: String, volume: Double) {
        cancelPendingFadeStop()
        noiseVolume = Float(min(max(volume, 0), 1))
        guard let url = SoundLibrary.url(forAssetID: soundID) else {
            log.error("white noise asset missing: \(soundID, privacy: .public)")
            audioUnavailable = true   // session continues visual-only (edge row 12)
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = noiseVolume
            player.prepareToPlay()
            player.play()
            noisePlayer = player
            noiseIsPlaying = player.isPlaying
            audioUnavailable = !player.isPlaying
            log.notice("white noise \(soundID, privacy: .public) started, isPlaying=\(player.isPlaying)")
            // Second confirmation shortly after start, for sim log verification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let p = self.noisePlayer else { return }
                self.log.notice("white noise check at t+2s: isPlaying=\(p.isPlaying), time=\(p.currentTime, format: .fixed(precision: 2))s")
            }
        } catch {
            log.error("white noise player failed: \(error.localizedDescription, privacy: .public)")
            audioUnavailable = true
        }
    }

    /// The engine's `.stopNoiseFade` effect: ~3 s fade, then stop.
    func fadeOutNoise() {
        guard let player = noisePlayer, player.isPlaying else { return }
        cancelPendingFadeStop()
        log.notice("white noise fading out over \(Self.noiseFadeDuration, format: .fixed(precision: 0))s")
        player.setVolume(0, fadeDuration: Self.noiseFadeDuration)
        let work = DispatchWorkItem { [weak self] in
            self?.stopNoiseImmediately()
        }
        fadeStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noiseFadeDuration, execute: work)
    }

    func stopNoiseImmediately() {
        cancelPendingFadeStop()
        if noisePlayer != nil { log.notice("white noise stopped") }
        noisePlayer?.stop()
        noisePlayer = nil
        noiseIsPlaying = false
    }

    /// Live volume change from settings/night slider.
    func setNoiseVolume(_ volume: Double) {
        noiseVolume = Float(min(max(volume, 0), 1))
        noisePlayer?.volume = noiseVolume
    }

    private func cancelPendingFadeStop() {
        fadeStopWorkItem?.cancel()
        fadeStopWorkItem = nil
    }

    // MARK: - Settings tap-preview (PRD D: ~5 s)

    static let previewDuration: TimeInterval = 5

    /// Short preview for the Settings sound pickers and volume sliders.
    /// Uses its own player so a mid-session preview never disturbs the
    /// running white noise player.
    func previewSound(soundID: String, volume: Double) {
        stopPreview()
        guard let url = SoundLibrary.url(forAssetID: soundID) else {
            log.error("preview asset missing: \(soundID, privacy: .public)")
            return
        }
        // Outside a session the .playback category may not be active yet;
        // activating here is harmless when a session already owns it.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1   // short files still fill the full ~5 s
            player.volume = Float(min(max(volume, 0), 1))
            player.prepareToPlay()
            player.play()
            previewPlayer = player
            log.notice("preview \(soundID, privacy: .public) started (~\(Int(Self.previewDuration))s)")
            let work = DispatchWorkItem { [weak self] in self?.stopPreview() }
            previewStopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDuration, execute: work)
        } catch {
            log.error("preview player failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops any preview. Never deactivates the shared audio session - a
    /// running night session owns it.
    func stopPreview() {
        previewStopWorkItem?.cancel()
        previewStopWorkItem = nil
        previewPlayer?.stop()
        previewPlayer = nil
    }

    // MARK: - Alarm

    /// Loops until stopAlarm(); the engine handles the 5-minute auto-stop by
    /// emitting `.stopAlarm`.
    func startAlarm(soundID: String, volume: Double) {
        guard let url = SoundLibrary.url(forAssetID: soundID) else {
            log.error("alarm asset missing: \(soundID, privacy: .public)")
            audioUnavailable = true
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = Float(min(max(volume, 0), 1))
            player.prepareToPlay()
            player.play()
            alarmPlayer = player
            alarmIsPlaying = player.isPlaying
            log.notice("alarm \(soundID, privacy: .public) started, isPlaying=\(player.isPlaying)")
        } catch {
            log.error("alarm player failed: \(error.localizedDescription, privacy: .public)")
            audioUnavailable = true
        }
    }

    /// Live volume change from the Settings alarm slider while an alarm sounds.
    func setAlarmVolume(_ volume: Double) {
        alarmPlayer?.volume = Float(min(max(volume, 0), 1))
    }

    func stopAlarm() {
        if alarmPlayer != nil { log.notice("alarm stopped") }
        alarmPlayer?.stop()
        alarmPlayer = nil
        alarmIsPlaying = false
    }

    // MARK: - Interruptions (PRD edge row 6)

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        // AVAudioSession notifications can arrive off-main.
        Task { @MainActor in
            switch type {
            case .began:
                self.log.notice("audio interruption began")
                self.noiseIsPlaying = false
                self.alarmIsPlaying = false
            case .ended:
                self.log.notice("audio interruption ended - resuming")
                self.resumeAfterInterruption(attempt: 1)
            @unknown default:
                break
            }
        }
    }

    /// Auto-resume on interruption end; retry once; then silent + flag.
    private func resumeAfterInterruption(attempt: Int) {
        var resumed = true
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            resumed = false
        }
        if let player = noisePlayer {
            player.volume = noiseVolume
            if !player.play() { resumed = false }
            noiseIsPlaying = player.isPlaying
        }
        if let player = alarmPlayer {
            if !player.play() { resumed = false }
            alarmIsPlaying = player.isPlaying
        }
        if resumed {
            log.notice("audio resumed after interruption (attempt \(attempt))")
            audioUnavailable = false
        } else if attempt == 1 {
            log.notice("audio resume failed, retrying once")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.resumeAfterInterruption(attempt: 2)
            }
        } else {
            log.error("audio resume failed after retry - staying silent (muted glyph)")
            audioUnavailable = true
        }
    }
}

/// The single registry the pickers, settings, and audio layer share
/// (PRD Section 8, "Bundled content"). Asset id == bundled CAF file name.
enum SoundLibrary {
    /// Phase 2 placeholders; Phase 6 replaces/extends these with Justin's picks.
    static let whiteNoiseIDs = ["classicWhite"]
    static let alarmIDs = ["gentleChime"]

    static func url(forAssetID id: String) -> URL? {
        Bundle.main.url(forResource: id, withExtension: "caf")
    }

    /// Human-readable names for the pickers and the Home secondary row.
    static func displayName(forAssetID id: String) -> String {
        switch id {
        case "classicWhite": return "Classic White"
        case "gentleChime": return "Gentle Chime"
        default: return id
        }
    }
}
