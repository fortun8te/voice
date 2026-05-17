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
//   serifTitle   28  Sheet titles ("Settings")
//   serifValue   32  Stat card numbers (sits below hero, above section)
//   serifSection 22  Card titles ("Light", "Casual")
//   serifLabel   16  Muted serif captions
//   bodyLarge    15  Settings descriptions
//   bodyBase     13  Body text
//   bodyMedium   13  Emphasized body (.medium)
//   bodySmall    12  Secondary captions
//   label        11  Uppercase section headers (.semibold)
//   badge        10  Chips, pill badges (.semibold)
//   mono         12  Logs, code
//
// Rule of thumb: `.tracking(0.8)` is reserved for uppercase `label` only.
// Body and serif sizes never get explicit tracking.

extension Font {
    // SERIF family (Tiempos / fallback chain)
    static let serifHero    = serif(40, weight: .regular)   // hero titles
    static let serifTitle   = serif(28, weight: .regular)   // sheet titles
    static let serifValue   = serif(32, weight: .medium)    // stat card numbers
    static let serifSection = serif(22, weight: .regular)   // card titles
    static let serifLabel   = serif(16, weight: .regular)   // muted serif captions

    // SANS family (Diatype / fallback)
    static let bodyLarge    = sans(15, weight: .regular)    // settings descriptions
    static let bodyBase     = sans(13, weight: .regular)    // body text everywhere
    static let bodyMedium   = sans(13, weight: .medium)     // emphasized body
    static let bodySmall    = sans(12, weight: .regular)    // secondary captions
    static let label        = sans(11, weight: .semibold)   // ALL-CAPS section headers
    static let badge        = sans(10, weight: .semibold)   // chips, badges
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
}
