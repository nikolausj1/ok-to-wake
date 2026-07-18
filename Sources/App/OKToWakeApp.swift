import SwiftUI

@main
struct OKToWakeApp: App {
    @StateObject private var audio = AudioController()
    @StateObject private var display = DisplayController()

    var body: some Scene {
        WindowGroup {
            PlaceholderView()
                .environmentObject(audio)
                .environmentObject(display)
        }
    }
}

/// Phase 1 placeholder: black screen, app name, live clock.
/// Phase 2 adds a temporary dev harness to exercise the audio/display layer in
/// the sim - the real Home / night screens arrive in Phase 3 and replace it.
struct PlaceholderView: View {
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var display: DisplayController

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private let muted = Color(red: 0.54, green: 0.56, blue: 0.59) // #8a8f96

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("OK to Wake")
                    .font(.system(.title2, design: .rounded).weight(.light))
                    .foregroundStyle(muted)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.timeFormatter.string(from: context.date))
                        .font(.system(size: 110, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                devHarness
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: handleLaunchArguments)
    }

    // MARK: - Phase 2 dev harness (temporary; removed when Phase 3 lands)

    private var devHarness: some View {
        VStack(spacing: 14) {
            Text(statusLine)
                .font(.system(.footnote, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(muted)
            HStack(spacing: 12) {
                harnessButton("Start Noise") { startNoise() }
                harnessButton("Fade Out") { audio.fadeOutNoise() }
                harnessButton("Stop") { audio.stopNoiseImmediately() }
            }
            HStack(spacing: 12) {
                harnessButton("Play Alarm") {
                    audio.startAlarm(soundID: PersistenceStore.shared.settings.alarmSound,
                                     volume: PersistenceStore.shared.settings.alarmVolume)
                }
                harnessButton("Stop Alarm") { audio.stopAlarm() }
                harnessButton("End Session") { endHarnessSession() }
            }
        }
        .padding(.top, 12)
    }

    private var statusLine: String {
        var parts: [String] = []
        parts.append(audio.noiseIsPlaying ? "noise: playing" : "noise: off")
        parts.append(audio.alarmIsPlaying ? "alarm: playing" : "alarm: off")
        if audio.audioUnavailable { parts.append("AUDIO UNAVAILABLE") }
        return parts.joined(separator: "   ")
    }

    private func harnessButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(red: 0.13, green: 0.145, blue: 0.157)) // #212528
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }

    /// Mimics the real Start path's ordering: persist the session (with prior
    /// brightness) BEFORE any side effect, then audio + display.
    private func startNoise() {
        let store = PersistenceStore.shared
        let settings = store.settings
        if store.activeSession == nil {
            let (session, _) = Engine.startSession(settings: settings,
                                                   now: Date(),
                                                   timeZone: TimeZone.current,
                                                   priorBrightness: display.currentBrightness)
            store.activeSession = session
        }
        audio.activateSession()
        display.beginSession()
        audio.startNoise(soundID: settings.whiteNoiseSound, volume: settings.whiteNoiseVolume)
    }

    private func endHarnessSession() {
        let store = PersistenceStore.shared
        let prior = store.activeSession?.priorBrightness ?? display.currentBrightness
        audio.deactivateSession()
        display.endSession(restoring: prior)
        store.clearActiveSession()
    }

    /// simctl can't tap, so the sim starts audio via a launch argument
    /// (Build Guide sim-verify convention).
    private func handleLaunchArguments() {
        if ProcessInfo.processInfo.arguments.contains("-autostartNoise") {
            startNoise()
        }
        if ProcessInfo.processInfo.arguments.contains("-autostartAlarm") {
            audio.startAlarm(soundID: PersistenceStore.shared.settings.alarmSound,
                             volume: PersistenceStore.shared.settings.alarmVolume)
        }
    }
}
