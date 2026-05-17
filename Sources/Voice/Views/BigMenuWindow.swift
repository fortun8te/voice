// VOICE — Main App Window (redesigned May 2026)
// ============================================================
// Standard macOS window chrome (traffic lights, ".." toolbar overflow).
// Layout, top to bottom:
//   * 3 STAT CARDS — words/min, fixes by voice, total words (last 7 days).
//   * DATE-GROUPED DICTATION LIST — scrollable, one section per day.
//     Empty dictations are filtered out. Click a row to expand it (full
//     polished text + stage chips). Click an already-expanded row to copy
//     its text (with a brief "Copied" indicator). Clicking another row
//     expands that one and collapses the previous.
// Settings (pill skin, polish toggle, hotkey, perms) live in the sheet
// presented via the toolbar's "…" overflow → Settings… item, posted by
// the AppKit menu and observed here via .voiceOpenBigMenuSettings.
// ============================================================

import SwiftUI
import AppKit
import AVFoundation

// MARK: - Spacing tokens
//
// Single source of truth for ALL padding / spacing in this window. Inline
// numeric literals (`.padding(13)`) are not allowed below this point unless
// they're accompanied by a comment explaining why — every legitimate value
// already exists on this enum.

enum Sp {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
}

// MARK: - Card surface tokens

private enum CardShape {
    /// Same corner radius across stat cards, cleanup cards, personality
    /// cards, and hotkey-role cards. Keeping them identical reads as "one
    /// rounded-rectangle family" instead of "a few different cards".
    static let corner: CGFloat = 14
    /// Hairline border on every unselected card.
    static let borderUnselected = 1.0
    /// Slightly thicker accent border when the card is the selected option.
    static let borderSelected = 1.5
}

// MARK: - App shell background
//
// Solid app-shell surface (replaces the older WindowVibrancyBackground). User
// feedback called the old vibrancy "too translucent" — it made the window
// blend into whatever was behind it and read as a quick prototype rather than
// a finished app. A solid base color with a barely-there top sheen reads as a
// custom-built app while still feeling at home on macOS. The window keeps its
// `.titled` styleMask + transparent titlebar (set in the AppKit layer), so the
// title bar still picks up native chrome — only the content area is solid.

private struct AppShellBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Base solid color — near-black in dark mode, near-white in light.
            (scheme == .dark
                ? Color(red: 0.072, green: 0.072, blue: 0.080)
                : Color(red: 0.985, green: 0.985, blue: 0.990))

            // Subtle vertical sheen (top a few percent lighter than bottom).
            // Only meaningfully visible in dark mode; light mode stays flat.
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(scheme == .dark ? 0.015 : 0.000), location: 0.0),
                    .init(color: Color.white.opacity(0.0), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// Slightly darker surface for the dictation list area. Sits between the app
/// shell and the row content so users can read the list as a distinct
/// "container" without needing a heavy frame around it.
private struct DictationListBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark
            ? Color.black.opacity(0.10)
            : Color.black.opacity(0.015))
    }
}

// MARK: - Root view

struct BigMenuWindow: View {
    @Bindable var recordingState: RecordingState
    var onClose: (() -> Void)? = nil

    @State private var showSettings = false
    /// At most ONE row is expanded at a time. nil = nothing expanded.
    @State private var expandedID: String? = nil
    /// Transient "Copied" indicator. Maps row id → expiration token. Each
    /// copy increments to keep timing accurate when re-copied quickly.
    @State private var copiedToken: [String: Int] = [:]

    // MARK: - Permissions integration
    //
    // TODO(integration): VoiceApp.applicationDidFinishLaunching should call
    // PermissionsService.shared.refresh() at startup. Until then, the first
    // refresh happens lazily when BigMenuWindow appears (.task modifier below).
    //
    // The @Observable PermissionsService publishes accessibility / microphone /
    // inputMonitoring statuses + an `allGranted` rollup. The banner reacts to
    // changes automatically; macOS may relaunch the app after Accessibility is
    // granted via System Settings, in which case the banner is simply absent
    // on next launch.
    @State private var permissions = PermissionsService.shared
    @State private var showPermissionsSheet = false

    private var recents: [RecentDictation] {
        // Empty-polished rows are filtered out per spec — they used to show
        // up as a lonely timestamp with no content.
        _ = recordingState.recentDictationsTick
        return RecentDictations.all().filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Group by calendar-day (newest day first). Keeps RecentDictation
    /// ordering inside each group (newest first within a day).
    private var grouped: [(day: Date, items: [RecentDictation])] {
        let cal = Calendar.current
        var buckets: [(Date, [RecentDictation])] = []
        for r in recents {
            let day = cal.startOfDay(for: r.timestamp)
            if let idx = buckets.firstIndex(where: { $0.0 == day }) {
                buckets[idx].1.append(r)
            } else {
                buckets.append((day, [r]))
            }
        }
        return buckets
    }

    var body: some View {
        ZStack {
            AppShellBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Permission gate banner — only shown when ANY required grant
                // is missing. Tapping presents the full PermissionsView in a
                // sheet. Disappears reactively once all grants land (so the OS
                // forced relaunch after granting Accessibility lands on a
                // banner-free window).
                if !permissions.allGranted {
                    PermissionsBanner(onTap: { showPermissionsSheet = true })
                        .padding(.horizontal, Sp.xl)
                        .padding(.top, Sp.md)
                }

                statsRow
                    .padding(.horizontal, Sp.xl)
                    .padding(.top, Sp.md)
                    .padding(.bottom, Sp.md)

                // Model loading indicator, shown during first-run download.
                Group {
                    if case .downloading(let p) = recordingState.modelState {
                        VStack(spacing: Sp.xs) {
                            ProgressView(value: p)
                                .tint(.accentColor)
                                .padding(.horizontal, Sp.xl)
                            Text("Downloading AI model… \(Int(p * 100))%")
                                .font(.bodySmall)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, Sp.xs)
                        }
                    } else if case .loading = recordingState.modelState {
                        Text("Loading AI model…")
                            .font(.bodySmall)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, Sp.xs)
                    }
                }

                Divider().opacity(0.4)

                if recents.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                            ForEach(Array(grouped.enumerated()), id: \.element.day) { _, group in
                                dateHeader(group.day)
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                    DictationRow(
                                        item: item,
                                        isLast: idx == group.items.count - 1,
                                        isExpanded: expandedID == item.id,
                                        showCopied: copiedToken[item.id] != nil,
                                        onTap: { handleRowTap(item) },
                                        onCopied: { handleRowCopied(item) },
                                        onRevertToRaw: { rawText in handleRevertToRaw(item, rawText: rawText) },
                                        onDelete: { handleDeleteRow(item) }
                                    )
                                }
                            }
                        }
                        .padding(.bottom, Sp.md)
                    }
                    // Subtle "content area" surface — slightly darker than the
                    // window chrome so the list reads as a distinct container
                    // without needing a heavy frame. Corner radius 0 because
                    // the area extends to the bottom of the window and would
                    // look clipped if rounded.
                    .background(DictationListBackground())
                }

                Divider()
                HStack {
                    // Lighter chrome for the footer controls. They're utility
                    // buttons and shouldn't compete with content above.
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(Sp.sm)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Sp.sm))
                    }
                    .buttonStyle(.plain)
                    .help("Settings")

                    Spacer()

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Text("Quit Voice")
                            .font(.bodyMedium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Sp.md)
                            .padding(.vertical, Sp.sm)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Sp.sm))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Sp.lg)
                .padding(.vertical, Sp.sm)
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 500, idealHeight: 620)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(recordingState: recordingState)
        }
        .sheet(isPresented: $showPermissionsSheet) {
            PermissionsView(onDone: { showPermissionsSheet = false })
                .frame(minWidth: 560, minHeight: 540)
        }
        .task {
            // First-appearance refresh. Once VoiceApp.applicationDidFinishLaunching
            // calls PermissionsService.shared.refresh() at startup (see
            // TODO(integration) above), this becomes a redundant no-op — safe.
            permissions.refresh()
        }
        .onChange(of: recordingState.recentDictationsTick) { _, _ in
            // Auto-expand the new latest entry so the user immediately sees
            // the per-model breakdown for the fresh result.
            if let newest = recents.first {
                expandedID = newest.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceOpenBigMenuSettings)) { _ in
            showSettings = true
        }
    }

    // MARK: - Stats row

    @ViewBuilder
    private var statsRow: some View {
        let stats = computeStats(over: recents, days: 7)
        HStack(spacing: Sp.md) {
            StatCard(
                icon: "waveform",
                value: "\(stats.wordsPerMinute)",
                label: "words per minute"
            )
            StatCard(
                icon: "sparkles",
                value: "\(stats.fixesByVoice)",
                label: "fixes made by voice"
            )
            StatCard(
                icon: "doc.text",
                value: "\(stats.totalWords)",
                label: "total words dictated"
            )
        }
    }

    /// Compute the three headline numbers over `recents` within the last
    /// `days` days. Voice-command count + duration are sourced from per-row
    /// fields (added May 2026); for older entries without those, falls back
    /// to 0 contribution rather than guessing.
    private func computeStats(over items: [RecentDictation], days: Int) -> (wordsPerMinute: Int, fixesByVoice: Int, totalWords: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let recent = items.filter { $0.timestamp >= cutoff }

        var totalWords = 0
        var totalDuration = 0
        var fixes = 0
        var lifetimeWords = 0
        for r in items {
            let wc = r.text.split { $0.isWhitespace }.count
            lifetimeWords += wc
            if r.timestamp >= cutoff {
                totalWords += wc
                if let d = r.durationSeconds { totalDuration += d }
                if let c = r.polishFixCount { fixes += c }
            }
        }
        _ = recent
        let wpm: Int = totalDuration > 0 ? Int((Double(totalWords) * 60.0) / Double(totalDuration)) : 0
        // "Total words dictated" is intentionally the lifetime sum across all
        // persisted dictations (matches the reference card label exactly).
        return (wpm, fixes, lifetimeWords)
    }

    // MARK: - Date header

    @ViewBuilder
    private func dateHeader(_ day: Date) -> some View {
        // BUGFIX: tightened tracking + uppercase to match the inspo's
        // small-caps day headers. Previously read as a regular sentence
        // label and got lost between rows; uppercase + 0.6 tracking
        // anchors the section visually without enlarging the font.
        Text(formatDayHeader(day).uppercased())
            .font(.label)
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Sp.xl)
            .padding(.top, Sp.md)
            .padding(.bottom, Sp.xs)
    }

    private func formatDayHeader(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: day)
    }

    // MARK: - Row tap

    /// Click toggles expansion. Copy is an explicit action handled by the
    /// Copy button inside the expanded row, the right-click context menu, or
    /// ⌘C with the polished-text field selected. Surprise copy-on-click was
    /// surfacing the "Copied" flash when users were just trying to inspect a
    /// row, so the two-state behavior was removed.
    private func handleRowTap(_ item: RecentDictation) {
        withAnimation(.easeOut(duration: 0.14)) {
            if expandedID == item.id {
                expandedID = nil
            } else {
                expandedID = item.id
            }
        }
    }

    /// Flashes the "Copied" badge for ~1.5s after an explicit copy action
    /// fires from the expanded-row toolbar or the context menu. Token-based
    /// so rapid re-copies don't clear an in-flight indicator early.
    private func handleRowCopied(_ item: RecentDictation) {
        let token = (copiedToken[item.id] ?? 0) &+ 1
        copiedToken[item.id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedToken[item.id] == token {
                copiedToken.removeValue(forKey: item.id)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Sp.md) {
            Image(systemName: "waveform.badge.microphone")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No dictations yet")
                .font(.bodyLarge.weight(.medium))
                .foregroundStyle(.primary.opacity(0.7))
            Text("Hold Right ⌥ anywhere and start speaking.")
                .font(.bodySmall)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Sp.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Context menu handlers

    private func handleRevertToRaw(_ item: RecentDictation, rawText: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rawText, forType: .string)

        let token = (copiedToken[item.id] ?? 0) + 1
        copiedToken[item.id] = token
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedToken[item.id] == token { copiedToken[item.id] = nil }
        }

        NotificationCenter.default.post(
            name: .voiceError,
            object: nil,
            userInfo: ["message": "Raw transcript copied — paste with ⌘V"]
        )
    }

    private func handleDeleteRow(_ item: RecentDictation) {
        RecentDictations.delete(id: item.id)
        recordingState.recentDictationsTick &+= 1
        if expandedID == item.id { expandedID = nil }
    }
}

// MARK: - Permissions banner
//
// Shown at the top of BigMenuWindow when ANY required grant
// (Accessibility, Microphone, Input Monitoring) is missing. Tapping presents
// the full PermissionsView sheet. The banner reads as an actionable warning —
// orange tint, shield icon, chevron — distinct enough from the stat-card row
// that users don't mistake it for content. Background and border opacity are
// tuned to be readable in both light + dark scheme without theming hooks.
private struct PermissionsBanner: View {
    var onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Sp.md) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: Sp.xxs) {
                    Text("Set up VOICE")
                        .font(.bodyMedium.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to grant required permissions")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Sp.lg)
            .padding(.vertical, Sp.md)
            .background(
                RoundedRectangle(cornerRadius: CardShape.corner)
                    .fill(Color.orange.opacity(isHovering ? 0.12 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CardShape.corner)
                    .strokeBorder(Color.orange.opacity(0.25), lineWidth: CardShape.borderUnselected)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: CardShape.corner))
        .onHover { isHovering = $0 }
        .help("Open the VOICE permission setup")
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.serifValue)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.bodyBase)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Sp.lg)
        // Equal width via maxWidth and a shared baseline height so the three
        // cards stay consistent regardless of value length. minHeight tuned
        // for the 32pt serifValue (icon + value + 2-line label fits without
        // wasted space). .topLeading keeps the icon pinned during reflow.
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        // Solid (not translucent) surface. Sits on AppShellBackground at a
        // slightly different tint so the cards read as real surfaces, not
        // glassy overlays. Hairline border anchors the edge without shouting.
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(scheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: CardShape.borderUnselected)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Dictation row (collapsed + expanded)

struct DictationRow: View {
    let item: RecentDictation
    let isLast: Bool
    let isExpanded: Bool
    let showCopied: Bool
    var onTap: () -> Void
    /// Fired by the explicit Copy button + context menu items. Parent uses
    /// this to flash the "Copied" indicator. Optional so previews / callers
    /// that don't wire it still compile.
    var onCopied: (() -> Void)? = nil
    var onRevertToRaw: ((String) -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovering: Bool = false

    private var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: item.timestamp)
    }

    /// Reflection-safe lookup for optional fields that may not yet exist on
    /// RecentDictation (a parallel agent is adding cleanupLevelUsed +
    /// personalityStyleUsed). Returns nil if the field is absent or non-String.
    private func optString(_ field: String) -> String? {
        let m = Mirror(reflecting: item)
        return m.children.first(where: { $0.label == field })?.value as? String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Sp.md) {
                Text(timeString)
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                    // 1pt nudge keeps the time baseline level with the body
                    // text, which sits a hair lower due to its lineSpacing.
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: Sp.sm) {
                    Text(showCopied ? "Copied" : item.text)
                        .font(.bodyBase)
                        .foregroundStyle(showCopied ? Color.green : Color.primary.opacity(0.92))
                        .lineLimit(isExpanded ? nil : 3)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)

                    if isExpanded {
                        // Metadata badges show the cleanup level + personality
                        // used for this dictation. Always render this row when
                        // expanded so the Copy button is reachable even for
                        // legacy entries that have no polish metadata.
                        let levelUsed   = optString("cleanupLevelUsed")
                        let styleUsed   = optString("personalityStyleUsed")
                        HStack(spacing: Sp.xs) {
                            if let level = levelUsed {
                                MetaBadge(icon: "sparkles", label: level)
                            }
                            if let style = styleUsed {
                                MetaBadge(icon: "person.crop.circle", label: style)
                            }
                            if let ms = item.polishMs {
                                MetaBadge(icon: "stopwatch", label: "\(ms)ms")
                            }
                            Spacer()
                            // Explicit copy affordance. Copying is no longer
                            // a side effect of clicking the row.
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(item.text, forType: .string)
                                onCopied?()
                            } label: {
                                HStack(spacing: Sp.xs) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                    Text("Copy")
                                        .font(.bodySmall)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Sp.sm)
                                .padding(.vertical, Sp.xs)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help("Copy polished text to clipboard")
                        }

                        HStack(spacing: Sp.xs) {
                            if item.parakeetRawText != nil {
                                StageChip(label: "Parakeet", accent: false)
                            }
                            if let raw = item.rawText, raw != item.text {
                                StageChip(label: "TextFormat", accent: false)
                            }
                            if let ms = item.polishMs {
                                StageChip(label: "Qwen3 \(ms)ms", accent: true)
                            }
                        }

                        if item.hasPolishDiff, let raw = item.rawText {
                            VStack(alignment: .leading, spacing: Sp.sm) {
                                Divider().opacity(0.3)
                                Text("WHAT POLISH CHANGED")
                                    .font(.label)
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .top, spacing: Sp.md) {
                                    VStack(alignment: .leading, spacing: Sp.xs) {
                                        Label("Raw", systemImage: "waveform")
                                            .font(.badge)
                                            .foregroundStyle(.secondary)
                                        Text(raw)
                                            .font(.bodySmall)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    VStack(alignment: .leading, spacing: Sp.xs) {
                                        Label("Polished", systemImage: "sparkles")
                                            .font(.badge)
                                            .foregroundStyle(.primary)
                                        Text(item.text)
                                            .font(.bodyMedium)
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, Sp.sm)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Sp.md)
            .padding(.horizontal, Sp.xl)
            .background(isHovering ? Color.primary.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .onHover { isHovering = $0 }
            .contextMenu {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(item.text, forType: .string)
                    onCopied?()
                } label: { Label("Copy polished text", systemImage: "doc.on.doc") }

                if let raw = item.rawText, !raw.isEmpty {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(raw, forType: .string)
                        onCopied?()
                    } label: { Label("Copy raw transcript", systemImage: "waveform") }
                }

                Divider()

                Button {
                    onRevertToRaw?(item.rawText ?? item.text)
                } label: { Label("Revert to raw", systemImage: "arrow.uturn.backward") }
                    .disabled(item.rawText == nil)

                Button(role: .destructive) { onDelete?() } label: {
                    Label("Delete dictation", systemImage: "trash")
                }
            }

            if !isLast {
                // 96 = horizontal outer padding (Sp.xl = 20) + time column
                // width (64) + inner HStack spacing (Sp.md = 12). Anchored
                // here so the hairline starts exactly under the body text,
                // never under the timestamp column.
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                    .padding(.leading, 96)
            }
        }
    }
}

private struct StageChip: View {
    let label: String
    let accent: Bool
    var body: some View {
        Text(label)
            .font(.badge)
            .foregroundStyle(accent ? Color.accentColor : .secondary)
            .padding(.horizontal, Sp.sm)
            .padding(.vertical, Sp.xxs)
            .background((accent ? Color.accentColor : Color.secondary).opacity(0.14), in: Capsule())
    }
}

/// Compact metadata pill. Shown above the StageChip row to surface the
/// cleanup level and personality used for this dictation, plus polish time.
private struct MetaBadge: View {
    let icon: String
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.badge)
        }
        .padding(.horizontal, Sp.sm)
        .padding(.vertical, 3)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.04), in: Capsule())
    }
}

// MARK: - Settings sheet
//
// Reached via the toolbar's "…" overflow → Settings…. Same surface area as
// the previous sheet PLUS the Pill Style picker (relocated from the main
// window) and an explicit "polishEnabled" toggle wired to @AppStorage so the
// latency-saving kill switch on TextFormatter works from a stable key.

private struct SettingsSheet: View {
    @Bindable var recordingState: RecordingState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("autoPaste")        private var autoPaste: Bool = true
    @AppStorage("autoCopy")         private var autoCopy: Bool = true
    @AppStorage("soundEffectsEnabled") private var soundEffects: Bool = true
    @AppStorage("llmPolishEnabled") private var llmPolishEnabled: Bool = LLMPolisher.isAvailable
    /// Latency kill switch for the Qwen3 polish stage. Distinct key from
    /// `llmPolishEnabled` (which the polisher itself reads) — this is the
    /// UI-facing fast-paste toggle the latency agent reads in finishRecording.
    @AppStorage("polishEnabled")    private var polishEnabled: Bool = true
    @AppStorage("cleanupLevel")     private var cleanupLevel: String = "medium"
    @AppStorage("personalityStyle") private var personality: String = "neutral"
    /// Experimental: 2-pass goal-first polish. Splits dictation into topic
    /// chunks, classifies each intent, then routes. Currently logs only;
    /// intent-specific polish prompts are not wired yet.
    @AppStorage("useGoalFirstPolish") private var useGoalFirstPolish: Bool = false

    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var refreshTimer: Timer?

    /// Always-visible permissions section is driven by the shared service so
    /// status stays in sync with the top-of-window banner. Settings continues
    /// to own a periodic 1.5s refresh (in case the user grants a permission
    /// through System Settings while this sheet is open).
    @State private var permissions = PermissionsService.shared
    @State private var showFullPermissionsSheet = false

    // Debug: polish replay harness. Lazy — only loads cases when the user
    // opens the sheet.
    @State private var showPolishReplay: Bool = false

    // Hotkey bindings — inlined from the (removed) ChangeHotkeysSheet so the
    // hotkey UI lives directly inside Settings instead of a nested sheet.
    @State private var pttBindings:  [CapturedHotkey] = HotkeyRole.pushToTalk.loadBindings()
    @State private var lockBindings: [CapturedHotkey] = HotkeyRole.handsFree.loadBindings()

    private var polishStatusColor: Color {
        switch Qwen3Polisher.availabilityStatus {
        case .available:             return .green
        case .downloading, .loading: return .orange
        case .notDownloaded:         return .yellow
        case .error:                 return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.serifTitle)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.top, Sp.xl)
            .padding(.bottom, Sp.lg)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 1. Hotkeys (inlined, replaces the old nested sheet).
                    // Two role cards stacked vertically so each gets the full
                    // width for binding chips and the editing controls.
                    // Visual density matches the cleanup/personality cards.
                    section("Hotkeys") {
                        VStack(spacing: Sp.md) {
                            HotkeyRoleCard(role: .pushToTalk, bindings: $pttBindings)
                            HotkeyRoleCard(role: .handsFree,  bindings: $lockBindings)
                        }
                    }

                    Divider()

                    // 2. AI Cleanup (horizontal row of cards).
                    section("AI cleanup") {
                        VStack(alignment: .leading, spacing: Sp.md) {
                            HStack(alignment: .top, spacing: Sp.md) {
                                ForEach(CleanupLevel.allCases) { level in
                                    CleanupCard(
                                        level: level,
                                        tagline: taglineFor(level),
                                        isSelected: cleanupLevel == level.rawValue,
                                        onTap: { cleanupLevel = level.rawValue }
                                    )
                                }
                            }
                            toggle("Goal-first polish (experimental)", isOn: $useGoalFirstPolish)
                        }
                    }

                    Divider()

                    // 3. Writing personality (horizontal row of cards).
                    section("Writing personality") {
                        HStack(alignment: .top, spacing: Sp.md) {
                            ForEach(PersonalityStyle.allCases) { style in
                                PersonalityCard(
                                    style: style,
                                    tagline: tagline(for: style),
                                    bubbleTint: bubbleTint(for: style),
                                    avatarTint: avatarTint(for: style),
                                    initial: "M",
                                    isSelected: personality == style.rawValue,
                                    onTap: { personality = style.rawValue }
                                )
                            }
                        }
                    }

                    Divider()

                    // 4. Output
                    section("Output") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            toggle("Paste automatically", isOn: $autoPaste)
                            toggle("Copy to clipboard", isOn: $autoCopy)
                            toggle("Sound effects", isOn: $soundEffects)
                            VStack(alignment: .leading, spacing: Sp.xs) {
                                toggle("Smart corrections", isOn: $llmPolishEnabled)
                                HStack(spacing: Sp.xs) {
                                    Circle()
                                        .fill(polishStatusColor)
                                        .frame(width: 6, height: 6)
                                    Text("Status: \(Qwen3Polisher.availabilityStatus.displayLabel)")
                                        .font(.bodySmall)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, Sp.xl)
                            }
                        }
                    }

                    Divider()

                    // 5. Pill
                    section("Pill style") {
                        PillSkinSelector()
                    }

                    Divider()

                    // 5a. Debug — Polish Replay window for verifying polish
                    // quality against a golden-case battery. Lazy load so the
                    // view does not block app launch.
                    section("Debug") {
                        Button {
                            showPolishReplay = true
                        } label: {
                            HStack(spacing: Sp.xs) {
                                Image(systemName: "wand.and.stars")
                                Text("Polish Replay…")
                                    .font(.bodyMedium)
                            }
                            .padding(.horizontal, Sp.md)
                            .padding(.vertical, Sp.xs)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Divider()

                    // 6. Permissions
                    //
                    // Inline always-visible grid. Mirrors the top-of-window
                    // banner so users can re-check status from a known place
                    // even after `allGranted` removes the banner. The "Set up"
                    // button opens the full PermissionsView sheet (same flow
                    // as the banner) for one-stop reauthorization.
                    section("Permissions") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            permissionRow(
                                "Microphone",
                                granted: permissions.microphone == .granted
                            ) {
                                openPane("Privacy_Microphone")
                            }
                            permissionRow(
                                "Accessibility",
                                granted: permissions.accessibility == .granted
                            ) {
                                openPane("Privacy_Accessibility")
                            }
                            permissionRow(
                                "Input Monitoring",
                                granted: permissions.inputMonitoring == .granted
                            ) {
                                openPane("Privacy_ListenEvent")
                            }

                            if !permissions.allGranted {
                                Button {
                                    showFullPermissionsSheet = true
                                } label: {
                                    Text("Open setup")
                                        .font(.bodyMedium)
                                        .padding(.horizontal, Sp.md)
                                        .padding(.vertical, Sp.xs)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, Sp.xs)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("VOICE \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.bodySmall)
                    .foregroundStyle(.quaternary)
                Spacer()
                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(.bodyMedium)
                        .padding(.horizontal, Sp.md)
                        .padding(.vertical, Sp.xs)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.vertical, Sp.md)
        }
        .frame(width: 820, height: 720)
        // Same solid app-shell surface as the main window so the sheet reads
        // as part of the app, not a stock translucent dialog.
        .background(AppShellBackground().ignoresSafeArea())
        .sheet(isPresented: $showFullPermissionsSheet) {
            PermissionsView(onDone: { showFullPermissionsSheet = false })
                .frame(minWidth: 560, minHeight: 540)
        }
        .sheet(isPresented: $showPolishReplay) {
            PolishReplayView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                refreshPermissions()
                permissions.refresh()
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                DispatchQueue.main.async {
                    refreshPermissions()
                    permissions.refresh()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: pttBindings)  { _, new in HotkeyRole.pushToTalk.saveBindings(new) }
        .onChange(of: lockBindings) { _, new in HotkeyRole.handsFree.saveBindings(new) }
    }

    @ViewBuilder
    private func section<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            Text(label.uppercased())
                .font(.label)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.lg)
    }

    @ViewBuilder
    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.bodyBase)
                .foregroundStyle(.primary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    @ViewBuilder
    private func permissionRow(_ label: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: Sp.sm) {
            Circle()
                .fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: granted ? "checkmark" : "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(granted ? .green : .orange)
                )
            Text(label)
                .font(.bodyBase)
                .foregroundStyle(.primary)
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(.borderless)
                    .font(.bodyMedium)
                    .foregroundStyle(Color.accentColor)
                    .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.bodySmall)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Per-level / per-style local helpers
    //
    // A parallel agent is adding `tagline`, `bubbleTint`, `avatarTint` to
    // CleanupLevel / PersonalityStyle in VoiceApp.swift. Until then these
    // local helpers keep the cards working with no cross-file dependency.

    fileprivate func taglineFor(_ level: CleanupLevel) -> String {
        switch level {
        case .none:   return "Transcribes exactly what you said, including mistakes"
        case .light:  return "Cleans up filler words and grammar"
        case .medium: return "Edits for clarity and conciseness"
        case .high:   return "Rewrites for brevity and polish"
        }
    }

    fileprivate func tagline(for s: PersonalityStyle) -> String {
        switch s {
        case .neutral:  return "Balanced everyday voice"
        case .formal:   return "Caps + full punctuation"
        case .casual:   return "Light caps, light punctuation"
        case .excited:  return "Energetic + punchy"
        }
    }

    fileprivate func bubbleTint(for s: PersonalityStyle) -> Color {
        switch s {
        case .neutral:  return Color.gray.opacity(0.12)
        case .formal:   return Color.purple.opacity(0.10)
        case .casual:   return Color.pink.opacity(0.10)
        case .excited:  return Color.orange.opacity(0.12)
        }
    }

    fileprivate func avatarTint(for s: PersonalityStyle) -> Color {
        switch s {
        case .neutral:  return Color.gray
        case .formal:   return Color(red: 0.62, green: 0.55, blue: 0.95)
        case .casual:   return Color(red: 0.95, green: 0.65, blue: 0.78)
        case .excited:  return Color(red: 0.95, green: 0.6, blue: 0.35)
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
    }

    private func openPane(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Cleanup card (Wispr-style)
//
// One per CleanupLevel. Serif title + sans tagline, with the level's
// "after" example shown inside a tinted speech-bubble. Selection is a
// solid border (no garish fill).

private struct CleanupCard: View {
    let level: CleanupLevel
    let tagline: String
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: Sp.xs) {
                Text(level.displayName)
                    .font(.serifSection)
                Text(tagline)
                    .font(.bodyBase)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            Text(level.example.after)
                .font(.sans(11, weight: .regular).italic())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Sp.md)
                .padding(.vertical, Sp.sm)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                )
        }
        .padding(Sp.lg)
        // Shared baseline height with PersonalityCard so the two grids read
        // as one visual rhythm. 190 fits the tallest tagline + example bubble
        // without forcing a vertical stretch on shorter variants.
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(scheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? CardShape.borderSelected : CardShape.borderUnselected
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: CardShape.corner))
        .onTapGesture { onTap() }
    }
}

// MARK: - Personality card (Wispr-style)
//
// Serif title, sans "tagline" descriptor (e.g. "Caps + Punctuation"), an
// italic example bubble in a per-style tint, and a small colored initial
// avatar bottom-right. Selection shows a clear accent border — no emoji.

private struct PersonalityCard: View {
    let style: PersonalityStyle
    let tagline: String
    let bubbleTint: Color
    let avatarTint: Color
    let initial: String
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: Sp.xs) {
                Text(style.displayName)
                    .font(.serifSection)
                Text(tagline)
                    .font(.bodyBase)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Text(style.example.after)
                .font(.sans(11, weight: .regular).italic())
                .padding(.horizontal, Sp.md)
                .padding(.vertical, Sp.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(bubbleTint)
                )

            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(avatarTint)
                        .frame(width: 28, height: 28)
                    Text(initial)
                        // Inline literal: this is a single-character avatar
                        // glyph that must sit slightly heavier than bodyMedium
                        // (13/.medium) so it reads inside the 28pt circle.
                        .font(.sans(13, weight: .semibold))
                        // Literal white kept here: avatar tints are
                        // saturated colors that need a high-contrast glyph
                        // regardless of the system theme.
                        .foregroundStyle(Color.white)
                }
            }
        }
        .padding(Sp.lg)
        // Matches CleanupCard.minHeight so the two card grids share an
        // identical rhythm. The avatar strip adds height naturally; without
        // a shared baseline the personality cards would always read taller.
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(scheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? CardShape.borderSelected : CardShape.borderUnselected
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: CardShape.corner))
        .onTapGesture { onTap() }
    }
}

// MARK: - Hotkey role card (inlined into Settings)
//
// One card per HotkeyRole that HotkeyService recognizes:
//   * Push to talk  — hold to record, release to transcribe
//   * Hands-free    — tap to start, tap to stop (lock mode toggle)
//
// Bindings are arbitrary CapturedHotkey values captured live via
// HotkeyCapturer. Each card lives directly inside the Hotkeys section of
// SettingsSheet — there is no longer a nested "Change hotkeys" sheet.

private struct HotkeyRoleCard: View {
    let role: HotkeyRole
    @Binding var bindings: [CapturedHotkey]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: Sp.xs) {
                Text(role.displayName)
                    .font(.bodyMedium)
                Text(role.subtitle)
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: Sp.sm) {
                ForEach(Array(bindings.enumerated()), id: \.element.id) { idx, b in
                    HotkeyBindingRow(
                        binding: b,
                        onChange: { new in
                            if idx < bindings.count {
                                var copy = new
                                copy.id = bindings[idx].id
                                bindings[idx] = copy
                            }
                        },
                        onRemove: { if idx < bindings.count { bindings.remove(at: idx) } }
                    )
                }
                if bindings.isEmpty {
                    Text("No bindings yet. Tap Add another below.")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                bindings.append(CapturedHotkey(keyCode: nil, modifiersRaw: 0))
            } label: {
                Text("Add another")
                    .font(.bodyMedium)
                    .padding(.horizontal, Sp.md)
                    .padding(.vertical, Sp.sm)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(Sp.lg)
        // Matches the surrounding cleanup/personality card surface so the
        // Hotkeys section reads as part of the same card family.
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(scheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: CardShape.borderUnselected)
        )
    }
}

private struct HotkeyBindingRow: View {
    let binding: CapturedHotkey
    var onChange: (CapturedHotkey) -> Void
    var onRemove: () -> Void

    @State private var capturing = false
    @State private var capturer = HotkeyCapturer()

    var body: some View {
        HStack(spacing: Sp.sm) {
            HStack(spacing: Sp.xs) {
                if capturing {
                    Text("Press a key combo… (Esc to cancel)")
                        .font(.bodyMedium)
                        .foregroundStyle(Color.accentColor)
                } else if binding.isEmpty {
                    Text("Tap the pencil to record a hotkey")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(binding.displayChips, id: \.self) { chip in
                        Text(chip)
                            .font(.sans(12, weight: .medium))
                            .padding(.horizontal, Sp.sm)
                            .padding(.vertical, Sp.xs)
                            .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Sp.md)
            .padding(.vertical, Sp.xs)
            .background(
                Color.secondary.opacity(capturing ? 0.10 : 0.04),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(capturing ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18), lineWidth: 1)
            )

            Button {
                if capturing { capturer.cancel(); capturing = false }
                else { startCapture() }
            } label: {
                Image(systemName: capturing ? "xmark" : "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button { onRemove() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            if binding.isEmpty { startCapture() }
        }
    }

    private func startCapture() {
        capturing = true
        capturer.startCapture { result in
            capturing = false
            if let captured = result {
                onChange(captured)
            } else if binding.isEmpty {
                // Cancelled empty placeholder — remove
                onRemove()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    BigMenuWindow(recordingState: RecordingState())
}
