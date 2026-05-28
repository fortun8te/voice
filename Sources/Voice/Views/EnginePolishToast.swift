// EnginePolishToast.swift
//
// The single SF Symbol in TranscribingGlyph (cloud.fill / cpu / sparkles) was
// the only signal of which engine ran each polish, and it disappeared the
// instant the in-flight window ended — easy to miss. A user reported "why are
// we using the local model, even though in settings I'm clearly on the cloud?"
// because the indicator wasn't sticking around long enough to read.
//
// EnginePolishToast shows for ~2 seconds after every polish completes with:
//   - color-coded tint (green = cloud, amber = local, red = rules-only)
//   - engine family + latency in plain text
//   - tap to open a details popover with the routing reason + word counts
//
// Driven by PolishStatus updates via NotificationCenter.voicePolishComplete
// (when callers go through the new `record()` entry point) and as a fallback
// by .onChange of PolishStatus.lastEngine (for Qwen3Polisher's direct writes
// until that file is migrated).
//
// The orchestration (when to present, when to dismiss, the @AppStorage gate
// for the persistent chip) lives on OverlayPillView in OverlayPanel.swift —
// this file holds only the data types and view structs.

import SwiftUI
import AppKit

// MARK: - Data types

/// Pure-data snapshot captured at toast-present time so the view doesn't have
/// to re-read @Observable state on every redraw (avoids re-firing transitions
/// if the underlying singleton changes mid-display).
struct EngineToastSnapshot: Equatable {
    let engine: String
    let latencyMs: Int
    let reason: String?
    let inputWordCount: Int
    let outputWordCount: Int
    let fallbackCount: Int
    let sanitizerRejected: Bool
}

/// Engine-family classification used to pick the toast tint, icon, and the
/// human-readable model label. Mirrors TranscribingGlyph's engineKind logic
/// but extended with `rulesOnly` so the fallback path is visually distinct.
enum EngineFamily {
    case cloud, local, rulesOnly, unknown

    static func classify(_ raw: String) -> EngineFamily {
        if raw.hasPrefix("cloud:") { return .cloud }
        if raw.hasPrefix("local:") { return .local }
        if raw == "rules-only" || raw.hasPrefix("rules") { return .rulesOnly }
        return .unknown
    }

    /// Color tint per engine family. Matches the user's spec:
    /// cloud → green, local → amber, rules-only → red.
    var tint: Color {
        switch self {
        case .cloud:     return Color.green
        case .local:     return Color.orange
        case .rulesOnly: return Color.red
        case .unknown:   return Color.gray
        }
    }

    /// Short label shown on the toast left-of the model name.
    var label: String {
        switch self {
        case .cloud:     return "cloud"
        case .local:     return "local"
        case .rulesOnly: return "rules"
        case .unknown:   return "engine"
        }
    }

    var icon: String {
        switch self {
        case .cloud:     return "cloud.fill"
        case .local:     return "cpu"
        case .rulesOnly: return "exclamationmark.triangle.fill"
        case .unknown:   return "sparkles"
        }
    }
}

// MARK: - Formatting helpers

/// Pretty-print the engine suffix as a recognizable model name. Falls back to
/// the raw suffix when no mapping is known so newly-added engines aren't
/// silently mislabeled — they just show the suffix string verbatim.
func prettyEngineLabel(_ raw: String) -> String {
    let suffix: String = {
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }()
    switch suffix {
    case "gpt-oss-120b":       return "GPT-OSS 120B"
    case "qwen-3-235b":        return "Qwen 3 235B"
    case "groq-llama3.1-8b":   return "Llama 3.1 8B (Groq)"
    case "qwen3-1.7b":         return "Qwen3 1.7B"
    case "qwen3-4b":           return "Qwen3 4B"
    case "cerebras":           return "Cerebras"
    default:                   return suffix
    }
}

/// Format latency in human-friendly units. <1s → "247ms", >=1s → "1.8s".
func formatLatency(_ ms: Int) -> String {
    if ms <= 0 { return "—" }
    if ms < 1000 { return "\(ms)ms" }
    let s = Double(ms) / 1000.0
    return String(format: "%.1fs", s)
}

// MARK: - Transient toast

struct EnginePolishToast: View {
    let snapshot: EngineToastSnapshot
    let shownAt: Date
    @Binding var detailsOpen: Bool
    let onTap: () -> Void

    private var family: EngineFamily { EngineFamily.classify(snapshot.engine) }

    var body: some View {
        let modelLabel = prettyEngineLabel(snapshot.engine)
        let latency = formatLatency(snapshot.latencyMs)
        // " · " separator matches the rest of the pill's typographic style
        // (see MeetingCapturePill which uses U+00B7 too).
        HStack(spacing: 6) {
            Image(systemName: family.icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(family.tint)
            Text("\(family.label) \u{00B7} \(modelLabel) \u{00B7} \(latency)")
                .font(.sans(10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(family.tint.opacity(0.22))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(family.tint.opacity(0.55), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.30), radius: 6, x: 0, y: 2)
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .popover(isPresented: $detailsOpen, arrowEdge: .top) {
            EnginePolishDetailsPopover(snapshot: snapshot)
        }
    }
}

// MARK: - Details popover

/// Details popover surfaced when the user taps the engine toast within its
/// 2s visible window. Shows everything PolishStatus knows about the most
/// recent polish + a copy-to-clipboard affordance for the diagnostic blob.
struct EnginePolishDetailsPopover: View {
    let snapshot: EngineToastSnapshot

    private var family: EngineFamily { EngineFamily.classify(snapshot.engine) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: family.icon)
                    .foregroundStyle(family.tint)
                Text(prettyEngineLabel(snapshot.engine))
                    .font(.sans(13, weight: .semibold))
                Spacer()
                Text(formatLatency(snapshot.latencyMs))
                    .font(.sans(12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            row("Engine", value: snapshot.engine)
            row("Latency", value: formatLatency(snapshot.latencyMs))
            row("Why", value: snapshot.reason ?? "—")
            row("Words in / out",
                value: "\(snapshot.inputWordCount) / \(snapshot.outputWordCount)")
            if snapshot.fallbackCount > 1 {
                row("Fallback chain depth", value: "\(snapshot.fallbackCount)")
            }
            if snapshot.sanitizerRejected {
                Text("Sanitizer rejected output — pasted raw text instead.")
                    .font(.sans(11, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.85))
            }

            Divider()

            Button {
                let payload = """
                engine: \(snapshot.engine)
                latency: \(formatLatency(snapshot.latencyMs))
                reason: \(snapshot.reason ?? "-")
                input words: \(snapshot.inputWordCount)
                output words: \(snapshot.outputWordCount)
                fallback count: \(snapshot.fallbackCount)
                sanitizer rejected: \(snapshot.sanitizerRejected)
                """
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(payload, forType: .string)
            } label: {
                Label("Copy diagnostics", systemImage: "doc.on.doc")
                    .font(.sans(11, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 280)
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.sans(11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.sans(11, weight: .regular))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

// MARK: - Persistent debug chip

/// Persistent always-visible engine chip — gated by @AppStorage flag in
/// OverlayPillView. Reads PolishStatus directly so it updates live as the
/// observable singleton changes. Click-through (allowsHitTesting=false) at
/// the call site so it never intercepts pill interactions.
struct EnginePolishDebugChip: View {
    /// PolishStatus is @Observable so reading from it inside body re-runs the
    /// body on changes — that's exactly what we want here.
    private let status = PolishStatus.shared

    var body: some View {
        let raw = status.lastEngine ?? "—"
        let family = EngineFamily.classify(raw)
        let latency = formatLatency(status.lastLatencyMs)
        HStack(spacing: 4) {
            Image(systemName: family.icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(family.tint)
            Text("\(prettyEngineLabel(raw)) \u{00B7} \(latency)")
                .font(.sans(9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(family.tint.opacity(0.45), lineWidth: 0.6)
        )
    }
}
