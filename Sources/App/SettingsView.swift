import SwiftUI

/// Screen D - Settings (PRD Section 6D). A simple single scrolling list,
/// dark, in the app's design language (sharp-cornered panels on black).
/// All changes bind straight to SessionCoordinator.settings: they persist
/// immediately and, mid-session, update the session's settings snapshot -
/// volumes/sounds apply live, offsets/toggles on the next engine evaluation.
struct SettingsView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var audio: AudioController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    whiteNoiseSection
                    alarmSection
                    kidLockSection
                    aboutSection
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
            }
        }
        .safeAreaInset(edge: .top) { header }
        .preferredColorScheme(.dark)
        // Presented as a fullScreenCover, which gets its own status bar
        // visibility: keep it hidden like the rest of the app (no stray
        // light when Settings is opened mid-session at night).
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onDisappear { audio.stopPreview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                audio.stopPreview()
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 24)
                    .frame(height: 44)
                    .background(Theme.panel)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.canvas)
    }

    // MARK: - White noise (PRD D)

    private var whiteNoiseSection: some View {
        section("White Noise") {
            toggleRow("White noise", isOn: $coordinator.settings.whiteNoiseEnabled)
            divider
            soundPickerRows(ids: SoundLibrary.whiteNoiseIDs,
                            selection: $coordinator.settings.whiteNoiseSound,
                            previewVolume: coordinator.settings.whiteNoiseVolume)
            divider
            volumeRow("Volume",
                      value: $coordinator.settings.whiteNoiseVolume,
                      previewSound: coordinator.settings.whiteNoiseSound,
                      isLiveAlready: audio.noiseIsPlaying)
            divider
            toggleRow("Stop white noise", isOn: $coordinator.settings.noiseStopEnabled)
            if coordinator.settings.noiseStopEnabled {
                divider
                stepperRow("Stops",
                           value: $coordinator.settings.noiseStopOffsetMin,
                           range: AppSettings.noiseOffsetRange,
                           step: 5)
            }
        }
    }

    // MARK: - Alarm (PRD D; default off)

    private var alarmSection: some View {
        section("Alarm") {
            toggleRow("Alarm", isOn: $coordinator.settings.alarmEnabled)
            divider
            soundPickerRows(ids: SoundLibrary.alarmIDs,
                            selection: $coordinator.settings.alarmSound,
                            previewVolume: coordinator.settings.alarmVolume)
            divider
            stepperRow("Alarm time",
                       value: $coordinator.settings.alarmOffsetMin,
                       range: AppSettings.alarmOffsetRange,
                       step: 5)
            divider
            volumeRow("Alarm volume",
                      value: $coordinator.settings.alarmVolume,
                      previewSound: coordinator.settings.alarmSound,
                      isLiveAlready: audio.alarmIsPlaying)
        }
    }

    // MARK: - Kid lock + Guided Access note (PRD D/E)

    private var kidLockSection: some View {
        section("Kid Lock") {
            toggleRow("Kid lock", isOn: $coordinator.settings.kidLockEnabled)
            Text("During a session, exiting and settings require a grown-up hold + question.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 14)
            divider
            Text("For determined kids, iOS Guided Access is the stronger lock: turn it on in Settings \u{2192} Accessibility \u{2192} Guided Access, then triple-click the side button in this app.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 14)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        section("About") {
            HStack {
                Text("Version")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(Self.versionString)
                    .font(.system(.body, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(minHeight: 48)
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Row builders

    /// Sharp-cornered panel with a muted uppercase section title above it
    /// (PRD Section 7 components).
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded).weight(.medium))
                .kerning(1.2)
                .foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 20)
                .background(Theme.panel)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.wakeGreen)
        .frame(minHeight: 52)
    }

    /// One row per bundled sound; tapping selects it and plays a ~5 s preview
    /// (PRD D). Phase 6 grows the lists; these rows scale with them.
    private func soundPickerRows(ids: [String],
                                 selection: Binding<String>,
                                 previewVolume: Double) -> some View {
        ForEach(ids, id: \.self) { id in
            Button {
                selection.wrappedValue = id
                audio.previewSound(soundID: id, volume: previewVolume)
            } label: {
                HStack {
                    Text(SoundLibrary.displayName(forAssetID: id))
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: selection.wrappedValue == id
                          ? "checkmark.circle.fill" : "play.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selection.wrappedValue == id
                                         ? Theme.wakeGreen : Theme.textMuted)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Volume slider. Applies live to a playing noise/alarm; otherwise a
    /// short preview on release lets the parent hear the level.
    private func volumeRow(_ title: String,
                           value: Binding<Double>,
                           previewSound: String,
                           isLiveAlready: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .layoutPriority(1)
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Slider(value: value, in: 0...1) { editing in
                if !editing && !isLiveAlready {
                    audio.previewSound(soundID: previewSound, volume: value.wrappedValue)
                }
            }
            .tint(Theme.textPrimary)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(minHeight: 52)
    }

    /// Offset stepper relative to wake time ("At wake time" / "+15 min" / "-10 min").
    private func stepperRow(_ title: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            step: Int) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(Self.offsetLabel(value.wrappedValue))
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
        .frame(minHeight: 52)
    }

    static func offsetLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "At wake time" }
        return minutes > 0 ? "+\(minutes) min" : "\(minutes) min"
    }
}
