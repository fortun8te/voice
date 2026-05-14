// VOICE — Typography Theme
// ============================================================
// Custom type system using bundled fonts:
//   • Test Tiempos Headline (serif) — for headlines
//   • ABC Diatype Plus Variable (sans + mono) — for body & mono
//
// PostScript names verified via fc-query:
//   Family for serif: "Test Tiempos Headline"
//   Family for sans:  "ABC Diatype Plus Variable Unlicensed Trial"
//   Mono PS name:     "ABCDiatypePlusVariable-MonoRegular"
//
// Tighter tracking is applied across the board because the user
// asked for shorter letter spacing.
// ============================================================

import SwiftUI

extension Font {
    /// Serif — Test Tiempos Headline (for headlines).
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Test Tiempos Headline", size: size).weight(weight)
    }

    /// Sans (body) — ABC Diatype Plus Variable.
    /// The variable font handles weight via the Weight axis.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("ABC Diatype Plus Variable Unlicensed Trial", size: size).weight(weight)
    }

    /// Mono — Mono variant of Diatype Plus, accessed via PostScript name.
    /// If this falls back, switch to Semi-Mono or the regular family with
    /// `.monospaced()` modifier — but on macOS variable-font subfamilies
    /// addressed by PS name typically resolve correctly.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("ABCDiatypePlusVariable-MonoRegular", size: size).weight(weight)
    }
}

/// Tighter tracking — the user asked for shorter letter spacing.
/// Apply via `.tracking(...)` on Text views.
enum LetterSpacing {
    static let body: CGFloat = -0.2
    static let headline: CGFloat = -0.6
    static let mono: CGFloat = 0
}

/// Preset modifiers — apply consistent type styles across the app.
extension Text {
    func appH1() -> some View {
        self.font(.serif(28, weight: .semibold))
            .tracking(LetterSpacing.headline)
    }
    func appH2() -> some View {
        self.font(.serif(22, weight: .medium))
            .tracking(LetterSpacing.headline)
    }
    func appH3() -> some View {
        self.font(.sans(15, weight: .semibold))
            .tracking(LetterSpacing.body)
    }
    func appBody() -> some View {
        self.font(.sans(13))
            .tracking(LetterSpacing.body)
    }
    func appBodySemibold() -> some View {
        self.font(.sans(13, weight: .semibold))
            .tracking(LetterSpacing.body)
    }
    func appCaption() -> some View {
        self.font(.sans(11, weight: .medium))
            .tracking(LetterSpacing.body)
            .foregroundStyle(.secondary)
    }
    func appMicro() -> some View {
        self.font(.sans(10))
            .tracking(LetterSpacing.body)
            .foregroundStyle(.tertiary)
    }
    func appMono(_ size: CGFloat = 12) -> some View {
        self.font(.mono(size))
            .tracking(LetterSpacing.mono)
    }
}
