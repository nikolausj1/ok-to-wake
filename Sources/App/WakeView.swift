import SwiftUI

/// Screen C - Wake (green) state (PRD Section 6C / 7). Full-bleed #2de368
/// with black graphics: big sun, "Time to get up!", current time. Huge black
/// Done pill ends the session. No timeout; a tap anywhere stops a sounding
/// alarm (green stays).
struct WakeView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.wakeGreen.ignoresSafeArea()
                VStack(spacing: geo.size.height * 0.03) {
                    Spacer(minLength: 0)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: min(geo.size.width, geo.size.height) * 0.2))
                        .foregroundStyle(.black)
                    Text("Time to get up!")
                        .font(.system(size: min(geo.size.width * 0.065, geo.size.height * 0.1),
                                      weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clockFormatter.string(from: context.date))
                            .font(.system(size: min(geo.size.width * 0.09, geo.size.height * 0.14),
                                          weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.black)
                    }
                    Spacer(minLength: 0)
                    Button {
                        coordinator.endSession()
                    } label: {
                        Text("Done")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.wakeGreen)
                            .frame(maxWidth: 560)
                            .frame(height: 82)
                            .background(.black)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 36)
                .padding(.vertical, geo.size.height * 0.07)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap anywhere: stop the alarm sound, keep the green (PRD C).
                coordinator.stopAlarmTapped()
            }
        }
    }
}
