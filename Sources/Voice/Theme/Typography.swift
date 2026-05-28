// VOICE — Typography Theme
// ============================================================
// Two font families with graceful fallback chains:
//
//   SERIF (titles, section headers, big labels)
//     Tiempos Headline → Tiempos Text → NewYork → system .serif
//
//   SANS (body, labels, secondary text)
//     ABC Diatype Variable → ABC Diatype → Inter-Regular → system .default
//
//   MONO (logs, code)
//     JetBrainsMono-Regular → system .monospaced
//
// Each named static const lazily resolves via the helper functions
// (`serif`, `sans`, `monoBase`), so swapping a font is one place.
//
// Fonts are not bundled in this file — that's a project.yml change.
// `NSFont(name:size:)` returning nil is the macOS-correct check for
// "font not installed" and drives the fallback cascade.
// ============================================================

import SwiftUI
import AppKit

// Typography hierarchy (largest -> smallest)
//   serifHero    40  Page hero titles
//   serifTitle   28  Sheet titles ("Settings")  [.regular]
//   serifTitleHeavy 28 Hero titles (heavier serif, .semibold)
//   serifValue   42  Stat card numbers (sits below hero, above section)
//   serifSection 22  Card titles ("Light", "Casual")
//   serifLabel   16  Muted serif captions
//   bodyLarge    15  Settings descriptions
//   bodyBase     13  Body text
//   bodyMedium   13  Emphasized body (.medium)
//   bodyTight    13  Body text, tight line-height (dense lists)
//   bodySmall    12  Secondary captions
//   metadata     11  Row metadata (date, duration, secondary FG)
//   label        11  Uppercase section headers (.semibold)
//   chipLabel    10  Status chips (.medium uppercase, tracking 0.4)
//   badge        10  Chips, pill badges (.semibold)
//   dataValue    13  Monospaced-digit stats values ("$4.5M" / "$820K")
//   mono         12  Logs, code
//
// Rule of thumb: `.tracking(0.8)` is reserved for uppercase `label` only.
// `chipLabel` carries its own tracking(0.4) at the call site.
// Body and serif sizes never get explicit tracking.
//
// Naming notes (rename suggestions — DO NOT rename without a sweeping refactor):
//   `bodyBase`   -> `bodyRegular`  (mirrors `bodyMedium` weight suffix; "Base"
//                                   reads as a size, not a weight)
//   `label`      -> `labelCaps`    (current name collides with SwiftUI .label
//                                   and doesn't signal uppercase usage)
//   `badge`      -> `badgeBold`    (distinguish from new lighter `chipLabel`)
// These would cascade through dozens of view files; leave for a dedicated PR.

extension Font {
    // SERIF family (Tiempos / fallback chain)
    static let serifHero    = serif(40, weight: .regular)   // hero titles
    static let serifTitle   = serif(28, weight: .regular)   // sheet titles
    /// Heavier serif for hero titles where `serifHero` feels too light.
    /// Use over `serifHero` when the title sits on a noisy background or
    /// needs extra presence (landing-style heroes, splash screens).
    static let serifTitleHeavy = serif(28, weight: .semibold) // heavier hero title
    static let serifValue   = serif(42, weight: .medium)    // stat card numbers
    static let serifSection = serif(22, weight: .regular)   // card titles
    static let serifLabel   = serif(16, weight: .regular)   // muted serif captions

    // SANS family (Diatype / fallback)
    static let bodyLarge    = sans(15, weight: .regular)    // settings descriptions
    static let bodyBase     = sans(13, weight: .regular)    // body text everywhere
    static let bodyMedium   = sans(13, weight: .medium)     // emphasized body
    /// Same size/weight as `bodyBase` but intended to be paired with a
    /// tighter `.lineSpacing(-1)` (or `.lineSpacing(0)` with reduced
    /// vertical padding) at the call site. Use in dense lists, table
    /// rows, or stacked metadata where the default body leading creates
    /// too much vertical breathing room. Pair with `Theme.LineSpacing.tight`
    /// or apply `.lineSpacing(0)` directly.
    static let bodyTight    = sans(13, weight: .regular)    // dense-list body
    static let bodySmall    = sans(12, weight: .regular)    // secondary captions
    /// 11pt regular sans for row metadata: dates, durations, file sizes,
    /// timestamps. Always pair with `Theme.Color.secondaryFG` (or the
    /// SwiftUI `.secondary` foreground). Distinct from `label` which is
    /// uppercase + semibold for section headers.
    static let metadata     = sans(11, weight: .regular)    // row metadata
    static let label        = sans(11, weight: .semibold)   // ALL-CAPS section headers
    /// 10pt medium sans for status chips ("ACTIVE", "DRAFT", "ERROR").
    /// Lighter weight than `badge` (.semibold) — use when the chip's
    /// background already carries the emphasis (filled pill) and the
    /// label only needs to be legible, not loud. Apply
    /// `.tracking(0.4)` and `.textCase(.uppercase)` at the call site.
    static let chipLabel    = sans(10, weight: .medium)     // status chip label
    static let badge        = sans(10, weight: .semibold)   // chips, badges
    /// Monospaced-digit variant for displaying numeric values where
    /// vertical alignment across rows matters: stat cards, tables,
    /// currency columns. Digits share a fixed advance so "$4.5M" and
    /// "$820K" line up at the decimal even with proportional letters
    /// around them. Body text size (13pt) by default — bump via the
    /// `dataValue(size:)` helper if a larger stat callout is needed.
    static let dataValue    = dataValueBase(13, weight: .regular)
    static let mono         = monoBase(12)                  // log/code

    // Family helpers (call these for arbitrary sizes)
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Tiempos Headline", size: size) != nil {
            return Font.custom("Tiempos Headline", size: size).weight(weight)
        }
        if NSFont(name: "Tiempos Text", size: size) != nil {
            return Font.custom("Tiempos Text", size: size).weight(weight)
        }
        if NSFont(name: "NewYork", size: size) != nil {
            return Font.custom("NewYork", size: size).weight(weight)
        }
        // System serif (macOS 13+)
        return Font.system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "ABC Diatype Variable", size: size) != nil {
            return Font.custom("ABC Diatype Variable", size: size).weight(weight)
        }
        if NSFont(name: "ABC Diatype", size: size) != nil {
            return Font.custom("ABC Diatype", size: size).weight(weight)
        }
        if NSFont(name: "Inter-Regular", size: size) != nil {
            return Font.custom("Inter-Regular", size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: .default)
    }

    static func monoBase(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrainsMono-Regular", size: size) != nil {
            return Font.custom("JetBrainsMono-Regular", size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// Sans face with monospaced digits — proportional letters, fixed-width
    /// numbers. Use for any numeric value that needs to align vertically
    /// across rows (stat cards, currency columns, percentage tables).
    /// Falls back through the sans chain, applying `.monospacedDigit()`
    /// on top so non-numeric glyphs still read as Diatype/Inter, not mono.
    static func dataValueBase(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        sans(size, weight: weight).monospacedDigit()
    }

    /// Convenience for arbitrary-size data values (e.g. a 20pt hero stat).
    static func dataValue(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        dataValueBase(size, weight: weight)
    }
}
