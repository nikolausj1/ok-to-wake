import SwiftUI

/// Screen E - Parent gate overlay (PRD Section 6E). Presented wherever kid
/// lock protects an action (revealing night controls, opening Settings
/// mid-session, ending a session early). A simple addition challenge with
/// three large answer pills, operands and positions randomized each time.
/// Wrong answer or 10 s of inactivity dismisses back to the night screen;
/// success reveals the protected controls (the caller keeps them up ~15 s).
///
/// Intentionally beatable by a 7-year-old who can add - a speed bump, not a
/// vault (locked decision: do NOT escalate difficulty; Guided Access is the
/// vault, documented in Settings).
struct ParentGateView: View {
    /// Correct pill tapped.
    let onSuccess: () -> Void
    /// Wrong pill or timeout; the reason string feeds the log line.
    let onDismiss: (String) -> Void

    @State private var challenge = Challenge.random()
    @State private var timeoutTask: Task<Void, Never>?

    /// One addition question: small operands, answer + two near-miss
    /// distractors, shuffled so the correct position moves every time.
    struct Challenge {
        let a: Int
        let b: Int
        let options: [Int]
        var answer: Int { a + b }

        static func random() -> Challenge {
            let a = Int.random(in: 2...6)
            let b = Int.random(in: 2...6)
            let answer = a + b
            var options: Set<Int> = [answer]
            while options.count < 3 {
                let distractor = answer + Int.random(in: -3...3)
                if distractor > 0 { options.insert(distractor) }
            }
            return Challenge(a: a, b: b, options: options.shuffled())
        }
    }

    var body: some View {
        ZStack {
            // Absorbs taps so the night screen underneath never reacts while
            // the gate is up. Dim, not bright - it is still night.
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }

            VStack(spacing: 34) {
                VStack(spacing: 10) {
                    Text("Grown-ups only")
                        .font(.system(.footnote, design: .rounded).weight(.light))
                        .foregroundStyle(Theme.textMuted)
                    Text("Tap the answer: \(challenge.a) + \(challenge.b)")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: 20) {
                    ForEach(challenge.options, id: \.self) { option in
                        Button {
                            resolve(option)
                        } label: {
                            Text("\(option)")
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 108, height: 74)
                                .background(Theme.panel)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(40)
        }
        .onAppear(perform: startTimeout)
        .onDisappear { timeoutTask?.cancel() }
    }

    private func resolve(_ option: Int) {
        timeoutTask?.cancel()
        if option == challenge.answer {
            onSuccess()
        } else {
            onDismiss("wrong answer")
        }
    }

    /// 10 s of inactivity dismisses the overlay (PRD E).
    private func startTimeout() {
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            onDismiss("10 s inactivity")
        }
    }
}
