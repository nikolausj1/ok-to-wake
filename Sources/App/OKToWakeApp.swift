import SwiftUI

/// Dev-only orientation override: `-demoLandscape` locks the app to landscape
/// so simctl (which can't rotate the simulator) can screenshot the primary
/// design orientation. Release builds always return `.all`.
final class OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoLandscape") { return .landscape }
        #endif
        return .all
    }
}

@main
struct OKToWakeApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientationDelegate
    @StateObject private var audio: AudioController
    @StateObject private var display: DisplayController
    @StateObject private var coordinator: SessionCoordinator

    init() {
        let audio = AudioController()
        let display = DisplayController()
        _audio = StateObject(wrappedValue: audio)
        _display = StateObject(wrappedValue: display)
        _coordinator = StateObject(wrappedValue: SessionCoordinator(audio: audio, display: display))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .environmentObject(audio)
                .environmentObject(display)
        }
    }
}
