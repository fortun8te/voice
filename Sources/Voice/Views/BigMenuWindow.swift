// VOICE — Big Menu Window
// ============================================================
// Single-section layout: History only. The old Meetings tab was removed
// because it surfaced any dictation over 30 seconds as a "meeting", which
// isn't what users mean by that word. Real meetings will arrive from a
// separate browser extension that captures call audio; until then this
// window is pure dictation history.
//
// Settings live behind a ⚙ button at the BOTTOM of the sidebar.
// ============================================================

import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

// MARK: - Main window

struct BigMenuWindow: View {
    @Bindable var recordingState: RecordingState

    @State private var showSettings: Bool = false
    @State private var historyCount: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            HistoryView(
                onCountChange: { historyCount = $0 },
                recordingState: recordingState
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.5))
                        .frame(width: 1),
                    alignment: .trailing
                )

            VStack(alignment: .leading, spacing: 0) {
                // Wordmark
                Text("VOICE")
                    .font(.serif(22))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 24)

                // Nav rows — only History today. Layout still uses VStack to
                // leave room for future entries (e.g. Meetings, once the
                // browser-extension capture path ships).
                VStack(spacing: 1) {
                    sidebarRow(
                        title: "History",
                        icon: "clock",
                        count: historyCount,
                        selected: true,
                        action: {}
                    )
                    sidebarRow(
                        title: "Meetings",
                        icon: "calendar.badge.clock",
                        count: 0,
                        selected: false,
                        disabled: true,
                        trailingNote: "Soon",
                        action: {}
                    )
                }
                .padding(.horizontal, 10)

                Spacer()

                Divider()
                    .padding(.bottom, 2)

                Button(action: { showSettings.toggle() }) {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                        Text("Settings")
                            .font(.sans(13))
                            .tracking(LetterSpacing.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .popover(isPresented: $showSettings, arrowEdge: .trailing) {
                    SettingsPopover(recordingState: recordingState)
                }
            }
        }
        .frame(width: 188)
    }

    /// Sidebar row. `disabled` rows render dimmed and aren't tappable — used
    /// for the "Meetings · Soon" placeholder while the browser-extension
    /// capture flow is in flight.
    @ViewBuilder
    private func sidebarRow(
        title: String,
        icon: String,
        count: Int,
        selected: Bool,
        disabled: Bool = false,
        trailingNote: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(
                        disabled ? AnyShapeStyle(.quaternary)
                                 : (selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
                    )
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.sans(13, weight: selected ? .semibold : .regular))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(
                        disabled ? AnyShapeStyle(.tertiary)
                                 : (selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                    )
                Spacer()
                if let note = trailingNote {
                    Text(note.uppercased())
                        .font(.sans(9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        )
                } else if count > 0 {
                    Text("\(count)")
                        .font(.sans(11))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor.opacity(0.8)) : AnyShapeStyle(.tertiary))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "Coming soon — meetings will appear here when you connect the VOICE browser extension" : "")
    }
}

// MARK: - History

private struct HistoryEntry: Identifiable {
    let id: UUID
    let date: Date
    let duration: TimeInterval
    let title: String
    let fullText: String
}

private struct HistoryView: View {
    var onCountChange: (Int) -> Void = { _ in }
    var recordingState: RecordingState?

    @State private var entries: [HistoryEntry] = []
    @State private var search: String = ""
    @State private var loadError: String? = nil
    @State private var copiedID: UUID? = nil
    @State private var copiedRecentText: String? = nil
    /// Which recent-row is currently expanded to show the raw / polished
    /// diff. Only one at a time — collapses on tap-out or selecting another.
    @State private var expandedRecentID: String? = nil

    // Mirror of the Settings popover toggle — bound here so the stats strip
    // can flip polish on/off inline without opening Settings.
    @AppStorage("llmPolishEnabled") private var llmPolishEnabledStorage: Bool = LLMPolisher.isAvailable

    private let storage = StorageService()

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.fullText.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if let state = recordingState {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        statsStrip(state: state)
                        recentDictationsSection(tick: state.recentDictationsTick)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 380)
            }

            searchField
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            if let err = loadError {
                errorState(err)
            } else if filtered.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            HistoryRow(
                                entry: entry,
                                copied: copiedID == entry.id,
                                onCopy: { copy(entry) }
                            )
                            if entry.id != filtered.last?.id {
                                Divider()
                                    .padding(.leading, 24)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { load() }
    }

    // MARK: Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("History")
                    .font(.sans(22, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
                Text("Your recent dictations")
                    .font(.sans(12))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !entries.isEmpty {
                pillBadge("\(entries.count) saved")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    // MARK: Design tokens

    @ViewBuilder
    private func pillBadge(_ text: String) -> some View {
        Text(text)
            .font(.sans(11, weight: .medium))
            .tracking(LetterSpacing.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )
            )
    }

    @ViewBuilder
    private func sectionEyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.sans(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search transcripts…", text: $search)
                .textFieldStyle(.plain)
                .font(.sans(13))
                .tracking(LetterSpacing.body)
                .foregroundStyle(.primary)
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    // MARK: Stats strip
    //
    // One row of four equal-width tiles + a tiny polish indicator in the
    // corner. Replaces the old multi-card stack (Today hero / FM pill /
    // Last / All-Time) — same data, one quarter the visual weight.

    private func formatHMS(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private var fmDot: Color {
        switch Qwen3Polisher.availabilityStatus {
        case .available: return .green
        case .downloading, .loading: return .orange
        case .notDownloaded, .error: return .red
        }
    }

    @ViewBuilder
    private func statsStrip(state: RecordingState) -> some View {
        let avgWPM = state.sessionDictationCount > 0
            ? state.sessionAvgWPM
            : state.lifetimeAvgWPM

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionEyebrow("Stats")
                Spacer()
                polishIndicator
            }

            HStack(spacing: 10) {
                statTile(
                    icon: "sun.max",
                    label: "Today",
                    value: "\(state.sessionTotalWords.compactKilo())",
                    sub: "words",
                    dim: state.sessionDictationCount == 0
                )
                statTile(
                    icon: "infinity",
                    label: "All-Time",
                    value: "\(state.lifetimeWords.compactKilo())",
                    sub: "words",
                    dim: state.lifetimeDictations == 0
                )
                statTile(
                    icon: "gauge.with.dots.needle.67percent",
                    label: "Avg WPM",
                    value: avgWPM > 0 ? "\(avgWPM)" : "—",
                    sub: "spoken",
                    dim: avgWPM == 0
                )
                statTile(
                    icon: "mic.fill",
                    label: "Dictations",
                    value: "\(state.sessionDictationCount)",
                    sub: state.lifetimeDictations > 0
                        ? "of \(state.lifetimeDictations.compactKilo())"
                        : "today",
                    dim: state.sessionDictationCount == 0
                )
            }
        }
    }

    /// Equal-width compact stat — flat, icon eyebrow, single-line value+sub.
    /// Way lighter than the old miniTile (no inner divider, smaller hero size,
    /// no two-line layout).
    @ViewBuilder
    private func statTile(
        icon: String,
        label: String,
        value: String,
        sub: String,
        dim: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(label.uppercased())
                    .font(.sans(9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Text(sub)
                    .font(.sans(11, weight: .medium))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    /// Tiny polish-state chip wired to the same `llmPolishEnabled` AppStorage
    /// flag as Settings. Tap to toggle. Status dot reflects model readiness.
    @ViewBuilder
    private var polishIndicator: some View {
        let status = Qwen3Polisher.availabilityStatus
        let on = llmPolishEnabledStorage && status.isReady
        Button(action: {
            if status.isReady { llmPolishEnabledStorage.toggle() }
        }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(fmDot)
                    .frame(width: 6, height: 6)
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(on ? "Polish on" : "Polish off")
                    .font(.sans(10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Click to toggle polish · model: \(status.displayLabel)")
        .disabled(!status.isReady)
    }

    // MARK: Recent Dictations

    private func relativeTimestamp(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    private func previewText(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let prefix = String(oneLine.prefix(48))
        return oneLine.count > 48 ? prefix + "…" : prefix
    }

    @ViewBuilder
    private func recentRow(item: RecentDictation, isCopied: Bool, isLast: Bool) -> some View {
        RecentRowView(
            item: item,
            isCopied: isCopied,
            isLast: isLast,
            expandedRecentID: $expandedRecentID,
            onCopy: { copyRecent(item.text) },
            compareBlock: { raw, polished in compareBlock(raw: raw, polished: polished) }
        )
    }

    /// Side-by-side raw vs polished. Compact, scrollable horizontally on
    /// narrow widths via lineLimit guarding — wrap is fine here, the row
    /// already expanded vertically so we have the space.
    @ViewBuilder
    private func compareBlock(raw: String, polished: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            compareColumn(label: "Raw", text: raw, primary: false)
            compareColumn(label: "Polished", text: polished, primary: true)
        }
    }

    @ViewBuilder
    private func compareColumn(label: String, text: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: primary ? "wand.and.sparkles" : "text.alignleft")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(primary ? Color.accentColor : Color.secondary.opacity(0.7))
                Text(label.uppercased())
                    .font(.sans(9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(primary ? AnyShapeStyle(Color.accentColor.opacity(0.9)) : AnyShapeStyle(.tertiary))
            }
            Text(text)
                .font(.sans(11))
                .tracking(LetterSpacing.body)
                .foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(primary
                      ? Color.accentColor.opacity(0.07)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    primary ? Color.accentColor.opacity(0.22) : Color(nsColor: .separatorColor).opacity(0.35),
                    lineWidth: 0.5
                )
        )
    }

    @ViewBuilder
    private func recentDictationsSection(tick: Int) -> some View {
        // `tick` is a no-op param — its only purpose is to make this view depend
        // on RecordingState.recentDictationsTick so SwiftUI re-renders after a
        // fresh dictation is recorded.
        let recents = RecentDictations.all()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionEyebrow("Quick Copy")
                Spacer()
                if !recents.isEmpty {
                    Text("\(recents.count)")
                        .font(.sans(10, weight: .medium))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(.quaternary)
                        .monospacedDigit()
                }
            }

            if recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                        Text("No recent dictations")
                            .font(.sans(12, weight: .medium))
                            .tracking(LetterSpacing.body)
                            .foregroundStyle(.secondary)
                    }
                    Text("Hold Right \u{2325} to record — last 5 will appear here for one-click copy")
                        .font(.sans(11))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.35),
                            style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                        )
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recents.enumerated()), id: \.element.id) { idx, item in
                        recentRow(
                            item: item,
                            isCopied: copiedRecentText == item.text,
                            isLast: idx == recents.count - 1
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                )
            }
        }
    }

    private func copyRecent(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedRecentText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedRecentText == text { copiedRecentText = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 56, height: 56)
                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 4) {
                Text("No dictations yet")
                    .font(.sans(15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.primary)
                Text(search.isEmpty
                     ? "Hold Right \u{2325} anywhere to start"
                     : "No results for \"\(search)\"")
                    .font(.sans(12))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Couldn't load history")
                .font(.sans(14, weight: .semibold))
                .foregroundStyle(.primary)
            Text(message)
                .font(.sans(11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ entry: HistoryEntry) {
        let text = entry.fullText.isEmpty ? entry.title : entry.fullText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = entry.id
        let id = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == id { copiedID = nil }
        }
    }

    private func load() {
        do {
            try storage.initialize()
            let meetings = try storage.fetchAllMeetings()
            // We render every persisted recording as a transcript row, sorted
            // newest-first. The old "< 60s OR no summary" gate filtered out
            // long-form recordings, but with the Meetings tab gone there's no
            // second home for them — surface everything here.
            entries = meetings
                .sorted(by: { $0.date > $1.date })
                .map { m in
                    let txt = m.segments.map { $0.text }.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return HistoryEntry(
                        id: m.id,
                        date: m.date,
                        duration: m.duration,
                        title: m.title,
                        fullText: txt
                    )
                }
            onCountChange(entries.count)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Recent Row (hover-only copy button)

private struct RecentRowView: View {
    let item: RecentDictation
    let isCopied: Bool
    let isLast: Bool
    @Binding var expandedRecentID: String?
    let onCopy: () -> Void
    let compareBlock: (String, String) -> AnyView

    @State private var isHovering = false

    init(
        item: RecentDictation,
        isCopied: Bool,
        isLast: Bool,
        expandedRecentID: Binding<String?>,
        onCopy: @escaping () -> Void,
        compareBlock: @escaping (String, String) -> some View
    ) {
        self.item = item
        self.isCopied = isCopied
        self.isLast = isLast
        self._expandedRecentID = expandedRecentID
        self.onCopy = onCopy
        self.compareBlock = { raw, polished in AnyView(compareBlock(raw, polished)) }
    }

    private var wordCount: Int { item.text.split(separator: " ").count }
    private var isExpanded: Bool { expandedRecentID == item.id }
    private var canCompare: Bool { item.hasRawText }

    private func previewText(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let prefix = String(oneLine.prefix(48))
        return oneLine.count > 48 ? prefix + "…" : prefix
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: onCopy) {
                    HStack(spacing: 10) {
                        Text(previewText(item.text))
                            .font(.sans(12))
                            .tracking(LetterSpacing.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(wordCount)w")
                            .font(.sans(10, weight: .medium))
                            .tracking(LetterSpacing.body)
                            .foregroundStyle(.quaternary)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            )

                        Text(relativeTimestamp(item.timestamp))
                            .font(.sans(11))
                            .tracking(LetterSpacing.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to copy to clipboard")

                // Compare toggle — only when raw and polished actually differ.
                if canCompare {
                    let polished = item.hasPolishDiff
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            expandedRecentID = isExpanded ? nil : item.id
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.up" : (polished ? "wand.and.sparkles" : "text.alignleft"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isExpanded ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide raw" : (polished ? "Show before polish" : "Show raw transcript"))
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }

                // Copy icon — visible only on hover (or when just copied).
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: isCopied ? .semibold : .regular))
                    .foregroundStyle(isCopied ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 14)
                    .opacity(isHovering || isCopied ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isCopied)
                    .animation(.easeOut(duration: 0.1), value: isHovering)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if isExpanded, let raw = item.rawText {
                compareBlock(raw, item.text)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void

    @State private var hover = false

    private var relativeDate: String {
        let calendar = Calendar.current
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        if calendar.isDateInToday(entry.date) {
            return f.string(from: entry.date)
        } else if calendar.isDateInYesterday(entry.date) {
            return "Yesterday, \(f.string(from: entry.date))"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            return df.string(from: entry.date)
        }
    }

    private var durationStr: String? {
        guard entry.duration > 2 else { return nil }
        let s = Int(entry.duration)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m"
    }

    private var preview: String {
        (entry.fullText.isEmpty ? entry.title : entry.fullText)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview)
                        .font(.sans(13))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        Text(relativeDate)
                            .font(.sans(11))
                            .tracking(LetterSpacing.body)
                            .foregroundStyle(.tertiary)
                        if let dur = durationStr {
                            Text("·")
                                .font(.sans(11))
                                .foregroundStyle(.quaternary)
                            Text(dur)
                                .font(.sans(11))
                                .tracking(LetterSpacing.body)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else if hover {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .frame(width: 24, alignment: .center)
                .animation(.easeOut(duration: 0.12), value: copied)
                .animation(.easeOut(duration: 0.1), value: hover)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
            .background(hover ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy transcript")
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.1), value: hover)
    }
}

// MARK: - Settings Popover

private struct SettingsPopover: View {
    @Bindable var recordingState: RecordingState

    @AppStorage("hotkey") private var hotkey: String = HotkeyOption.rightOption.rawValue
    @AppStorage("autoPaste") private var autoPaste: Bool = true
    @AppStorage("autoCopy") private var autoCopy: Bool = true
    @AppStorage("soundEffectsEnabled") private var soundEffects: Bool = true
    // Default mirrors Qwen3Polisher.isEnabled: ON by default (MLX-Swift is
    // always available on Apple Silicon). The user's first toggle writes a
    // concrete value and from then on the stored preference wins.
    @AppStorage("llmPolishEnabled") private var llmPolishEnabled: Bool = LLMPolisher.isAvailable

    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var refreshTimer: Timer?

    private var fmStatusColor: Color {
        switch Qwen3Polisher.availabilityStatus {
        case .available:               return .green
        case .downloading, .loading:   return .orange
        case .notDownloaded:           return .yellow
        case .error:                   return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.sans(16, weight: .semibold))
                .tracking(-0.2)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider()

            settingsSection("Hotkey") {
                Picker("", selection: $hotkey) {
                    ForEach(HotkeyOption.allCases) { opt in
                        Text(opt.displayName).tag(opt.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .onChange(of: hotkey) { _, _ in
                    NotificationCenter.default.post(name: .voiceHotkeyChanged, object: nil)
                }
            }

            Divider()

            settingsSection("Output") {
                VStack(alignment: .leading, spacing: 8) {
                    settingsToggle("Auto-paste at cursor", isOn: $autoPaste)
                    settingsToggle("Copy to clipboard", isOn: $autoCopy)
                    settingsToggle("Sound effects", isOn: $soundEffects)
                    VStack(alignment: .leading, spacing: 2) {
                        settingsToggle("LLM polish (on-device)", isOn: $llmPolishEnabled)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(fmStatusColor)
                                .frame(width: 7, height: 7)
                            Text("Polish model: \(Qwen3Polisher.availabilityStatus.displayLabel)")
                                .font(.sans(11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 20)
                        .padding(.top, 2)
                    }
                }
            }

            Divider()

            settingsSection("Permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(label: "Microphone", granted: micGranted) {
                        openSecurity("Privacy_Microphone")
                    }
                    permissionRow(label: "Accessibility", granted: axGranted) {
                        openSecurity("Privacy_Accessibility")
                    }
                }
            }

            Divider()

            HStack {
                Text("VOICE 1.0")
                    .font(.sans(11))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.quaternary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.sans(11, weight: .medium))
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 290)
        .onAppear {
            refreshPermissions()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                refreshPermissions()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.sans(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func settingsToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.sans(13))
                .tracking(LetterSpacing.body)
                .foregroundStyle(.primary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    @ViewBuilder
    private func permissionRow(label: String, granted: Bool, openAction: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                    .frame(width: 20, height: 20)
                Image(systemName: granted ? "checkmark" : "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(granted ? .green : .orange)
            }
            Text(label)
                .font(.sans(13))
                .tracking(LetterSpacing.body)
                .foregroundStyle(.primary)
            Spacer()
            if !granted {
                Button("Enable") { openAction() }
                    .buttonStyle(.borderless)
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.sans(11))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    private func openSecurity(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Helpers

fileprivate extension Int {
    /// Compact thousands formatting: 1234 -> "1.2k", 12345 -> "12k", 1_234_567 -> "1.2M".
    func compactKilo() -> String {
        let n = self
        if n < 1_000 { return "\(n)" }
        if n < 10_000 {
            let v = Double(n) / 1_000.0
            return String(format: "%.1fk", v)
        }
        if n < 1_000_000 { return "\(n / 1_000)k" }
        let m = Double(n) / 1_000_000.0
        return String(format: "%.1fM", m)
    }
}

// MARK: - Preview

#Preview {
    BigMenuWindow(recordingState: RecordingState())
        .frame(width: 860, height: 580)
}
