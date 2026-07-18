import SwiftUI

/// Screen B - Night sleep state (PRD Section 6B / 7). Near-black background,
/// large dim centered clock (12-hour, no seconds, no AM/PM, monospaced digits,
/// proportional to the viewport), deep-red moon cue, OLED pixel drift.
/// Tap (kid lock off) reveals low-opacity controls for ~5 s. Battery-saver
/// mode blacks everything out; tap peeks the clock + cue for ~10 s.
struct SleepView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var audio: AudioController

    @State private var controlsVisible = false
    @State private var peekVisible = false
    @State private var driftOffset: CGSize = .zero
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var hidePeekTask: Task<Void, Never>?
    @State private var showSettingsPlaceholder = false

    /// OLED pixel drift: a few points on a slow (~60 s) cycle, imperceptible
    /// in the moment (PRD Section 7).
    private let driftTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"   // 12-hour, no seconds, no AM/PM
        return formatter
    }()

    /// Battery-saver dark mode: fully black unless the kid tapped for a peek.
    private var blackout: Bool { coordinator.batterySaverActive && !peekVisible }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Dim clock + red cue (hidden entirely in battery-saver blackout)
                VStack(spacing: geo.size.height * 0.05) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clockFormatter.string(from: context.date))
                            .font(.system(size: clockSize(geo), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                    Image(systemName: "moon.fill")
                        .font(.system(size: clockSize(geo) * 0.2))
                        .foregroundStyle(Theme.sleepRed)
                }
                .offset(driftOffset)
                .opacity(blackout ? 0 : 1)

                // Muted-speaker glyph when audio is unavailable (PRD edge row 6)
                if audio.audioUnavailable && !blackout {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.textMuted.opacity(0.45))
                            Spacer()
                        }
                    }
                    .padding(28)
                }

                if controlsVisible && !blackout { revealedControls }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: handleTap)
            .animation(.easeInOut(duration: 0.8), value: blackout)
            .animation(.easeInOut(duration: 0.4), value: controlsVisible)
            .onReceive(driftTimer) { _ in
                withAnimation(.easeInOut(duration: 20)) {
                    driftOffset = CGSize(width: CGFloat.random(in: -4...4),
                                         height: CGFloat.random(in: -4...4))
                }
            }
            .onDisappear {
                hideControlsTask?.cancel()
                hidePeekTask?.cancel()
            }
        }
        .sheet(isPresented: $showSettingsPlaceholder) {
            SettingsPlaceholderSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    /// Big clock proportional to the viewport (landscape primary, portrait
    /// functional) - roughly 12-20% of width per digit across devices.
    private func clockSize(_ geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.24, geo.size.height * 0.48)
    }

    // MARK: - Tap routing (the Phase 5 gate drops in here)

    private func handleTap() {
        if coordinator.batterySaverActive {
            showPeek()   // works with kid lock on too (PRD B)
            return
        }
        if coordinator.settings.kidLockEnabled {
            // Kid lock ON: a plain tap reveals nothing. Phase 5's parent gate
            // (press-and-hold ~3 s bottom-right + challenge) will call
            // revealControls() once the gate passes.
            return
        }
        revealControls()
    }

    private func revealControls() {
        hideControlsTask?.cancel()
        controlsVisible = true
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func showPeek() {
        hidePeekTask?.cancel()
        peekVisible = true
        hidePeekTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            peekVisible = false
        }
    }

    // MARK: - Revealed parent controls (~5 s, low opacity)

    private var revealedControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.1.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textMuted)
                    Slider(value: $coordinator.settings.whiteNoiseVolume, in: 0...1)
                        .tint(Theme.textMuted)
                        .frame(width: 190)
                }
                Button {
                    coordinator.endSession()
                } label: {
                    Text("End Session")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .background(Theme.panel)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    showSettingsPlaceholder = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            .opacity(0.55)
            .padding(.bottom, 44)
        }
        .transition(.opacity)
    }
}
