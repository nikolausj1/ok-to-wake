import SwiftUI
import os

/// Screen B - Night sleep state (PRD Section 6B / 7). Near-black background,
/// large dim centered clock (12-hour, no seconds, no AM/PM, monospaced digits,
/// proportional to the viewport), deep-red moon cue, OLED pixel drift.
///
/// Night controls (Phase 8 spec, supersedes the PRD's low-opacity reveal):
/// - Kid lock OFF, in BOTH normal dim and battery-saver blackout: a single
///   tap temporarily ramps screen brightness back up (stored priorBrightness,
///   min 0.4) and shows a clearly visible controls panel - current time,
///   white-noise volume slider, End Session button, Settings gear. It fades
///   back to the previous night state after ~10 s without interaction (any
///   interaction resets the timer); a tap outside the panel dismisses
///   immediately.
/// - Kid lock ON: a plain tap shows nothing (blackout: ~10 s clock peek
///   only); press-and-hold ~3 s bottom-right raises the parent gate (E), and
///   passing it shows the same bright panel for ~15 s.
/// All dim->bright->dim transitions use the standard 800 ms ease.
struct SleepView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var audio: AudioController
    @EnvironmentObject private var display: DisplayController

    @State private var panelVisible = false
    @State private var peekVisible = false
    @State private var driftOffset: CGSize = .zero
    @State private var hidePanelTask: Task<Void, Never>?
    @State private var hidePeekTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var gateVisible = false

    private let log = Logger(subsystem: "com.levelup.oktowake", category: "gate")

    /// How long the panel stays up: a plain tap vs a passed parent gate
    /// (PRD E: ~15 s).
    private static let panelRevealSeconds: Double = 10
    private static let gatedRevealSeconds: Double = 15

    /// OLED pixel drift: a few points on a slow (~60 s) cycle, imperceptible
    /// in the moment (PRD Section 7).
    private let driftTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"   // 12-hour, no seconds, no AM/PM
        return formatter
    }()

    /// Battery-saver dark mode: fully black unless the kid tapped for a peek
    /// or the controls panel is up (the panel must never be invisible while
    /// it is active, or an unplugged session could not be ended from the UI).
    private var blackout: Bool {
        coordinator.batterySaverActive && !peekVisible && !panelVisible
    }

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

                if panelVisible { controlsPanel }

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
            .animation(.easeInOut(duration: 0.8), value: panelVisible)
            .animation(.easeInOut(duration: 0.3), value: gateVisible)
            .onReceive(driftTimer) { _ in
                withAnimation(.easeInOut(duration: 20)) {
                    driftOffset = CGSize(width: CGFloat.random(in: -4...4),
                                         height: CGFloat.random(in: -4...4))
                }
            }
            .onAppear(perform: applyDemoHooks)
            .onDisappear {
                hidePanelTask?.cancel()
                hidePeekTask?.cancel()
                // Leaving the sleep state (wake fired / session ended): the
                // next state owns the screen brightness - just drop the panel
                // flag, never touch brightness from here.
                coordinator.nightPanelVisible = false
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
        }
        // Settings opened from the panel: pause the auto-hide while it is up
        // (fading to night brightness mid-Settings would strand the parent),
        // restart the window when it closes.
        .onChange(of: showSettings) { _, open in
            guard panelVisible else { return }
            if open {
                hidePanelTask?.cancel()
            } else {
                scheduleHidePanel(after: Self.panelRevealSeconds)
            }
        }
        // Any panel interaction resets the fade timer (volume drags included).
        .onChange(of: coordinator.settings.whiteNoiseVolume) { _, _ in
            if panelVisible { scheduleHidePanel(after: Self.panelRevealSeconds) }
        }
    }

    /// Big clock proportional to the viewport (landscape primary, portrait
    /// functional) - roughly 12-20% of width per digit across devices.
    private func clockSize(_ geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.24, geo.size.height * 0.48)
    }

    // MARK: - Tap / hold routing

    private func handleTap() {
        if panelVisible {
            // Tap outside the panel (the panel absorbs its own taps).
            log.notice("night panel dismissed (outside tap)")
            hidePanel()
            return
        }
        if coordinator.settings.kidLockEnabled {
            // Kid lock ON: a plain tap reveals nothing; in blackout it peeks
            // the clock. The parent gate (corner hold + challenge) is the
            // only way to the panel.
            if coordinator.batterySaverActive { showPeek() }
            return
        }
        // Kid lock OFF: tap -> bright panel, from normal dim AND blackout.
        showPanel(for: Self.panelRevealSeconds)
    }

    /// The ~3 s bottom-right hold completed. Kid lock on -> parent gate;
    /// kid lock off -> same panel a plain tap gives (the hold is only the
    /// gate's trigger, never a lock of its own).
    private func handleCornerHold() {
        if coordinator.settings.kidLockEnabled {
            log.notice("corner hold (~3 s) -> parent gate presented")
            gateVisible = true
        } else {
            showPanel(for: Self.panelRevealSeconds)
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
        log.notice("parent gate passed -> night panel for \(Int(Self.gatedRevealSeconds))s")
        gateVisible = false
        showPanel(for: Self.gatedRevealSeconds)
    }

    private func gateDismissed(reason: String) {
        log.notice("parent gate dismissed (\(reason, privacy: .public)) -> back to night screen")
        gateVisible = false
    }

    // MARK: - Night controls panel (bright, clearly visible)

    private func showPanel(for seconds: Double) {
        let target = max(coordinator.activeSession?.priorBrightness ?? 0, 0.4)
        log.notice("night panel shown (brightness -> \(target, format: .fixed(precision: 2)), auto-hide \(Int(seconds))s)")
        panelVisible = true
        coordinator.nightPanelVisible = true   // RootView lifts the DimOverlay
        display.boostForControls(to: target)
        scheduleHidePanel(after: seconds)
    }

    private func scheduleHidePanel(after seconds: Double) {
        hidePanelTask?.cancel()
        hidePanelTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            log.notice("night panel auto-hidden after \(Int(seconds))s idle -> back to night")
            hidePanel()
        }
    }

    /// Back to the previous night state: dim clock, or blackout when the
    /// session runs unplugged (`blackout` recomputes automatically).
    private func hidePanel() {
        hidePanelTask?.cancel()
        panelVisible = false
        coordinator.nightPanelVisible = false
        display.returnToNight()
    }

    private func endSessionFromPanel() {
        if coordinator.settings.kidLockEnabled {
            log.notice("end session inside gated reveal window")
        } else {
            log.notice("End Session tapped on night panel")
        }
        coordinator.endSession()
    }

    private var controlsPanel: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clockFormatter.string(from: context.date))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                    Slider(value: $coordinator.settings.whiteNoiseVolume, in: 0...1)
                        .tint(Theme.textPrimary)
                        .frame(minWidth: 180, maxWidth: 320)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }
                HStack(spacing: 16) {
                    Button(action: endSessionFromPanel) {
                        Text("End Session")
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 28)
                            .frame(height: 54)
                            .background(Theme.textPrimary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 21))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 54, height: 54)
                            .background(Theme.panel)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .background(Theme.panel)   // sharp-cornered panel (Section 7)
            // The panel itself absorbs taps and treats them as interaction
            // (resets the fade timer); taps outside it fall through to the
            // screen-level handleTap, which dismisses immediately.
            .contentShape(Rectangle())
            .onTapGesture { scheduleHidePanel(after: Self.panelRevealSeconds) }
            .padding(.bottom, 44)
        }
        .transition(.opacity)
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

    // MARK: - Dev-only demo hooks (Build Guide: simctl can't tap)

    /// `-demoGate`      show the parent gate overlay immediately (screenshot)
    /// `-demoGateFlow`  scripted gated end-session attempt, verified via logs
    /// `-demoPeekFlow`  scripted battery-saver peek (kid lock forced on by
    ///                  the coordinator hook - peeks are kid-lock-only now)
    /// `-demoPanelFlow` scripted night-panel walk: tap -> bright panel, 10 s
    ///                  auto-fade, tap -> outside-tap dismiss, End Session
    private func applyDemoHooks() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoGate") {
            gateVisible = true
        }
        if args.contains("-demoGateFlow") {
            runDemoGateFlow()
        }
        if args.contains("-demoPeekFlow") {
            runDemoPeekFlow()
        }
        if args.contains("-demoPanelFlow") {
            runDemoPanelFlow()
        }
        #endif
    }

    #if DEBUG
    /// `-demoPanelFlow` (optionally with -demoUnplugged): tap at t+2 (panel
    /// + brightness ramp), auto-fade check at t+15, tap + outside-tap
    /// dismiss, then End Session from the panel. Screenshots timed externally.
    private func runDemoPanelFlow() {
        log.notice("DEMO panel flow start (batterySaver=\(coordinator.batterySaverActive), kidLock=\(coordinator.settings.kidLockEnabled))")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: tap (expect bright panel)")
            handleTap()
            try? await Task.sleep(for: .seconds(13))
            log.notice("DEMO: t+15 panelVisible=\(panelVisible) (expect false: 10s auto-fade)")
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: tap again (panel)")
            handleTap()
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: outside tap (expect immediate dismiss)")
            handleTap()
            log.notice("DEMO: after outside tap panelVisible=\(panelVisible) (expect false)")
            try? await Task.sleep(for: .seconds(2))
            log.notice("DEMO: tap (panel) then End Session from panel")
            handleTap()
            try? await Task.sleep(for: .seconds(2))
            endSessionFromPanel()
        }
    }

    /// `-demoPeekFlow` (with -demoUnplugged -demoState sleep): scripted
    /// battery-saver peek - tap at t+3 s (clock peeks ~10 s), confirm the
    /// peek expired at t+15 s. Screenshots are timed externally.
    private func runDemoPeekFlow() {
        log.notice("DEMO peek flow: battery-saver black screen (batterySaver=\(coordinator.batterySaverActive))")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            log.notice("DEMO: tap on black screen (expect ~10 s clock peek)")
            handleTap()
            log.notice("DEMO: peekVisible=\(peekVisible) after tap")
            try? await Task.sleep(for: .seconds(12))
            log.notice("DEMO: peek window over, peekVisible=\(peekVisible) (expect false, back to black)")
        }
    }

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
