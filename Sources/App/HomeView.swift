import SwiftUI

/// Screen A - Home (Setup). Calm, dark, minimal (PRD Section 6A / 7):
/// large tappable wake time -> inline wheel picker (5-min steps), live
/// "Green in Xh Ym" line, huge Start Night pill, low-contrast secondary row
/// (sound + volume quick sheet, alarm status, Settings gear), and the soft
/// not-charging notice at Start.
struct HomeView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    @State private var showPicker = false
    @State private var showChargingNotice = false
    @State private var showSoundSheet = false
    @State private var showSettingsPlaceholder = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.canvas.ignoresSafeArea()
                VStack(spacing: geo.size.height * 0.025) {
                    Spacer(minLength: 0)
                    wakeTimeButton(geo)
                    if showPicker { pickerWheels }
                    greenInLine
                    Spacer(minLength: 0)
                    if showChargingNotice {
                        chargingNotice
                    } else {
                        startButton
                    }
                    secondaryRow
                        .padding(.top, 8)
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 36)
                .padding(.vertical, geo.size.height * 0.06)
            }
        }
        .sheet(isPresented: $showSoundSheet) {
            SoundQuickSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettingsPlaceholder) {
            SettingsPlaceholderSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Wake time + picker

    private func wakeTimeButton(_ geo: GeometryProxy) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { showPicker.toggle() }
        } label: {
            Text(coordinator.settings.wakeTime.display12h)
                .font(.system(size: min(geo.size.width * 0.13, geo.size.height * 0.2),
                              weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wake time \(coordinator.settings.wakeTime.display12h), tap to change")
    }

    /// Inline hour / minute (5-min steps) / AM-PM wheels bound to settings.
    private var pickerWheels: some View {
        HStack(spacing: 0) {
            Picker("Hour", selection: hour12Binding) {
                ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Minute", selection: minuteBinding) {
                ForEach(Array(stride(from: 0, through: 55, by: 5)), id: \.self) {
                    Text(String(format: "%02d", $0)).tag($0)
                }
            }
            Picker("AM/PM", selection: isPMBinding) {
                Text("AM").tag(false)
                Text("PM").tag(true)
            }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: 420)
        .frame(height: 150)
        .clipped()
        .transition(.opacity)
    }

    private var hour12Binding: Binding<Int> {
        Binding {
            ((coordinator.settings.wakeTime.hour + 11) % 12) + 1
        } set: { new in
            let pm = coordinator.settings.wakeTime.hour >= 12
            coordinator.settings.wakeTime.hour = (new % 12) + (pm ? 12 : 0)
        }
    }

    private var minuteBinding: Binding<Int> {
        Binding {
            coordinator.settings.wakeTime.minute
        } set: { new in
            coordinator.settings.wakeTime.minute = new
        }
    }

    private var isPMBinding: Binding<Bool> {
        Binding {
            coordinator.settings.wakeTime.hour >= 12
        } set: { pm in
            let h12 = ((coordinator.settings.wakeTime.hour + 11) % 12) + 1
            coordinator.settings.wakeTime.hour = (h12 % 12) + (pm ? 12 : 0)
        }
    }

    // MARK: - "Green in Xh Ym" (live; the safeguard against AM/PM mistakes)

    private var greenInLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(greenInText(at: context.date))
                .font(.system(.title3, design: .rounded).weight(.light))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func greenInText(at now: Date) -> String {
        let wake = coordinator.settings.wakeTime.nextOccurrence(after: now, calendar: .current)
        let mins = max(0, Int(ceil(wake.timeIntervalSince(now) / 60)))
        return "Green in \(mins / 60)h \(mins % 60)m"
    }

    // MARK: - Start + charging notice

    private var startButton: some View {
        Button {
            if coordinator.isPluggedIn {
                coordinator.startNight()
            } else {
                withAnimation(.easeInOut(duration: 0.25)) { showChargingNotice = true }
            }
        } label: {
            Text("Start Night")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .background(Theme.textPrimary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Soft inline notice; starting anyway is fully supported (battery-saver
    /// mode covers the unplugged night - PRD A).
    private var chargingNotice: some View {
        VStack(spacing: 16) {
            Text("Not charging \u{2014} the screen stays on all night and will use battery.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                Button {
                    showChargingNotice = false
                    coordinator.startNight()
                } label: {
                    Text("Start anyway")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Theme.panel)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showChargingNotice = false }
                } label: {
                    Text("Cancel")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .overlay(Capsule().strokeBorder(Theme.panel, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }

    // MARK: - Secondary row (small, low-contrast)

    private var whiteNoiseAvailable: Bool {
        SoundLibrary.url(forAssetID: coordinator.settings.whiteNoiseSound) != nil
    }

    private var soundLabel: String {
        guard whiteNoiseAvailable else { return "White noise unavailable" }
        guard coordinator.settings.whiteNoiseEnabled else { return "White noise off" }
        return SoundLibrary.displayName(forAssetID: coordinator.settings.whiteNoiseSound)
    }

    private var alarmStatusText: String {
        guard coordinator.settings.alarmEnabled else { return "Alarm off" }
        let at = coordinator.settings.wakeTime.adding(minutes: coordinator.settings.alarmOffsetMin)
        return "Alarm at \(at.display12h)"
    }

    private var secondaryRow: some View {
        HStack(spacing: 0) {
            Button { showSoundSheet = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: whiteNoiseAvailable ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    Text(soundLabel)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Text(alarmStatusText)
            Spacer()
            Button { showSettingsPlaceholder = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 19))
                    .frame(width: 44, height: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .font(.system(.footnote, design: .rounded).weight(.light))
        .foregroundStyle(Theme.textMuted)
    }
}

/// Quick sound/volume sheet from the Home secondary row (same controls as
/// Settings will have in Phase 5).
struct SoundQuickSheet: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("White Noise")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Toggle(isOn: $coordinator.settings.whiteNoiseEnabled) {
                Text("Play white noise all night")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.wakeGreen)
            VStack(alignment: .leading, spacing: 10) {
                Text("Sound")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                Picker("Sound", selection: $coordinator.settings.whiteNoiseSound) {
                    ForEach(SoundLibrary.whiteNoiseIDs, id: \.self) { id in
                        Text(SoundLibrary.displayName(forAssetID: id)).tag(id)
                    }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Volume")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                    Slider(value: $coordinator.settings.whiteNoiseVolume, in: 0...1)
                        .tint(Theme.textPrimary)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}

/// Placeholder until Phase 5 delivers the full Settings screen + parent gate.
struct SettingsPlaceholderSheet: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textMuted)
            Text("Settings coming in the next phase")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Alarm, offsets, kid lock, and the parent gate arrive in Phase 5.")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}
