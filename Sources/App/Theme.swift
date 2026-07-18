import SwiftUI

/// PRD Section 7 palette. Dark-only; status is big flat color fields with
/// black graphics on saturated fills.
enum Theme {
    /// Canvas #000000
    static let canvas = Color.black
    /// Panel surface #212528
    static let panel = Color(red: 0x21 / 255, green: 0x25 / 255, blue: 0x28 / 255)
    /// Primary text #ffffff
    static let textPrimary = Color.white
    /// Muted text #8a8f96
    static let textMuted = Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x96 / 255)
    /// Wake state green #2de368 (black text/graphics on top)
    static let wakeGreen = Color(red: 0x2D / 255, green: 0xE3 / 255, blue: 0x68 / 255)
    /// Sleep cue red #8a1c1c - placeholder pending Justin's on-device design pass
    static let sleepRed = Color(red: 0x8A / 255, green: 0x1C / 255, blue: 0x1C / 255)
}
