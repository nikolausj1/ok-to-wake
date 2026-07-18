import SwiftUI

/// Switches between the three screens on the engine's display state with
/// ~800 ms ease cross-fades, and layers the DimOverlay (a black opacity layer
/// on top of content - the second half of the two-layer dimming model,
/// alongside UIScreen.brightness in DisplayController; PRD Section 7).
struct RootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            Group {
                switch coordinator.displayState {
                case .idle: HomeView()
                case .sleep: SleepView()
                case .wake: WakeView()
                }
            }
            .transition(.opacity)

            // DimOverlay: on with the sleep state, off for Home and wake.
            Color.black
                .opacity(coordinator.displayState == .sleep ? 0.45 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.8), value: coordinator.displayState)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            coordinator.boot()
            applyDemoOrientation()
        }
    }

    /// Dev-only: `-demoLandscape` / `-demoPortrait` force the scene
    /// orientation so simctl screenshots capture both orientations without a
    /// rotation gesture (the sim scene otherwise keeps its last orientation).
    private func applyDemoOrientation() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let target: UIInterfaceOrientationMask
        if args.contains("-demoLandscape") {
            target = .landscapeRight
        } else if args.contains("-demoPortrait") {
            target = .portrait
        } else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        }
        #endif
    }
}
