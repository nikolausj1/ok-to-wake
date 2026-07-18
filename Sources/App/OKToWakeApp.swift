import SwiftUI

@main
struct OKToWakeApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// Phase 1 placeholder: black screen, app name, live clock.
/// The real Home / night screens arrive in Phase 3.
struct PlaceholderView: View {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("OK to Wake")
                    .font(.system(.title2, design: .rounded).weight(.light))
                    .foregroundStyle(Color(red: 0.54, green: 0.56, blue: 0.59)) // muted #8a8f96
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.timeFormatter.string(from: context.date))
                        .font(.system(size: 110, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
    }
}
