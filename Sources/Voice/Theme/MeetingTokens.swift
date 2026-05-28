// VOICE — Meeting & Surface Tokens
// ============================================================
// Color tokens for the meeting list (recording / transcribing /
// transcribed / failed) and the row interaction surface (hover,
// active/expanded, hairline border).
//
// These exist because BigMenuWindow.swift currently spells the
// same opacity literals (0.03 hover, 0.05 expanded, 0.06 border)
// and the same state colors (.red, .orange) inline at ~20 call
// sites. New views that touch the meeting list — context menus,
// the calendar's "meetings on this day" hover state, the audio
// player's recording indicator — should pull from here instead
// of guessing fresh numbers.
//
// Numeric opacities mirror the existing values in BigMenuWindow
// so adopting these tokens in new code reads visually identical
// to today's window. We intentionally don't refactor existing
// inline usages here — that's a separate sweep.
// ============================================================

import SwiftUI

// MARK: - Meeting lifecycle states

/// Lifecycle of a meeting row in the main list. Mirrors the
/// `RowState` enum that `MeetingRow` computes from `meeting`,
/// `isTranscribing`, and `transcribeError`. Lifted here so
/// other views (calendar, audio player, share sheet) can map
/// to the same color vocabulary.
enum MeetingState {
    /// Recording in progress (red pulse stripe).
    case recording
    /// Audio captured, transcription running.
    case transcribing
    /// Transcribed and ready (no stripe — keeps long lists calm).
    case done
    /// Last transcription attempt failed.
    case failed
    /// Audio on disk but never transcribed.
    case untranscribed
    /// Audio file is missing from disk.
    case audioMissing
}

extension Color {
    // MARK: Meeting state colors

    /// Red stripe / dot used for live recording rows. Pairs with
    /// a smooth opacity pulse driven by the row view.
    static let meetingRecording: Color = .red

    /// Amber for transcribing-in-flight and "audio only, tap to
    /// transcribe". Visibly different from `meetingRecording` so
    /// users can tell "live" from "processing" at a glance.
    static let meetingTranscribing: Color = .orange

    /// Same amber as `meetingTranscribing` — kept as a separate
    /// token so the call site reads as intent ("this row has
    /// audio but no segments") rather than as a color reuse.
    static let meetingUntranscribed: Color = .orange

    /// Done rows render no leading stripe; transparent keeps a
    /// long list calm. Caption text falls back to `.secondary`.
    static let meetingDone: Color = .clear

    /// Red for terminal failure (transcribe failed, audio missing).
    /// Same hue as `meetingRecording` because the user's mental
    /// model — "something is wrong, look here" — overlaps.
    static let meetingFailed: Color = .red

    // MARK: Row surface tints
    //
    // All three are `Color.primary.opacity(...)` so they adapt
    // automatically across light and dark mode without needing
    // `@Environment(\.colorScheme)` plumbing at the call site.

    /// Background tint for a row the cursor is hovering over.
    /// Subtle enough that a long list doesn't shimmer when the
    /// pointer drifts across it, strong enough to read as an
    /// affordance ("this row is clickable").
    static let rowHover: Color = Color.primary.opacity(0.03)

    /// Background tint for the row that is currently expanded
    /// / active. About 1.5x stronger than `rowHover` so the
    /// active row stays visible even after the pointer leaves.
    static let rowActive: Color = Color.primary.opacity(0.05)

    /// Hairline border opacity used on every unselected card and
    /// surface chrome. Matches `CardShape.borderUnselected`'s
    /// stroke color across the app.
    static let surfaceHairline: Color = Color.primary.opacity(0.06)
}

extension MeetingState {
    /// Convenience: map a state to its stripe color. Use this
    /// in new views so the recording/transcribing/done vocabulary
    /// stays consistent across the app.
    var stripeColor: Color {
        switch self {
        case .recording:                          return .meetingRecording
        case .transcribing, .untranscribed:       return .meetingTranscribing
        case .done:                               return .meetingDone
        case .failed, .audioMissing:              return .meetingFailed
        }
    }
}
