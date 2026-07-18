import SwiftUI
import os

/// Screen B - Night sleep state (PRD Section 6B / 7). Near-black background,
/// large dim centered clock (12-hour, no seconds, no AM/PM, monospaced digits,
/// proportional to the viewport), deep-red moon cue, OLED pixel drift.
/// Tap (kid lock off) reveals low-opacity controls for ~5 s. Kid lock on:
/// plain taps do nothing; press-and-hold ~3 s on the bottom-right corner
/// region raises the parent gate (E), and passing it reveals the controls
/// for ~15 s. Battery-saver mode blacks everything out; tap peeks the
/// clock + cue for ~10 s.
struct SleepView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var audio: AudioController

    @State private var controlsVisible = false
    @State private var peekVisible = false
    @State private var driftOffset: CGSize = .zero
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var hidePeekTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var gateVisible = false

    private let log = Logger(subsystem: "com.levelup.oktowake", category: "gate")

    /// How long the controls stay revealed: a plain tap (kid lock off) vs a
    /// passed parent gate (PRD E: ~15 s).
    private static let plainRevealSeconds: Double = 5
    private static let gatedRevealSeconds: Double = 15

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
                VStack(spacing: geo.size.height * 0.04) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clockFormatter.string(from: context.date))
                            .font(.system(size: clockSize(geo), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary.opacity(0.55))
                    }
                    // The "still sleeping" cue is the primary signal for a
                    // pre-reader across a dark room: a BIG moon, ~30% of the
                    // clock's height, in dim desaturated red (#8a1c1c, no
                    // glow) so it reads as "red = stay in bed" without
                    // lighting the room (PRD Section 7 + lead design pass).
                    Image(systemName: "moon.fill")
                        .font(.system(size: clockSize(geo) * 0.32))
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

                // Invisible bottom-right corner region: press-and-hold ~3 s is
                // the parent-gate trigger (PRD E). A plain tap here behaves
                // like a tap anywhere else.
                cornerHoldHotspot

                if gateVisible {
                    ParentGateView(onSuccess: gateSucceeded,
                                   onDismiss: gateDismissed(reason:))
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: handleTap)
            .animation(.easeInOut(duration: 0.8), value: blackout)
            .animation(.easeInOut(duration: 0.4), value: controlsVisible)
            .animation(.easeInOut(duration: 0.3), value: gateVisible)
            .onReceive(driftTimer) { _ in
                withAnimation(.easeInOut(duration: 20)) {
                    driftOffset = CGSize(width: CGFloat.random(in: -4...4),
                                         height: CGFloat.random(in: -4...4))
                }
            }
            .onAppear(perform: applyDemoHooks)
            .onDisappear {
                hideControlsTask?.cancel()
                hidePeekTask?.cancel()
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// Big clock proportional to the viewport (landscape primary, portrait
    /// functional) - roughly 12-20% of width per digit across devices.
    private func clockSize(_ geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.24, geo.size.height * 0.48)
    }

    // MARK: - Tap / hold routing (PRD B tap behavior + E trigger)

    private func handleTap() {
        if coordinator.batterySaverActive {
            showPeek()   // works with kid lock on too (PRD B)
            return
        }
        if coordinator.settings.kidLockEnabled {
            // Kid lock ON: a plain tap reveals nothing. The parent gate
            // (corner hold + challenge) is the only way in.
            return
        }
        revealControls(for: Self.plainRevealSeconds)
    }

    /// The ~3 s bottom-right hold completed. Kid lock on -> parent gate;
    /// kid lock off -> same reveal a plain tap gives (the hold is only the
    /// gate's trigger, never a lock of its own).
    private func handleCornerHold() {
        if coordinator.settings.kidLockEnabled {
            log.notice("corner hold (~3 s) -> parent gate presented")
            gateVisible = true
        } else {
            revealControls(for: Self.plainRevealSeconds)
        }
    }

    private var cornerHoldHotspot: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Color.clear
                    .frame(width: 150, height: 150)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleTap)
                    .onLongPressGesture(minimumDuration: 3, perform: handleCornerHold)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Parent gate outcomes (PRD E)

    private func gateSucceeded() {
        log.notice("parent gate passed -> controls revealed for \(Int(Self.gatedRevealSeconds))s")
        gateVisible = false
        revealControls(for: Self.gatedRevealSeconds)
    }

    private func gateDismissed(reason: String) {
        log.notice("parent gate dismissed (\(reason, privacy: .public)) -> back to night screen")
        gateVisible = false
    }

    private func revealControls(for seconds: Double) {
        hideControlsTask?.cancel()
        controlsVisible = true
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
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

    // MARK: - Revealed parent controls (low opacity, auto-hide)

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
                    // With kid lock on this button is only reachable inside a
                    // passed gate's reveal window - the gated early end
                    // (PRD E: ending a session early is what the gate protects).
                    if coordinator.settings.kidLockEnabled {
                        log.notice("end session inside gated reveal window")
                    }
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
                    showSettings = true
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

    // MARK: - Dev-only demo hooks (Build Guide: simctl can't tap)

    /// `-demoGate`     show the parent gate overlay immediately (screenshot)
    /// `-demoGateFlow` scripted gated end-session attempt, verified via logs:
    ///                 plain tap (no-op) -> hold -> wrong answer bounces ->
    ///                 hold -> correct answer -> End Session inside the window
    private func applyDemoHooks() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoGate") {
            gateVisible = true
        }
        if args.contains("-demoGateFlow") {
            runDemoGateFlow()
        }
        #endif
    }

    #if DEBUG
    private func runDemoGateFlow() {
        log.notice("DEMO gate flow: kid lock on, attempting a gated end-session")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: plain tap with kid lock on (expect: nothing revealed)")
            handleTap()
            try? await Task.sleep(for: .seconds(1))
            log.notice("DEMO: bottom-right 3 s hold completed")
            handleCornerHold()
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: wrong answer tapped")
            gateDismissed(reason: "wrong answer")
            try? await Task.sleep(for: .seconds(1))
            log.notice("DEMO: bottom-right 3 s hold completed again")
            handleCornerHold()
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: correct answer tapped")
            gateSucceeded()
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: End Session tapped inside the gated reveal window")
            coordinator.endSession()
        }
    }
    #endif
}
