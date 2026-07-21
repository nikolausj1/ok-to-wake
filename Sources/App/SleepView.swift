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

    // Quick-gesture state (Phase 9 item 4). Axis is locked once per drag from
    // the dominant direction at the start; the baselines are captured then so
    // the whole drag is measured from where it began.
    private enum DragAxis { case horizontal, vertical }
    @State private var dragAxis: DragAxis?
    @State private var dragStartVolume: Double = 0
    @State private var dragStartBrightness: Double = 0
    @State private var indicator: GestureIndicator?
    @State private var hideIndicatorTask: Task<Void, Never>?

    /// A minimal, dim, ephemeral readout shown only while a quick-gesture is in
    /// flight (no menu, no brightening). `fraction` is 0...1 for the bar.
    private struct GestureIndicator: Equatable {
        enum Kind { case volume, brightness }
        var kind: Kind
        var fraction: Double
    }

    private let log = Logger(subsystem: "com.levelup.oktowake", category: "gate")

    // Quick-gesture tuning (Phase 9 item 4). Movement below the tap threshold
    // on release is a tap (opens the panel); the axis-start threshold is how
    // far the finger travels before an axis is committed. Both are small so a
    // gentle nudge registers, per the sensitivity requirement.
    private static let tapThreshold: CGFloat = 12
    private static let axisStartThreshold: CGFloat = 8

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
                            // Dim clock color follows the persisted clockColor
                            // toggle (Phase 9 item 2). The dim values already
                            // bake in the night dimness - no extra opacity.
                            .foregroundStyle(Theme.dimClock(coordinator.settings.clockColor))
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

                // Minimal ephemeral quick-gesture indicator (Phase 9 item 4):
                // a small dim bar, dark-respecting, no menu. Hidden in blackout
                // (gestures are disabled there) and while the panel is up.
                if let indicator, !blackout, !panelVisible {
                    gestureIndicatorView(indicator, geo: geo)
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
            // Taps (open the panel / dismiss / kid-lock peek) stay on their own
            // tap gesture - this is the proven behavior that coexists with the
            // panel's buttons and sliders (they take priority in their region).
            .onTapGesture(perform: handleTap)
            // Quick nudges are a SEPARATE drag gesture gated by a minimum
            // distance (Phase 9 item 4): movements below `tapThreshold` never
            // start it, so a tap is unambiguously a tap; only a real drag
            // adjusts volume/brightness. It never opens or dismisses the panel.
            .gesture(
                DragGesture(minimumDistance: Self.tapThreshold)
                    .onChanged { handleDragChanged($0.translation, viewSize: geo.size) }
                    .onEnded { _ in handleDragEnded() }
            )
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
        // Brightness-slider drags keep the panel up too (item 2 live preview).
        .onChange(of: coordinator.settings.nightBrightness) { _, _ in
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

    // MARK: - Quick gestures (Phase 9 item 4)

    /// Quick gestures run ONLY in normal dim sleep with nothing else up: kid
    /// lock off, no panel/gate, not in battery-saver blackout (the black screen
    /// has nothing to nudge, and a tap there opens the panel instead).
    private var quickGesturesEnabled: Bool {
        !panelVisible && !gateVisible
            && !coordinator.settings.kidLockEnabled
            && !coordinator.batterySaverActive
    }

    /// Live drag. Axis is locked from the dominant direction once travel passes
    /// `axisStartThreshold`, and the volume/brightness baselines are captured at
    /// that instant so the whole drag measures from where it started. Sensitivity
    /// (item 4): a full view-height drag spans the whole volume range, a full
    /// view-width drag the whole brightness range - measured off the real view
    /// size (GeometryReader), so landscape and portrait both feel right.
    private func handleDragChanged(_ translation: CGSize, viewSize: CGSize) {
        guard quickGesturesEnabled else { return }
        if dragAxis == nil {
            guard abs(translation.width) > Self.axisStartThreshold
                    || abs(translation.height) > Self.axisStartThreshold else { return }
            dragAxis = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
            dragStartVolume = coordinator.settings.whiteNoiseVolume
            dragStartBrightness = coordinator.settings.nightBrightness
            hideIndicatorTask?.cancel()
        }
        switch dragAxis {
        case .vertical:
            // Up (negative height) = louder.
            let delta = Double(-translation.height / max(viewSize.height, 1))
            let volume = min(max(dragStartVolume + delta, 0), 1)
            applyVolume(volume)
            indicator = GestureIndicator(kind: .volume, fraction: volume)
        case .horizontal:
            // Right (positive width) = brighter.
            let range = AppSettings.nightBrightnessRange
            let span = range.upperBound - range.lowerBound
            let delta = Double(translation.width / max(viewSize.width, 1)) * span
            let brightness = min(max(dragStartBrightness + delta, range.lowerBound), range.upperBound)
            applyNightBrightness(brightness)
            indicator = GestureIndicator(kind: .brightness,
                                         fraction: (brightness - range.lowerBound) / span)
        case .none:
            break
        }
    }

    private func handleDragEnded() {
        // Taps are handled by the separate tap gesture; this only ends a real
        // drag (or a suppressed one, where dragAxis stayed nil - a harmless
        // no-op). Never opens or dismisses the panel.
        dragAxis = nil
        scheduleHideIndicator()
    }

    /// Live volume from a nudge or the panel slider: drive the player and
    /// persist (the coordinator's `settings` didSet does both).
    private func applyVolume(_ volume: Double) {
        coordinator.settings.whiteNoiseVolume = min(max(volume, 0), 1)
    }

    /// Live brightness from a nudge or the panel slider: set the screen NOW for
    /// a true preview, and persist as `nightBrightness` so the dim state uses it
    /// when the panel/gesture settles back.
    private func applyNightBrightness(_ brightness: Double) {
        let clamped = AppSettings.clampNightBrightness(brightness)
        coordinator.settings.nightBrightness = clamped   // persists + syncs display
        display.previewNightBrightness(clamped)          // live UIScreen preview
    }

    private func scheduleHideIndicator() {
        hideIndicatorTask?.cancel()
        hideIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { indicator = nil }
        }
    }

    /// The minimal dim indicator: a short bar plus a small glyph, bottom-center,
    /// dark enough not to light the room. No text menu (item 4).
    private func gestureIndicatorView(_ indicator: GestureIndicator, geo: GeometryProxy) -> some View {
        let barWidth = min(geo.size.width * 0.34, 260)
        let glyph = indicator.kind == .volume ? "speaker.wave.2.fill" : "sun.max.fill"
        return VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textMuted.opacity(0.7))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: barWidth, height: 6)
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: max(6, barWidth * indicator.fraction), height: 6)
                }
            }
            .padding(.bottom, geo.size.height * 0.16)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
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

    /// Panel-clock formatter for the "Green at 7:00 AM" rows: 12-hour with AM/PM
    /// and no seconds (real clock times, not offsets - Phase 9 item 2).
    private func timeRows() -> [(icon: String, label: String)] {
        guard let session = coordinator.activeSession else { return [] }
        var rows: [(String, String)] = [
            ("sunrise.fill", "Green at \(Engine.wakeWallClock(for: session).display12h)")
        ]
        if let noise = Engine.noiseStopWallClock(for: session) {
            rows.append(("speaker.slash.fill", "Noise stops \(noise.display12h)"))
        }
        if let alarm = Engine.alarmStartWallClock(for: session) {
            rows.append(("alarm.fill", "Alarm \(alarm.display12h)"))
        }
        return rows
    }

    private var clockColorLabel: String {
        switch coordinator.settings.clockColor {
        case .white: return "White"
        case .orange: return "Orange"
        case .red: return "Red"
        }
    }

    /// Cycle the dim clock color White -> Orange -> Red (Phase 9 item 2),
    /// persisting it, and keep the panel up (this is an interaction).
    private func cycleClockColor() {
        let next = coordinator.settings.clockColor.next
        coordinator.settings.clockColor = next
        log.notice("night panel: clock color -> \(next.rawValue, privacy: .public)")
        if panelVisible { scheduleHidePanel(after: Self.panelRevealSeconds) }
    }

    private var controlsPanel: some View {
        VStack {
            Spacer()
            VStack(spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clockFormatter.string(from: context.date))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }

                // Real clock times for the scheduled events (item 2).
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(timeRows(), id: \.label) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 20)
                            Text(row.label)
                                .font(.system(.subheadline, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)

                // Volume: the single in-app knob (item 3).
                VStack(spacing: 4) {
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
                    Text("Phone buttons still work too.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                }

                // Brightness with LIVE preview (item 2): dragging sets the
                // screen in real time; the value persists as nightBrightness.
                HStack(spacing: 12) {
                    Image(systemName: "sun.min.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                    Slider(value: Binding(get: { coordinator.settings.nightBrightness },
                                          set: { applyNightBrightness($0) }),
                           in: AppSettings.nightBrightnessRange)
                        .tint(Theme.textPrimary)
                        .frame(minWidth: 180, maxWidth: 320)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }

                // Clock color toggle: White / Orange / Red (item 2).
                Button(action: cycleClockColor) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textMuted)
                        Text("Clock color")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 12)
                        Text(clockColorLabel)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Theme.dimClock(coordinator.settings.clockColor))
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: 320)
                    .frame(height: 40)
                    .padding(.horizontal, 14)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

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
            // screen-level handler, which dismisses immediately.
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
    ///
    /// Phase 9 hooks (simctl can't multi-touch drag) - all invoke the SAME
    /// gesture/handler code the real UI uses:
    /// `-demoPanel`           open the panel and hold it for a screenshot
    /// `-demoNudgeVolume`     simulate an up vertical-drag; logs before/after
    ///                        volume and that the panel did NOT open (also the
    ///                        kid-lock-suppressed case when -demoKidLock is set)
    /// `-demoNudgeBrightness` simulate a right horizontal-drag; logs before/after
    ///                        nightBrightness + UIScreen.brightness + no panel
    /// `-demoClockColor <c>`  set the dim clock color (white|orange|red)
    private func applyDemoHooks() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
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
        if let color = value(after: "-demoClockColor"), let c = ClockColor(rawValue: color) {
            coordinator.settings.clockColor = c
            log.notice("DEMO: -demoClockColor \(c.rawValue, privacy: .public)")
        }
        if args.contains("-demoPanel") {
            runDemoPanel()
        }
        if args.contains("-demoNudgeVolume") {
            runDemoNudgeVolume()
        }
        if args.contains("-demoNudgeBrightness") {
            runDemoNudgeBrightness()
        }
        #endif
    }

    #if DEBUG
    /// A representative iPad-landscape view size for the scripted drags (the
    /// live gestures use the real GeometryReader size; the demos only need a
    /// plausible extent to exercise the same math).
    private func demoViewSize() -> CGSize { CGSize(width: 1366, height: 1024) }

    /// `-demoPanel`: open the panel and keep it up long enough to screenshot.
    private func runDemoPanel() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            log.notice("DEMO: open night panel for screenshot")
            showPanel(for: 3600)   // effectively no auto-fade during the shot
        }
    }

    /// `-demoNudgeVolume`: run the SAME drag handlers as a finger would, with an
    /// up (louder) vertical translation. Proves volume changes WITHOUT opening
    /// the panel (and, with -demoKidLock, that the gesture is suppressed).
    private func runDemoNudgeVolume() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let size = demoViewSize()
            let before = coordinator.settings.whiteNoiseVolume
            log.notice("DEMO nudgeVolume: before=\(before, format: .fixed(precision: 2)) kidLock=\(coordinator.settings.kidLockEnabled) panelVisible=\(panelVisible)")
            // Vertical, upward = +40% of range; two changes then release.
            let t = CGSize(width: 2, height: -size.height * 0.4)
            handleDragChanged(t, viewSize: size)
            handleDragChanged(t, viewSize: size)
            handleDragEnded()
            log.notice("DEMO nudgeVolume: after=\(coordinator.settings.whiteNoiseVolume, format: .fixed(precision: 2)) panelVisible=\(panelVisible) (expect louder + panel false; unchanged if kid lock)")
        }
    }

    /// `-demoNudgeBrightness`: same handlers with a right (brighter) horizontal
    /// translation. Proves nightBrightness + the live screen change, no panel.
    private func runDemoNudgeBrightness() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let size = demoViewSize()
            let before = coordinator.settings.nightBrightness
            let screenBefore = Double(UIScreen.main.brightness)
            log.notice("DEMO nudgeBrightness: before nightBrightness=\(before, format: .fixed(precision: 2)) screen=\(screenBefore, format: .fixed(precision: 2)) panelVisible=\(panelVisible)")
            let t = CGSize(width: size.width * 0.4, height: 2)
            handleDragChanged(t, viewSize: size)
            handleDragChanged(t, viewSize: size)
            handleDragEnded()
            log.notice("DEMO nudgeBrightness: after nightBrightness=\(coordinator.settings.nightBrightness, format: .fixed(precision: 2)) screen=\(Double(UIScreen.main.brightness), format: .fixed(precision: 2)) panelVisible=\(panelVisible) (expect brighter + panel false)")
        }
    }
    #endif

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
